# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Ralph Loop is a Bash utility that runs Claude Code CLI in an iterative loop, feeding the same prompt file until a task converges to completion. Based on the Ralph Wiggum technique — persistent iteration beats perfect first attempts. Pure Bash, no external dependencies beyond the Claude CLI.

## Running the Script

```bash
# Make executable (first time)
chmod +x ralph.sh

# Run with defaults (30 iterations, clean session, docs/PROMPT.md)
./ralph.sh

# Common options
./ralph.sh --live                    # Stream output to terminal
./ralph.sh --max 50                  # Custom iteration cap
./ralph.sh --session continue        # Resume same Claude session across iterations
./ralph.sh --prompt tasks/refactor.md  # Different prompt file
./ralph.sh --promise "DONE"          # Custom completion signal
./ralph.sh --cooldown 5              # Seconds between iterations
```

There is no build step, no test suite, no linting. The project is a single `ralph.sh` script.

## Architecture

### Execution Flow

1. Parse CLI args and validate prerequisites (Claude CLI installed, prompt file exists)
2. Set up logging directory (`.ralph/`)
3. Loop up to `MAX_ITERATIONS`:
   - Invoke `claude --dangerously-skip-permissions -p "$PROMPT" --output-format text`
   - Capture response to iteration log and run log
   - Check response for completion signal (`<promise>COMPLETE</promise>` by default)
   - If found: exit success. If not: cooldown and repeat.

### Session Modes

- **`clean`** (default): Fresh Claude session each iteration. No memory of prior passes. Claude re-assesses the (now modified) codebase from scratch.
- **`continue`**: Resumes same session via `--resume --session-id`. Claude retains context of what it tried previously. Session ID is extracted from first iteration's response.

### Key File Paths

| Path | Purpose |
|---|---|
| `ralph.sh` | The entire script (~208 lines) |
| `docs/PROMPT.md` | Default prompt file location (user-created) |
| `.ralph/` | Auto-created log directory |
| `.ralph/run_*.log` | Combined log for an entire run |
| `.ralph/iter_*_N.log` | Individual iteration log |

### Conventions

- Bash strict mode: `set -euo pipefail`
- Claude invoked with `--dangerously-skip-permissions` for unattended operation
- Exit codes: 0 (success), 1 (config/validation error), 130 (Ctrl+C interrupt)
- SIGINT/SIGTERM trapped for graceful cleanup with log preservation
- Errors from Claude invocation are caught with `|| true` to continue the loop
