#!/usr/bin/env bash
# Remote analyzer bootstrap - no clone required
# Usage: curl -sL <url> | bash -s [file]
#
# Prerequisites:
#   - python3 (with pyyaml: pip install pyyaml)
#   - curl
#   - bash

set -euo pipefail

ANALYZER_URL="https://raw.githubusercontent.com/submariner-io/submariner-diagnostics/devel/analyze-basic.py"
TMP_ANALYZER="/tmp/submariner-analyze-$$.py"

# Cleanup on exit
trap 'rm -f "$TMP_ANALYZER"' EXIT

# Check prerequisites
if ! command -v python3 &> /dev/null; then
    echo "❌ python3 not found. Please install Python 3."
    exit 1
fi

if ! python3 -c "import yaml" 2>/dev/null; then
    echo "❌ PyYAML not found. Please install it:"
    echo "   pip install pyyaml"
    exit 1
fi

echo "📥 Downloading analyzer..."
if ! curl -sL "$ANALYZER_URL" -o "$TMP_ANALYZER" 2>/dev/null; then
    echo "❌ Failed to download analyzer"
    exit 1
fi

# Get file from argument or ask user
if [ "${1:-}" = "" ]; then
    # No argument - ask user for file path
    echo "Please enter the full path to your diagnostics file:"
    echo "(Example: ~/Downloads/submariner-diagnostics-20260701.tar.gz)"
    echo ""
    read -r FILE

    # Expand tilde in file path
    FILE="${FILE/#\~/$HOME}"

    if [ -z "$FILE" ]; then
        echo "❌ No file path provided"
        exit 1
    fi

    if [ ! -f "$FILE" ]; then
        echo "❌ File not found: $FILE"
        exit 1
    fi

    echo ""
    echo "📁 Analyzing: $(basename "$FILE")"
    echo ""
else
    FILE="$1"
    if [ ! -f "$FILE" ]; then
        echo "❌ File not found: $FILE"
        exit 1
    fi
fi

# Run analysis
echo "🔍 Analyzing..."
echo ""
python3 "$TMP_ANALYZER" "$FILE" --format slack

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Analysis complete!"
echo ""
