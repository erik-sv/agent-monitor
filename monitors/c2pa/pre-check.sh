#!/usr/bin/env bash
# Quick API check: any PR/issue updates on tracked C2PA repos since last run?
# Exits 0 if changes found (proceed with triage), 1 if nothing new (skip triage).
# Expects LAST_CHECK to be set by the caller.

set -euo pipefail

REPOS=(
  "c2pa-org/specs-core"
  "contentauth/c2pa-rs"
  "encypherai/c2pa-text"
)

CHANGES=0

for REPO in "${REPOS[@]}"; do
  # Count PRs updated since last check
  PR_COUNT=$(gh pr list --repo "$REPO" --state all --limit 50 \
    --json updatedAt --jq "[.[] | select(.updatedAt > \"${LAST_CHECK}\")] | length" 2>/dev/null || echo "0")
  CHANGES=$((CHANGES + PR_COUNT))

  # Count issues updated since last check
  ISSUE_COUNT=$(gh issue list --repo "$REPO" --state all --limit 50 \
    --json updatedAt --jq "[.[] | select(.updatedAt > \"${LAST_CHECK}\")] | length" 2>/dev/null || echo "0")
  CHANGES=$((CHANGES + ISSUE_COUNT))
done

echo "$CHANGES"
[ "$CHANGES" -gt 0 ] && exit 0 || exit 1
