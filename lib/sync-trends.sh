#!/usr/bin/env bash
# Sync trends.md to AgentDesk Research Intelligence feed.
# Called after blog writer Phase 1.5 (trends update) completes.
#
# Usage: ./sync-trends.sh /path/to/trends.md
#
# Requires: AGENTDESK_WEBHOOK_URL, AGENTDESK_WEBHOOK_TOKEN (or AGENTDESK_API_URL + auth cookie)
# Falls back to direct API if available.

set -euo pipefail

TRENDS_FILE="${1:-}"
if [ -z "$TRENDS_FILE" ] || [ ! -f "$TRENDS_FILE" ]; then
  echo "Usage: $0 /path/to/trends.md" >&2
  exit 1
fi

# Determine AgentDesk API base
API_BASE="${AGENTDESK_API_URL:-${AGENTDESK_WEBHOOK_URL:-}}"
API_BASE="${API_BASE%/api/monitors/webhook*}"  # Strip webhook path if present
TOKEN="${AGENTDESK_WEBHOOK_TOKEN:-}"

if [ -z "$API_BASE" ]; then
  echo "[sync-trends] No AGENTDESK_API_URL or AGENTDESK_WEBHOOK_URL set. Skipping." >&2
  exit 0
fi

# Parse the markdown table into JSON using awk
TRENDS_JSON=$(awk '
BEGIN { print "["; first=1 }
/^\|[^-]/ && !/Trend.*Category/ {
  gsub(/^\| */, ""); gsub(/ *\| *$/, "");
  n = split($0, cols, / *\| */);
  if (n >= 7 && cols[1] != "Trend") {
    if (!first) print ",";
    first=0;
    gsub(/"/, "\\\"", cols[1]);
    gsub(/"/, "\\\"", cols[2]);
    printf "  {\"name\":\"%s\",\"category\":\"%s\",\"firstSeen\":\"%s\",\"lastSeen\":\"%s\",\"appearances\":\"%s\",\"trajectory\":\"%s\",\"signalStrength\":\"%s\"}", cols[1], cols[2], cols[3], cols[4], cols[5], cols[6], cols[7];
  }
}
END { print "\n]" }
' "$TRENDS_FILE")

COUNT=$(echo "$TRENDS_JSON" | grep -c '"name"' || true)
if [ "$COUNT" -eq 0 ]; then
  echo "[sync-trends] No trends parsed from $TRENDS_FILE" >&2
  exit 0
fi

echo "[sync-trends] Parsed $COUNT trends, syncing to AgentDesk..."

# POST to sync-trends endpoint
RESULT=$(curl -s --connect-timeout 5 --max-time 15 \
  -X POST "${API_BASE}/api/research/sync-trends" \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer ${TOKEN}" \
  -d "{\"trends\": $TRENDS_JSON}" 2>/dev/null || echo '{"error":"connection failed"}')

INGESTED=$(echo "$RESULT" | jq -r '.ingested // empty' 2>/dev/null)
if [ -n "$INGESTED" ]; then
  echo "[sync-trends] Synced $INGESTED trend items to Research Feed."
else
  ERROR=$(echo "$RESULT" | jq -r '.error // "unknown"' 2>/dev/null)
  echo "[sync-trends] Sync failed: $ERROR" >&2
fi
