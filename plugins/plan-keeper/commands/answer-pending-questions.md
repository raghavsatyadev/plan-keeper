---
description: Review decisions still waiting on you (.claude/DECISIONS.md)
argument-hint: "[optional: your answers, e.g. '1 yes, 2 use Room']"
disable-model-invocation: true
---

Read `.claude/DECISIONS.md`.

- If it has no `- ` items, reply "No pending decisions." and stop.
- If $ARGUMENTS gives answers, apply each one. Act on the decision, or record it in PLAN.md Notes if it affects later work. Then delete the settled lines in one edit.
- If no arguments were given, list the pending items numbered, with one line of context each (from the item's `context:` part; if an item has none and you can't tell what it refers to, say so rather than guessing), and ask the user to answer them in one message. Don't start other work.
