# Ralph Loop for Claude Code
A minimal Bash script that runs [Claude Code](https://docs.anthropic.com/en/docs/claude-code) in a loop, feeding it the same prompt file until the task converges on completion. Based on the [Ralph Wiggum technique](https://github.com/anthropics/claude-code/tree/main/plugins/ralph-wiggum) by Geoffrey Huntley. Persistent iteration beats perfect first attempts.

```
  ╔══════════════════════════════════════╗
  ║              Ralph Loop              ║
  ║        We Don't Do One-Time.        ║
  ╚══════════════════════════════════════╝
```

## How It Works

1. You write your task in `docs/PROMPT.md`
2. The script feeds it to Claude Code in non-interactive mode
3. Claude works on the task, modifies your files, runs commands
4. The script checks if Claude output the completion signal
5. If not — loop again. Same prompt, same codebase (now modified), fresh attempt
6. Repeat until done or the iteration limit is hit

Each iteration sees the codebase as Claude left it in the prior pass. Failures become data. The work accumulates across loops.

## Prerequisites

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI installed and authenticated

  ```bash
  curl -fsSL https://claude.ai/install.sh | bash
  ```

## Quick Start

1. **Clone the repo and make the script executable:**

   ```bash
   git clone https://github.com/davediv/ralph-loop.git
   cd ralph-loop
   chmod +x ralph.sh
   ```

2. **Create your prompt file:**

   ```bash
   mkdir -p docs
   cat > docs/PROMPT.md << 'EOF'
   ## Task

   Build a REST API for a todo app with full CRUD endpoints.

   ## Requirements
   - Express.js with TypeScript
   - Input validation
   - Tests with >80% coverage
   - README with API documentation

   ## Completion

   When ALL requirements are met and all tests pass,
   output: <promise>COMPLETE</promise>
   EOF
   ```

3. **Run it:**

   ```bash
   ./ralph.sh
   ```

4. **Go get coffee.** Come back to commits.

## Usage

```
./ralph.sh [OPTIONS]
```

### Options

| Flag | Description | Default |
|---|---|---|
| `--max N` | Maximum number of iterations | `30` |
| `--prompt FILE` | Path to the prompt file | `docs/PROMPT.md` |
| `--promise TEXT` | Completion signal to watch for | `<promise>COMPLETE</promise>` |
| `--cooldown N` | Seconds to wait between iterations | `3` |
| `--session MODE` | Session mode: `clean` or `continue` | `clean` |
| `--live` | Stream Claude's output to terminal in real time | `true` |
| `--no-live` | Disable live stream output (text mode preview) | `false` |
| `--idle-timeout N` | Live mode inactivity timeout (seconds without new output) | `600` |
| `--hard-timeout N` | No-live mode hard timeout (max seconds per iteration) | `1800` |
| `--kill-grace N` | Grace period between `TERM` and `KILL` when stopping stuck processes | `5` |
| `-h, --help` | Show help message | — |

### Examples

```bash
# Basic — uses all defaults
./ralph.sh

# Watch Claude work in real time
./ralph.sh --live

# Disable live stream output (non-live text mode)
./ralph.sh --no-live

# Long-running task with more iterations
./ralph.sh --max 50 --live

# Use a different prompt file
./ralph.sh --prompt tasks/refactor.md

# Custom completion signal
./ralph.sh --promise "DONE"

# Resume session across iterations (Claude retains context)
./ralph.sh --session continue

# Combine options
./ralph.sh --max 50 --session continue --live --cooldown 5

# Tighten hang detection while debugging a flaky prompt
./ralph.sh --live --idle-timeout 120 --kill-grace 3

# No-live mode with a stricter wall-clock cap
./ralph.sh --no-live --hard-timeout 900
```

## Session Modes

### `clean` (default)

Each iteration starts a fresh Claude session with no memory of prior iterations. Claude approaches the codebase with fresh eyes every time.

**Best for:**
- Tasks where context buildup causes drift or confusion
- Large codebases where you want Claude to re-assess from scratch
- The classic Ralph philosophy — pure `while :; do cat PROMPT.md | claude; done`

### `continue`

Resumes the same Claude session across iterations. Claude remembers what it tried and changed in previous passes.

**Best for:**
- Iterative refinement where Claude needs to know what it already attempted
- Multi-step tasks that build on each other
- Debugging loops where prior error context is valuable

## Writing Good Prompts

The quality of your prompt determines whether the loop converges. A few tips:

**Be specific about success criteria.** Claude needs to know when it's done.

```markdown
When all tests pass and coverage exceeds 80%, output <promise>COMPLETE</promise>
```

**Break large tasks into phases.** Give Claude a clear sequence.

```markdown
Phase 1: Set up project structure and dependencies
Phase 2: Implement core API endpoints
Phase 3: Add input validation
Phase 4: Write tests
Phase 5: Write documentation

Complete each phase before moving to the next.
Output <promise>COMPLETE</promise> when all phases are done.
```

**Include guardrails.** Tell Claude what NOT to do.

```markdown
- Do NOT delete existing tests
- Do NOT change the database schema
- Commit after completing each phase
```

**Use verifiable criteria.** Things Claude can check programmatically.

```markdown
- `npm test` passes with 0 failures
- `npm run lint` exits cleanly
- `npm run build` produces no errors
```

## Logs

All output is saved to the `.ralph/` directory:

```
.ralph/
├── run_20260204_143022.log          # Combined log for the entire run
├── iter_20260204_143022_1.log       # Individual iteration logs
├── iter_20260204_143022_2.log
└── iter_20260204_143022_3.log
```

Use logs to review what Claude did across iterations, debug convergence issues, or audit changes.

## Project Structure

```
.
├── ralph.sh          # The loop script
├── docs/
│   └── PROMPT.md     # Your task prompt (you create this)
├── .ralph/           # Logs (auto-created on first run)
└── README.md
```

## Safety

- **Iteration cap** — `--max` prevents runaway loops (default: 30). Always set a reasonable limit.
- **Ctrl+C** — Deterministic interrupt handling. Active Claude/tool processes are terminated, then Ralph exits with code `130`.
- **Hang protection** — In `--live`, Ralph aborts the run if no new output arrives for `--idle-timeout` seconds (default: 600). In `--no-live`, each iteration has a hard wall-clock cap via `--hard-timeout` (default: 1800). Timeout exits use code `124`.
- **Kill escalation** — Stuck processes receive `TERM`, then `KILL` after `--kill-grace` seconds (default: 5).
- **`--dangerously-skip-permissions`** — The script runs Claude in unattended mode. Make sure you trust your prompt and run in a git-tracked directory so you can revert.
- **Cost awareness** — Each iteration is an API call. A 30-iteration loop on a large codebase can cost $30–100+ depending on context size. Monitor your usage.

### Recommended: Run in a Git Repo

Always run Ralph in a git-tracked directory. If something goes wrong, you can revert:

```bash
git init
git add -A && git commit -m "before ralph"
./ralph.sh --live
# If things go sideways:
git diff          # see what changed
git checkout .    # revert everything
```

## Tips

- Start with `--max 5 --live` to validate your prompt before letting it run unattended
- Add `git add -A && git commit -m "iteration complete"` instructions in your prompt so Claude commits after each pass
- Use `.gitignore` to exclude `.ralph/` logs from your repo
- If Claude keeps looping without converging, refine your success criteria — don't just increase `--max`

## Credits

Based on the [Ralph Wiggum technique](https://github.com/anthropics/claude-code/tree/main/plugins/ralph-wiggum) by [Geoffrey Huntley](https://ghuntley.com). The core idea: persistent iteration despite setbacks.

## License

MIT
