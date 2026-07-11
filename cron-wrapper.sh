#!/usr/bin/env bash
# Thin cron wrapper: sets PATH, invokes run.sh for a named monitor.
#
# Example crontab entries:
#   15 */4 * * *    /path/to/agent-monitor/cron-wrapper.sh gh-activity
#   17 8,18 * * *   /path/to/agent-monitor/cron-wrapper.sh c2pa
#   0  9 * * 1      /path/to/agent-monitor/cron-wrapper.sh marketing-intel
#   30 8 * * 2-6    /path/to/agent-monitor/cron-wrapper.sh marketing-intel --anomaly
set -euo pipefail

MONITOR="${1:?Usage: $0 <monitor-name> [flags...]}"
shift
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs/$MONITOR"
mkdir -p "$LOG_DIR"

export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

# Source AgentDesk webhook credentials for run phase reporting.
# Expected keys: AGENTDESK_WEBHOOK_URL, AGENTDESK_WEBHOOK_TOKEN
if [ -f "$SCRIPT_DIR/.env.agentdesk" ]; then
  set -a
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/.env.agentdesk"
  set +a
fi

exec "$SCRIPT_DIR/run.sh" "$MONITOR" "$@" >> "$LOG_DIR/cron.log" 2>&1
