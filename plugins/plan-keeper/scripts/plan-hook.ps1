# plan-keeper hook dispatcher (Windows PowerShell 5.1+ / PowerShell 7).
# Usage: plan-hook.ps1 <session-start|prompt|stop|stop-llm|stop-agy>
param([string]$Hook)

$ErrorActionPreference = 'SilentlyContinue'
$utf8 = New-Object System.Text.UTF8Encoding($false)
[Console]::InputEncoding = $utf8    # hook JSON is UTF-8; default OEM codepage mangles emoji/accents
[Console]::OutputEncoding = $utf8   # no BOM on stdout

$root    = if ($env:CLAUDE_PROJECT_DIR) { $env:CLAUDE_PROJECT_DIR } else { (Get-Location).Path }
$dir     = Join-Path $root '.claude'
$plan    = Join-Path $dir 'PLAN.md'
$dec     = Join-Path $dir 'DECISIONS.md'
$lastAsk = Join-Path $dir '.last-ask'
$turn    = Join-Path $dir '.turn'
$tstate  = Join-Path $dir '.turn-start'     # git fingerprint when the prompt was sent
$pending = Join-Path $dir '.plan-pending'   # agy run failed or was busy: retry at the next stop
$lastPrompt = Join-Path $dir '.last-prompt' # user's latest prompt, only with the agy plan writer
$agyLock = Join-Path $dir '.plan-agy-lock'
$hist    = Join-Path $dir 'HISTORY.md'     # timeline, one line per working turn; never loaded at session start
$agy     = $env:PLAN_KEEPER_AGY_MODEL       # set -> agy writes PLAN.md in the background, Claude never does
$maxLines = 150

$j = $null
if ([Console]::IsInputRedirected) {
  $raw = [Console]::In.ReadToEnd()
  if ($raw) { try { $j = $raw | ConvertFrom-Json } catch { $j = $null } }
}

# Git work is checked in the session's own folder (the hook's "cwd"), which may be a worktree of $root.
# The plan files stay in $root\.claude, shared by every worktree.
$wt = $root
if ($j -and $j.cwd) { $top = & git -C $j.cwd rev-parse --show-toplevel 2>$null; if ($LASTEXITCODE -eq 0 -and $top) { $wt = $top } }
$inWorktree = (($wt -replace '\\', '/').TrimEnd('/') -ne ($root -replace '\\', '/').TrimEnd('/'))

function Get-Asks([string]$msg) {
  if (-not $msg) { return @() }
  $marked = New-Object System.Collections.Generic.List[string]
  $last = $null; $prev = $null; $code = $false
  foreach ($l in ($msg -split "`r?`n")) {
    if ($l -match '^\s*```') { $code = -not $code; continue }
    if ($code) { continue }
    $line = ($l -replace '^[\s>*_#-]+', '') -replace '[\s*_]+$', ''
    if (-not $line) { continue }
    if ($line -match '^DECIDE:') {
      $q = $line -replace '^DECIDE:[*_ ]*', ''
      if ($marked.Count -lt 5 -and $q.Length -lt 600) { $marked.Add($q) }
      continue
    }
    $prev = $last; $last = $line
  }
  if ($marked.Count -gt 0) { return $marked.ToArray() }
  if ($last -and $last -match '\?[^A-Za-z0-9.!]*$' -and $last.Length -lt 400) {
    # the line before the question is its context (unless it is another question)
    if ($prev -and $prev -notmatch '\?[^A-Za-z0-9.!]*$') { $last += ' -- context: ' + $prev.Substring(0, [Math]::Min(300, $prev.Length)) }
    return @($last)
  }
  return @()
}

# One dated line in HISTORY.md (no model; read only when someone asks).
function Add-History([string]$text) {
  if (-not $text) { return }
  if (-not (Test-Path -LiteralPath $hist)) { [IO.File]::WriteAllText($hist, "# History`n", $utf8) }
  [IO.File]::AppendAllText($hist, "- $(Get-Date -Format 'yyyy-MM-dd HH:mm') $text`n", $utf8)
}
# Commit subjects since the prompt, joined with "; " (the timeline when agy does not run).
function Get-TurnCommits {
  if (-not (Test-Path -LiteralPath $tstate) -or -not (In-Git)) { return '' }
  $since = (Get-Item -LiteralPath $tstate).LastWriteTime.ToString('yyyy-MM-ddTHH:mm:ss')
  (@(& git -C $wt log --since=$since --format=%s 2>$null) | Select-Object -First 5) -join '; '
}

# Log lines of a plan's text.
function Get-LogLines([string]$text) {
  $f = $false
  foreach ($l in ($text -split "`r?`n")) {
    if ($l -match '^## Log') { $f = $true; continue }
    if ($l -match '^## ') { $f = $false }
    if ($f -and $l -match '^- ') { $l }
  }
}
# Log lines that the new plan dropped go to HISTORY.md as they were.
function Save-DroppedLog([string]$old, [string]$new) {
  $keep = @(Get-LogLines $new)
  $gone = @(Get-LogLines $old | Where-Object { $keep -notcontains $_ })
  if ($gone.Count -eq 0) { return }
  if (-not (Test-Path -LiteralPath $hist)) { [IO.File]::WriteAllText($hist, "# History`n", $utf8) }
  [IO.File]::AppendAllText($hist, (($gone -join "`n") + "`n"), $utf8)
}

function In-Git { & git -C $wt rev-parse --is-inside-work-tree 2>$null | Out-Null; $LASTEXITCODE -eq 0 }
# Hash of uncommitted changes outside .claude/. One git call per prompt and per stop, none per edit.
function Get-Fingerprint {
  # HEAD is included, so a turn that only commits (clean tree before and after) still counts as work.
  $t = (@(& git -C $wt rev-parse HEAD 2>$null) + @(& git -C $wt status --porcelain -- . ':!.claude' 2>$null) + @(& git -C $wt diff -- . ':!.claude' 2>$null)) -join "`n"
  $sha = [Security.Cryptography.SHA1]::Create()
  [BitConverter]::ToString($sha.ComputeHash($utf8.GetBytes($t)))
}
# Files changed since the prompt (git repos only), or an earlier agy run still owes an update.
function Work-Done {
  if (Test-Path -LiteralPath $pending) { return $true }
  if (-not (Test-Path -LiteralPath $tstate) -or -not (In-Git)) { return $false }
  (Get-Fingerprint) -ne [IO.File]::ReadAllText($tstate)
}
# Claude edited PLAN.md itself during this turn.
function Plan-Touched {
  (Test-Path -LiteralPath $plan) -and (Test-Path -LiteralPath $tstate) -and
    ((Get-Item -LiteralPath $plan).LastWriteTimeUtc -gt (Get-Item -LiteralPath $tstate).LastWriteTimeUtc)
}

function Has-Items($path) { (Test-Path -LiteralPath $path) -and (Select-String -LiteralPath $path -Pattern '^- ' -Quiet) }

switch ($Hook) {
  'session-start' {
    $src = if ($j) { $j.source } else { '' }
    if ((Test-Path -LiteralPath $lastAsk) -and ($src -eq 'startup' -or $src -eq 'clear')) {
      if (-not (Test-Path -LiteralPath $dec)) { [IO.File]::WriteAllText($dec, "# Decisions waiting on you`n", $utf8) }
      # exact-match dedupe on the question text (ignores the date prefix)
      $existing = @([IO.File]::ReadAllLines($dec) | ForEach-Object { $_ -replace '^- [0-9-]+: ', '' })
      $today = Get-Date -Format 'yyyy-MM-dd'
      foreach ($q in [IO.File]::ReadAllLines($lastAsk)) {
        if ($q -and $existing -notcontains $q) { [IO.File]::AppendAllText($dec, "- ${today}: $q`n", $utf8); $existing += $q }
      }
      Remove-Item -LiteralPath $lastAsk -Force
    }

    if (Test-Path -LiteralPath $plan) {
      Write-Output "[plan-keeper] Saved plan from .claude/PLAN.md. Resume from 'Now' unless the user asks for something else."
      Get-Content -LiteralPath $plan -TotalCount $maxLines -Encoding UTF8
    } else {
      $docs = @(Get-ChildItem -Path (Join-Path $root 'docs') -Filter '*plan*.md' | ForEach-Object { "docs/$($_.Name)" })
      foreach ($f in @('task_plan.md','progress.md','findings.md','PLAN.md','PROGRESS.md','TODO.md','TASKS.md','HANDOFF.md','.planning','memory/PLAN.md') + $docs) {
        if (Test-Path -LiteralPath (Join-Path $root $f)) {
          Write-Output "[plan-keeper] Found old plan/progress docs (e.g. $f) but no .claude/PLAN.md. Tell the user they can run /plan-keeper:import-old-plan-docs to convert them."
          break
        }
      }
    }

    if (Has-Items $dec) {
      Write-Output "[plan-keeper] Decisions still waiting on the user (.claude/DECISIONS.md):"
      Select-String -LiteralPath $dec -Pattern '^- ' -Encoding UTF8 | Select-Object -First 20 | ForEach-Object { $_.Line }
      Write-Output "Mention these in one short line at the start of your first reply. When the user settles one, delete its line from .claude/DECISIONS.md."
    }
    if ($inWorktree) { Write-Output "[plan-keeper] Plan file: $plan (main checkout, shared by all worktrees). Never edit a .claude/PLAN.md inside the worktree." }
    if ($agy) { Write-Output "[plan-keeper] agy rewrites the plan after each turn that changes files or commits: don't edit it yourself unless the user asks; say new requests and outcomes plainly in your final reply." }
    Write-Output "[plan-keeper] Put each question for the user on its own line starting 'DECIDE: '. Write it self-contained for a future session: name the feature/file, what prompted it, and the options."
  }

  'prompt' {
    if ($agy) {
      New-Item -ItemType Directory -Force -Path $dir | Out-Null
      $p = if ($j) { [string]$j.prompt } else { '' }
      if ($p.Length -gt 2000) { $p = $p.Substring($p.Length - 2000) }
      [IO.File]::WriteAllText($lastPrompt, $p, $utf8)                   # context for stop-agy
    } else {
      Write-Output "[plan-keeper] Multi-step task: add/merge it into $plan first (skip quick ones)."
    }
    if (In-Git) { New-Item -ItemType Directory -Force -Path $dir | Out-Null; [IO.File]::WriteAllText($tstate, (Get-Fingerprint), $utf8) }
    if ((Test-Path -LiteralPath $lastAsk) -and (Get-Item -LiteralPath $lastAsk).Length -gt 0) {
      Write-Output "[plan-keeper] Your previous reply asked the user:"
      [IO.File]::ReadAllLines($lastAsk) | ForEach-Object { "- $_" }
      Write-Output "Any this message leaves unsettled: append to .claude/DECISIONS.md as '- YYYY-MM-DD: q -- context: <feature/file it concerns, what prompted it, options>'. A future session sees only that line, so it must make sense on its own."
      Remove-Item -LiteralPath $lastAsk -Force
    }
    # New turn: tells a still-running stop-llm that its result is stale.
    if ($env:PLAN_KEEPER_OLLAMA_MODEL -and (Test-Path -LiteralPath $dir)) { [IO.File]::WriteAllText($turn, "$([DateTime]::UtcNow.Ticks)-$PID", $utf8) }
  }

  'stop-llm' {
    # Optional, runs as an async hook (never blocks Claude). Only when PLAN_KEEPER_OLLAMA_MODEL is set
    # and the reply has no DECIDE: lines: a local Ollama model replaces the regex guess in .last-ask.
    if (-not $env:PLAN_KEEPER_OLLAMA_MODEL -or -not $j -or $j.stop_hook_active) { exit 0 }
    $msg = (([string]$j.last_assistant_message) -replace '(?ms)^\s*```.*?^\s*```[^\n]*', '').Trim()
    if (-not $msg -or $msg -match '(?m)^[\s>*_#-]*DECIDE:') { exit 0 }
    if ($msg.Length -gt 3000) { $msg = $msg.Substring($msg.Length - 3000) }
    $t0 = if (Test-Path -LiteralPath $turn) { [IO.File]::ReadAllText($turn) } else { '' }
    $prompt = "Below is an AI coding assistant's reply to its user. List every question in it that asks the user to decide, choose, confirm or answer something before work can continue. Rhetorical questions and questions the assistant answers itself do not count. Output one question per line, at most 5, each understandable by someone who never saw the reply: name the feature or file it concerns and the options offered. If there are none, output exactly NONE. No other text.`n`nREPLY:`n$msg"
    $keep = if ($env:LOCAL_MODEL_KEEP_ALIVE) { $env:LOCAL_MODEL_KEEP_ALIVE } else { '10m' }
    $body = @{ model = $env:PLAN_KEEPER_OLLAMA_MODEL; prompt = $prompt; stream = $false; think = $false; keep_alive = $keep; options = @{ temperature = 0; num_predict = 200 } } | ConvertTo-Json -Compress
    $url = if ($env:PLAN_KEEPER_OLLAMA_URL) { $env:PLAN_KEEPER_OLLAMA_URL } else { 'http://localhost:11434' }
    # Share the model with other tools (e.g. lm-on): only use it if already loaded, unless PLAN_KEEPER_OLLAMA_LOAD=1.
    if ($env:PLAN_KEEPER_OLLAMA_LOAD -ne '1') {
      try { $ps = Invoke-RestMethod -Uri "$url/api/ps" -TimeoutSec 2 -ErrorAction Stop } catch { exit 0 }
      if (-not ($ps.models | Where-Object { $_.name -eq $env:PLAN_KEEPER_OLLAMA_MODEL })) { exit 0 }
    }
    $timeout = if ($env:PLAN_KEEPER_OLLAMA_TIMEOUT) { [int]$env:PLAN_KEEPER_OLLAMA_TIMEOUT } else { 60 }
    try {
      $r = Invoke-RestMethod -Uri "$url/api/generate" -Method Post -ContentType 'application/json; charset=utf-8' -Body $utf8.GetBytes($body) -TimeoutSec $timeout -ErrorAction Stop
    } catch { exit 0 }                                                    # Ollama down or error: keep regex result
    $text = ([string]$r.response) -replace '(?s)<think>.*?</think>', ''
    $asks = @($text -split "`r?`n" | ForEach-Object { ($_ -replace '^\s*([-*>]|\d+[.)])?\s*', '').TrimEnd() } |
      Where-Object { $_ -and $_ -notmatch '^NONE\.?$' -and $_.Length -lt 600 } | Select-Object -First 5)
    $t1 = if (Test-Path -LiteralPath $turn) { [IO.File]::ReadAllText($turn) } else { '' }
    if ($t1 -ne $t0) { exit 0 }                                           # user already replied: stale
    if ($asks.Count -gt 0) {
      New-Item -ItemType Directory -Force -Path $dir | Out-Null
      [IO.File]::WriteAllLines($lastAsk, [string[]]$asks, $utf8)
    } else { Remove-Item -LiteralPath $lastAsk -Force }
  }

  'stop-agy' {
    # Optional async hook: with PLAN_KEEPER_AGY_MODEL set, the agy CLI rewrites PLAN.md after a turn
    # that changed files, so Claude spends no tokens on it. On failure it retries at the next stop.
    if (-not $agy -or ($j -and $j.stop_hook_active)) { exit 0 }
    if (-not (Work-Done)) { exit 0 }
    if (Plan-Touched) { Remove-Item -LiteralPath $pending -Force; Add-History (Get-TurnCommits); exit 0 }
    $lock = Get-Item -LiteralPath $agyLock
    if ($lock -and $lock.LastWriteTime -lt (Get-Date).AddMinutes(-15)) { Remove-Item -LiteralPath $agyLock -Force }   # stale lock
    try { New-Item -ItemType Directory -Path $agyLock -ErrorAction Stop | Out-Null } catch { [IO.File]::WriteAllText($pending, '', $utf8); exit 0 }
    $log = Join-Path $dir '.plan-agy.log'
    function Fail($why) {
      [IO.File]::WriteAllText($log, "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $why`n", $utf8)
      [IO.File]::WriteAllText($pending, '', $utf8); Remove-Item -LiteralPath $agyLock -Force; exit 0
    }
    $bin = if ($env:PLAN_KEEPER_AGY_BIN) { $env:PLAN_KEEPER_AGY_BIN } else { 'agy' }
    if (-not (Get-Command $bin)) { Fail "agy not found ($bin)" }

    $hadPlan = Test-Path -LiteralPath $plan
    $cur = if ($hadPlan) { [IO.File]::ReadAllText($plan) } else { '(no plan yet: create one)' }
    $reply = if ($j) { ([string]$j.last_assistant_message) -replace '(?ms)^\s*```.*?^\s*```[^\n]*', '' } else { '' }
    if ($reply.Length -gt 4000) { $reply = $reply.Substring($reply.Length - 4000) }
    if (-not $reply.Trim()) { $reply = '(empty)' }
    $ask = if (Test-Path -LiteralPath $lastPrompt) { [IO.File]::ReadAllText($lastPrompt) } else { '' }
    if (-not $ask) { $ask = '(unknown)' }
    $changed = (@(& git -C $wt status --short 2>$null | Where-Object { $_ -notmatch ' \.claude/' } | Select-Object -First 30) -join "`n")
    if (-not $changed) { $changed = '(not a git repo or none)' }
    $prompt = @"
You maintain .claude/PLAN.md, the short progress file an AI coding assistant reads at the start of every session. Everything you need is below: do not read, search or run anything, and do not use any tools. Output ONLY the complete new file, starting with the line '# Plan'. No other text, no code fences.

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
$cur

USER'S LATEST REQUEST:
$ask

ASSISTANT'S FINAL REPLY THIS TURN:
$reply

UNCOMMITTED FILES (git status):
$changed
"@
    # Windows PowerShell 5.1 drops embedded double quotes when passing args to native exes.
    if ($PSVersionTable.PSVersion.Major -lt 7) { $prompt = $prompt -replace '"', '\"' }
    $sum0 = if ($hadPlan) { (Get-FileHash -LiteralPath $plan).Hash } else { '' }
    $timeout = if ($env:PLAN_KEEPER_AGY_TIMEOUT) { $env:PLAN_KEEPER_AGY_TIMEOUT } else { '90' }
    $wd = Join-Path ([IO.Path]::GetTempPath()) 'plan-keeper-agy'   # empty dir: nothing for agy to wander into
    New-Item -ItemType Directory -Force -Path $wd | Out-Null
    Push-Location $wd
    $out = & $bin --model $agy --disable-slash-commands --print-timeout "${timeout}s" -p $prompt 2>$null
    $rc = $LASTEXITCODE
    Pop-Location
    if ($rc -ne 0) { Fail 'agy exited with an error' }
    $lines = @(@($out) -split "`r?`n")
    $tl = @($lines | Where-Object { $_ -match '^[\s*_]*TIMELINE:' } | ForEach-Object { $_ -replace '^[\s*_]*TIMELINE:[\s*_]*', '' }) | Select-Object -Last 1
    if ($tl -and $tl.Length -gt 300) { $tl = $tl.Substring(0, 300) }
    $keep = $false
    $new = @($lines | Where-Object { $_ -notmatch '^[\s*_]*TIMELINE:' } | ForEach-Object { if ($_ -match '^# Plan') { $keep = $true }; if ($keep -and $_ -notmatch '^\s*```') { $_ } })
    foreach ($h in '## Now', '## Next', '## Log') { if (-not ($new | Where-Object { $_ -like "$h*" })) { Fail "bad output (missing $h)" } }
    if ($new.Count -gt 90) { Fail 'bad output (too long)' }
    $sum1 = if (Test-Path -LiteralPath $plan) { (Get-FileHash -LiteralPath $plan).Hash } else { '' }
    if ($sum1 -ne $sum0) { Remove-Item -LiteralPath $pending, $agyLock -Force; exit 0 }   # Claude edited it meanwhile
    if ($hadPlan) { Copy-Item -LiteralPath $plan -Destination (Join-Path $dir '.PLAN.md.bak') -Force }
    [IO.File]::WriteAllText($plan, (($new -join "`n") + "`n"), $utf8)
    if ($hadPlan) { Save-DroppedLog $cur ($new -join "`n") }
    Add-History $(if ($tl) { $tl } else { Get-TurnCommits })
    Remove-Item -LiteralPath $pending, $log, $agyLock -Force
  }

  'stop' {
    $active = [bool]($j -and $j.stop_hook_active)
    if (-not $active) {
      $asks = @(Get-Asks ([string]$j.last_assistant_message))
      if ($asks.Count -gt 0) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        [IO.File]::WriteAllLines($lastAsk, [string[]]$asks, $utf8)
      } else { Remove-Item -LiteralPath $lastAsk -Force }
    }
    # Without agy: once per working turn, Claude updates the plan itself (one extra turn).
    if ($agy -or $active -or -not (Test-Path -LiteralPath $plan)) { exit 0 }   # with agy, stop-agy handles it
    if (-not (Work-Done) -or (Plan-Touched)) { exit 0 }
    Write-Output ('{"decision":"block","reason":"plan-keeper: files changed this turn but ' + ($plan -replace '\\', '/') + ' was not updated. Update it now in ONE edit: delete finished items (add a one-line summary to Log, keep the last 5), set Now/Next to what remains, merge duplicates. Then stop without further work."}')
  }
}
exit 0
