#!/usr/bin/env bash
# Quick API check: are there any notifications or involved-item updates since last run?
# Exits 0 if changes found (proceed with triage), 1 if nothing new (skip triage).
# Expects LAST_CHECK and LAST_CHECK_DATE to be set by the caller.

set -euo pipefail

CHANGES=0

# Check unread/recent notifications
NOTIF_COUNT=$(gh api "/notifications?since=${LAST_CHECK}&all=true&per_page=1" --jq 'length' 2>/dev/null || echo "0")
if [ "$NOTIF_COUNT" -gt 0 ]; then
  CHANGES=$((CHANGES + NOTIF_COUNT))
fi

# Check issues/PRs involving erik-sv updated since last check
INVOLVED_COUNT=$(gh api "search/issues?q=involves:erik-sv+updated:>${LAST_CHECK_DATE}&per_page=1" --jq '.total_count' 2>/dev/null || echo "0")
if [ "$INVOLVED_COUNT" -gt 0 ]; then
  CHANGES=$((CHANGES + INVOLVED_COUNT))
fi

echo "$CHANGES"
[ "$CHANGES" -gt 0 ] && exit 0 || exit 1
