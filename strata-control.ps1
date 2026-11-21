#Requires -Version 5.1
<#
  strata-control.ps1 - start, stop, unload and list models, through Strata's own command line.

  Dot-sourced by strata-tray.ps1. It draws nothing and opens no window, so it can be checked on its
  own:  powershell -NoProfile -ExecutionPolicy Bypass -File test-control.ps1
  There is no param() block on purpose: a param block in a dot-sourced file binds the CALLER's
  arguments instead of its own.

  TIMING - deliberately none. No --wait, no --shutdown-timeout anywhere except where noted. Strata's
  own defaults are used exactly as shipped: `runtime start` watches the load for 300 s, `runtime stop`
  allows 330 s for the teardown, and a stop drains in-flight requests for 30 s before cancelling them
  (terminal/strata_cli/cli.py:238-257). The single flag we add is `runtime start --wait 0`, which is
  NOT a shorter timeout: it means "the CLI returns now", and the host it spawns still gets 300 s
  (terminal/strata_control/runtime.py:708: str(wait if wait else 300)). The tray then polls
  `runtime status` itself, so the minute or two a model takes to load never blocks the tray's message
  loop.

  WHY THE CLI AND NOT AN HTTP CALL FOR STOP - Strata has no HTTP shutdown route. `runtime stop` asks
  the host that owns the server; the host closes its end of the pipe it passed to the server as stdin
  (--owner-fd 0); serve/owner_guard.py turns that EOF into _thread.interrupt_main(). That is the same
  KeyboardInterrupt the user gets from Ctrl+C in the server window: drain, then httpd.shutdown,
  engine.close (QUIT to the engine), vision.shutdown, hub.close, then "[strata] stopped". This is also
  how Strata's own desktop app runs its engines, so it is the supported lifecycle, not a side door.

  WHY NOT SENDING Ctrl+C TO THE CONSOLE INSTEAD - the server's own lifeline caps a console close at
  about 4.5 s and then the kill-on-close job object ends the tree (serve/lifeline.py), and a console
  control event hits every process attached to that console, including cmd, which is what produces the
  "Terminate batch job (Y/N)?" prompt. It is also unreliable: terminal\.venv\Scripts\python.exe is a
  shim that re-execs the real interpreter, so the pid you can see is not the pid holding the handlers.
#>

# Trace goes to the HOST, never to the pipeline: `Write-Output` here would be captured by the caller
# as part of the function's return value, and Get-Models then hands back a list with a stray string
# in it (this bit me once already while writing the module).
function CtlTrace([string]$m) {
  if (Get-Command Trace -ErrorAction SilentlyContinue) { Trace $m } else { Write-Host ('  . ' + $m) }
}

# An error from the CLI is either a plain string or an OBJECT {code, message} (a refusal like
# runtime_not_owned is the object form). Assigning the object straight to $st.ctlMsg puts a hashtable
# in there, and the menu row then reads "@{code=3; message=The helper program ...}". Always take the
# message.
function Err-Text($e) {
  if ($null -eq $e) { return '' }
  if ($e -is [string]) { return [string]$e }
  if ($e.message) { return [string]$e.message }
  return ([string]$e)
}

# The CLI is a Python start-up every time: measured 0.4-0.7 s per call on a modern desktop. So none of this
# belongs in the 1.5 s card poll - Refresh-Control paces it instead.
function Strata-Exe() {
  if ($null -ne $st.strataExe) { return $st.strataExe }
  $cmd = if ($st.strataCmd) { [string]$st.strataCmd } else { 'strata' }
  $g = Get-Command $cmd -ErrorAction SilentlyContinue
  $st.strataExe = if ($g) { [string]$g.Source } else { '' }
  if (-not $st.strataExe) { $st.ctlMsg = ('"' + $cmd + '" is not on PATH') }
  CtlTrace ('strata exe: ' + $(if ($st.strataExe) { $st.strataExe } else { 'NOT FOUND (' + $cmd + ')' }))
  return $st.strataExe
}

# Strata's own start-here script (START-HERE.bat): the wizard that installs a model or changes
# settings. The tray cannot install anything itself - that wizard is interactive and it is the person
# who decides what to download - so when `models list` comes back empty the menu points at it.
# Found by walking up from the command line: <root>\terminal\bin\strata.cmd -> <root>\START-HERE.bat
# (the 0.2.16 layout keeps the sources in terminal\; an older clone has the .bat one level deeper, so
# both are tried). $Wizard in settings.local.ps1 overrides the search.
function Strata-Wizard() {
  if ($null -ne $st.wizardPath) { return [string]$st.wizardPath }
  $st.wizardPath = ''
  $cfg = if ($st.wizard) { [string]$st.wizard } else { '' }
  if ($cfg) {
    if (Test-Path -LiteralPath $cfg) { $st.wizardPath = $cfg }
    else { CtlTrace ('wizard not found where settings.local.ps1 said: ' + $cfg) }
    return [string]$st.wizardPath
  }
  $exe = Strata-Exe
  if (-not $exe) { return '' }
  $dir = Split-Path -Parent (Split-Path -Parent ([string]$exe))     # ...\terminal\bin -> ...\terminal
  foreach ($cand in @((Join-Path $dir 'START-HERE.bat'), (Join-Path (Split-Path -Parent $dir) 'START-HERE.bat'))) {
    if (Test-Path -LiteralPath $cand) { $st.wizardPath = $cand; break }
  }
  CtlTrace ('wizard: ' + $(if ($st.wizardPath) { $st.wizardPath } else { 'START-HERE.bat not found near ' + $exe }))
  return [string]$st.wizardPath
}

# Open that wizard in its own console window. It asks questions, so it has to be visible, and it has to
# be the person answering them - the tray only opens the door.
function Open-Strata-Wizard() {
  $bat = Strata-Wizard
  if (-not $bat) { $st.ctlMsg = "Strata's START-HERE.bat was not found - no wizard to open"; return }
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { [void](Start-Process -FilePath $bat -WorkingDirectory (Split-Path -Parent $bat) -WindowStyle Normal -ErrorAction Stop) }
  catch { $st.ctlMsg = ('could not open ' + $bat) }
  $ErrorActionPreference = $prev
  CtlTrace ('wizard opened: ' + $bat)
}

# Parse what the CLI printed: --output json puts the object on the first line and a human note can
# follow it. Returns the object, or $null with the reason in $st.ctlMsg.
function Parse-Cli-Text([string]$txt) {
  $txt = ([string]$txt).Trim()
  if (-not $txt) { return $null }
  $nl = $txt.IndexOf("`n")
  if ($nl -gt 0) { $txt = $txt.Substring(0, $nl) }
  $j = $null
  try { $j = $txt | ConvertFrom-Json } catch { $j = $null }
  if ($null -eq $j) { $st.ctlMsg = ('strata: ' + $txt); CtlTrace ('cli not json: ' + $txt); return $null }
  if (-not $j.ok -and $j.error) { $st.ctlMsg = Err-Text $j.error } else { $st.ctlMsg = '' }
  return $j
}

# Run the CLI, return its parsed JSON, or $null with the reason in $st.ctlMsg.
# This BLOCKS for the length of the call, so it belongs to the one-time setup paths (profile create)
# and to the console test script - not to the tray's timer. See Fire-Cli.
function Invoke-Strata([string[]]$argv) {
  $exe = Strata-Exe
  if (-not $exe) { return $null }
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $out = ''
  try { $out = (& $exe @argv 2>$null | Out-String) } catch { $out = '' }
  $code = $LASTEXITCODE
  $ErrorActionPreference = $prev
  $j = Parse-Cli-Text $out
  if ($null -eq $j) { $st.ctlMsg = ('strata ' + ($argv -join ' ') + ' said nothing (exit ' + $code + ')') }
  return $j
}

# The model rows, from either the blocking or the asynchronous call.
function Build-ModelList($j) {
  $list = @()
  if (-not $j) { return ,$list }
  foreach ($m in @($j.models)) {
    $list += [ordered]@{
      id     = [string]$m.id
      name   = [string]$m.name
      source = [string]$m.source_config
      ctx    = $m.context_tokens
      ready  = ([string]$m.component_status -eq 'present')
    }
  }
  return ,$list
}

# What is installed. Strata lists only the models THIS version can run: a DeepSeek pack (last supported
# on Strata 0.2.13) is not listed at all, and starting one is refused before any process exists
# (strata_control/retired.py). So this menu can never offer something this Strata will not load.
function Get-Models() {
  $j = Invoke-Strata @('models', 'list', '--output', 'json')
  $list = Build-ModelList $j
  CtlTrace ('models: ' + $(if ($list.Count) { ($list | ForEach-Object { $_.id }) -join ', ' } else { 'none' }))
  return ,$list
}

# Does a runtime host own this profile right now?
#   stopped   nothing owned is running (a server started from a console window reads as this)
#   starting  loading, with $st.ctlPhase naming the step
#   ready     serving, and stoppable
#   draining  a stop is in progress
#   failed    the last start did not make it; $st.ctlMsg says why
#   stale     the owner host died with a model loaded; the next start cleans it up
# A server the tray did not start is NOT stoppable from here: runtime.py:792 answers
# runtime_not_owned for it. The tray says so instead of offering a Stop that cannot work.
function Get-Owned([string]$id) {
  if (-not $id) { return 'unknown' }
  $j = Invoke-Strata @('runtime', 'status', '--profile', $id, '--output', 'json')
  if (-not $j) { return 'unknown' }
  $s = [string]$j.state
  if (-not $s) { return 'unknown' }
  $st.ctlPhase = if ($j.phase) { [string]$j.phase } else { '' }
  $st.ctlId    = $id            # which profile $st.ctl describes (the Stop row needs it)
  if ($s -eq 'failed' -and $j.error) { $st.ctlMsg = Err-Text $j.error }
  return $s
}

# ---------------------------------------------- asynchronous read-only calls -------------------
#
# WHY: a WinForms Timer callback runs on the UI thread, and one `strata` call is a whole Python
# start-up - 0.16-0.45 s when warm, and several seconds when the machine has just freed tens of GB
# (i.e. right after the model went down). During that time the message loop is blocked: the right-click
# menu opens late or takes no clicks at all. So the tray NEVER runs the CLI inline. It fires the call
# hidden with its output going to a temp file, and harvests the answer on a later tick.
function Fire-Cli([string]$kind, [string[]]$argv, [string]$forId) {
  if ($st.cli) { return }                       # one read-only call at a time
  $exe = Strata-Exe
  if (-not $exe) { return }
  $st.cliSeq = [int]$st.cliSeq + 1
  $seq = [string]$st.cliSeq
  $out = Join-Path $env:TEMP ('strata-tray-cli-' + $kind + '-' + $seq + '.out')
  $err = Join-Path $env:TEMP ('strata-tray-cli-' + $kind + '-' + $seq + '.err')
  Remove-Item -LiteralPath $out, $err -Force -ErrorAction SilentlyContinue
  $p = Start-Process -FilePath $exe -ArgumentList ($argv + @('--output', 'json')) `
        -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError $err -PassThru `
        -ErrorAction SilentlyContinue
  if (-not $p) { $st.ctlMsg = ('could not run: strata ' + ($argv -join ' ')); return }
  $st.cli = @{ kind = $kind; seq = $seq; pid = [int]$p.Id; out = $out; err = $err
               forId = [string]$forId; at = (Get-Date) }
  CtlTrace ('cli: ' + $kind + ' (pid ' + $p.Id + ')')
}

# Has the fired call answered? If so, apply it to the cache. Returns $true when something was read.
# A read-only call that has not answered in 20 s is dropped rather than sat on; the next tick fires a
# fresh one, so a stuck call cannot freeze the state for good.
function Collect-Cli() {
  $c = $st.cli
  if (-not $c) { return $false }
  $alive = $null
  try { $alive = Get-Process -Id ([int]$c.pid) -ErrorAction SilentlyContinue } catch {}
  $txt = ''
  if (Test-Path -LiteralPath $c.out) { try { $txt = ([string](Get-Content -LiteralPath $c.out -Raw)).Trim() } catch {} }
  if ($alive -and -not $txt) {
    if (((Get-Date) - [datetime]$c.at).TotalSeconds -gt 20) {
      CtlTrace ('cli call gave up on: ' + $c.kind)
      $st.ctlMsg = ('strata ' + $c.kind + ' did not answer in 20 s')
      try { Stop-Process -Id ([int]$c.pid) -Force -ErrorAction SilentlyContinue } catch {}
      $st.cli = $null
    }
    return $false
  }
  $st.cli = $null
  Remove-Item -LiteralPath $c.out, $c.err -Force -ErrorAction SilentlyContinue
  $j = Parse-Cli-Text $txt
  if (-not $j) { CtlTrace ($c.kind + ' answered nothing usable'); return $false }
  if ($c.kind -eq 'models') {
    $st.models   = Build-ModelList $j
    $st.modelSrc = @{}
    foreach ($m in $st.models) { $st.modelSrc[$m.id] = $m.source }
    CtlTrace ('models: ' + $(if (@($st.models).Count) { ($st.models | ForEach-Object { $_.id }) -join ', ' } else { 'none' }))
    return $true
  }
  if ($c.kind -eq 'status') {
    $s = [string]$j.state
    if (-not $s) { return $false }
    $st.ctl      = $s
    $st.ctlId    = [string]$c.forId
    $st.ctlPhase = if ($j.phase) { [string]$j.phase } else { '' }
    if ($s -eq 'failed' -and $j.error) { $st.ctlMsg = Err-Text $j.error }
    CtlTrace ('status ' + $c.forId + ': ' + $s + $(if ($st.ctlPhase) { ' (' + $st.ctlPhase + ')' } else { '' }))
    return $true
  }
  return $false
}

# A profile is only a pointer: {schema_version, id, source_config, overrides} where source_config is
# the absolute path of the run config and overrides is empty (strata_control/profiles.py:261). It does
# not copy a single setting, so the run config stays the one place settings live. Creating it is a
# one-time thing per model; `profile set` is never used, because that WOULD put a second copy of the
# settings in play.
function Ensure-Profile([string]$id, [string]$source) {
  $j = Invoke-Strata @('profile', 'list', '--output', 'json')
  if ($j -and $j.profiles) {
    foreach ($p in @($j.profiles)) { if ([string]$p.id -eq $id) { return $true } }
  }
  if (-not $source) { $st.ctlMsg = ('no run config recorded for ' + $id); return $false }
  if (-not (Test-Path -LiteralPath $source)) { $st.ctlMsg = ('run config not found: ' + $source); return $false }
  $c = Invoke-Strata @('profile', 'create', $id, '--from-config', $source, '--output', 'json')
  CtlTrace ('profile create ' + $id + ' -> ' + $(if ($c) { 'ok' } else { $st.ctlMsg }))
  return [bool]$c
}

# Fire and forget: the CLI runs hidden, its JSON goes to a temp file, and the tray keeps asking
# `runtime status` meanwhile. A load takes a minute or two (tens of GB of experts into RAM) and a stop
# can take ~38 s, so neither may run inside a menu click handler.
function Start-Strata([string]$id, [string]$source) {
  $exe = Strata-Exe
  if (-not $exe) { return }
  if ($st.snap -and $st.snap.ok) { $st.ctlMsg = 'a server is already answering on ' + $st.url; return }
  if (-not (Ensure-Profile $id $source)) { return }
  $out = Join-Path $env:TEMP ('strata-tray-start-' + $id + '.out')
  $err = Join-Path $env:TEMP ('strata-tray-start-' + $id + '.err')
  Remove-Item -LiteralPath $out, $err -Force -ErrorAction SilentlyContinue
  $p = Start-Process -FilePath $exe `
        -ArgumentList @('runtime', 'start', '--profile', $id, '--wait', '0', '--output', 'json') `
        -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError $err -PassThru `
        -ErrorAction SilentlyContinue
  if (-not $p) { $st.ctlMsg = 'could not run the start command'; return }
  $st.action    = 'start'
  $st.actionId  = $id
  $st.actionOut = $out
  $st.actionErr = $err
  $st.actionAt  = Get-Date
  $st.ownedId   = $id
  $st.ctl       = 'starting'
  $st.ctlPhase  = 'starting'
  $st.ctlMsg    = ''
  CtlTrace ('runtime start ' + $id + ' (pid ' + $p.Id + ')')
}

function Stop-Strata([string]$id) {
  $exe = Strata-Exe
  if (-not $exe -or -not $id) { return }
  $out = Join-Path $env:TEMP ('strata-tray-stop-' + $id + '.out')
  $err = Join-Path $env:TEMP ('strata-tray-stop-' + $id + '.err')
  Remove-Item -LiteralPath $out, $err -Force -ErrorAction SilentlyContinue
  $p = Start-Process -FilePath $exe `
        -ArgumentList @('runtime', 'stop', '--profile', $id, '--output', 'json') `
        -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError $err -PassThru `
        -ErrorAction SilentlyContinue
  if (-not $p) { $st.ctlMsg = 'could not run the stop command'; return }
  $st.action    = 'stop'
  $st.actionId  = $id
  $st.actionOut = $out
  $st.actionErr = $err
  $st.actionAt  = Get-Date
  $st.ctl       = 'draining'
  $st.ctlPhase  = 'draining'
  $st.ctlMsg    = ''
  CtlTrace ('runtime stop ' + $id + ' (pid ' + $p.Id + ')')
}

# Soft control, no teardown: the server drops the model (VRAM back to everything else) or picks it up
# again. This frees the graphics memory, NOT the system RAM the experts sit in, and the card says so.
# The routes are guarded the way /settings is: application/json and no foreign Origin
# (serve/server.py:7333), so a stray form POST from some web page cannot do this.
function Post-Route([string]$path) {
  if (-not ($st.snap -and $st.snap.ok)) { $st.ctlMsg = 'no server to ask'; return }
  try {
    $r = Invoke-RestMethod -Uri ($st.url.TrimEnd('/') + '/' + $path) -Method Post `
            -ContentType 'application/json' -Body '{}' -TimeoutSec 60
    $st.ctlMsg = ''
    CtlTrace ($path + ' -> ' + $(if ($r) { [string]$r.status } else { 'ok' }))
  } catch {
    $resp = $_.Exception.Response
    $code = if ($resp) { [int]$resp.StatusCode } else { 0 }
    $st.ctlMsg = switch ($code) {
      409 { 'busy - a request is running or queued' }
      415 { 'the server refused the request (needs application/json)' }
      403 { 'the server refused: origin not trusted' }
      503 { 'the server could not do it: ' + $_.Exception.Message }
      default { $_.Exception.Message }
    }
    CtlTrace ($path + ' failed: ' + $st.ctlMsg)
  }
}

# Read what a fired start/stop finally printed, once it has printed it. A refusal (a port already
# taken, a retired model, a stale record) is a one-line JSON object and belongs on the card.
function Read-ActionResult() {
  if (-not $st.actionOut) { return }
  if (-not (Test-Path -LiteralPath $st.actionOut)) { return }
  $txt = ''
  try { $txt = ([string](Get-Content -LiteralPath $st.actionOut -Raw)).Trim() } catch { return }
  if (-not $txt) { return }
  $nl = $txt.IndexOf("`n")
  if ($nl -gt 0) { $txt = $txt.Substring(0, $nl) }
  $j = $null
  try { $j = $txt | ConvertFrom-Json } catch {}
  if ($j -and (-not $j.ok) -and $j.error) {
    $st.ctlMsg = Err-Text $j.error
    CtlTrace ($st.action + ' refused: ' + $st.ctlMsg)
    $st.action = ''          # the CLI said no - nothing is in flight, so stop waiting for a state change
    $st.ctlPhase = ''
  } elseif ($j) {
    CtlTrace ($st.action + ' command answered: ' + $(if ($j.state) { $j.state } else { 'ok' }))
  }
  $st.actionOut = $null            # read once
  $st.actionErr = $null
}

# How often the control state is worth asking about: often while something is happening, and otherwise
# rarely enough that a Python start-up every now and then is nothing.
function Refresh-Control() {
  if (-not $st.control) { return }
  $now = Get-Date

  # nothing in this function may block: Fire-Cli starts the call, Collect-Cli picks the answer up on a
  # later tick (see the note above Fire-Cli for why that is not an optimisation but the whole point).
  Collect-Cli

  # what is installed changes only when a person installs something - but an EMPTY list is a failure,
  # not a fact, so it is retried quickly instead of being cached for ten minutes and showing no Start
  # row at all in the meantime.
  $modelGap = $(if (@($st.models).Count) { 600 } else { 30 })
  if (-not $st.cli -and ($null -eq $st.modelsAt -or ($now - $st.modelsAt).TotalSeconds -ge $modelGap)) {
    $st.modelsAt = $now
    Fire-Cli 'models' @('models', 'list') ''
  }
  elseif (-not $st.cli) {
    # the CLI call for the load phase / ownership
    $gap = if ($st.action) { 3 } elseif ($st.ctl -in @('ready', 'starting', 'draining')) { 30 } else { 60 }
    if ($null -eq $st.ctlAt -or ($now - $st.ctlAt).TotalSeconds -ge $gap) {
      $id = if ($st.actionId) { $st.actionId } elseif ($st.ownedId) { $st.ownedId } elseif ($st.ctlId) { $st.ctlId }
            elseif ($st.models -and $st.models.Count) { $st.models[0].id } else { '' }
      if ($id) {
        $st.ctlAt = $now
        Fire-Cli 'status' @('runtime', 'status', '--profile', $id) $id
      }
    }
  }

  # The gap between asking and the process existing: after `runtime start --wait 0` the owner host has
  # not written its state file yet, so `runtime status` still reads `stopped`; after `runtime stop` it
  # reads `ready` until the teardown actually begins. Taken at face value the card and the menu flicker
  # `loading <-> no server` for a few seconds of every start. `runtime start --wait 0` returns
  # {ok:true, state:"starting"} (runtime.py:728), which is what the action is promising, so hold the
  # state we expect for a little while and let the real answer take over when it arrives.
  $since = if ($null -ne $st.actionAt) { ($now - $st.actionAt).TotalSeconds } else { 0 }
  if ($st.action -eq 'start' -and $st.ctl -eq 'stopped' -and -not ($st.snap -and $st.snap.ok) -and $since -lt 60) {
    $st.ctl = 'starting'
    if (-not $st.ctlPhase) { $st.ctlPhase = 'launching' }
  }
  if ($st.action -eq 'stop' -and $st.ctl -eq 'ready' -and $since -lt 60) { $st.ctl = 'draining' }

  if ($st.action) { Read-ActionResult }

  # an action is over when the state says so, or when the wait has plainly run out
  if ($st.action -and ($st.ctl -in @('ready', 'stopped', 'failed', 'stale'))) {
    if ($st.action -eq 'start' -and $st.ctl -eq 'ready') { $st.action = ''; $st.ctlPhase = '' }
    if ($st.action -eq 'stop' -and $st.ctl -in @('stopped', 'failed')) { $st.action = ''; $st.ctlPhase = '' }
  }
  if ($st.action -and $null -ne $st.actionAt -and ($now - $st.actionAt).TotalSeconds -gt 420) {
    CtlTrace ('action still unfinished after 420 s: reading its output and letting go')
    Read-ActionResult
    $st.action = ''
  }

  # a stale record or a dead owner clears itself on the next start; keep the wording short
  if ($st.ctl -eq 'stale') { $st.action = '' }
}
