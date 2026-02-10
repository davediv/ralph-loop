#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────
#  ralph.sh — Ralph Loop runner for Claude Code
#
#  Feeds docs/PROMPT.md to Claude Code in a loop until the task
#  is complete or the iteration limit is reached.
#
#  Usage:
#    ./ralph.sh                      # defaults: 30 iterations, clean session
#    ./ralph.sh --max 50             # custom iteration cap
#    ./ralph.sh --promise DONE       # custom completion signal
#    ./ralph.sh --session clean      # fresh context every iteration
#    ./ralph.sh --session continue   # resume session (default)
#    ./ralph.sh --live               # stream Claude output live
# ──────────────────────────────────────────────────────────────

# ── Defaults ─────────────────────────────────────────────────
MAX_ITERATIONS=30
PROMPT_FILE="docs/PROMPT.md"
COMPLETION_PROMISE="<promise>COMPLETE</promise>"
LOG_DIR=".ralph"
LIVE=false
SESSION_MODE="clean"  # "continue" = resume session, "clean" = fresh context each iteration
SESSION_ID=""
COOLDOWN=3  # seconds between iterations

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
        (.text // "" | clean | clip(240) | select(length > 0) | "[assistant] " + .)
      elif .type == "tool_use" then
        "[tool] " + (.name // "unknown") + " " + ((.input // {} | tojson | clean | clip(180)))
      else empty end
  elif .type == "user" then
    .message.content[]?
    | select(.type == "tool_result")
    | (.content // "" | tostring | clean | clip(240) | select(length > 0) | "[tool-result] " + .)
  elif .type == "result" then
    "[result] " + ((.result // "" | clean | clip(240)))
    + (if .total_cost_usd? then " | cost=$" + (.total_cost_usd | tostring) else "" end)
  elif .type == "raw" then
    (.raw | clean | select(length > 0) | "[raw] " + .)
  else
    empty
  end
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

# ── Parse arguments ──────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --max)        MAX_ITERATIONS="$2"; shift 2 ;;
    --prompt)     PROMPT_FILE="$2"; shift 2 ;;
    --promise)    COMPLETION_PROMISE="$2"; shift 2 ;;
    --cooldown)   COOLDOWN="$2"; shift 2 ;;
    --session)
      if [[ "$2" == "continue" || "$2" == "clean" ]]; then
        SESSION_MODE="$2"
      else
        echo "Error: --session must be 'continue' or 'clean'"; exit 1
      fi
      shift 2 ;;
    --live)       LIVE=true; shift ;;
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
      echo "  --live         Stream Claude output to terminal in real time"
      echo "  -h, --help     Show this help message"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

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
echo ""

# ── Trap Ctrl+C for clean exit ───────────────────────────────
cleanup() {
  echo ""
  echo -e "${YELLOW}🚥 Ralph Loop interrupted at iteration ${ITERATION}/${MAX_ITERATIONS}${RESET}"
  echo -e "   Log saved to: ${MAGENTA}${RUN_LOG}${RESET}"
  exit 130
}
trap cleanup SIGINT SIGTERM

# ── Main loop ────────────────────────────────────────────────
ITERATION=0
COMPLETED=false

while [[ $ITERATION -lt $MAX_ITERATIONS ]]; do
  ITERATION=$((ITERATION + 1))

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

  if [[ "$LIVE" == true ]]; then
    # stream-json enables true live updates; jq formats events for readability.
    if command -v jq &>/dev/null; then
      claude --dangerously-skip-permissions --verbose "${CLAUDE_ARGS[@]}" --output-format stream-json --include-partial-messages 2>&1 \
        | tee "$ITER_LOG" \
        | jq --unbuffered -Rr "$LIVE_STREAM_FILTER" || true
    else
      echo -e "${YELLOW}Warning:${RESET} jq not found. Showing raw live JSON stream."
      claude --dangerously-skip-permissions --verbose "${CLAUDE_ARGS[@]}" --output-format stream-json --include-partial-messages 2>&1 | tee "$ITER_LOG" || true
    fi
    RESPONSE="$(cat "$ITER_LOG")"
  else
    RESPONSE="$(claude --dangerously-skip-permissions "${CLAUDE_ARGS[@]}" --output-format text 2>&1)" || true
    echo "$RESPONSE" > "$ITER_LOG"
    # Show a truncated preview
    PREVIEW="$(echo "$RESPONSE" | tail -20)"
    echo "$PREVIEW"
  fi

  # Log the iteration
  {
    echo "=== ITERATION ${ITERATION} — $(date) ==="
    echo "$RESPONSE"
    echo ""
  } >> "$RUN_LOG"

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
else
  echo -e "${YELLOW}${BOLD}  🫡  Max iterations (${MAX_ITERATIONS}) reached without completion.${RESET}"
  echo -e "  Tip: Increase --max or refine your prompt for convergence."
fi
echo -e "  ${BOLD}Iterations:${RESET}  ${ITERATION}"
echo -e "  ${BOLD}Full log:${RESET}    ${RUN_LOG}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
