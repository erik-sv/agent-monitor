You are monitoring the public C2PA specification site for schema changes that affect the c2pa-knowledge-graph repository maintained by Encypher.

## Background

C2PA publishes specification schemas (CDDL definitions, crJSON JSON Schema, softbinding OpenAPI) as a ZIP archive on spec.c2pa.org. Updates sometimes land without a new version number: the spec team rebuilds the site with corrections or additions to the same version. We call these "intra-version updates."

We track changes by checksum and Last-Modified date. When the ZIP content changes, the knowledge graph may need regeneration.

## Paths

- State directory: /home/developer/code/agent-monitor/state/c2pa-kg-upstream/
- Knowledge graph repo: /home/developer/code/c2pa-knowledge-graph/
- Site base URL: https://spec.c2pa.org/specifications/specifications

## State files

| File | Contents |
|-|-|
| `discovered-version.txt` | Version found by pre-check (just written) |
| `latest-version.txt` | Version we last processed |
| `checksum.txt` | SHA256 of last-processed ZIP |
| `last-modified.txt` | Last-Modified header of last-processed ZIP |
| `content-length.txt` | Content-Length header |
| `build-date.txt` | Parsed date from Last-Modified (YYYYMMDD format) |
| `prev-schemas/` | Extracted contents of last-processed ZIP |

## Instructions

### Step 1: Read current state

```bash
STATE=/home/developer/code/agent-monitor/state/c2pa-kg-upstream
echo "Discovered version: $(cat $STATE/discovered-version.txt 2>/dev/null || echo 'none')"
echo "Stored version: $(cat $STATE/latest-version.txt 2>/dev/null || echo 'none')"
echo "Stored checksum: $(cat $STATE/checksum.txt 2>/dev/null || echo 'none')"
echo "Stored build date: $(cat $STATE/build-date.txt 2>/dev/null || echo 'none')"
```

### Step 2: Download and checksum the ZIP

```bash
VERSION=$(cat /home/developer/code/agent-monitor/state/c2pa-kg-upstream/discovered-version.txt)
ZIP_URL="https://spec.c2pa.org/specifications/specifications/${VERSION}/specs/_attachments/C2PA_Schemas.zip"
curl -sL "$ZIP_URL" -o /tmp/c2pa-schemas-check.zip
NEW_CHECKSUM=$(sha256sum /tmp/c2pa-schemas-check.zip | cut -d' ' -f1)
echo "New checksum: $NEW_CHECKSUM"
```

Compare against stored checksum. If identical, the pre-check triggered on a Last-Modified timestamp change but the content is the same. Update the stored headers, write an empty delta, write a short report noting "false alarm, no content change," and stop.

### Step 3: Extract and diff

If checksum differs, extract and compare:

```bash
mkdir -p /tmp/c2pa-schemas-new
cd /tmp/c2pa-schemas-new && unzip -o /tmp/c2pa-schemas-check.zip 2>/dev/null
```

Compare against previous extraction:

```bash
PREV=/home/developer/code/agent-monitor/state/c2pa-kg-upstream/prev-schemas
if [ -d "$PREV/cddl" ]; then
  # List changed files
  diff -rq "$PREV/cddl" /tmp/c2pa-schemas-new/cddl/ 2>/dev/null || true
  # Show actual diffs for changed CDDL files
  for f in /tmp/c2pa-schemas-new/cddl/*.cddl; do
    BASENAME=$(basename "$f")
    if [ -f "$PREV/cddl/$BASENAME" ]; then
      DELTA=$(diff -u "$PREV/cddl/$BASENAME" "$f" 2>/dev/null || true)
      if [ -n "$DELTA" ]; then
        echo "=== $BASENAME ==="
        echo "$DELTA"
      fi
    else
      echo "=== NEW: $BASENAME ==="
    fi
  done
  # Check for removed files
  for f in "$PREV"/cddl/*.cddl; do
    BASENAME=$(basename "$f")
    [ ! -f "/tmp/c2pa-schemas-new/cddl/$BASENAME" ] && echo "=== REMOVED: $BASENAME ==="
  done
else
  echo "No previous schemas stored. This is the first run."
  ls /tmp/c2pa-schemas-new/cddl/
fi
```

Also check crJSON and softbinding schemas:

```bash
PREV=/home/developer/code/agent-monitor/state/c2pa-kg-upstream/prev-schemas
# crJSON schema
if [ -f "$PREV/crJSON/partials/crJSON.schema.json" ] && [ -f /tmp/c2pa-schemas-new/crJSON/partials/crJSON.schema.json ]; then
  diff -u "$PREV/crJSON/partials/crJSON.schema.json" /tmp/c2pa-schemas-new/crJSON/partials/crJSON.schema.json | head -80 || true
elif [ -f /tmp/c2pa-schemas-new/crJSON/partials/crJSON.schema.json ]; then
  echo "NEW: crJSON schema ($(wc -c < /tmp/c2pa-schemas-new/crJSON/partials/crJSON.schema.json) bytes)"
fi
# Softbinding
for f in /tmp/c2pa-schemas-new/softbinding/partials/*; do
  BASENAME=$(basename "$f")
  if [ -f "$PREV/softbinding/partials/$BASENAME" ]; then
    diff -q "$PREV/softbinding/partials/$BASENAME" "$f" 2>/dev/null || echo "CHANGED: softbinding/$BASENAME"
  else
    echo "NEW: softbinding/$BASENAME"
  fi
done 2>/dev/null || true
```

### Step 4: Compare against current KG

Check what the knowledge graph currently represents for this version:

```bash
KG=/home/developer/code/c2pa-knowledge-graph
VERSION=$(cat /home/developer/code/agent-monitor/state/c2pa-kg-upstream/discovered-version.txt)
if [ -f "$KG/versions/$VERSION/metadata.json" ]; then
  python3 -c "
import json
d = json.loads(open('$KG/versions/$VERSION/metadata.json').read())
print(f'KG entities: {len(d[\"entities\"])}')
print(f'KG rules: {len(d[\"validation_rules\"])}')
print(f'KG enums: {len(d[\"enum_types\"])}')
print(f'KG type aliases: {len(d[\"type_aliases\"])}')
"
else
  echo "No KG artifacts for version $VERSION yet."
fi
```

Count entities in the new CDDL for comparison:

```bash
# Count map definitions (= entities) in new CDDL
grep -c '=' /tmp/c2pa-schemas-new/cddl/*.cddl 2>/dev/null | tail -1 || true
# Count new crJSON definitions
if [ -f /tmp/c2pa-schemas-new/crJSON/partials/crJSON.schema.json ]; then
  python3 -c "
import json
d = json.loads(open('/tmp/c2pa-schemas-new/crJSON/partials/crJSON.schema.json').read())
defs = d.get('\$defs', d.get('definitions', {}))
print(f'crJSON definitions: {len(defs)}')
"
fi
```

### Step 5: Classify the change

Assign one of:
- **new-version** - The version number itself changed (e.g., 2.4 -> 2.5)
- **intra-version-update** - Same version number, different content
- **schema-only** - Only CDDL schema changes (fields, types)
- **crjson-update** - crJSON schema changed (with or without CDDL changes)
- **first-run** - No previous state exists

### Step 6: Update state

```bash
STATE=/home/developer/code/agent-monitor/state/c2pa-kg-upstream
VERSION=$(cat "$STATE/discovered-version.txt")
ZIP_URL="https://spec.c2pa.org/specifications/specifications/${VERSION}/specs/_attachments/C2PA_Schemas.zip"

# Checksum
sha256sum /tmp/c2pa-schemas-check.zip | cut -d' ' -f1 > "$STATE/checksum.txt"

# HTTP headers
HEADERS=$(curl -sI "$ZIP_URL" 2>/dev/null)
echo "$HEADERS" | grep -i "^last-modified:" | sed 's/^[^:]*: *//' | tr -d '\r' > "$STATE/last-modified.txt"
echo "$HEADERS" | grep -i "^content-length:" | awk '{print $2}' | tr -d '\r' > "$STATE/content-length.txt"

# Build date from Last-Modified
LM=$(cat "$STATE/last-modified.txt")
BUILD_DATE=$(date -d "$LM" +%Y%m%d 2>/dev/null || echo "unknown")
echo "$BUILD_DATE" > "$STATE/build-date.txt"

# Version
echo "$VERSION" > "$STATE/latest-version.txt"

# Replace previous schemas with new extraction
rm -rf "$STATE/prev-schemas"
cp -r /tmp/c2pa-schemas-new "$STATE/prev-schemas"
```

### Step 7: Write outputs

You MUST write all three output files.

#### Report -> REPORT_OUTPUT_PATH

```
# C2PA KG Upstream - DATE

**Spec version:** X.Y
**Build date:** YYYYMMDD
**Previous build date:** YYYYMMDD (or "none" if first run)
**Change type:** new-version | intra-version-update | schema-only | crjson-update | first-run
**Checksum:** sha256:abcd...

## Changed CDDL files

For each changed file, one-line summary of what changed:

- **actions.cddl**: Added new action type `c2pa.foo`
- **claim.cddl**: Made `specVersion` field required
- **new-file.cddl**: New entity `BarMap` with 5 properties

## crJSON schema changes

If applicable.

## Current KG coverage

- Entities: N in KG, M map definitions in new CDDL
- Rules: N in KG
- Estimated gap: K new entities, J modified

## Recommended KG tag

v1.X.Y-YYYYMMDD
```

#### Delta -> DELTA_OUTPUT_PATH

One JSON object. Key is `upstream-X.Y-YYYYMMDD`. Set relevance to HIGH if any structural CDDL changes (new/changed map definitions, fields, types) or crJSON schema changes. Set MEDIUM if comments-only or formatting. Set LOW for first-run baseline capture.

```json
{
  "upstream-X.Y-YYYYMMDD": {
    "title": "C2PA X.Y schemas updated (YYYYMMDD)",
    "relevance": "HIGH",
    "type": "intra-version-update",
    "spec_version": "X.Y",
    "build_date": "YYYYMMDD",
    "checksum": "sha256:abcd...",
    "changed_files": ["cddl/actions.cddl"],
    "new_files": ["cddl/new-assertion.cddl"],
    "removed_files": [],
    "summary": "Added new action type, updated claim schema",
    "lastReportedUpdate": "PERIOD_END"
  }
}
```

#### Discord -> DISCORD_OUTPUT_PATH

Write a Discord embed payload. Include only if the change is HIGH relevance.

```json
{
  "embeds": [{
    "title": "C2PA KG: upstream schema update detected",
    "description": "**Version:** X.Y\n**Build date:** YYYYMMDD\n**Type:** intra-version-update\n\n**Changed:** actions.cddl, claim.cddl\n**New:** new-assertion.cddl\n\nReview agent will analyze impact on knowledge graph.",
    "color": 5793266,
    "footer": {"text": "c2pa-kg-upstream | DATE"}
  }]
}
```

If the change is LOW or MEDIUM relevance, or if this is a first-run baseline, write `{}` to DISCORD_OUTPUT_PATH (no notification).

**Important:** Always write all three files, even if empty/minimal.
