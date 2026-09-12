#!/bin/bash
set -euo pipefail

# Claude Code quota companion for MeterUsage
# Extracts live Anthropic limits from Claude Code's local statusline cache,
# preserving the complete limits[] array verbatim, and writing atomically
# to ~/.claude/meterusage-usage.json.

TARGET_DIR="$HOME/.claude"
TARGET_FILE="$TARGET_DIR/meterusage-usage.json"
TEMP_FILE="$TARGET_DIR/meterusage-usage.json.tmp.$$"

mkdir -p "$TARGET_DIR"

CACHE_FILE=$(ls -t /tmp/claude/statusline-usage-cache-*.json 2>/dev/null | head -n 1 || true)

if [[ -n "$CACHE_FILE" && -f "$CACHE_FILE" ]]; then
    python3 -c '
import json, sys, os

cache_file = sys.argv[1]
temp_file = sys.argv[2]

try:
    with open(cache_file, "r") as f:
        data = json.load(f)
    
    # Wrap or preserve structure with updated timestamp
    import time
    data["updated_at"] = int(time.time())
    
    with open(temp_file, "w") as f:
        json.dump(data, f, indent=2)
    print("Exported live Claude quota cache to temp file.")
except Exception as e:
    sys.exit(1)
' "$CACHE_FILE" "$TEMP_FILE"

    mv "$TEMP_FILE" "$TARGET_FILE"
    echo "Successfully updated $TARGET_FILE"
else
    echo "No Claude Code usage cache found in /tmp/claude."
    exit 0
fi
