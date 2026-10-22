# plan-keeper

plan-keeper keeps a short `.claude/PLAN.md` in each project:

- **Before work:** Claude adds or merges the request into the plan.
- **After a turn that changed files:** the plan is updated: finished items deleted, related ones merged. With the optional agy writer (below), a free Gemini model does this in the background and Claude never does.
- **New session, `/clear` or compaction:** the plan is re-injected automatically, so Claude resumes where it left off.

### Decisions you haven't answered: `.claude/DECISIONS.md`

1. **Detect (free):** when Claude stops, the Stop hook reads its last reply in shell. It picks up `DECIDE: …` lines, or the last line if it ends with `?` (plus the line before it as context), and saves them to `.claude/.last-ask`. Claude is told to write each question self-contained (feature/file, what prompted it, options), and entries in `DECISIONS.md` carry a `-- context:` part, so a later session still knows what each question was about.
2. **You reply:** your next prompt carries a ~40-token note listing those questions. If your message doesn't settle one, Claude appends it to `DECISIONS.md`. If it does, nothing happens.
3. **You forgot:** if the session ends or you `/clear` without replying, the next session moves the questions into `DECISIONS.md` automatically, with no model call.
4. **Reminder:** every new session shows the pending list, and Claude mentions it in one line. Once you answer an item, Claude deletes it. `/plan-keeper:answer-pending-questions` reviews them all at once.

#### Optional: local Ollama classifier (never blocks Claude)

The regex fallback misses questions that aren't on the last line. To have a local model find them instead, set these in `~/.claude/settings.json` under `"env"`:

```json
"env": { "PLAN_KEEPER_OLLAMA_MODEL": "nimble:latest" }
```

Optional: `PLAN_KEEPER_OLLAMA_URL` (default `http://localhost:11434`) and `PLAN_KEEPER_OLLAMA_TIMEOUT` (seconds, default 60).

**Sharing the model with other tools** (e.g. lm-on / lm-ask):
- By default it only uses the model if it's already loaded (checked via `/api/ps`). It never loads the model itself, so `lm-off` or a keep-alive expiry frees the GPU as usual. Set `PLAN_KEEPER_OLLAMA_LOAD=1` to let it load the model.
- It sends `keep_alive` from `LOCAL_MODEL_KEEP_ALIVE` (default `10m`), the same as lm-on, so it never shortens or stretches that timer.
- It sets no `num_ctx`, so Ollama reuses the same loaded instance.
- In tests with `nimble:latest` it got 6/6 sample replies right in 0.4–0.9s. OpenCode free models took 5–90s and mixed up questions from earlier replies.

- It runs as a separate `async` Stop hook, so Claude never waits for it. It costs 0 Claude tokens.
- It only runs when the reply has no `DECIDE:` lines. Its answer replaces the regex guess in `.claude/.last-ask`.
- If you send your next prompt before the model answers, the result is discarded as stale. If Ollama is down, the regex result stays.
- With `PLAN_KEEPER_OLLAMA_MODEL` unset, it exits immediately.

### Optional: agy writes the plan (0 Claude tokens)

Set this in the project's `.claude/settings.local.json` (or `~/.claude/settings.json`) under `"env"`:

```json
"env": { "PLAN_KEEPER_AGY_MODEL": "gemini-3.8-flash-high" }
```

- After every turn that changed files, an `async` Stop hook runs `agy -p` with the current plan, your last prompt, Claude's final reply and `git status`, and writes the new PLAN.md. Claude never waits and never edits the plan itself. The per-prompt "add it to the plan first" reminder is dropped too.
- "Changed files" is a checksum of `git status` + `git diff` taken at each prompt and compared at stop, so there is no per-edit hook. Non-git projects are never updated automatically.
- Output must contain `## Now`, `## Next` and `## Log` and stay under 90 lines, or it's rejected. The previous plan is kept in `.claude/.PLAN.md.bak`.
- The same call also returns a one-line summary of the turn, appended to `.claude/HISTORY.md` with the date and time: a timeline of the work, never loaded into context (read it or grep it when you need it). Turns where Claude edited the plan itself get the commit subjects of that turn instead, with no model call. Log lines that drop out of PLAN.md are moved to HISTORY.md too, not deleted.
- If agy fails or times out, the reason goes to `.claude/.plan-agy.log` and it retries at the next stop. If Claude edited the plan in the meantime, agy's result is discarded.
- Optional: `PLAN_KEEPER_AGY_BIN` (default `agy`), `PLAN_KEEPER_AGY_TIMEOUT` (seconds, default 90). A run usually takes 15–50s.

### Token cost

| Hook | When | Cost |
|---|---|---|
| SessionStart | startup / clear / compact | size of PLAN.md (kept under ~60 lines) |
| SessionStart (decisions) | only if DECISIONS.md has items | ~15 tokens per item, plus the always-on `DECIDE:` rule (~25) |
| UserPromptSubmit | every prompt | ~20 tokens (0 with agy), +~35 only when the previous reply asked you something |
| Stop | end of turn | with agy: 0. Without: 0 unless files changed and the plan wasn't updated; then 1 short forced update, at most once per turn |
| Stop (async, optional) | end of turn, if Ollama / agy is configured | 0 (runs in the background) |

Without agy, projects without a `.claude/PLAN.md` never get forced updates. With agy, the first working turn creates the plan.

### Install (all OSes)

In Claude Code:

```
/plugin marketplace add <path-to-plan-keeper>
/plugin install plan-keeper@raghav-plugins
```

Pick **user scope** in the install dialog to get it in every project (or `claude plugin install plan-keeper@raghav-plugins --scope user` from a terminal). On macOS/Linux, use that machine's path to this folder instead. Restart Claude Code after installing.

After you edit plugin files, bump the version in `plugin.json` and `marketplace.json`, then run `claude plugin marketplace update raghav-plugins` and `claude plugin update plan-keeper@raghav-plugins --scope user`, and restart Claude Code. A running session keeps the version it started with.

### Windows without Git Bash

The default hooks run `bash`, which Claude Code on Windows provides through Git for Windows. If Git Bash isn't installed, Claude Code uses PowerShell instead, so swap the hook file:

1. In `plugins/plan-keeper/hooks/`, rename `hooks.json` to `hooks.bash.json`.
2. Rename `hooks.powershell.json` to `hooks.json`.

### Commands

- `/plan-keeper:show-or-update-plan [what to add/change]`: shows status, creates the plan, or merges changes into it.
- `/plan-keeper:import-old-plan-docs [extra path]`: converts old docs (`task_plan.md`, `progress.md`, `findings.md`, `TODO.md`, `PROGRESS.md`, `.planning/`, etc.) into `.claude/PLAN.md`. It drops finished items and moves the originals to `.claude/plan-archive/<date>/` instead of deleting them. When a project has old docs but no plan yet, plan-keeper suggests this at session start.
- `/plan-keeper:answer-pending-questions [answers]`: lists pending decisions, or applies your answers (e.g. `1 yes, 2 use Room`) and removes them.
- `/plan-keeper:clean-up-plan`: compacts the plan by deleting done items, merging related ones and trimming the log.

### Files

```
.claude-plugin/marketplace.json        marketplace (add more plugins under plugins/)
plugins/plan-keeper/
  .claude-plugin/plugin.json
  hooks/hooks.json                     bash hooks (default)
  hooks/hooks.powershell.json          PowerShell alternative
  scripts/plan-hook.sh | plan-hook.ps1 one dispatcher per shell
  skills/plan-writing-rules/SKILL.md  rules: prune, merge, size limits, template
  commands/show-or-update-plan.md, clean-up-plan.md, import-old-plan-docs.md, answer-pending-questions.md
```

Add `.claude/.last-ask`, `.claude/.turn`, `.claude/.turn-start`, `.claude/.last-prompt`, `.claude/.plan-*` and `.claude/.PLAN.md.bak` to your projects' `.gitignore`. Whether to commit `.claude/PLAN.md` is up to you.
