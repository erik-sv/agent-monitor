#!/usr/bin/env bash
# Thin cron wrapper: sets PATH, invokes run.sh for a named monitor.
#
# Example crontab entries:
#   15 */4 * * *    /path/to/agent-monitor/cron-wrapper.sh my-monitor
#   17 8,18 * * *   /path/to/agent-monitor/cron-wrapper.sh another-monitor
set -euo pipefail

MONITOR="${1:?Usage: $0 <monitor-name>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs/$MONITOR"
mkdir -p "$LOG_DIR"

export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
exec "$SCRIPT_DIR/run.sh" "$MONITOR" >> "$LOG_DIR/cron.log" 2>&1
