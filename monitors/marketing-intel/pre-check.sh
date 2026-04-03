#!/usr/bin/env bash
# Pre-check for marketing-intel monitor.
#
# Runs source collectors to gather analytics data. The data is stored in
# state/<monitor>/sources/ for the triage agent to read.
#
# Supports two modes via MONITOR_MODE env var:
#   MONITOR_MODE=weekly   — full 7-day collection (default)
#   MONITOR_MODE=anomaly  — yesterday vs. same day last week
#
# Exit 0 + prints count: proceed with triage
# Exit 1: no data collected, skip triage

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCES_DIR="$SCRIPT_DIR/sources"
RUNNER="$SOURCES_DIR/_runner.sh"

# Mode comes from the environment (set by run-marketing-intel.sh wrapper)
MODE="${MONITOR_MODE:-weekly}"

# Output collected data to state dir so the triage agent can read it
# STATE_DIR is set by the parent run.sh via init_state
COLLECT_DIR="${STATE_DIR:-$(dirname "$SCRIPT_DIR")/../../state/marketing-intel}/sources"
mkdir -p "$COLLECT_DIR"

# Run the source collector
OUTPUT=$("$RUNNER" "$MODE" "$COLLECT_DIR" 2>&1)
COLLECTED=$(echo "$OUTPUT" | tail -1)

# Check if we got any data
if [ "$COLLECTED" -gt 0 ] 2>/dev/null; then
  echo "$COLLECTED"
  exit 0
else
  echo "0"
  exit 1
fi
