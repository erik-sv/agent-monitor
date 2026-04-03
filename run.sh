#!/usr/bin/env bash
# Modular agent monitor - runs a named monitor's triage + optional review + Discord notify.
#
# Usage:
#   ./run.sh <monitor-name> [--lookback] [--reset] [--no-review]
#
# Each monitor lives in monitors/<name>/ with:
#   monitor.conf       - shell variables (LOOKBACK_HOURS, DISCORD_EMBED_COLOR, etc.)
#   PROMPT.md           - triage agent prompt
#   REVIEW_PROMPT.md    - (optional) per-item review prompt; enables Phase 2
#   pre-check.sh        - (optional) cheap API check; skips LLM when nothing changed
#   .env                - (optional) per-monitor env overrides
#
# State is kept in state/<name>/, logs in logs/<name>/.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -- Parse arguments ----------------------------------------------------------
MONITOR_NAME="${1:?Usage: $0 <monitor-name> [--lookback] [--reset] [--no-review]}"
shift

LOOKBACK=false
RESET=false
NO_REVIEW=false
for arg in "$@"; do
  case "$arg" in
    --lookback) LOOKBACK=true ;;
    --reset)    RESET=true ;;
    --no-review) NO_REVIEW=true ;;
  esac
done

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
load_env
check_prereqs
init_state
acquire_lock
get_check_window

# -- Pre-check: skip LLM if nothing changed ----------------------------------
PRECHECK_SCRIPT="$MONITOR_DIR/pre-check.sh"
if [ -f "$PRECHECK_SCRIPT" ] && [ "$LOOKBACK" = false ] && [ "$RESET" = false ]; then
  log "Running pre-check..."
  PRECHECK_OUTPUT=$("$PRECHECK_SCRIPT" 2>&1) && PRECHECK_RC=0 || PRECHECK_RC=$?
  if [ "$PRECHECK_RC" -ne 0 ]; then
    save_timestamp
    log "Pre-check: no new activity ($PRECHECK_OUTPUT items). Skipping triage."
    exit 0
  fi
  log "Pre-check: $PRECHECK_OUTPUT changed items detected."
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

    while IFS= read -r ITEM_KEY; do
      REPO="${ITEM_KEY%#*}"
      NUMBER="${ITEM_KEY##*#}"
      SAFE_KEY=$(echo "$ITEM_KEY" | tr '/#' '-')
      REVIEW_FILE="$REVIEWS_DIR/review-${SAFE_KEY}-$(date +%Y%m%d).md"
      SESSION_OUTPUT="$REVIEWS_DIR/.session-${SAFE_KEY}.json"

      ITEM_TYPE="pr"
      GH_CMD="pr view"
      if ! gh pr view "$NUMBER" --repo "$REPO" --json number > /dev/null 2>&1; then
        ITEM_TYPE="issue"; GH_CMD="issue view"
      fi

      REVIEW_PROMPT="$(sed \
        -e "s|ITEM_REPO|$REPO|g" \
        -e "s|ITEM_NUMBER|$NUMBER|g" \
        -e "s|ITEM_TYPE|$ITEM_TYPE|g" \
        -e "s|ITEM_GH_CMD|$GH_CMD|g" \
        -e "s|REVIEW_OUTPUT_PATH|$REVIEW_FILE|g" \
        "$MONITOR_DIR/REVIEW_PROMPT.md")"

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
        SUMMARY_RAW=$(grep '^\*\*Summary:\*\*' "$REVIEW_FILE" | sed 's/\*\*Summary:\*\* *//' | head -c 140)
        ACTION_TYPE=$(grep '^\*\*Recommended action:\*\*' "$REVIEW_FILE" | sed 's/\*\*Recommended action:\*\* *//' | head -c 200)
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

rm -f "$DELTA_FILE"
prune_logs 30
log "Done."
