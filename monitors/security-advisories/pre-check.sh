#!/usr/bin/env bash
# Quick API check: any security-related activity since last run?
# Exits 0 if changes found (proceed with triage), 1 if nothing new (skip triage).
# Expects LAST_CHECK and TRACKED_REPOS from the caller.

set -euo pipefail

CHANGES=0

for REPO in "${TRACKED_REPOS[@]}"; do
  # Check PRs updated since last run
  PR_COUNT=$(gh pr list --repo "$REPO" --state all --limit 50 \
    --json updatedAt --jq "[.[] | select(.updatedAt > \"${LAST_CHECK}\")] | length" 2>/dev/null || echo "0")
  CHANGES=$((CHANGES + PR_COUNT))

  # Check issues updated since last run
  ISSUE_COUNT=$(gh issue list --repo "$REPO" --state all --limit 50 \
    --json updatedAt --jq "[.[] | select(.updatedAt > \"${LAST_CHECK}\")] | length" 2>/dev/null || echo "0")
  CHANGES=$((CHANGES + ISSUE_COUNT))
done

echo "$CHANGES"
[ "$CHANGES" -gt 0 ] && exit 0 || exit 1
