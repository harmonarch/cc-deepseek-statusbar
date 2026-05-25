#!/usr/bin/env bash
# Install cc-deepseek-statusbar for Claude Code
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

echo -e "${BOLD}cc-deepseek-statusbar${RESET} - installer"
echo ""

# ── Check prerequisites ──────────────────────────────────────────────
MISSING=""
for cmd in jq curl awk; do
  if ! command -v $cmd &>/dev/null; then
    MISSING="$MISSING $cmd"
  fi
done
if [ -n "$MISSING" ]; then
  echo -e "${RED}Missing required tools:${MISSING}${RESET}"
  echo "Install them first: brew install jq curl"
  exit 1
fi
echo -e "${GREEN}✓${RESET} Prerequisites: jq, curl, awk"

# ── Check API key ────────────────────────────────────────────────────
API_KEY="${ANTHROPIC_AUTH_TOKEN:-}"
if [ -z "$API_KEY" ]; then
  # Try reading from settings.json
  SETTINGS_FILE="$HOME/.claude/settings.json"
  if [ -f "$SETTINGS_FILE" ]; then
    API_KEY=$(jq -r '.env.ANTHROPIC_AUTH_TOKEN // ""' "$SETTINGS_FILE" 2>/dev/null || echo "")
  fi
fi
if [ -z "$API_KEY" ]; then
  echo -e "${RED}✗${RESET} ANTHROPIC_AUTH_TOKEN not found"
  echo ""
  echo "  Set it in ~/.claude/settings.json:"
  echo ""
  echo '  {'
  echo '    "env": {'
  echo '      "ANTHROPIC_AUTH_TOKEN": "sk-your-deepseek-api-key"'
  echo '    }'
  echo '  }'
  echo ""
  echo "  Or export it: export ANTHROPIC_AUTH_TOKEN=sk-..."
  exit 1
fi

# Verify the key works with Deepseek balance API
if ! curl -s -L -X GET 'https://api.deepseek.com/user/balance' \
     -H 'Accept: application/json' \
     -H "Authorization: Bearer ${API_KEY}" 2>/dev/null | jq -e '.is_available' >/dev/null 2>&1; then
  echo -e "${RED}✗${RESET} API key validation failed. Check your ANTHROPIC_AUTH_TOKEN."
  exit 1
fi
echo -e "${GREEN}✓${RESET} Deepseek API key validated"

# ── Install the status line script ───────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cp "$SCRIPT_DIR/statusline-command.sh" ~/.claude/statusline-command.sh
chmod +x ~/.claude/statusline-command.sh
echo -e "${GREEN}✓${RESET} Script installed to ~/.claude/statusline-command.sh"

# ── Configure settings.json ──────────────────────────────────────────
SETTINGS_FILE="$HOME/.claude/settings.json"

if [ ! -f "$SETTINGS_FILE" ]; then
  echo '{}' > "$SETTINGS_FILE"
fi

# Check if statusLine already configured
CURRENT=$(jq -r '.statusLine.command // ""' "$SETTINGS_FILE" 2>/dev/null || echo "")
if [ "$CURRENT" = "bash ~/.claude/statusline-command.sh" ]; then
  echo -e "${GREEN}✓${RESET} Status line already configured"
else
  if [ -n "$CURRENT" ]; then
    # Backup existing config
    cp "$SETTINGS_FILE" "${SETTINGS_FILE}.backup.$(date +%s)"
    echo -e "${CYAN}!${RESET} Existing statusLine backed up"
  fi

  # Merge the new statusLine config
  TMP=$(mktemp)
  jq '.statusLine = {"type": "command", "command": "bash ~/.claude/statusline-command.sh"}' "$SETTINGS_FILE" > "$TMP"
  mv "$TMP" "$SETTINGS_FILE"
  echo -e "${GREEN}✓${RESET} Status line configured in settings.json"
fi

# ── Done ─────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}Installation complete!${RESET}"
echo ""
echo "  The status bar will show token usage and balance"
echo "  automatically for Deepseek models (deepseek-v4-pro, etc.)."
echo ""
echo "  Restart Claude Code or start a new session to see it."
echo ""
echo "  Display format:"
echo "    125.2K · 2,343.9K · ¥14.44"
echo "    ───────   ─────────   ──────"
echo "    session   daily        balance"
echo "    tokens    tokens       (CNY)"
