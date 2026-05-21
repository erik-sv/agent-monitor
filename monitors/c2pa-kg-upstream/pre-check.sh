#!/usr/bin/env bash
# Quick HTTP HEAD check: has the C2PA schemas ZIP changed or a new version appeared?
# Exits 0 if changes found (proceed with triage), exit 1 with count if unchanged (skip).
#
# Version discovery is dynamic. The script scrapes the public index page for
# version links and compares the latest against stored state. No version number
# is hardcoded.
set -euo pipefail

SITE_BASE="${C2PA_SITE_BASE:-https://spec.c2pa.org/specifications/specifications}"
VERSION_FILE="$STATE_DIR/latest-version.txt"
LM_FILE="$STATE_DIR/last-modified.txt"
CL_FILE="$STATE_DIR/content-length.txt"

CHANGES=0

# ---------------------------------------------------------------------------
# Check 1: discover latest version from public index
# ---------------------------------------------------------------------------
STORED_VERSION="$(cat "$VERSION_FILE" 2>/dev/null || echo "")"

# The index page at spec.c2pa.org redirects to the latest version and lists
# links to all prior versions. Scrape for /specifications/X.Y/ patterns.
# Try the root index first; if that fails, try the stored version's index.
INDEX_CONTENT=$(curl -sL "${SITE_BASE}/" 2>/dev/null || echo "")
if [ -z "$INDEX_CONTENT" ] && [ -n "$STORED_VERSION" ]; then
  INDEX_CONTENT=$(curl -sL "${SITE_BASE}/${STORED_VERSION}/index.html" 2>/dev/null || echo "")
fi

LATEST_VERSION=""
if [ -n "$INDEX_CONTENT" ]; then
  LATEST_VERSION=$(echo "$INDEX_CONTENT" \
    | grep -oP 'specifications/[0-9]+\.[0-9]+' \
    | grep -oP '[0-9]+\.[0-9]+' \
    | sort -t. -k1,1n -k2,2n \
    | uniq \
    | tail -1)
fi

# Fallback: if scraping fails, use stored version
LATEST_VERSION="${LATEST_VERSION:-${STORED_VERSION:-}}"

if [ -z "$LATEST_VERSION" ]; then
  # No stored version and scraping failed. Cannot proceed.
  echo "0"
  exit 1
fi

# New version detected
if [ -n "$STORED_VERSION" ] && [ "$LATEST_VERSION" != "$STORED_VERSION" ]; then
  CHANGES=$((CHANGES + 1))
fi

# ---------------------------------------------------------------------------
# Check 2: HTTP HEAD on schemas ZIP for latest version
# ---------------------------------------------------------------------------
ZIP_URL="${SITE_BASE}/${LATEST_VERSION}/specs/_attachments/C2PA_Schemas.zip"
HEADERS=$(curl -sI "$ZIP_URL" 2>/dev/null || echo "")

CURRENT_LM=$(echo "$HEADERS" | grep -i "^last-modified:" | sed 's/^[^:]*: *//' | tr -d '\r' || echo "")
CURRENT_CL=$(echo "$HEADERS" | grep -i "^content-length:" | awk '{print $2}' | tr -d '\r' || echo "")

STORED_LM="$(cat "$LM_FILE" 2>/dev/null || echo "")"
STORED_CL="$(cat "$CL_FILE" 2>/dev/null || echo "")"

# Either Last-Modified or Content-Length changed
if [ -n "$CURRENT_LM" ] && [ "$CURRENT_LM" != "$STORED_LM" ]; then
  CHANGES=$((CHANGES + 1))
elif [ -n "$CURRENT_CL" ] && [ "$CURRENT_CL" != "$STORED_CL" ]; then
  CHANGES=$((CHANGES + 1))
fi

# ---------------------------------------------------------------------------
# Save discovered version for triage agent
# ---------------------------------------------------------------------------
echo "$LATEST_VERSION" > "$STATE_DIR/discovered-version.txt"

echo "$CHANGES"
[ "$CHANGES" -gt 0 ] && exit 0 || exit 1
