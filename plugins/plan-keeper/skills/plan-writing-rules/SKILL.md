---
name: plan-writing-rules
description: Rules for .claude/PLAN.md (plan-keeper). Use when creating, updating, pruning or merging plan items, or when a plan-keeper hook asks.
user-invocable: false
---

# plan-writing-rules

`.claude/PLAN.md` in the project root is the single source of truth for what's in flight. It survives `/clear`, compaction and new sessions. Hooks re-inject it at session start, so **keep it short**, since every line costs tokens in every future session.

## When to write

1. **Before starting** a multi-step request: add it to the plan, merging it into an existing item if related. Skip this for quick questions and one-line fixes.
2. **Before stopping**, whether the task is done or interrupted mid-task: record where things stand so a fresh session can resume.
3. When a hook asks for it: do one edit, then stop.

Make each update a **single Edit/Write**. Don't re-read the file if it's already in context.

## Rules

- **Delete finished items.** Don't tick them off. Replace each finished item with a one-line entry at the top of **Log**, and keep only the latest 5 Log lines.
- **Merge** duplicates and related items into one line. Fold sub-steps into their parent once only one or two remain.
- **Now** holds what's actively in progress (at most 3 items). Include the exact next action and the file or symbol it touches, e.g. `Add retry to SyncWorker.doWork() — tests not written yet`.
- **Next** holds queued items in priority order.
- **Blocked / Questions** holds items waiting on the user or something external.
- **Notes** holds only durable decisions and gotchas a fresh session would get wrong (at most 8 lines). No narration.
- Keep the whole file **under ~60 lines**. Write terse fragments, not prose.
- Several independent workstreams are fine: prefix items with a short tag, e.g. `[auth]`, `[ui]`.
- Never paste code, logs or diffs into the plan. Reference the path instead.

## Decisions waiting on the user: `.claude/DECISIONS.md`

- When you need the user's decision, put each one on its own line starting with `DECIDE: `. The hooks detect these at zero cost. A reply whose last line is a question is also picked up (with the line before it as context).
- Write every question **self-contained**: a future session sees only that line. Name the feature or file it concerns, what prompted it, and the options. Bad: `DECIDE: Where did you see it?` Good: `DECIDE: You mentioned "that mod thingy" in the 02:10 list; I can't find it. Which screen or file was it in?`
- If the user's next message doesn't settle a question, or a session ends before they reply, the question goes into `.claude/DECISIONS.md` as `- YYYY-MM-DD: question -- context: <feature/file, what prompted it, options>`. Add the context even if the question looked clear in the conversation.
- Once the user settles one, delete its line. Don't keep answered items or move them anywhere.
- Don't copy these questions into PLAN.md's Blocked section. Blocked is for external blockers.

## Template (when creating the file)

```markdown
# Plan
Goal: <one line>

## Now
- 

## Next
- 

## Blocked / Questions
- 

## Notes
- 

## Log
- 
```
