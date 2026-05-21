You are an Opus-class review agent analyzing a C2PA upstream schema change for its impact on the c2pa-knowledge-graph repository.

## Context

The C2PA specification publishes schema artifacts (CDDL, crJSON JSON Schema, softbinding OpenAPI) as a ZIP at spec.c2pa.org. The triage agent detected a content change and classified it as: ITEM_TYPE.

Summary: ITEM_SUMMARY

## Paths

| Resource | Path |
|-|-|
| KG repo | /home/developer/code/c2pa-knowledge-graph/ |
| Monitor state | /home/developer/code/agent-monitor/state/c2pa-kg-upstream/ |
| New schemas | /home/developer/code/agent-monitor/state/c2pa-kg-upstream/prev-schemas/ |
| Triage report | (find with ls -t below) |

## Your task

### 1. Read the triage report

```bash
REPORT=$(ls -t /home/developer/code/agent-monitor/logs/c2pa-kg-upstream/report-*.md 2>/dev/null | head -1)
[ -n "$REPORT" ] && cat "$REPORT"
```

Read the delta for structured data:

```bash
STATE=/home/developer/code/agent-monitor/state/c2pa-kg-upstream
cat "$STATE/delta.json" 2>/dev/null || echo "No delta file"
echo "-"
echo "Version: $(cat $STATE/latest-version.txt)"
echo "Build date: $(cat $STATE/build-date.txt)"
echo "Checksum: $(cat $STATE/checksum.txt)"
```

### 2. Deep-diff each changed CDDL file

For every CDDL file the triage report flagged as changed, read both the old and new versions. Parse the actual structural changes:

```bash
SCHEMAS=/home/developer/code/agent-monitor/state/c2pa-kg-upstream/prev-schemas
# The triage agent already replaced prev-schemas with the new extraction.
# Read the new CDDL files directly:
ls "$SCHEMAS/cddl/"
```

For each CDDL file, identify:
- **New map definitions** (lines matching `name = { ... }`) - these become new KG entities
- **New/changed fields** within existing maps - these become property additions or modifications
- **New type-choice plugs** (lines matching `name /= "value"`) - these become new enum values
- **Changed optionality** (`?` added or removed) - this changes property cardinality
- **Removed definitions or fields** - these need KG entity/property removal

### 3. Analyze crJSON schema changes

If the crJSON schema changed:

```bash
SCHEMAS=/home/developer/code/agent-monitor/state/c2pa-kg-upstream/prev-schemas
if [ -f "$SCHEMAS/crJSON/partials/crJSON.schema.json" ]; then
  python3 -c "
import json
d = json.loads(open('$SCHEMAS/crJSON/partials/crJSON.schema.json').read())
defs = d.get('\$defs', d.get('definitions', {}))
print(f'crJSON types: {len(defs)}')
for name in sorted(defs.keys()):
    props = defs[name].get('properties', {})
    req = defs[name].get('required', [])
    print(f'  {name}: {len(props)} properties, {len(req)} required')
"
fi
```

Compare against what the KG tracks. The crJSON schema defines a JSON-LD view of C2PA manifests. New definitions here may correspond to entities the KG already has (from CDDL) or may represent new derived types.

### 4. Compare against current KG entities

```bash
VERSION=$(cat /home/developer/code/agent-monitor/state/c2pa-kg-upstream/latest-version.txt)
KG=/home/developer/code/c2pa-knowledge-graph

python3 << 'PYEOF'
import json
from pathlib import Path

version = Path("/home/developer/code/agent-monitor/state/c2pa-kg-upstream/latest-version.txt").read_text().strip()
kg_path = Path(f"/home/developer/code/c2pa-knowledge-graph/versions/{version}/metadata.json")

if kg_path.exists():
    kg = json.loads(kg_path.read_text())
    print(f"KG version {version}:")
    print(f"  Entities: {len(kg['entities'])}")
    print(f"  Relationships: {len(kg['relationships'])}")
    print(f"  Validation rules: {len(kg['validation_rules'])}")
    print(f"  Enum types: {len(kg['enum_types'])}")
    print(f"  Type aliases: {len(kg['type_aliases'])}")
    print(f"  Status codes: {len(kg['status_codes'])}")
    print()
    print("Entity names:")
    for name in sorted(kg['entities'].keys()):
        ent = kg['entities'][name]
        props = len(ent.get('properties', []))
        print(f"  {name}: {props} properties")
else:
    print(f"No KG artifacts for version {version}")
PYEOF
```

### 5. Attempt pipeline regeneration (best effort)

Try running the KG pipeline against the new schemas. The pipeline supports two source modes:
1. **CDDL + HTML** (public site) - use extracted schemas ZIP for CDDL/crJSON and the rendered HTML spec for validation rules and status codes
2. **specs-core** (private repo) - traditional full-source mode

Download the rendered HTML spec and regenerate:

```bash
cd /home/developer/code/c2pa-knowledge-graph
VERSION=$(cat /home/developer/code/agent-monitor/state/c2pa-kg-upstream/latest-version.txt)
SCHEMAS=/home/developer/code/agent-monitor/state/c2pa-kg-upstream/prev-schemas

# Download the rendered HTML spec for validation rules + status codes
HTML_URL="https://spec.c2pa.org/specifications/specifications/${VERSION}/specs/C2PA_Specification.html"
curl -sL "$HTML_URL" -o /tmp/c2pa_spec_${VERSION}.html
echo "HTML spec: $(wc -c < /tmp/c2pa_spec_${VERSION}.html) bytes"

# Run pipeline with -html-spec for validation content
uv run c2pa-kg generate \
  -spec-source "$SCHEMAS" \
  -version "$VERSION" \
  -html-spec "/tmp/c2pa_spec_${VERSION}.html" \
  -output-dir /tmp/kg-regen-output 2>&1 || echo "PIPELINE_FAILED"
```

If regeneration succeeds, diff the output against existing artifacts:

```bash
if [ -d "/tmp/kg-regen-output/$VERSION" ]; then
  KG=/home/developer/code/c2pa-knowledge-graph
  python3 << 'PYEOF'
import json
from pathlib import Path

version = Path("/home/developer/code/agent-monitor/state/c2pa-kg-upstream/latest-version.txt").read_text().strip()
old_path = Path(f"/home/developer/code/c2pa-knowledge-graph/versions/{version}/metadata.json")
new_path = Path(f"/tmp/kg-regen-output/{version}/metadata.json")

if old_path.exists() and new_path.exists():
    old = json.loads(old_path.read_text())
    new = json.loads(new_path.read_text())

    old_ents = set(old['entities'].keys())
    new_ents = set(new['entities'].keys())
    print(f"Entities added: {sorted(new_ents - old_ents)}")
    print(f"Entities removed: {sorted(old_ents - new_ents)}")

    # Check for property changes in shared entities
    for name in sorted(old_ents & new_ents):
        old_props = {p['name'] for p in old['entities'][name].get('properties', [])}
        new_props = {p['name'] for p in new['entities'][name].get('properties', [])}
        added = new_props - old_props
        removed = old_props - new_props
        if added or removed:
            print(f"  {name}: +{sorted(added)} -{sorted(removed)}")

    old_enums = set(old['enum_types'].keys())
    new_enums = set(new['enum_types'].keys())
    print(f"\nEnums added: {sorted(new_enums - old_enums)}")
    print(f"Enums removed: {sorted(old_enums - new_enums)}")

    print(f"\nRules: {len(old['validation_rules'])} -> {len(new['validation_rules'])}")
else:
    print("Cannot diff: missing old or new metadata.json")
PYEOF
fi
```

If the pipeline fails, note the error and proceed with manual CDDL analysis.

### 6. Assess predicates impact

Check whether changed validation rules affect existing predicates:

```bash
VERSION=$(cat /home/developer/code/agent-monitor/state/c2pa-kg-upstream/latest-version.txt)
PRED_FILE="/home/developer/code/c2pa-knowledge-graph/versions/$VERSION/predicates.json"
if [ -f "$PRED_FILE" ]; then
  python3 -c "
import json
d = json.loads(open('$PRED_FILE').read())
total = sum(len(fam['predicates']) for fam in d.get('format_families', {}).values())
total += len(d.get('cross_cutting', {}).get('predicates', []))
print(f'Current predicates: {total}')
print(f'Coverage: {d.get(\"coverage_summary\", {}).get(\"rules_covered\", \"unknown\")}')
"
fi
```

### 7. Write review

Write your analysis to REVIEW_OUTPUT_PATH. Structure:

```markdown
## C2PA KG Upstream Review: ITEM_SUMMARY

**Spec version:** X.Y
**Build date:** YYYYMMDD
**Change type:** ITEM_TYPE
**Pipeline regeneration:** succeeded | failed (reason)

### CDDL schema changes

For each changed file, cite specific definitions and fields:

- **file.cddl**
  - Added: `field-name` (type: tstr, optionality: required) in `MapName`
  - Modified: `field-name` changed optionality from required to optional in `MapName`
  - New map: `NewMapName` with fields: field1 (tstr), field2 (uint), field3 (?bstr)
  - New enum value: `"new-value"` added to `type-choice-name`

### KG entity impact

| Entity | Status | Details |
|-|-|-|
| ExistingEntity | modified | Added property `foo` (string, optional) |
| NewEntity | new | 5 properties, referenced by ClaimMap |
| OldEntity | unchanged | - |

### Validation rules impact

- N existing rules unaffected
- N rules may need predicate updates due to field changes
- N potential new rules implied by new SHALL/MUST constraints in CDDL comments

### crJSON schema impact

- N new type definitions (list names)
- N modified definitions (list changes)
- Coverage gap: these crJSON types have no corresponding KG entity: [list]

### Recommended actions

Ordered by priority:

1. [ ] Regenerate metadata.json, ontology.ttl, context.jsonld from updated CDDL
2. [ ] Add N new entities to KG: [names]
3. [ ] Update N existing entities: [names with changes]
4. [ ] Add crJSON type definitions to KG: [names]
5. [ ] Draft N new predicates for new validation constraints
6. [ ] Update spec-version.json with build_date and source_checksum
7. [ ] Update SPEC_VERSIONS in versioning/manager.py (if new version)
8. [ ] Tag as v1.X.Y-YYYYMMDD

### Draft spec-version.json

```json
{
  "spec_version": "X.Y",
  "build_date": "YYYYMMDD",
  "source_checksum": "sha256:abcd...",
  "artifacts": {
    "metadata": "versions/X.Y/metadata.json",
    "ontology": "versions/X.Y/ontology.ttl",
    "context": "versions/X.Y/context.jsonld",
    "validation_rules": "versions/X.Y/validation-rules.json",
    "predicates": "versions/X.Y/predicates.json"
  }
}
```

**Summary:** One sentence on overall impact.
**Recommended action:** [Regenerate and tag | Review changes before proceeding | No KG update needed]
```

Be precise. Cite CDDL definition names, field names, and types. Do not pad with generic observations. If the pipeline succeeded, use the diff output as the primary source of truth. If it failed, base the analysis on manual CDDL reading.

### 8. Create GitHub issue for tracking

If the change requires KG updates (recommended action is NOT "No KG update needed"), create a GitHub issue on the c2pa-knowledge-graph repo:

```bash
VERSION=$(cat /home/developer/code/agent-monitor/state/c2pa-kg-upstream/latest-version.txt)
BUILD_DATE=$(cat /home/developer/code/agent-monitor/state/c2pa-kg-upstream/build-date.txt)
CHECKSUM=$(cat /home/developer/code/agent-monitor/state/c2pa-kg-upstream/checksum.txt)

gh issue create \
  -repo encypherai/c2pa-knowledge-graph \
  -title "Upstream spec update: C2PA ${VERSION} (${BUILD_DATE})" \
  -label "upstream-update" \
  -body "$(cat <<ISSUEEOF
## Upstream spec change detected

**Version:** ${VERSION}
**Build date:** ${BUILD_DATE}
**Source checksum:** sha256:${CHECKSUM}
**Change type:** ITEM_TYPE

## Summary

ITEM_SUMMARY

## Review findings

$(cat REVIEW_OUTPUT_PATH 2>/dev/null || echo 'Review output not available.')

-
*Auto-created by c2pa-kg-upstream monitor*
ISSUEEOF
)" 2>&1 || echo "ISSUE_CREATION_FAILED"
```

If the `upstream-update` label does not exist, create it first:

```bash
gh label create upstream-update \
  -repo encypherai/c2pa-knowledge-graph \
  -description "Automated upstream spec change detection" \
  -color "0E8A16" 2>/dev/null || true
```

Skip issue creation if recommended action is "No KG update needed."
