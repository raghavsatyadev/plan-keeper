#!/usr/bin/env bash
# plan-keeper hook dispatcher (macOS, Linux, Windows Git Bash).
# Usage: plan-hook.sh <session-start|prompt|stop|stop-llm|stop-agy>
# Needs only bash + sed/awk/grep. No jq/python/node.

HOOK="$1"
ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
ROOT="${ROOT//\\//}"                      # Windows backslashes -> forward slashes
DIR="$ROOT/.claude"
PLAN="$DIR/PLAN.md"
DEC="$DIR/DECISIONS.md"                   # decisions still waiting on the user
LASTASK="$DIR/.last-ask"                  # questions from Claude's latest reply (not yet seen by a prompt)
TURN="$DIR/.turn"                         # per-prompt id, only with the optional Ollama classifier
LASTPROMPT="$DIR/.last-prompt"            # user's latest prompt, only with the optional agy plan writer
TSTATE="$DIR/.turn-start"                 # git fingerprint when the prompt was sent
PENDING="$DIR/.plan-pending"              # agy run failed or was busy: retry at the next stop
AGYLOCK="$DIR/.plan-agy-lock"
HIST="$DIR/HISTORY.md"                    # timeline, one line per working turn; never loaded at session start
AGY="${PLAN_KEEPER_AGY_MODEL:-}"          # set -> agy writes PLAN.md in the background, Claude never does
MAX_LINES=150

INPUT=""
if [ ! -t 0 ]; then INPUT="$(cat)"; fi

in_git() { git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; }
# Checksum of uncommitted changes outside .claude/. One git call per prompt and per stop, none per edit.
fingerprint() { { git -C "$ROOT" status --porcelain -- . ':!.claude'; git -C "$ROOT" diff -- . ':!.claude'; } 2>/dev/null | cksum; }
# Files changed since the prompt (git repos only), or an earlier agy run still owes an update.
work_done() { [ -f "$PENDING" ] || { [ -f "$TSTATE" ] && in_git && [ "$(fingerprint)" != "$(cat "$TSTATE")" ]; }; }
# Claude edited PLAN.md itself during this turn.
plan_touched() { [ -f "$PLAN" ] && [ -f "$TSTATE" ] && [ "$PLAN" -nt "$TSTATE" ]; }

# history_add TEXT: one dated line in HISTORY.md (no model; read only when someone asks).
history_add() {
  [ -n "$1" ] || return 0
  [ -f "$HIST" ] || printf '# History\n' > "$HIST"
  printf -- '- %s %s\n' "$(date '+%Y-%m-%d %H:%M')" "$1" >> "$HIST"
}
# Commit subjects since the prompt, joined with "; " (the timeline when agy does not run).
commits_this_turn() {
  { [ -f "$TSTATE" ] && in_git; } || return 0
  git -C "$ROOT" log --since="@$(date -r "$TSTATE" +%s)" --format=%s 2>/dev/null | head -n 5 \
    | awk 'NR > 1 { printf "; " } { printf "%s", $0 }'
}

# Log lines of a plan (stdin), one per line.
log_lines() { awk '/^## Log/ { f = 1; next } /^## / { f = 0 } f && /^- /'; }
# archive_log OLD NEW: Log lines that NEW dropped go to HISTORY.md as they were.
archive_log() {
  GONE="$(printf '%s\n' "$1" | log_lines | grep -Fxv -f <(printf '%s\n' "$2" | log_lines))"
  [ -n "$GONE" ] || return 0
  [ -f "$HIST" ] || printf '# History\n' > "$HIST"
  printf '%s\n' "$GONE" >> "$HIST"
}

json_true() { printf '%s' "$INPUT" | grep -Eq "\"$1\"[[:space:]]*:[[:space:]]*true"; }

# json_str KEY [JSON]: decoded value of string field KEY (single-line JSON; default $INPUT).
json_str() {
  printf '%s' "${2-$INPUT}" \
  | sed -nE 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)".*/\1/p' | head -n 1 \
  | awk '{ gsub(/\\\\/, "\001"); gsub(/\\r/, ""); gsub(/\\n/, "\n"); gsub(/\\t/, " "); gsub(/\\"/, "\""); gsub(/\001/, "\\"); print }'
}

# Print the questions in Claude's last reply, one per line (max 5).
# 1) lines starting with "DECIDE:" (explicit marker), else
# 2) the last prose line, if it ends with "?", with the line before it as context.
extract_asks() {
  json_str last_assistant_message \
  | awk '
      /^[[:space:]]*```/ { code = !code; next }          # skip code blocks
      code { next }
      { line = $0; gsub(/^[[:space:]>*_#-]+|[[:space:]*_]+$/, "", line) }
      line == "" { next }
      line ~ /^DECIDE:/ { sub(/^DECIDE:[*_ ]*/, "", line); if (n < 5 && length(line) < 600) marked[++n] = line; next }
      { prev = last; last = line }
      END {
        if (n > 0) { for (i = 1; i <= n; i++) print marked[i] }
        else if (last ~ /\?[^A-Za-z0-9.!]*$/ && length(last) < 400) {
          if (prev != "" && prev !~ /\?[^A-Za-z0-9.!]*$/) last = last " -- context: " substr(prev, 1, 300)
          print last
        }
      }'
}

case "$HOOK" in
  session-start)
    SRC="$(printf '%s' "$INPUT" | grep -oE '"source"[[:space:]]*:[[:space:]]*"[a-z]+"' | grep -oE '[a-z]+"$' | tr -d '"')"
    # New session / clear with questions never followed by a prompt -> the user forgot them.
    if [ -s "$LASTASK" ] && { [ "$SRC" = "startup" ] || [ "$SRC" = "clear" ]; }; then
      [ -f "$DEC" ] || printf '# Decisions waiting on you\n' > "$DEC"
      TODAY="$(date +%Y-%m-%d)"
      while IFS= read -r q; do
        # exact-match dedupe on the question text (ignores the date prefix)
        [ -n "$q" ] && ! Q="$q" awk '{ sub(/^- [0-9-]+: /, "") } $0 == ENVIRON["Q"] { f = 1 } END { exit !f }' "$DEC" \
          && printf -- '- %s: %s\n' "$TODAY" "$q" >> "$DEC"
      done < "$LASTASK"
      rm -f "$LASTASK"
    fi

    if [ -f "$PLAN" ]; then
      echo "[plan-keeper] Saved plan from .claude/PLAN.md. Resume from 'Now' unless the user asks for something else."
      head -n "$MAX_LINES" "$PLAN"
    else
      for f in task_plan.md progress.md findings.md PLAN.md PROGRESS.md TODO.md TASKS.md HANDOFF.md .planning memory/PLAN.md "$ROOT"/docs/*[Pp]lan*.md; do
        f="${f#"$ROOT/"}"
        if [ -e "$ROOT/$f" ]; then
          echo "[plan-keeper] Found old plan/progress docs (e.g. $f) but no .claude/PLAN.md. Tell the user they can run /plan-keeper:import-old-plan-docs to convert them."
          break
        fi
      done
    fi

    if [ -f "$DEC" ] && grep -q '^- ' "$DEC"; then
      echo "[plan-keeper] Decisions still waiting on the user (.claude/DECISIONS.md):"
      grep '^- ' "$DEC" | head -n 20
      echo "Mention these in one short line at the start of your first reply. When the user settles one, delete its line from .claude/DECISIONS.md."
    fi
    echo "[plan-keeper] Put each question for the user on its own line starting 'DECIDE: '. Write it self-contained for a future session: name the feature/file, what prompted it, and the options."
    ;;

  prompt)
    if [ -n "$AGY" ]; then
      mkdir -p "$DIR"; json_str prompt | tail -c 2000 > "$LASTPROMPT"   # context for stop-agy
    else
      echo "[plan-keeper] Multi-step task: add/merge it into .claude/PLAN.md first (skip quick ones)."
    fi
    in_git && { mkdir -p "$DIR"; fingerprint > "$TSTATE"; }
    # Only when the previous reply asked something (~40 tokens, otherwise 0).
    if [ -s "$LASTASK" ]; then
      echo "[plan-keeper] Your previous reply asked the user:"
      sed 's/^/- /' "$LASTASK"
      echo "Any this message leaves unsettled: append to .claude/DECISIONS.md as '- YYYY-MM-DD: q -- context: <feature/file it concerns, what prompted it, options>'. A future session sees only that line, so it must make sense on its own."
      rm -f "$LASTASK"
    fi
    # New turn: tells a still-running stop-llm that its result is stale.
    [ -n "$PLAN_KEEPER_OLLAMA_MODEL" ] && [ -d "$DIR" ] && printf '%s-%s\n' "$(date +%s)" "$$" > "$TURN"
    ;;

  stop-llm)
    # Optional, runs as an async hook (never blocks Claude). Only when PLAN_KEEPER_OLLAMA_MODEL is set
    # and the reply has no DECIDE: lines: a local Ollama model replaces the regex guess in .last-ask.
    [ -n "$PLAN_KEEPER_OLLAMA_MODEL" ] || exit 0
    json_true stop_hook_active && exit 0
    command -v curl >/dev/null 2>&1 || exit 0
    MSG="$(json_str last_assistant_message | awk '/^[[:space:]]*```/ { c = !c; next } !c')"
    [ -n "$MSG" ] || exit 0
    printf '%s\n' "$MSG" | grep -q '^[[:space:]>*_#-]*DECIDE:' && exit 0
    OURL="${PLAN_KEEPER_OLLAMA_URL:-http://localhost:11434}"
    # Share the model with other tools (e.g. lm-on): only use it if already loaded, unless PLAN_KEEPER_OLLAMA_LOAD=1.
    if [ "$PLAN_KEEPER_OLLAMA_LOAD" != 1 ]; then
      curl -s -m 2 "$OURL/api/ps" | grep -qF "\"name\":\"$PLAN_KEEPER_OLLAMA_MODEL\"" || exit 0
    fi
    T0="$(cat "$TURN" 2>/dev/null)"
    MSG="$(printf '%s' "$MSG" | tail -c 3000)"
    PROMPT="Below is an AI coding assistant's reply to its user. List every question in it that asks the user to decide, choose, confirm or answer something before work can continue. Rhetorical questions and questions the assistant answers itself do not count. Output one question per line, at most 5, each understandable by someone who never saw the reply: name the feature or file it concerns and the options offered. If there are none, output exactly NONE. No other text.

REPLY:
$MSG"
    esc() { sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/[[:cntrl:]]/ /g' | awk 'BEGIN { ORS = "" } NR > 1 { print "\\n" } { print }'; }
    BODY="{\"model\":\"$(printf '%s' "$PLAN_KEEPER_OLLAMA_MODEL" | esc)\",\"prompt\":\"$(printf '%s' "$PROMPT" | esc)\",\"stream\":false,\"think\":false,\"keep_alive\":\"${LOCAL_MODEL_KEEP_ALIVE:-10m}\",\"options\":{\"temperature\":0,\"num_predict\":200}}"
    RESP="$(printf '%s' "$BODY" | curl -s -m "${PLAN_KEEPER_OLLAMA_TIMEOUT:-60}" -H 'Content-Type: application/json' \
      --data-binary @- "$OURL/api/generate" | tr -d '\n')"
    printf '%s' "$RESP" | grep -q '"response"' || exit 0          # Ollama down or error: keep regex result
    ASKS="$(json_str response "$RESP" | awk '
      /<think>/ { t = 1 } t { if (/<\/think>/) t = 0; next }
      { sub(/^[[:space:]]*([-*>]|[0-9]+[.)])?[[:space:]]*/, ""); sub(/[[:space:]]+$/, "") }
      $0 == "" || toupper($0) ~ /^NONE[.]?$/ { next }
      n < 5 && length($0) < 600 { print; n++ }')"
    [ "$(cat "$TURN" 2>/dev/null)" = "$T0" ] || exit 0           # user already replied: stale
    if [ -n "$ASKS" ]; then mkdir -p "$DIR"; printf '%s\n' "$ASKS" > "$LASTASK"; else rm -f "$LASTASK"; fi
    ;;

  stop-agy)
    # Optional async hook: with PLAN_KEEPER_AGY_MODEL set, the agy CLI rewrites PLAN.md after a turn
    # that changed files, so Claude spends no tokens on it. On failure it retries at the next stop.
    [ -n "$AGY" ] || exit 0
    json_true stop_hook_active && exit 0
    work_done || exit 0
    if plan_touched; then rm -f "$PENDING"; history_add "$(commits_this_turn)"; exit 0; fi
    find "$AGYLOCK" -maxdepth 0 -mmin +15 -exec rmdir {} \; 2>/dev/null   # stale lock from a killed run
    mkdir "$AGYLOCK" 2>/dev/null || { : > "$PENDING"; exit 0; }            # a run is active: retry next stop
    trap 'rmdir "$AGYLOCK" 2>/dev/null' EXIT
    LOG="$DIR/.plan-agy.log"
    fail() { echo "$(date '+%F %T') $1" > "$LOG"; : > "$PENDING"; exit 0; }
    BIN="${PLAN_KEEPER_AGY_BIN:-agy}"
    command -v "$BIN" >/dev/null 2>&1 || fail "agy not found ($BIN)"

    if [ -f "$PLAN" ]; then CUR="$(cat "$PLAN")"; OLD="$CUR"; else CUR="(no plan yet: create one)"; OLD=""; fi
    SUM0="$(cksum < "$PLAN" 2>/dev/null)"
    REPLY="$(json_str last_assistant_message | awk '/^[[:space:]]*```/ { c = !c; next } !c' | tail -c 4000)"
    ASK="$(cat "$LASTPROMPT" 2>/dev/null)"
    CHANGED="$(git -C "$ROOT" status --short 2>/dev/null | grep -v ' \.claude/' | head -n 30)"
    PROMPT="You maintain .claude/PLAN.md, the short progress file an AI coding assistant reads at the start of every session. Everything you need is below: do not read, search or run anything, and do not use any tools. Output ONLY the complete new file, starting with the line '# Plan'. No other text, no code fences.

Rules:
- Exactly these parts in order: '# Plan', 'Goal: <one line>', '## Now', '## Next', '## Blocked / Questions', '## Notes', '## Log'. Use '- ' bullets.
- Delete finished items (never tick them). Add a one-line summary of each to the top of Log. Keep only the latest 5 Log lines.
- Now: what is actively in progress, at most 3 items, each with the exact next action and the file or symbol it touches.
- Next: queued items in priority order. Blocked / Questions: items waiting on the user or something external.
- Notes: only durable decisions and gotchas a fresh session would get wrong, at most 8 lines.
- Merge duplicate and related items. Prefix separate workstreams with a short tag like [auth].
- Terse fragments, whole file under 60 lines. Never include code, logs or diffs; reference paths instead.
- Keep items this turn did not touch. Change only what the information below supports; never invent work.
- After the file, add one last line: 'TIMELINE: <what this turn did, at most 25 words>'.

CURRENT PLAN.md:
$CUR

USER'S LATEST REQUEST:
${ASK:-(unknown)}

ASSISTANT'S FINAL REPLY THIS TURN:
${REPLY:-(empty)}

UNCOMMITTED FILES (git status):
${CHANGED:-(not a git repo or none)}"

    WD="${TMPDIR:-/tmp}/plan-keeper-agy"; mkdir -p "$WD"   # empty dir: nothing for agy to wander into
    OUT="$(cd "$WD" && "$BIN" --model "$AGY" --disable-slash-commands --print-timeout "${PLAN_KEEPER_AGY_TIMEOUT:-90}s" -p "$PROMPT" 2>/dev/null)" \
      || fail "agy exited with an error"
    OUT="$(printf '%s\n' "$OUT" | tr -d '\r')"
    TL="$(printf '%s\n' "$OUT" | sed -n 's/^[[:space:]*_]*TIMELINE:[[:space:]*_]*//p' | tail -n 1 | cut -c1-300)"
    NEW="$(printf '%s\n' "$OUT" | grep -v '^[[:space:]*_]*TIMELINE:' | awk '/^# Plan/ { p = 1 } p && !/^[[:space:]]*```/')"
    for h in '## Now' '## Next' '## Log'; do
      printf '%s\n' "$NEW" | grep -q "^$h" || fail "bad output (missing $h)"
    done
    [ "$(printf '%s\n' "$NEW" | wc -l)" -le 90 ] || fail "bad output (too long)"
    [ "$(cksum < "$PLAN" 2>/dev/null)" = "$SUM0" ] || { rm -f "$PENDING"; exit 0; }   # Claude edited it meanwhile
    [ -f "$PLAN" ] && cp -f "$PLAN" "$DIR/.PLAN.md.bak"
    printf '%s\n' "$NEW" > "$PLAN"
    [ -n "$OLD" ] && archive_log "$OLD" "$NEW"
    history_add "${TL:-$(commits_this_turn)}"
    rm -f "$PENDING" "$LOG"
    ;;

  stop)
    ACTIVE=0; json_true stop_hook_active && ACTIVE=1

    # Record questions from this reply (skip the forced follow-up turn so they aren't overwritten).
    if [ "$ACTIVE" = 0 ]; then
      ASKS="$(extract_asks)"
      if [ -n "$ASKS" ]; then mkdir -p "$DIR"; printf '%s\n' "$ASKS" > "$LASTASK"; else rm -f "$LASTASK"; fi
    fi

    # Without agy: once per working turn, Claude updates the plan itself (one extra turn).
    [ -n "$AGY" ] && exit 0                # stop-agy handles it
    [ "$ACTIVE" = 1 ] && exit 0            # never block twice in a row
    [ -f "$PLAN" ] || exit 0
    work_done || exit 0
    plan_touched && exit 0
    printf '%s\n' '{"decision":"block","reason":"plan-keeper: files changed this turn but .claude/PLAN.md was not updated. Update it now in ONE edit: delete finished items (add a one-line summary to Log, keep the last 5), set Now/Next to what remains, merge duplicates. Then stop without further work."}'
    ;;
esac
exit 0
