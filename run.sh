#!/usr/bin/env bash
# Modular agent monitor - runs a named monitor's triage + optional review + Discord notify.
#
# Usage:
#   ./run.sh <monitor-name> [--lookback] [--reset] [--no-review] [--anomaly]
#
# Each monitor lives in monitors/<name>/ with:
#   monitor.conf       - shell variables (LOOKBACK_HOURS, DISCORD_EMBED_COLOR, etc.)
#   PROMPT.md           - triage agent prompt
#   ANOMALY_PROMPT.md   - (optional) alternate prompt for --anomaly mode
#   REVIEW_PROMPT.md    - (optional) per-item review prompt; enables Phase 2
#   pre-check.sh        - (optional) cheap API check; skips LLM when nothing changed
#   .env                - (optional) per-monitor env overrides
#
# State is kept in state/<name>/, logs in logs/<name>/.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -- Parse arguments ----------------------------------------------------------
MONITOR_NAME="${1:?Usage: $0 <monitor-name> [--lookback] [--reset] [--no-review] [--anomaly]}"
shift

LOOKBACK=false
RESET=false
NO_REVIEW=false
ANOMALY=false
for arg in "$@"; do
  case "$arg" in
    --lookback)  LOOKBACK=true ;;
    --reset)     RESET=true ;;
    --no-review) NO_REVIEW=true ;;
    --anomaly)   ANOMALY=true ;;
  esac
done

# Export mode for pre-check scripts and source collectors
if [ "$ANOMALY" = true ]; then
  export MONITOR_MODE="anomaly"
else
  export MONITOR_MODE="weekly"
fi

# -- Resolve paths ------------------------------------------------------------
MONITOR_DIR="$SCRIPT_DIR/monitors/$MONITOR_NAME"
if [ ! -d "$MONITOR_DIR" ]; then
  echo "ERROR: monitor '$MONITOR_NAME' not found at $MONITOR_DIR" >&2
  exit 1
fi

STATE_DIR="$SCRIPT_DIR/state/$MONITOR_NAME"
LOGS_DIR="$SCRIPT_DIR/logs/$MONITOR_NAME"
TODAY="$(date +%Y-%m-%d)"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
REPORT_FILE="$LOGS_DIR/report-$(date +%Y%m%d-%H%M%S).md"
DELTA_FILE="$STATE_DIR/delta.json"
DISCORD_FILE="$LOGS_DIR/.discord-payload.json"

# -- Source shared library and monitor config ---------------------------------
source "$SCRIPT_DIR/lib/common.sh"

# Monitor defaults (overridden by monitor.conf)
LOOKBACK_HOURS=12
DISCORD_EMBED_COLOR=15158332
MONITOR_DISPLAY_NAME="$MONITOR_NAME"

source "$MONITOR_DIR/monitor.conf"

# -- Init ---------------------------------------------------------------------
export RUN_START_EPOCH=$(date +%s)
load_env
check_prereqs
init_state
acquire_lock
get_check_window

# -- Pre-check: skip LLM if nothing changed ----------------------------------
PRECHECK_SCRIPT="$MONITOR_DIR/pre-check.sh"
if [ -f "$PRECHECK_SCRIPT" ] && [ "$LOOKBACK" = false ] && [ "$RESET" = false ]; then
  log "Running pre-check..."
  PRECHECK_OUTPUT=$(source "$PRECHECK_SCRIPT" 2>&1) && PRECHECK_RC=0 || PRECHECK_RC=$?
  if [ "$PRECHECK_RC" -eq 1 ] && [[ "$PRECHECK_OUTPUT" =~ ^[0-9]+$ ]]; then
    # Clean exit with numeric output: no changes found
    save_timestamp
    log "Pre-check: no new activity ($PRECHECK_OUTPUT items). Skipping triage."
    exit 0
  elif [ "$PRECHECK_RC" -gt 1 ] || ! [[ "$PRECHECK_OUTPUT" =~ ^[0-9]+$ ]]; then
    # Crash or non-numeric output: log warning and proceed with triage
    log "WARNING: pre-check failed (exit $PRECHECK_RC), proceeding with triage."
    log "  Output: $PRECHECK_OUTPUT"
  else
    log "Pre-check: $PRECHECK_OUTPUT changed items detected."
  fi
fi

# =============================================================================
# Phase 1 - Triage
# =============================================================================
run_triage
save_timestamp

# Update state: prefer delta.json if written, else extract from report headers
if [ -f "$DELTA_FILE" ] && [ -s "$DELTA_FILE" ]; then
  SEEN_BEFORE="$(cat "$SEEN_FILE")"
  merge_delta
else
  SEEN_BEFORE=""
  merge_report_items
fi

if [ -f "$REPORT_FILE" ]; then
  LINES=$(wc -l < "$REPORT_FILE")
  log "Report: $REPORT_FILE ($LINES lines)"
fi

# =============================================================================
# Phase 2 - Sub-agent reviews (if REVIEW_PROMPT.md exists and delta has HIGH items)
# =============================================================================
REVIEW_COUNT=0
REVIEWS_DIR="$LOGS_DIR/reviews"
SESSIONS_FILE="$STATE_DIR/sessions.json"

if [ "$NO_REVIEW" = false ] && [ -f "$MONITOR_DIR/REVIEW_PROMPT.md" ] \
   && [ -f "$DELTA_FILE" ] && [ -s "$DELTA_FILE" ]; then

  HIGH_ITEMS=$(jq -r 'to_entries[] | select(.value.relevance == "HIGH") | .key' "$DELTA_FILE" 2>/dev/null)

  if [ -n "$HIGH_ITEMS" ]; then
    log "Phase 2: launching review sub-agents..."
    PIDS=(); REVIEW_FILES=(); SESSION_OUTPUTS=(); ITEM_KEYS=()

    REVIEW_MODEL="${REVIEW_MODEL:-claude-sonnet-4-6}"
    MERGED_DATA="$STATE_DIR/sources/merged.json"

    while IFS= read -r ITEM_KEY; do
      SAFE_KEY=$(echo "$ITEM_KEY" | tr '/#:' '---')
      REVIEW_FILE="$REVIEWS_DIR/review-${SAFE_KEY}-$(date +%Y%m%d).md"
      SESSION_OUTPUT="$REVIEWS_DIR/.session-${SAFE_KEY}.json"

      # Extract item metadata from delta for prompt interpolation
      ITEM_TYPE=$(jq -r --arg k "$ITEM_KEY" '.[$k].type // "insight"' "$DELTA_FILE" 2>/dev/null)
      ITEM_SUMMARY=$(jq -r --arg k "$ITEM_KEY" '.[$k].title // .[$k].summary // ""' "$DELTA_FILE" 2>/dev/null)

      # Build review prompt with all available interpolations
      REVIEW_PROMPT="$(sed \
        -e "s|ITEM_KEY|$ITEM_KEY|g" \
        -e "s|ITEM_TYPE|$ITEM_TYPE|g" \
        -e "s|ITEM_SUMMARY|$ITEM_SUMMARY|g" \
        -e "s|REVIEW_OUTPUT_PATH|$REVIEW_FILE|g" \
        -e "s|MERGED_DATA_PATH|$MERGED_DATA|g" \
        "$MONITOR_DIR/REVIEW_PROMPT.md")"

      # For GitHub-style monitors: also interpolate repo/number if key matches repo#N
      if [[ "$ITEM_KEY" == *"#"* ]]; then
        REPO="${ITEM_KEY%#*}"
        NUMBER="${ITEM_KEY##*#}"
        GH_TYPE="pr"
        GH_CMD="pr view"
        if ! gh pr view "$NUMBER" --repo "$REPO" --json number > /dev/null 2>&1; then
          GH_TYPE="issue"; GH_CMD="issue view"
        fi
        REVIEW_PROMPT="$(echo "$REVIEW_PROMPT" | sed \
          -e "s|ITEM_REPO|$REPO|g" \
          -e "s|ITEM_NUMBER|$NUMBER|g" \
          -e "s|ITEM_GH_CMD|$GH_CMD|g")"
        ITEM_TYPE="$GH_TYPE"
      fi

      log "  Spawning review: $ITEM_KEY ($ITEM_TYPE)"

      claude -p "$REVIEW_PROMPT" \
        --model "$REVIEW_MODEL" \
        --permission-mode bypassPermissions \
        --allowedTools "Bash,Read,Write,Glob,Grep" \
        --output-format json > "$SESSION_OUTPUT" 2>&1 &

      PIDS+=($!); REVIEW_FILES+=("$REVIEW_FILE")
      SESSION_OUTPUTS+=("$SESSION_OUTPUT"); ITEM_KEYS+=("$ITEM_KEY")
      REVIEW_COUNT=$((REVIEW_COUNT + 1))
    done <<< "$HIGH_ITEMS"

    log "  Waiting for $REVIEW_COUNT review sub-agents..."
    FAILED=0
    for PID in "${PIDS[@]}"; do
      if ! wait "$PID"; then FAILED=$((FAILED + 1)); fi
    done
    [ "$FAILED" -gt 0 ] && log "  WARNING: $FAILED/$REVIEW_COUNT reviews failed."

    # Extract session IDs
    echo '{}' > "$SESSIONS_FILE"
    for i in "${!SESSION_OUTPUTS[@]}"; do
      SO="${SESSION_OUTPUTS[$i]}"; IK="${ITEM_KEYS[$i]}"
      if [ -f "$SO" ]; then
        SID=$(jq -r '.session_id // empty' "$SO" 2>/dev/null)
        if [ -n "$SID" ]; then
          jq --arg k "$IK" --arg v "$SID" '.[$k] = $v' "$SESSIONS_FILE" > "$SESSIONS_FILE.tmp" \
            && mv "$SESSIONS_FILE.tmp" "$SESSIONS_FILE"
        fi
        rm -f "$SO"
      fi
    done

    # Append reviews to report
    APPENDED=0
    for RF in "${REVIEW_FILES[@]}"; do
      if [ -f "$RF" ] && [ -s "$RF" ]; then
        printf '\n---\n\n' >> "$REPORT_FILE"
        cat "$RF" >> "$REPORT_FILE"
        APPENDED=$((APPENDED + 1))
      fi
    done
    log "Phase 2 complete: $APPENDED/$REVIEW_COUNT reviews appended."
  fi
fi

# =============================================================================
# Discord notification
# =============================================================================
if [ -n "${DISCORD_WEBHOOK_URL:-}" ]; then

  # Mode 1: LLM wrote a discord.json directly
  if [ -f "$DISCORD_FILE" ] && [ -s "$DISCORD_FILE" ]; then
    HAS_EMBEDS=$(jq 'has("embeds")' "$DISCORD_FILE" 2>/dev/null || echo "false")
    if [ "$HAS_EMBEDS" = "true" ]; then
      PAYLOAD=$(inject_session_link "$(cat "$DISCORD_FILE")" "$SESSION_ID")
      send_discord_webhook "$PAYLOAD"
    else
      log "No material items, skipping Discord notification."
    fi
    rm -f "$DISCORD_FILE"

  # Mode 2: Build embed from delta.json + reviews
  elif [ -f "$DELTA_FILE" ] && [ -s "$DELTA_FILE" ]; then
    DELTA_CONTENT=$(cat "$DELTA_FILE")
    SESSIONS_CONTENT=$(cat "$SESSIONS_FILE" 2>/dev/null || echo '{}')
    DESC=""
    NOTIFY_COUNT=0

    while IFS= read -r ITEM_KEY; do
      [ -z "$ITEM_KEY" ] && continue
      STATE_VAL=$(echo "$DELTA_CONTENT" | jq -r --arg k "$ITEM_KEY" '.[$k].state // "OPEN"')
      RELEVANCE=$(echo "$DELTA_CONTENT" | jq -r --arg k "$ITEM_KEY" '.[$k].relevance // "LOW"')
      [ "$RELEVANCE" != "HIGH" ] && continue
      [[ "$STATE_VAL" == "CLOSED" || "$STATE_VAL" == "MERGED" ]] && continue

      TITLE_VAL=$(echo "$DELTA_CONTENT" | jq -r --arg k "$ITEM_KEY" '.[$k].title // ""')
      AUTHOR=$(echo "$DELTA_CONTENT" | jq -r --arg k "$ITEM_KEY" '.[$k].author // ""')
      IS_NEW=$(echo "$SEEN_BEFORE" | jq -r --arg k "$ITEM_KEY" 'if has($k) then "false" else "true" end' 2>/dev/null || echo "true")
      [ "$IS_NEW" = "true" ] && TAG="new" || TAG="update"

      REPO="${ITEM_KEY%#*}"; NUMBER="${ITEM_KEY##*#}"
      GH_LINK="https://github.com/${REPO}/pull/${NUMBER}"
      DESC="${DESC}${TAG} [${REPO}#${NUMBER}](${GH_LINK}) -- ${TITLE_VAL} (${AUTHOR})
"

      # Append review findings if available
      SAFE_KEY=$(echo "$ITEM_KEY" | tr '/#' '-')
      REVIEW_FILE="$REVIEWS_DIR/review-${SAFE_KEY}-$(date +%Y%m%d).md"
      if [ -f "$REVIEW_FILE" ]; then
        SUMMARY_RAW=$(grep '^\*\*Summary:\*\*' "$REVIEW_FILE" | sed 's/\*\*Summary:\*\* *//' | head -c 140 || true)
        ACTION_TYPE=$(grep '^\*\*Recommended action:\*\*' "$REVIEW_FILE" | sed 's/\*\*Recommended action:\*\* *//' | head -c 200 || true)
        [ -n "$SUMMARY_RAW" ] && DESC="${DESC}**Finding:** ${SUMMARY_RAW}
"
        [ -n "$ACTION_TYPE" ] && DESC="${DESC}**Action:** ${ACTION_TYPE}
"
      fi

      SID=$(echo "$SESSIONS_CONTENT" | jq -r --arg k "$ITEM_KEY" '.[$k] // empty')
      [ -n "$SID" ] && [ -n "${DASHBOARD_BASE_URL:-}" ] && DESC="${DESC}[View full review](${DASHBOARD_BASE_URL}${SID})
"
      DESC="${DESC}
"
      NOTIFY_COUNT=$((NOTIFY_COUNT + 1))
    done < <(echo "$DELTA_CONTENT" | jq -r 'keys[]')

    if [ "$NOTIFY_COUNT" -gt 0 ]; then
      DESC="${DESC:0:4000}"
      PAYLOAD=$(jq -n \
        --arg title "$MONITOR_DISPLAY_NAME: ${NOTIFY_COUNT} items need attention" \
        --arg desc "$DESC" \
        --arg footer "$MONITOR_NAME | $TODAY | $REVIEW_COUNT reviews" \
        --argjson color "$DISCORD_EMBED_COLOR" \
        '{"embeds": [{"title": $title, "description": $desc, "color": $color, "footer": {"text": $footer}}]}')
      send_discord_webhook "$PAYLOAD"
    else
      log "No open HIGH items, skipping Discord notification."
    fi
  else
    log "No material items, skipping Discord notification."
  fi
fi

# =============================================================================
# AgentDesk webhook (if configured)
# =============================================================================
if [ -n "${AGENTDESK_WEBHOOK_URL:-}" ] && [ -n "${AGENTDESK_WEBHOOK_TOKEN:-}" ]; then
  # Build findings array from delta
  FINDINGS_JSON="[]"
  if [ -f "$DELTA_FILE" ] && [ -s "$DELTA_FILE" ]; then
    FINDINGS_JSON=$(jq '[to_entries[] | {key: .key, severity: (.value.relevance // "LOW"), title: (.value.title // .key), summary: (.value.summary // ""), source: (.value.source // ""), action: (.value.action // "")}]' "$DELTA_FILE" 2>/dev/null || echo "[]")
  fi

  # Build source results from collected data (marketing-intel specific)
  SOURCE_RESULTS="{}"
  MERGED_FILE="$STATE_DIR/sources/merged.json"
  if [ -f "$MERGED_FILE" ] && [ -s "$MERGED_FILE" ]; then
    SOURCE_RESULTS=$(jq '[.[] | {key: .source, value: (if .error then .error else "ok" end)}] | from_entries' "$MERGED_FILE" 2>/dev/null || echo "{}")
  fi

  send_agentdesk_webhook "success" "$FINDINGS_JSON" "$SOURCE_RESULTS"
fi

rm -f "$DELTA_FILE"
prune_logs 30
log "Done."
