#!/usr/bin/env bash
# Quick API check: any new releases since last run?
# Exits 0 if changes found (proceed with triage), 1 if nothing new (skip triage).
# Expects LAST_CHECK and TRACKED_REPOS from the caller.

set -euo pipefail

CHANGES=0

for REPO in "${TRACKED_REPOS[@]}"; do
  # Check releases published since last run
  RELEASE_COUNT=$(gh api "repos/${REPO}/releases?per_page=10" \
    --jq "[.[] | select(.published_at > \"${LAST_CHECK}\")] | length" 2>/dev/null || echo "0")
  CHANGES=$((CHANGES + RELEASE_COUNT))

  # Check tags created since last run (catches repos that use tags without releases)
  TAG_COUNT=$(gh api "repos/${REPO}/tags?per_page=10" \
    --jq 'length' 2>/dev/null || echo "0")
  # Tags don't have dates, so we check if any releases were found as proxy
  # If no releases but tags exist, we conservatively proceed
  if [ "$RELEASE_COUNT" -eq 0 ] && [ "$TAG_COUNT" -gt 0 ]; then
    # Check if the latest tag's commit is newer than LAST_CHECK
    LATEST_TAG_SHA=$(gh api "repos/${REPO}/tags?per_page=1" --jq '.[0].commit.sha' 2>/dev/null || echo "")
    if [ -n "$LATEST_TAG_SHA" ]; then
      COMMIT_DATE=$(gh api "repos/${REPO}/commits/${LATEST_TAG_SHA}" --jq '.commit.committer.date' 2>/dev/null || echo "")
      if [ -n "$COMMIT_DATE" ] && [[ "$COMMIT_DATE" > "$LAST_CHECK" ]]; then
        CHANGES=$((CHANGES + 1))
      fi
    fi
  fi
done

echo "$CHANGES"
[ "$CHANGES" -gt 0 ] && exit 0 || exit 1
