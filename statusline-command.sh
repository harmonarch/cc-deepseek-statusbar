#!/usr/bin/env bash
# Claude Code Status Line with Deepseek balance tracking
# Display updates every 5s; token tracking runs every call for accuracy.
set -euo pipefail

DISPLAY_CACHE="/tmp/claude-deepseek/display_cache"
CACHE_TTL=5

input=$(cat)

# ── Parse all fields in one jq call ──────────────────────────────────
parsed=$(echo "$input" | jq -r '[
  .model.id // "",
  .model.display_name // .model.id // "?",
  .session_id // "unknown",
  .workspace.current_dir // "",
  (.context_window.used_percentage // empty),
  (.effort.level // empty),
  (.thinking.enabled // empty),
  (.cost.total_api_duration_ms // 0),
  (.context_window.current_usage.input_tokens // 0),
  (.context_window.current_usage.output_tokens // 0),
  (.context_window.current_usage.cache_read_input_tokens // 0),
  (.context_window.current_usage.cache_creation_input_tokens // 0),
  (.context_window.total_input_tokens // 0),
  (.context_window.total_output_tokens // 0),
  (.context_window.context_window_size // 0)
] | @tsv')

IFS=$'\t' read -r model_id model_name session_id cwd used_pct effort thinking_enabled \
     api_duration input_tokens output_tokens cache_read cache_write \
     ctx_total_in ctx_total_out ctx_size <<< "$parsed"

# ── ANSI colors ──────────────────────────────────────────────────────
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
RED=$'\033[0;31m'
CYAN=$'\033[0;36m'
MAGENTA=$'\033[0;35m'
DIM=$'\033[2m'
RESET=$'\033[0m'

choose_color() {
  local pct=$1
  if   [ "$pct" -le 40 ]; then echo "$GREEN"
  elif [ "$pct" -le 70 ]; then echo "$YELLOW"
  else                        echo "$RED"
  fi
}

# ══════════════════════════════════════════════════════════════════════
# Deepseek token tracking (ALWAYS runs - must be accurate)
# ══════════════════════════════════════════════════════════════════════
TRACKING_UPDATED=false

if [[ "$model_id" == deepseek-* ]]; then
  STATE_DIR="/tmp/claude-deepseek"
  mkdir -p "$STATE_DIR"

  PRICE_INPUT_CACHE_MISS=3.00
  PRICE_INPUT_CACHE_HIT=0.025
  PRICE_OUTPUT=6.00

  today=$(date +%Y-%m-%d)
  SESSION_FILE="${STATE_DIR}/session_${session_id}.json"
  DAILY_FILE="${STATE_DIR}/daily_${today}.json"
  BALANCE_FILE="${STATE_DIR}/balance_cache.json"

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
fi

# ══════════════════════════════════════════════════════════════════════
# Display cache check (AFTER tracking is done)
# ══════════════════════════════════════════════════════════════════════
if [ -f "$DISPLAY_CACHE" ] && [ "$TRACKING_UPDATED" = "false" ]; then
  cache_time=$(stat -f %m "$DISPLAY_CACHE" 2>/dev/null || echo 0)
  now=$(date +%s)
  if [ $((now - cache_time)) -lt $CACHE_TTL ]; then
    cat "$DISPLAY_CACHE"
    exit 0
  fi
fi

# ══════════════════════════════════════════════════════════════════════
# Regenerate display (every 5s, or immediately if tracking updated)
# ══════════════════════════════════════════════════════════════════════

# Context bar
context_str=""
if [ -n "$used_pct" ]; then
  used_int=$(printf "%.0f" "$used_pct")
  clr=$(choose_color "$used_int")
  filled=$(( used_int * 10 / 100 ))
  [ "$filled" -gt 10 ] && filled=10
  empty=$(( 10 - filled ))
  bar=""
  for ((i=0; i<filled; i++)); do bar+="█"; done
  for ((i=0; i<empty;  i++)); do bar+="░"; done
  context_str="${clr}${bar} ${used_int}%${RESET}"
else
  context_str="${DIM}(no data)${RESET}"
fi

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
deepseek_str=""
if [[ "$model_id" == deepseek-* ]]; then
  STATE_DIR="/tmp/claude-deepseek"
  SESSION_FILE="${STATE_DIR}/session_${session_id}.json"
  DAILY_FILE="${STATE_DIR}/daily_$(date +%Y-%m-%d).json"
  BALANCE_FILE="${STATE_DIR}/balance_cache.json"

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

  # Balance cache (refresh if older than 90s, background)
  balance="?"
  if [ -f "$BALANCE_FILE" ]; then
    balance=$(jq -r '.total_balance // "?"' "$BALANCE_FILE" 2>/dev/null || echo "?")
    cache_age=$(($(date +%s) - $(stat -f %m "$BALANCE_FILE" 2>/dev/null || echo 0)))
    if [ "$cache_age" -gt 90 ]; then
      (curl -s -L -X GET 'https://api.deepseek.com/user/balance' \
        -H 'Accept: application/json' \
        -H "Authorization: Bearer ${ANTHROPIC_AUTH_TOKEN}" 2>/dev/null | \
        jq -c '{total_balance: (.balance_infos[0].total_balance // "?"), updated_at: now}' \
        > "$BALANCE_FILE" 2>/dev/null) &
    fi
  else
    result=$(curl -s -L -X GET 'https://api.deepseek.com/user/balance' \
      -H 'Accept: application/json' \
      -H "Authorization: Bearer ${ANTHROPIC_AUTH_TOKEN}" 2>/dev/null)
    balance=$(echo "$result" | jq -r '.balance_infos[0].total_balance // "?"' 2>/dev/null || echo "?")
    echo "{\"total_balance\":\"$balance\",\"updated_at\":$(date +%s)}" > "$BALANCE_FILE"
  fi

  deepseek_str="${MAGENTA}${sess_k}${RESET} · ${DIM}${daily_k}${RESET} · ${GREEN}¥${balance}${RESET}"
fi

# ── Assemble ─────────────────────────────────────────────────────────
pieces=()
pieces+=("${CYAN}${model_name}${RESET}")
[ -n "$think_str" ] && pieces+=("$think_str")
pieces+=("$context_str")
[ -n "$deepseek_str" ] && pieces+=("$deepseek_str")
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

printf "%s" "$output" | tee "$DISPLAY_CACHE"
