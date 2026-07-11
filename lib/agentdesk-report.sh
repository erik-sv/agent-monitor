#!/usr/bin/env bash
# AgentDesk phase-level reporting library.
#
# Source this file from any automation script to report progress to AgentDesk.
# Requires: AGENTDESK_WEBHOOK_URL, AGENTDESK_WEBHOOK_TOKEN, and a monitor slug.
#
# Usage:
#   source /path/to/agentdesk-report.sh
#   ad_start_run "blog-writer" "weekly"
#   ad_phase "research" "started" "Phase 1: Sonnet research agent"
#   ad_phase "research" "completed" "Research complete" '[{"type":"file","title":"Research notes","path":"/path/to/notes.md"}]'
#   ad_complete "success" 120 '{"posts":1}' '[]'
#
# All functions are no-ops when AGENTDESK_WEBHOOK_URL is not set. This makes
# the library safe to source unconditionally - scripts that run outside the
# AgentDesk ecosystem just skip reporting.

# Internal state
_AD_RUN_ID=""
_AD_SLUG=""
_AD_URL=""
_AD_TOKEN=""

# Check if reporting is enabled.
_ad_enabled() {
  [ -n "$_AD_URL" ] && [ -n "$_AD_TOKEN" ] && [ -n "$_AD_SLUG" ]
}

# POST JSON to the webhook endpoint. Accepts an action suffix.
# Usage: _ad_post <action_suffix> <json_body>
_ad_post() {
  local suffix="$1"
  local body="$2"
  local url="${_AD_URL}/api/monitors/webhook/${_AD_SLUG}"
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    --connect-timeout 5 \
    --max-time 10 \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${_AD_TOKEN}" \
    -d "$body" \
    "$url" 2>/dev/null) || true
  if [ "$http_code" = "201" ] || [ "$http_code" = "200" ]; then
    return 0
  else
    echo "[ad-report] WARNING: webhook returned HTTP $http_code" >&2
    return 1
  fi
}

# POST and capture the response body (for extracting runId).
_ad_post_capture() {
  local body="$1"
  local url="${_AD_URL}/api/monitors/webhook/${_AD_SLUG}"
  curl -s \
    --connect-timeout 5 \
    --max-time 10 \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${_AD_TOKEN}" \
    -d "$body" \
    "$url" 2>/dev/null || echo "{}"
}

# ── Public API ────────────────────────────────────────────────────────────────

# Initialize reporting for a monitor.
# Usage: ad_init <slug>
# Reads AGENTDESK_WEBHOOK_URL and AGENTDESK_WEBHOOK_TOKEN from env.
ad_init() {
  _AD_SLUG="${1:-}"
  _AD_URL="${AGENTDESK_WEBHOOK_URL:-}"
  _AD_TOKEN="${AGENTDESK_WEBHOOK_TOKEN:-}"
  _AD_RUN_ID=""

  if ! _ad_enabled; then
    return 0
  fi
}

# Start a new run. Sets _AD_RUN_ID for subsequent phase/complete calls.
# Usage: ad_start_run [mode] [metadata_json]
# Always returns 0: reporting is best-effort and callers run under set -e —
# a webhook outage or bad metadata must never kill the monitor run itself.
ad_start_run() {
  _ad_enabled || return 0
  local mode="${1:-weekly}"
  # NOT ${2:-{}}: bash closes the expansion at the first unquoted '}', so that
  # form appends a stray '}' to any provided value ('{}' -> '{}}', invalid JSON).
  local metadata="${2:-}"
  [ -n "$metadata" ] || metadata='{}'

  local body
  body=$(jq -n \
    --arg action "start" \
    --arg mode "$mode" \
    --argjson metadata "$metadata" \
    '{action: $action, mode: $mode, metadata: $metadata}') || {
    echo "[ad-report] WARNING: invalid start-run metadata, skipping report" >&2
    return 0
  }

  local response
  response=$(_ad_post_capture "$body")

  _AD_RUN_ID=$(echo "$response" | jq -r '.runId // empty' 2>/dev/null)
  if [ -n "$_AD_RUN_ID" ]; then
    echo "[ad-report] Run started: $_AD_RUN_ID" >&2
    return 0
  else
    echo "[ad-report] WARNING: failed to start run" >&2
    return 0
  fi
}

# Record a phase event.
# Usage: ad_phase <phase_name> <status> [message] [artifacts_json] [metadata_json]
# Status: started | completed | failed | skipped
# Artifacts JSON: [{"type":"file","title":"Report","path":"/path/to/file"}]
ad_phase() {
  _ad_enabled || return 0
  [ -n "$_AD_RUN_ID" ] || return 0

  local phase="$1"
  local status="$2"
  local message="${3:-}"
  local artifacts="${4:-[]}"
  local metadata="${5:-}"
  [ -n "$metadata" ] || metadata='{}'

  local body
  body=$(jq -n \
    --arg action "phase" \
    --arg runId "$_AD_RUN_ID" \
    --arg phase "$phase" \
    --arg status "$status" \
    --arg message "$message" \
    --argjson artifacts "$artifacts" \
    --argjson metadata "$metadata" \
    '{action: $action, runId: $runId, phase: $phase, status: $status, message: $message, artifacts: $artifacts, metadata: $metadata}') || {
    echo "[ad-report] WARNING: invalid phase payload, skipping report" >&2
    return 0
  }

  _ad_post "" "$body" || true
}

# Complete the current run with success.
# Usage: ad_complete [status] [duration_seconds] [summary_json] [findings_json] [report_path] [session_id]
ad_complete() {
  _ad_enabled || return 0
  [ -n "$_AD_RUN_ID" ] || return 0

  local status="${1:-success}"
  local duration="${2:-0}"
  local summary="${3:-}"
  [ -n "$summary" ] || summary='{}'
  local findings="${4:-[]}"
  local report_path="${5:-}"
  local session_id="${6:-}"

  local body
  body=$(jq -n \
    --arg action "complete" \
    --arg runId "$_AD_RUN_ID" \
    --arg status "$status" \
    --argjson duration "$duration" \
    --argjson summary "$summary" \
    --argjson findings "$findings" \
    --arg reportPath "$report_path" \
    --arg sessionId "$session_id" \
    '{action: $action, runId: $runId, status: $status, duration: $duration, summary: $summary, findings: $findings, reportPath: $reportPath, sessionId: $sessionId}') || {
    echo "[ad-report] WARNING: invalid completion payload, skipping report" >&2
    return 0
  }

  _ad_post "" "$body" || true
  echo "[ad-report] Run completed: $_AD_RUN_ID ($status)" >&2
}

# Shorthand: complete the run with failure.
# Usage: ad_fail [message] [duration_seconds]
ad_fail() {
  local message="${1:-unknown error}"
  local duration="${2:-0}"
  ad_complete "failure" "$duration" "{\"error\":$(jq -n --arg m "$message" '$m')}" "[]" "" ""
}

# Get the current run ID (for use in scripts that need it).
ad_run_id() {
  echo "$_AD_RUN_ID"
}
