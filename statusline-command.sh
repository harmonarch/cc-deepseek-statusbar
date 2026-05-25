#!/usr/bin/env bash
# Claude Code Status Line with Deepseek balance tracking
# Display updates every 5s; token tracking runs every call for accuracy.
set -euo pipefail

AUTH_TOKEN="${ANTHROPIC_AUTH_TOKEN:-}"
BALANCE_FILE="/tmp/claude-deepseek/balance_cache.json"

# Ensure required directories always exist (before any conditional blocks)
mkdir -p /tmp/claude-deepseek

# ── ANSI colors ──────────────────────────────────────────────────────
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
RED=$'\033[0;31m'
CYAN=$'\033[0;36m'
MAGENTA=$'\033[0;35m'
LIGHT_PURPLE=$'\033[38;5;183m'
PINK=$'\033[38;5;205m'
DIM=$'\033[2m'
RESET=$'\033[0m'

read_cached_balance() {
  if [ -f "$BALANCE_FILE" ]; then
    jq -r '.total_balance // "unknown"' "$BALANCE_FILE" 2>/dev/null || echo "unknown"
  else
    echo "unknown"
  fi
}

format_balance_piece() {
  local balance=$1
  if [ "$balance" = "unknown" ] || [ "$balance" = "null" ] || [ -z "$balance" ]; then
    printf "%s" "${DIM}¥...${RESET}"
  else
    printf "%s" "${GREEN}¥${balance}${RESET}"
  fi
}

print_status_line() {
  local first_line=$1
  local second_line=${2:-}

  if [ -z "$second_line" ]; then
    printf "%s" "$first_line"
    return 0
  fi

  printf "%s\n%s" "$first_line" "$second_line"
}

choose_color() {
  local pct=$1
  if   [ "$pct" -le 40 ]; then echo "$GREEN"
  elif [ "$pct" -le 70 ]; then echo "$YELLOW"
  else                        echo "$RED"
  fi
}

refresh_balance_async() {
  [ -n "$AUTH_TOKEN" ] || return 0
  (
    result=$(curl -s -L --connect-timeout 3 --max-time 10 -X GET 'https://api.deepseek.com/user/balance' \
      -H 'Accept: application/json' \
      -H "Authorization: Bearer ${AUTH_TOKEN}" 2>/dev/null || true)
    fetched_balance=$(echo "$result" | jq -r '.balance_infos[0].total_balance // "unknown"' 2>/dev/null || echo "unknown")
    if [ -n "$fetched_balance" ] && [ "$fetched_balance" != "unknown" ] && [ "$fetched_balance" != "null" ]; then
      echo "{\"total_balance\":\"$fetched_balance\",\"updated_at\":$(date +%s)}" > "$BALANCE_FILE"
    fi
  ) >/dev/null 2>&1 &
}

# Non-blocking stdin read with a short timeout to prevent hanging at startup
# when Claude Code hasn't sent data yet. Falls back gracefully if python3 is unavailable.
if command -v python3 &>/dev/null; then
  input=$(python3 -c "
import sys, select
ready, _, _ = select.select([sys.stdin], [], [], 0.05)
if ready:
    sys.stdout.write(sys.stdin.read())
" 2>/dev/null || true)
else
  # bash fallback: read with 0 timeout (non-blocking test)
  if read -r -t 0 first_line 2>/dev/null; then
    input="${first_line}$(cat 2>/dev/null || true)"
  else
    input=""
  fi
fi

# Handle empty input at startup — show placeholder instead of hiding status bar
if [ -z "$input" ]; then
  startup_balance=$(read_cached_balance)
  if [ "$startup_balance" = "unknown" ] || [ "$startup_balance" = "null" ] || [ -z "$startup_balance" ]; then
    refresh_balance_async
  fi
  left_output="${CYAN}Claude Code${RESET}  ${DIM}waiting for session data${RESET}"
  second_output="${LIGHT_PURPLE}--${RESET} · ${PINK}--${RESET} · $(format_balance_piece "$startup_balance")"
  print_status_line "$left_output" "$second_output"
  exit 0
fi

# ── Parse all fields in one jq call ──────────────────────────────────
parsed=$(echo "$input" | jq -r '[
  .model.id // "",
  .model.display_name // .model.id // "?",
  .session_id // "unknown",
  .workspace.current_dir // "",
  (.context_window.used_percentage // ""),
  (.effort.level // ""),
  (.thinking.enabled // ""),
  (.cost.total_api_duration_ms // 0),
  (.context_window.current_usage.input_tokens // 0),
  (.context_window.current_usage.output_tokens // 0),
  (.context_window.current_usage.cache_read_input_tokens // 0),
  (.context_window.current_usage.cache_creation_input_tokens // 0),
  (.context_window.total_input_tokens // 0),
  (.context_window.total_output_tokens // 0),
  (.context_window.context_window_size // 0)
] | join("\u001f")')

IFS=$'\037' read -r model_id model_name session_id cwd used_pct effort thinking_enabled \
     api_duration input_tokens output_tokens cache_read cache_write \
     ctx_total_in ctx_total_out ctx_size <<< "$parsed"

# ══════════════════════════════════════════════════════════════════════
# Deepseek token tracking (ALWAYS runs - must be accurate)
# ══════════════════════════════════════════════════════════════════════
TRACKING_UPDATED=false
IS_IDLE=false

if [[ "$model_id" == deepseek-* ]]; then
  STATE_DIR="/tmp/claude-deepseek"
  mkdir -p "$STATE_DIR"

  PRICE_INPUT_CACHE_MISS=3.00
  PRICE_INPUT_CACHE_HIT=0.025
  PRICE_OUTPUT=6.00

  today=$(date +%Y-%m-%d)
  SESSION_FILE="${STATE_DIR}/session_${session_id}.json"
  DAILY_FILE="${STATE_DIR}/daily_${today}.json"

  calc_cost() {
    local in=$1 out=$2 cread=$3 cwrite=$4
    awk "BEGIN { printf \"%.4f\", (($in + $cwrite) * $PRICE_INPUT_CACHE_MISS + $cread * $PRICE_INPUT_CACHE_HIT + $out * $PRICE_OUTPUT) / 1000000 }"
  }

  last_api_dur=0
  if [ -f "$SESSION_FILE" ]; then
    last_api_dur=$(jq -r '.last_api_duration_ms // 0' "$SESSION_FILE" 2>/dev/null || echo 0)
  fi

  if [ ! -f "$SESSION_FILE" ]; then
    echo '{"session_in":0,"session_out":0,"session_cread":0,"session_cwrite":0,"session_cost":0,"last_api_duration_ms":0}' > "$SESSION_FILE"
  fi

  # Detect new API call
  if [ "$api_duration" -gt "$last_api_dur" ] 2>/dev/null; then
    TRACKING_UPDATED=true

    sess=$(cat "$SESSION_FILE")
    sess_in=$(echo "$sess" | jq -r '.session_in // 0')
    sess_out=$(echo "$sess" | jq -r '.session_out // 0')
    sess_cread=$(echo "$sess" | jq -r '.session_cread // 0')
    sess_cwrite=$(echo "$sess" | jq -r '.session_cwrite // 0')

    sess_in=$((sess_in + input_tokens))
    sess_out=$((sess_out + output_tokens))
    sess_cread=$((sess_cread + cache_read))
    sess_cwrite=$((sess_cwrite + cache_write))
    sess_cost=$(calc_cost "$sess_in" "$sess_out" "$sess_cread" "$sess_cwrite")

    jq -n \
      --argjson si "$sess_in" \
      --argjson so "$sess_out" \
      --argjson scr "$sess_cread" \
      --argjson scw "$sess_cwrite" \
      --arg sc "$sess_cost" \
      --argjson lad "$api_duration" \
      '{session_in: $si, session_out: $so, session_cread: $scr, session_cwrite: $scw, session_cost: $sc, last_api_duration_ms: $lad}' \
      > "$SESSION_FILE"

    # Update daily
    daily_in=0; daily_out=0; daily_cread=0; daily_cwrite=0
    if [ -f "$DAILY_FILE" ]; then
      daily_in=$(jq -r '.daily_in // 0' "$DAILY_FILE" 2>/dev/null || echo 0)
      daily_out=$(jq -r '.daily_out // 0' "$DAILY_FILE" 2>/dev/null || echo 0)
      daily_cread=$(jq -r '.daily_cread // 0' "$DAILY_FILE" 2>/dev/null || echo 0)
      daily_cwrite=$(jq -r '.daily_cwrite // 0' "$DAILY_FILE" 2>/dev/null || echo 0)
    fi

    daily_in=$((daily_in + input_tokens))
    daily_out=$((daily_out + output_tokens))
    daily_cread=$((daily_cread + cache_read))
    daily_cwrite=$((daily_cwrite + cache_write))
    daily_cost=$(calc_cost "$daily_in" "$daily_out" "$daily_cread" "$daily_cwrite")

    jq -n \
      --argjson di "$daily_in" \
      --argjson do "$daily_out" \
      --argjson dcr "$daily_cread" \
      --argjson dcw "$daily_cwrite" \
      --arg dc "$daily_cost" \
      '{daily_in: $di, daily_out: $do, daily_cread: $dcr, daily_cwrite: $dcw, daily_cost: $dc}' \
      > "$DAILY_FILE"
  fi

  # Determine idle: no session tokens AND no API calls made yet
  sess_total_idle=0
  if [ -f "$SESSION_FILE" ]; then
    sess_total_idle=$(jq -r '[.session_in, .session_out, .session_cread, .session_cwrite] | add // 0' "$SESSION_FILE" 2>/dev/null || echo 0)
  fi
  if [ "$sess_total_idle" -eq 0 ] 2>/dev/null && [ "$api_duration" -eq 0 ] 2>/dev/null; then
    IS_IDLE=true
  fi
fi

# ══════════════════════════════════════════════════════════════════════
# Regenerate display (every 5s, or immediately if tracking updated)
# ══════════════════════════════════════════════════════════════════════

# Context bar
context_str=""
if [ -n "$used_pct" ]; then
  used_int=$(printf "%.0f" "$used_pct")
else
  used_int=0
fi
clr=$(choose_color "$used_int")
filled=$(( used_int * 10 / 100 ))
[ "$filled" -gt 10 ] && filled=10
empty=$(( 10 - filled ))
bar=""
for ((i=0; i<filled; i++)); do bar+="█"; done
for ((i=0; i<empty;  i++)); do bar+="░"; done
context_str="${clr}${bar} ${used_int}%${RESET}"

# Thinking / effort
think_str=""
if [ -n "$effort" ]; then
  case "$effort" in
    low)    think_clr="$GREEN";  label="low" ;;
    medium) think_clr="$YELLOW"; label="med" ;;
    high)   think_clr="$RED";    label="high" ;;
    xhigh)  think_clr="$RED";    label="xhi" ;;
    max)    think_clr="$RED";    label="max" ;;
    *)      think_clr="$DIM";    label="$effort" ;;
  esac
  think_str="${think_clr}think:${label}${RESET}"
elif [ "$thinking_enabled" = "true" ]; then
  think_str="${YELLOW}think:on${RESET}"
fi

# Directory
dir_display=""
if [ -n "$cwd" ]; then
  home_short="${cwd/#$HOME/~}"
  if [ ${#home_short} -gt 45 ]; then
    dir_display="...${home_short: -42}"
  else
    dir_display="$home_short"
  fi
fi

# Deepseek balance display
token_str=""
balance_str=""
if [[ "$model_id" == deepseek-* ]]; then
  STATE_DIR="/tmp/claude-deepseek"
  SESSION_FILE="${STATE_DIR}/session_${session_id}.json"
  DAILY_FILE="${STATE_DIR}/daily_$(date +%Y-%m-%d).json"

  # Read session token totals
  sess_total=0
  if [ -f "$SESSION_FILE" ]; then
    sess_total=$(jq -r '[.session_in, .session_out, .session_cread, .session_cwrite] | add // 0' "$SESSION_FILE" 2>/dev/null || echo 0)
  fi
  # Read daily token totals
  daily_total=0
  if [ -f "$DAILY_FILE" ]; then
    daily_total=$(jq -r '[.daily_in, .daily_out, .daily_cread, .daily_cwrite] | add // 0' "$DAILY_FILE" 2>/dev/null || echo 0)
  fi

  # Format in k with thousand separators (tokens / 1000)
  add_commas() {
    echo "$1" | awk -F. '{
      intpart = $1;
      len = length(intpart);
      result = "";
      for (i = 1; i <= len; i++) {
        result = result substr(intpart, i, 1);
        if ((len - i) % 3 == 0 && i < len) result = result ",";
      }
      if (NF > 1) result = result "." $2;
      print result;
    }'
  }

  if [ "$sess_total" -ge 1000 ] 2>/dev/null; then
    sess_k=$(add_commas "$(awk "BEGIN { printf \"%.1f\", $sess_total / 1000 }")")K
  else
    sess_k="${sess_total}"
  fi
  if [ "$daily_total" -ge 1000 ] 2>/dev/null; then
    daily_k=$(add_commas "$(awk "BEGIN { printf \"%.1f\", $daily_total / 1000 }")")K
  else
    daily_k="${daily_total}"
  fi

  # Balance fetch (strategy depends on idle vs active state)
  balance="unknown"
  if [ -f "$BALANCE_FILE" ]; then
    balance=$(jq -r '.total_balance // "unknown"' "$BALANCE_FILE" 2>/dev/null || echo "unknown")
    cache_age=$(($(date +%s) - $(stat -f %m "$BALANCE_FILE" 2>/dev/null || echo 0)))
    if [ "$cache_age" -gt 90 ]; then
      refresh_balance_async
    fi
  else
    refresh_balance_async
    balance="unknown"
  fi

  balance_ready=false
  if [ "$balance" != "unknown" ] && [ "$balance" != "null" ] && [ -n "$balance" ]; then
    balance_ready=true
  fi

  if [ "$IS_IDLE" = "true" ]; then
    token_str="${LIGHT_PURPLE}0${RESET} · ${PINK}${daily_k}${RESET}"
    balance_str="$(format_balance_piece "$balance")"
  else
    token_str="${LIGHT_PURPLE}${sess_k}${RESET} · ${PINK}${daily_k}${RESET}"
    balance_str="$(format_balance_piece "$balance")"
  fi
fi

# ── Assemble ─────────────────────────────────────────────────────────
pieces=()
pieces+=("${CYAN}${model_name}${RESET}")
[ -n "$think_str" ] && pieces+=("$think_str")
pieces+=("$context_str")
pieces+=("${CYAN}${dir_display}${RESET}")

output=""
first=true
for piece in "${pieces[@]}"; do
  if $first; then
    output+="$piece"
    first=false
  else
    output+="  $piece"
  fi
done

second_line=""
if [ -n "$token_str" ] && [ -n "$balance_str" ]; then
  second_line="${token_str} · ${balance_str}"
elif [ -n "$token_str" ]; then
  second_line="$token_str"
elif [ -n "$balance_str" ]; then
  second_line="$balance_str"
fi

final_output=$(print_status_line "$output" "$second_line")
printf "%s" "$final_output"
