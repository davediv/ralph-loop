#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────
#  ralph.sh — Ralph Loop runner for Claude Code
#
#  Feeds docs/PROMPT.md to Claude Code in a loop until the task
#  is complete or the iteration limit is reached.
#
#  Usage:
#    ./ralph.sh                      # defaults: 30 iterations, clean session, live stream on
#    ./ralph.sh --max 50             # custom iteration cap
#    ./ralph.sh --promise DONE       # custom completion signal
#    ./ralph.sh --session clean      # fresh context every iteration
#    ./ralph.sh --session continue   # resume session across iterations
#    ./ralph.sh --live               # stream Claude output live
#    ./ralph.sh --no-live            # disable live stream output
#    ./ralph.sh --idle-timeout 600   # live mode inactivity timeout (seconds)
#    ./ralph.sh --hard-timeout 1800  # no-live mode hard timeout (seconds)
#    ./ralph.sh --kill-grace 5       # seconds between TERM and KILL
# ──────────────────────────────────────────────────────────────

# ── Defaults ─────────────────────────────────────────────────
MAX_ITERATIONS=30
PROMPT_FILE="docs/PROMPT.md"
COMPLETION_PROMISE="<promise>COMPLETE</promise>"
LOG_DIR=".ralph"
LIVE=true
SESSION_MODE="clean"  # "continue" = resume session, "clean" = fresh context each iteration
SESSION_ID=""
COOLDOWN=3  # seconds between iterations
LIVE_IDLE_TIMEOUT=600      # seconds with no output in live mode before abort
NO_LIVE_HARD_TIMEOUT=1800  # max runtime per iteration in no-live mode
KILL_GRACE=5               # seconds to wait between TERM and KILL

# jq filter to render stream-json events in a readable live format.
# Raw stream lines are still written to iteration logs.
LIVE_STREAM_FILTER="$(cat <<'JQ'
def clean: gsub("\r?\n+"; " ") | gsub(" +"; " ");
def clip($n): if length > $n then .[0:$n] + "..." else . end;
. as $raw
| (fromjson? // {"type":"raw","raw":$raw})
| if .type == "assistant" then
    .message.content[]?
    | if .type == "text" then
        (.text // "" | clean | clip(240) | select(length > 0) | "👽 " + ($assistant_prefix_start + . + $assistant_prefix_end))
      elif .type == "tool_use" then
        "⚙️  " + (.name // "unknown") + " " + ((.input // {} | tojson | clean | clip(180)))
      else empty end
  elif .type == "user" then
    .message.content[]?
    | select(.type == "tool_result")
    | (.content // "" | tostring | clean | clip(240) | select(length > 0) | "🦾 " + .)
  elif .type == "result" then
    "✅ " + ((.result // "" | clean | clip(240)))
    + (if .total_cost_usd? then " | cost=$" + (.total_cost_usd | tostring) else "" end)
  elif .type == "raw" then
    (.raw | clean | select(length > 0) | "[raw] " + .)
  else
    empty
  end
| . + "\n"
JQ
)"

# ── Colors ───────────────────────────────────────────────────
RED='\033[0;31m'
LIGHTRED='\033[1;31m'
GREEN='\033[0;32m'
LIGHTGREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
LIGHTBLUE='\033[1;34m'
MAGENTA='\033[1;35m'
CYAN='\033[0;36m'
LIGHTCYAN='\033[1;36m'
BOLD='\033[1m'
RESET='\033[0m'
ASSISTANT_PREFIX_START="$(printf '\033[1;32m')"
ASSISTANT_PREFIX_END="$(printf '\033[0m')"

is_non_negative_int() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

require_int_ge() {
  local name="$1"
  local value="$2"
  local min="$3"

  if ! is_non_negative_int "$value"; then
    echo -e "${RED}Error:${RESET} ${name} must be a non-negative integer (got: ${value})"
    exit 1
  fi

  if (( value < min )); then
    echo -e "${RED}Error:${RESET} ${name} must be >= ${min} (got: ${value})"
    exit 1
  fi
}

file_size_bytes() {
  local file_path="$1"
  if [[ -f "$file_path" ]]; then
    wc -c <"$file_path"
  else
    echo 0
  fi
}

# Active process/FIFO state for the current iteration.
ACTIVE_CLAUDE_PID=""
ACTIVE_TEE_PID=""
ACTIVE_RENDER_PID=""
ACTIVE_RAW_FIFO=""
ACTIVE_DISPLAY_FIFO=""
ITERATION=0

cleanup_active_resources() {
  [[ -n "${ACTIVE_RAW_FIFO}" ]] && rm -f "${ACTIVE_RAW_FIFO}" || true
  [[ -n "${ACTIVE_DISPLAY_FIFO}" ]] && rm -f "${ACTIVE_DISPLAY_FIFO}" || true
  ACTIVE_CLAUDE_PID=""
  ACTIVE_TEE_PID=""
  ACTIVE_RENDER_PID=""
  ACTIVE_RAW_FIFO=""
  ACTIVE_DISPLAY_FIFO=""
}

kill_descendants_signal() {
  local pid="$1"
  local signal_name="$2"
  local children=""
  local child

  if ! command -v pgrep &>/dev/null; then
    return
  fi

  children="$(pgrep -P "$pid" 2>/dev/null || true)"
  if [[ -z "$children" ]]; then
    return
  fi

  for child in $children; do
    kill_descendants_signal "$child" "$signal_name"
    kill "-${signal_name}" "$child" 2>/dev/null || true
  done
}

kill_with_escalation() {
  local pid="$1"
  local grace_seconds="$2"
  local start_time
  local now

  if [[ -z "$pid" ]]; then
    return
  fi

  if ! kill -0 "$pid" 2>/dev/null; then
    return
  fi

  kill_descendants_signal "$pid" "TERM"
  kill -TERM "$pid" 2>/dev/null || true

  start_time="$(date +%s)"
  while kill -0 "$pid" 2>/dev/null; do
    now="$(date +%s)"
    if (( now - start_time >= grace_seconds )); then
      break
    fi
    sleep 1
  done

  if kill -0 "$pid" 2>/dev/null; then
    kill_descendants_signal "$pid" "KILL"
    kill -KILL "$pid" 2>/dev/null || true
  fi

  wait "$pid" 2>/dev/null || true
}

terminate_active_iteration() {
  local reason="$1"
  if [[ -n "$reason" ]]; then
    echo -e "${YELLOW}⏱️  ${reason}${RESET}"
  fi

  kill_with_escalation "${ACTIVE_CLAUDE_PID}" "${KILL_GRACE}"
  kill_with_escalation "${ACTIVE_TEE_PID}" "${KILL_GRACE}"
  kill_with_escalation "${ACTIVE_RENDER_PID}" "${KILL_GRACE}"
}

run_live_iteration() {
  local iter_log="$1"
  local last_size
  local current_size
  local last_activity
  local now
  local idle_seconds
  local claude_status=0
  local tee_status=0
  local render_status=0

  : > "$iter_log"

  ACTIVE_RAW_FIFO="${iter_log}.raw.fifo"
  ACTIVE_DISPLAY_FIFO="${iter_log}.display.fifo"
  rm -f "${ACTIVE_RAW_FIFO}" "${ACTIVE_DISPLAY_FIFO}"
  mkfifo "${ACTIVE_RAW_FIFO}" "${ACTIVE_DISPLAY_FIFO}"

  if command -v jq &>/dev/null; then
    jq --unbuffered -Rr \
      --arg assistant_prefix_start "$ASSISTANT_PREFIX_START" \
      --arg assistant_prefix_end "$ASSISTANT_PREFIX_END" \
      "$LIVE_STREAM_FILTER" <"${ACTIVE_DISPLAY_FIFO}" &
  else
    echo -e "${YELLOW}Warning:${RESET} jq not found. Showing raw live JSON stream."
    cat <"${ACTIVE_DISPLAY_FIFO}" &
  fi
  ACTIVE_RENDER_PID=$!

  tee "$iter_log" <"${ACTIVE_RAW_FIFO}" >"${ACTIVE_DISPLAY_FIFO}" &
  ACTIVE_TEE_PID=$!

  claude --dangerously-skip-permissions --verbose "${CLAUDE_ARGS[@]}" --output-format stream-json --include-partial-messages >"${ACTIVE_RAW_FIFO}" 2>&1 &
  ACTIVE_CLAUDE_PID=$!

  last_size="$(file_size_bytes "$iter_log")"
  last_activity="$(date +%s)"

  while kill -0 "${ACTIVE_CLAUDE_PID}" 2>/dev/null; do
    current_size="$(file_size_bytes "$iter_log")"
    if [[ "$current_size" != "$last_size" ]]; then
      last_size="$current_size"
      last_activity="$(date +%s)"
    fi

    now="$(date +%s)"
    idle_seconds=$((now - last_activity))
    if (( idle_seconds >= LIVE_IDLE_TIMEOUT )); then
      ITER_TIMEOUT_REASON="Live mode inactivity timeout: no output for ${LIVE_IDLE_TIMEOUT}s"
      terminate_active_iteration "$ITER_TIMEOUT_REASON"
      cleanup_active_resources
      return 124
    fi

    sleep 1
  done

  set +e
  wait "${ACTIVE_CLAUDE_PID}"
  claude_status=$?
  wait "${ACTIVE_TEE_PID}"
  tee_status=$?
  wait "${ACTIVE_RENDER_PID}"
  render_status=$?
  set -e

  cleanup_active_resources

  if (( claude_status != 0 )); then
    return "$claude_status"
  fi
  if (( tee_status != 0 )); then
    return "$tee_status"
  fi
  if (( render_status != 0 )); then
    echo -e "${YELLOW}Warning:${RESET} Live renderer exited with status ${render_status}"
  fi

  return 0
}

run_nolive_iteration() {
  local iter_log="$1"
  local start_time
  local now
  local elapsed
  local claude_status=0

  : > "$iter_log"
  claude --dangerously-skip-permissions "${CLAUDE_ARGS[@]}" --output-format text >"$iter_log" 2>&1 &
  ACTIVE_CLAUDE_PID=$!

  start_time="$(date +%s)"
  while kill -0 "${ACTIVE_CLAUDE_PID}" 2>/dev/null; do
    now="$(date +%s)"
    elapsed=$((now - start_time))
    if (( elapsed >= NO_LIVE_HARD_TIMEOUT )); then
      ITER_TIMEOUT_REASON="No-live hard timeout: exceeded ${NO_LIVE_HARD_TIMEOUT}s"
      terminate_active_iteration "$ITER_TIMEOUT_REASON"
      cleanup_active_resources
      return 124
    fi
    sleep 1
  done

  set +e
  wait "${ACTIVE_CLAUDE_PID}"
  claude_status=$?
  set -e

  cleanup_active_resources
  return "$claude_status"
}

# ── Parse arguments ──────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --max)        MAX_ITERATIONS="$2"; shift 2 ;;
    --prompt)     PROMPT_FILE="$2"; shift 2 ;;
    --promise)    COMPLETION_PROMISE="$2"; shift 2 ;;
    --cooldown)   COOLDOWN="$2"; shift 2 ;;
    --idle-timeout) LIVE_IDLE_TIMEOUT="$2"; shift 2 ;;
    --hard-timeout) NO_LIVE_HARD_TIMEOUT="$2"; shift 2 ;;
    --kill-grace) KILL_GRACE="$2"; shift 2 ;;
    --session)
      if [[ "$2" == "continue" || "$2" == "clean" ]]; then
        SESSION_MODE="$2"
      else
        echo "Error: --session must be 'continue' or 'clean'"; exit 1
      fi
      shift 2 ;;
    --live)       LIVE=true; shift ;;
    --no-live)    LIVE=false; shift ;;
    --help|-h)
      echo "Usage: ./ralph.sh [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --max N        Maximum iterations (default: 30)"
      echo "  --prompt FILE  Prompt file path (default: docs/PROMPT.md)"
      echo "  --promise TXT  Completion signal to look for (default: <promise>COMPLETE</promise>)"
      echo "  --cooldown N   Seconds to wait between iterations (default: 3)"
      echo "  --session MODE Session mode: 'continue' or 'clean' (default: clean)"
      echo "                   continue — resume same session, Claude retains context"
      echo "                   clean    — fresh session each iteration, no prior context"
      echo "  --live         Stream Claude output to terminal in real time (default: true)"
      echo "  --no-live      Disable live output stream (uses text output mode)"
      echo "  --idle-timeout N  Live mode inactivity timeout in seconds (default: 600)"
      echo "  --hard-timeout N  No-live mode hard timeout in seconds (default: 1800)"
      echo "  --kill-grace N    Seconds to wait after TERM before KILL (default: 5)"
      echo "  -h, --help     Show this help message"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

require_int_ge "--max" "$MAX_ITERATIONS" 1
require_int_ge "--cooldown" "$COOLDOWN" 0
require_int_ge "--idle-timeout" "$LIVE_IDLE_TIMEOUT" 1
require_int_ge "--hard-timeout" "$NO_LIVE_HARD_TIMEOUT" 1
require_int_ge "--kill-grace" "$KILL_GRACE" 0

# ── Preflight checks ────────────────────────────────────────
if ! command -v claude &>/dev/null; then
  echo -e "${RED}Error:${RESET} 'claude' CLI not found. Install Claude Code first."
  echo "  npm install -g @anthropic-ai/claude-code"
  exit 1
fi

if [[ ! -f "$PROMPT_FILE" ]]; then
  echo -e "${RED}Error:${RESET} Prompt file not found: ${PROMPT_FILE}"
  exit 1
fi

PROMPT="$(cat "$PROMPT_FILE")"
if [[ -z "$PROMPT" ]]; then
  echo -e "${RED}Error:${RESET} Prompt file is empty: ${PROMPT_FILE}"
  exit 1
fi

# ── Setup logging ────────────────────────────────────────────
mkdir -p "$LOG_DIR"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
RUN_LOG="${LOG_DIR}/run_${TIMESTAMP}.log"

# ── Banner ───────────────────────────────────────────────────
echo -e "${BOLD}${CYAN}"
echo "  ╔════════════════════════════════════════╗"
echo "  ║               Ralph Loop               ║"
echo "  ║         We Don't Do One-Time           ║"
echo "  ╚════════════════════════════════════════╝"
echo -e "${RESET}"
echo -e "  ${LIGHTRED}Prompt:${RESET}     ${PROMPT_FILE}"
echo -e "  ${LIGHTGREEN}Max iter:${RESET}   ${MAX_ITERATIONS}"
echo -e "  ${YELLOW}Promise:${RESET}    ${COMPLETION_PROMISE}"
echo -e "  ${LIGHTBLUE}Log:${RESET}        ${RUN_LOG}"
echo -e "  ${MAGENTA}Session:${RESET}    ${SESSION_MODE}"
echo -e "  ${LIGHTCYAN}Live:${RESET}       ${LIVE}"
echo -e "  ${LIGHTCYAN}Idle timeout:${RESET} ${LIVE_IDLE_TIMEOUT}s (live mode)"
echo -e "  ${LIGHTCYAN}Hard timeout:${RESET} ${NO_LIVE_HARD_TIMEOUT}s (no-live mode)"
echo -e "  ${LIGHTCYAN}Kill grace:${RESET}  ${KILL_GRACE}s"
echo ""

# ── Trap Ctrl+C for clean exit ───────────────────────────────
cleanup() {
  echo ""
  terminate_active_iteration "Interrupted by signal"
  cleanup_active_resources
  echo -e "${YELLOW}🚥 Ralph Loop interrupted at iteration ${ITERATION}/${MAX_ITERATIONS}${RESET}"
  echo -e "   Log saved to: ${MAGENTA}${RUN_LOG}${RESET}"
  exit 130
}
trap cleanup SIGINT SIGTERM

# ── Main loop ────────────────────────────────────────────────
ITERATION=0
COMPLETED=false
TIMED_OUT=false
EXIT_CODE=0
TIMEOUT_REASON=""

while [[ $ITERATION -lt $MAX_ITERATIONS ]]; do
  ITERATION=$((ITERATION + 1))
  ITER_TIMEOUT_REASON=""

  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "${BOLD} 🤖 Iteration ${LIGHTGREEN}${ITERATION}/${GREEN}${MAX_ITERATIONS}${RESET}🍀   🎯 $(date '+%H:%M:%S')"
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"

  # Build claude command args
  CLAUDE_ARGS=(-p "$PROMPT")

  # Continue session after first iteration for context continuity
  if [[ "$SESSION_MODE" == "continue" && -n "$SESSION_ID" ]]; then
    CLAUDE_ARGS+=(--resume --session-id "$SESSION_ID")
  fi

  # Run Claude Code and capture output
  ITER_LOG="${LOG_DIR}/iter_${TIMESTAMP}_${ITERATION}.log"

  ITER_STATUS=0
  if [[ "$LIVE" == true ]]; then
    run_live_iteration "$ITER_LOG" || ITER_STATUS=$?
  else
    run_nolive_iteration "$ITER_LOG" || ITER_STATUS=$?
  fi

  RESPONSE="$(cat "$ITER_LOG")"

  if [[ "$LIVE" != true ]]; then
    # Show a truncated preview
    PREVIEW="$(echo "$RESPONSE" | tail -20 || true)"
    echo "$PREVIEW"
  fi

  # Log the iteration
  {
    echo "=== ITERATION ${ITERATION} — $(date) ==="
    echo "Exit status: ${ITER_STATUS}"
    if [[ -n "$ITER_TIMEOUT_REASON" ]]; then
      echo "Timeout: ${ITER_TIMEOUT_REASON}"
    fi
    echo "$RESPONSE"
    echo ""
  } >> "$RUN_LOG"

  if (( ITER_STATUS == 124 )); then
    TIMED_OUT=true
    TIMEOUT_REASON="$ITER_TIMEOUT_REASON"
    EXIT_CODE=124
    echo -e "${LIGHTRED}${BOLD}  ❌ Iteration ${ITERATION} timed out. Aborting run.${RESET}"
    break
  fi

  if (( ITER_STATUS != 0 )); then
    echo -e "${YELLOW}  ⚠️  Claude exited with status ${ITER_STATUS}. Continuing.${RESET}"
  fi

  # Capture session ID from first run for continuity (only in continue mode)
  if [[ "$SESSION_MODE" == "continue" && $ITERATION -eq 1 && -z "$SESSION_ID" ]]; then
    # Try to extract session ID if claude outputs one
    MAYBE_SESSION="$(echo "$RESPONSE" | grep -oE 'session[_-]?id["[:space:]]*[:=]["[:space:]]*[a-zA-Z0-9_-]+' | head -n1 | sed -E 's/.*[:=]["[:space:]]*//' || true)"
    if [[ -n "$MAYBE_SESSION" ]]; then
      SESSION_ID="$MAYBE_SESSION"
      echo -e "  ${GREEN}📎 Session: ${SESSION_ID}${RESET}"
    fi
  fi

  # Check for completion promise
  if echo "$RESPONSE" | grep -qF "$COMPLETION_PROMISE"; then
    COMPLETED=true
    echo ""
    echo -e "${LIGHTGREEN}${BOLD}  ✅  Completion promise detected!${RESET}"
    echo -e "${LIGHTGREEN}  Task completed in ${ITERATION} iteration(s).${RESET}"
    break
  fi

  # Check for empty / error responses
  if [[ -z "$RESPONSE" ]]; then
    echo -e "${YELLOW} 📭😱  Empty response. Claude may have hit a limit.${RESET}"
  fi

  # Cooldown between iterations
  if [[ $ITERATION -lt $MAX_ITERATIONS ]]; then
    echo -e "  ${BOLD}  🧘  ${LIGHTBLUE}Next iteration in ${COOLDOWN}s...${RESET}"
    sleep "$COOLDOWN"
  fi
done

# ── Summary ──────────────────────────────────────────────────
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
if [[ "$COMPLETED" == true ]]; then
  echo -e "${GREEN}${BOLD}  🎉 ✅ 🥳 Ralph Loop finished successfully!${RESET}"
elif [[ "$TIMED_OUT" == true ]]; then
  echo -e "${LIGHTRED}${BOLD}  ⏱️  Ralph Loop aborted due to timeout.${RESET}"
  echo -e "  Reason: ${TIMEOUT_REASON}"
else
  echo -e "${YELLOW}${BOLD}  🫡  Max iterations (${MAX_ITERATIONS}) reached without completion.${RESET}"
  echo -e "  Tip: Increase --max or refine your prompt for convergence."
fi
echo -e "  ${BOLD}Iterations:${RESET}  ${ITERATION}"
echo -e "  ${BOLD}Full log:${RESET}    ${RUN_LOG}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
exit "$EXIT_CODE"
