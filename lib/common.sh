#!/usr/bin/env bash
# Shared functions for all monitors.
# Source this from the main run.sh; expects MONITOR_DIR, SCRIPT_DIR to be set.

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

load_env() {
  # Global .env first, then monitor-specific override
  if [ -f "$SCRIPT_DIR/.env" ]; then
    set -a; source "$SCRIPT_DIR/.env"; set +a
  fi
  if [ -f "$MONITOR_DIR/.env" ]; then
    set -a; source "$MONITOR_DIR/.env"; set +a
  fi
  # Allow claude -p subprocesses when invoked from inside a Claude Code session
  unset CLAUDECODE
}

check_prereqs() {
  for cmd in claude gh jq; do
    if ! command -v "$cmd" &>/dev/null; then
      echo "ERROR: '$cmd' not found." >&2
      exit 1
    fi
  done
  if ! gh auth status &>/dev/null 2>&1; then
    echo "ERROR: gh CLI not authenticated." >&2
    exit 1
  fi
}

acquire_lock() {
  LOCKFILE="$STATE_DIR/.lock"
  if [ -f "$LOCKFILE" ]; then
    LOCK_PID=$(cat "$LOCKFILE" 2>/dev/null)
    if kill -0 "$LOCK_PID" 2>/dev/null; then
      echo "Already running (PID $LOCK_PID), exiting." >&2
      exit 0
    fi
    rm -f "$LOCKFILE"
  fi
  echo $$ > "$LOCKFILE"
  trap 'rm -f "$LOCKFILE"' EXIT
}

init_state() {
  mkdir -p "$STATE_DIR" "$LOGS_DIR"
  if [ -f "$MONITOR_DIR/REVIEW_PROMPT.md" ]; then
    mkdir -p "$LOGS_DIR/reviews"
  fi
  SEEN_FILE="$STATE_DIR/seen-items.json"
  LAST_CHECK_FILE="$STATE_DIR/last-check.txt"
  if [ "$RESET" = true ] || [ ! -f "$SEEN_FILE" ]; then
    echo '{}' > "$SEEN_FILE"
    [ "$RESET" = true ] && log "State reset."
  fi
}

get_check_window() {
  if [ "$LOOKBACK" = true ] || [ ! -f "$LAST_CHECK_FILE" ]; then
    LAST_CHECK="$(date -u -d "${LOOKBACK_HOURS} hours ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
      || date -u -v-${LOOKBACK_HOURS}H +%Y-%m-%dT%H:%M:%SZ)"
    LAST_CHECK_DATE="${LAST_CHECK%%T*}"
    log "Lookback mode: checking since $LAST_CHECK"
  else
    LAST_CHECK="$(cat "$LAST_CHECK_FILE")"
    LAST_CHECK_DATE="${LAST_CHECK%%T*}"
    log "Checking since last run: $LAST_CHECK"
  fi
}

save_timestamp() {
  echo "$NOW" > "$LAST_CHECK_FILE"
}

# Run the triage agent with the monitor's PROMPT.md.
# Sets SESSION_ID on success.
run_triage() {
  # Use ANOMALY_PROMPT.md when in anomaly mode, fall back to PROMPT.md
  local prompt_file="$MONITOR_DIR/PROMPT.md"
  if [ "${MONITOR_MODE:-weekly}" = "anomaly" ] && [ -f "$MONITOR_DIR/ANOMALY_PROMPT.md" ]; then
    prompt_file="$MONITOR_DIR/ANOMALY_PROMPT.md"
    log "Using anomaly prompt."
  fi
  local seen_items
  seen_items="$(cat "$SEEN_FILE")"

  # Interpolate standard variables into the prompt
  local merged_data_path="$STATE_DIR/sources/merged.json"
  local prompt
  prompt="$(sed \
    -e "s|LAST_CHECK_TIME|$LAST_CHECK|g" \
    -e "s|LAST_CHECK_DATE|$LAST_CHECK_DATE|g" \
    -e "s|REPORT_OUTPUT_PATH|$REPORT_FILE|g" \
    -e "s|DELTA_OUTPUT_PATH|$DELTA_FILE|g" \
    -e "s|DISCORD_OUTPUT_PATH|$DISCORD_FILE|g" \
    -e "s|MERGED_DATA_PATH|$merged_data_path|g" \
    -e "s|PERIOD_START|$LAST_CHECK|g" \
    -e "s|PERIOD_END|$NOW|g" \
    -e "s|DATE|$TODAY|g" \
    "$prompt_file")"

  prompt="$(echo "$prompt" | sed "s|SEEN_ITEMS_JSON|$seen_items|")"

  # Append previously reported items if not already embedded in the prompt
  if ! grep -q 'Previously reported items' "$prompt_file"; then
    prompt="$prompt

## Previously reported items

The following items have already been reported. Only report an item again if its
updatedAt timestamp is MORE RECENT than the lastReportedUpdate shown here.

\`\`\`json
$seen_items
\`\`\`"
  fi

  log "Running Sonnet triage..."
  local session_output="$LOGS_DIR/.session-output.json"

  local model="${TRIAGE_MODEL:-claude-sonnet-4-6}"
  claude -p "$prompt" \
    --model "$model" \
    --permission-mode bypassPermissions \
    --allowedTools "Bash,Read,Write,Glob,Grep" \
    --output-format json > "$session_output" 2>&1 || {
    log "ERROR: Triage agent failed."
    exit 1
  }

  SESSION_ID=$(jq -r '.session_id // empty' "$session_output" 2>/dev/null)
  rm -f "$session_output"
}

# Merge delta.json into seen-items.json.
merge_delta() {
  if [ -f "$DELTA_FILE" ] && [ -s "$DELTA_FILE" ]; then
    jq -s '.[0] * .[1]' "$SEEN_FILE" "$DELTA_FILE" > "$SEEN_FILE.tmp" \
      && mv "$SEEN_FILE.tmp" "$SEEN_FILE"
    DELTA_COUNT=$(jq 'length' "$DELTA_FILE")
    log "Delta: $DELTA_COUNT items tracked."
  else
    DELTA_COUNT=0
    log "No new items in delta."
  fi
}

# Update seen-items from report headers (repo#number patterns).
# Used when the LLM writes a report but no delta.json.
merge_report_items() {
  if [ ! -f "$REPORT_FILE" ] || [ ! -s "$REPORT_FILE" ]; then return; fi
  while IFS= read -r line; do
    if [[ "$line" =~ ^###[[:space:]]+([-a-zA-Z0-9_]+/[-a-zA-Z0-9_]+)#([0-9]+) ]]; then
      local key="${BASH_REMATCH[1]}#${BASH_REMATCH[2]}"
      jq --arg k "$key" --arg t "$NOW" \
        '.[$k] = {"lastReportedUpdate": $t}' "$SEEN_FILE" > "$SEEN_FILE.tmp" \
        && mv "$SEEN_FILE.tmp" "$SEEN_FILE"
    fi
  done < "$REPORT_FILE"
}

# Send a Discord webhook with the given JSON payload.
send_discord_webhook() {
  local payload="$1"
  if [ -z "${DISCORD_WEBHOOK_URL:-}" ]; then
    log "No DISCORD_WEBHOOK_URL set, skipping notification."
    return 0
  fi
  log "Sending Discord notification..."
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "$DISCORD_WEBHOOK_URL")
  if [ "$http_code" = "200" ] || [ "$http_code" = "204" ]; then
    log "Discord notification sent."
  else
    log "WARNING: Discord notification failed (HTTP $http_code)."
  fi
}

# Inject an external dashboard link into a Discord embed description.
# Set DASHBOARD_BASE_URL in .env to enable (e.g. https://yourdash.example.com/?s=).
inject_session_link() {
  local payload="$1"
  local sid="$2"
  if [ -n "$sid" ] && [ -n "${DASHBOARD_BASE_URL:-}" ]; then
    echo "$payload" | jq --arg url "${DASHBOARD_BASE_URL}${sid}" \
      '.embeds[0].description += "\n\n[View analysis](" + $url + ")"'
  else
    echo "$payload"
  fi
}

prune_logs() {
  local keep="${1:-30}"
  ls -t "$LOGS_DIR"/report-*.md 2>/dev/null | tail -n +"$((keep + 1))" | xargs -r rm -f
  if [ -d "$LOGS_DIR/reviews" ]; then
    ls -t "$LOGS_DIR"/reviews/review-*.md 2>/dev/null | tail -n +"$((keep + 1))" | xargs -r rm -f
  fi
}

# Post run results to AgentDesk webhook if configured.
# Env vars: AGENTDESK_WEBHOOK_URL, AGENTDESK_WEBHOOK_TOKEN
send_agentdesk_webhook() {
  local status="$1"
  local findings_json="${2:-[]}"
  local source_results="${3:-{}}"

  if [ -z "${AGENTDESK_WEBHOOK_URL:-}" ] || [ -z "${AGENTDESK_WEBHOOK_TOKEN:-}" ]; then
    return 0
  fi

  local duration=0
  if [ -n "${RUN_START_EPOCH:-}" ]; then
    duration=$(( $(date +%s) - RUN_START_EPOCH ))
  fi

  local summary_json
  summary_json=$(jq -n \
    --argjson findings "$(echo "$findings_json" | jq 'length')" \
    --argjson high "$(echo "$findings_json" | jq '[.[] | select(.severity == "HIGH" or .relevance == "HIGH")] | length')" \
    --arg sources_ok "$(echo "$source_results" | jq '[to_entries[] | select(.value == "ok")] | length')" \
    --arg sources_failed "$(echo "$source_results" | jq '[to_entries[] | select(.value != "ok")] | length')" \
    '{findings: $findings, high_findings: $high, sources_ok: ($sources_ok|tonumber), sources_failed: ($sources_failed|tonumber)}')

  local payload
  payload=$(jq -n \
    --arg mode "${MONITOR_MODE:-weekly}" \
    --arg status "$status" \
    --argjson duration "$duration" \
    --argjson summary "$summary_json" \
    --argjson findings "$findings_json" \
    --arg reportPath "${REPORT_FILE:-}" \
    --arg sessionId "${SESSION_ID:-}" \
    --argjson sourceResults "$source_results" \
    '{mode: $mode, status: $status, duration: $duration, summary: $summary, findings: $findings, reportPath: $reportPath, sessionId: $sessionId, sourceResults: $sourceResults}')

  local url="${AGENTDESK_WEBHOOK_URL}/api/monitors/webhook/${MONITOR_NAME}"
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${AGENTDESK_WEBHOOK_TOKEN}" \
    -d "$payload" \
    "$url")

  if [ "$http_code" = "201" ]; then
    log "AgentDesk webhook: sent (HTTP $http_code)"
  else
    log "WARNING: AgentDesk webhook failed (HTTP $http_code)"
  fi
}
