#!/usr/bin/env bash
# Source runner: discovers enabled sources, executes them, merges output.
#
# Usage: _runner.sh <mode> <output-dir>
#   mode:       "weekly" or "anomaly"
#   output-dir: directory to write individual source JSONs and merged output
#
# Reads sources.conf from the monitor directory to determine which sources
# are enabled. Each source is a Python script in this directory that accepts:
#   --mode <weekly|anomaly> --domain <domain> --output <path>
#
# Outputs:
#   <output-dir>/<source>.json   — per-source raw output
#   <output-dir>/merged.json     — combined array of all source outputs

set -euo pipefail

MODE="${1:?Usage: $0 <weekly|anomaly> <output-dir>}"
OUTPUT_DIR="${2:?Usage: $0 <weekly|anomaly> <output-dir>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONITOR_DIR="$(dirname "$SCRIPT_DIR")"
SOURCES_CONF="$MONITOR_DIR/sources.conf"

# Load monitor .env for API keys
if [ -f "$MONITOR_DIR/.env" ]; then
  set -a; source "$MONITOR_DIR/.env"; set +a
fi

# Load global .env as fallback
GLOBAL_ENV="$(dirname "$(dirname "$MONITOR_DIR")")/.env"
if [ -f "$GLOBAL_ENV" ]; then
  set -a; source "$GLOBAL_ENV"; set +a
fi

DOMAIN="${MARKETING_INTEL_DOMAIN:-encypher.com}"

mkdir -p "$OUTPUT_DIR"

# Parse sources.conf: lines like "ga4=1" or "gsc=0"
declare -A ENABLED_SOURCES
if [ -f "$SOURCES_CONF" ]; then
  while IFS='=' read -r key value; do
    # Skip comments and empty lines
    [[ "$key" =~ ^[[:space:]]*# ]] && continue
    [[ -z "$key" ]] && continue
    key=$(echo "$key" | xargs)
    value=$(echo "$value" | xargs)
    ENABLED_SOURCES["$key"]="$value"
  done < "$SOURCES_CONF"
else
  echo "WARNING: No sources.conf found at $SOURCES_CONF. Enabling all sources." >&2
  for src in "$SCRIPT_DIR"/*.py; do
    [ -f "$src" ] || continue
    name=$(basename "$src" .py)
    ENABLED_SOURCES["$name"]=1
  done
fi

# Run each enabled source
COLLECTED=0
FAILED=0
SOURCES_RUN=()

for name in "${!ENABLED_SOURCES[@]}"; do
  [ "${ENABLED_SOURCES[$name]}" != "1" ] && continue

  src="$SCRIPT_DIR/${name}.py"
  if [ ! -f "$src" ]; then
    echo "WARNING: Source '$name' enabled but $src not found. Skipping." >&2
    continue
  fi

  out_file="$OUTPUT_DIR/${name}.json"
  echo "  Collecting: $name ($MODE mode)..."

  if python3 "$src" --mode "$MODE" --domain "$DOMAIN" --output "$out_file" 2>&1; then
    if [ -f "$out_file" ] && [ -s "$out_file" ]; then
      COLLECTED=$((COLLECTED + 1))
      SOURCES_RUN+=("$name")
    else
      echo "  WARNING: $name produced no output." >&2
      FAILED=$((FAILED + 1))
    fi
  else
    echo "  ERROR: $name failed." >&2
    FAILED=$((FAILED + 1))
    # Write error stub so the triage agent knows this source failed
    cat > "$out_file" <<ERRJSON
{"source": "$name", "domain": "$DOMAIN", "mode": "$MODE", "period": {}, "collected_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)", "error": "Source collection failed", "data": {}}
ERRJSON
  fi
done

# Merge all source outputs into a single array
echo '[]' > "$OUTPUT_DIR/merged.json"
for name in "${SOURCES_RUN[@]}"; do
  out_file="$OUTPUT_DIR/${name}.json"
  if [ -f "$out_file" ]; then
    jq -s '.[0] + [.[1]]' "$OUTPUT_DIR/merged.json" "$out_file" > "$OUTPUT_DIR/merged.json.tmp" \
      && mv "$OUTPUT_DIR/merged.json.tmp" "$OUTPUT_DIR/merged.json"
  fi
done

echo "Sources: $COLLECTED collected, $FAILED failed (mode=$MODE, domain=$DOMAIN)"
echo "$COLLECTED"
