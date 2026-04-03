#!/usr/bin/env bash
# Quick API check: any PR/issue updates on tracked repos since last run?
# Exits 0 if changes found (proceed with triage), 1 if nothing new (skip triage).
# Expects LAST_CHECK to be set by the caller.
# Expects TRACKED_REPOS array from monitor.conf.

set -euo pipefail

CHANGES=0

for REPO in "${TRACKED_REPOS[@]}"; do
  PR_COUNT=$(gh pr list --repo "$REPO" --state all --limit 50 \
    --json updatedAt --jq "[.[] | select(.updatedAt > \"${LAST_CHECK}\")] | length" 2>/dev/null || echo "0")
  CHANGES=$((CHANGES + PR_COUNT))

  ISSUE_COUNT=$(gh issue list --repo "$REPO" --state all --limit 50 \
    --json updatedAt --jq "[.[] | select(.updatedAt > \"${LAST_CHECK}\")] | length" 2>/dev/null || echo "0")
  CHANGES=$((CHANGES + ISSUE_COUNT))
done

echo "$CHANGES"
[ "$CHANGES" -gt 0 ] && exit 0 || exit 1
