---
description: Migrate old plan/progress/todo docs into .claude/PLAN.md (plan-keeper format)
argument-hint: "[optional: extra file or folder to include]"
disable-model-invocation: true
---

Migrate this project's existing plan and progress docs into `.claude/PLAN.md`, following the plan-writing-rules skill.

1. **Find sources.** Look in the project root and its top two levels for: `task_plan.md`, `progress.md`, `findings.md`, `PLAN.md`, `PROGRESS.md`, `TODO.md`, `TASKS.md`, `HANDOFF.md`, `NEXT_STEPS.md`, `.planning/`, `memory/PLAN.md`, `memory/PROGRESS.md`, `docs/*plan*.md`, `docs/*progress*.md`, plus anything given in $ARGUMENTS. Ignore `node_modules`, `build`, `.git`, `.gradle` and the plugin's own `.claude/PLAN.md`. List what you found and stop if nothing is found.
2. **Merge into the new format.** If `.claude/PLAN.md` already exists, merge into it.
   - Unfinished items, including unchecked `[ ]`, "in progress" and "todo" items, go to **Now** (at most 3, the ones most clearly active) or **Next**.
   - Finished items, including checked `[x]`, "done" and "complete" items, are dropped. Only the latest 5 go into **Log** as one line each.
   - Blockers and open questions go to **Blocked / Questions**.
   - Durable decisions, gotchas and key findings go to **Notes** (at most 8 lines). Leave long research in the archive and reference its path.
   - Merge duplicates and related items. Tag separate workstreams, e.g. `[auth]`.
   - Keep the result under ~60 lines.
3. **Archive the originals.** Don't delete them. Move each source into `.claude/plan-archive/<YYYY-MM-DD>/`, keeping its relative path, and add a line to Notes saying where they went. If a source is also used for something else, such as a README section, leave it in place and say so.
4. **Report.** Give a short summary: the files migrated, the counts of items kept, dropped and archived, and anything ambiguous you weren't sure how to classify.
