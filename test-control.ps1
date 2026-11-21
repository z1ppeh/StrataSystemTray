#Requires -Version 5.1
<#
  test-control.ps1 - check strata-control.ps1 with no tray, no card and no clicks.

    powershell -NoProfile -ExecutionPolicy Bypass -File test-control.ps1 [url]

  Read only: it lists what is installed and what a runtime owns, and it asks the server the question
  the menu needs answered ("can Stop work on this server?"). It never starts, stops or unloads
  anything. The one POST it sends is deliberately refused before it can reach the unload itself: the
  /unload and /load routes demand application/json (serve/server.py:7333), and this sends
  text/plain, so the server rejects the request type rather than the action. Running this against a
  live server is safe - it is the same call shape the tray uses, minus the accepted content type.

  Which url: an argument wins, then settings.local.ps1 ($Url), then Strata's own default 8080. So
  running it with no argument checks the same server the tray looks at on this box.
#>
$ErrorActionPreference = 'Continue'

# pick up this machine's url and strata command the same way the tray does
$cfgUrl = ''
$cfgCmd = 'strata'
$cfgWizard = ''
$local = Join-Path $PSScriptRoot 'settings.local.ps1'
if (Test-Path -LiteralPath $local) {
  . $local
  $cfgUrl = if ($Url) { [string]$Url } else { '' }
  $cfgCmd = if ($StrataCmd) { [string]$StrataCmd } else { 'strata' }
  $cfgWizard = if ($Wizard) { [string]$Wizard } else { '' }
}
$UrlToCheck = if ($args.Count -ge 1) { [string]$args[0] }
              elseif ($cfgUrl)      { $cfgUrl }
              else                  { 'http://127.0.0.1:8080' }

. (Join-Path $PSScriptRoot 'strata-control.ps1')

$st = [ordered]@{
  control = $true; url = $UrlToCheck
  strataCmd = $cfgCmd; strataExe = $null
  wizard = $cfgWizard; wizardPath = $null
  models = @(); modelsAt = $null; modelSrc = @{}
  ctl = ''; ctlAt = $null; ctlPhase = ''; ctlMsg = ''; ctlId = ''
  cli = $null; cliSeq = 0    # the async paths are not used here, but the module shares $st
  action = ''; actionId = ''; actionOut = ''; actionErr = ''; actionAt = $null
  menuOpen = $false; cardWasOpen = $false
  ownedId = ''; snap = $null
}

Write-Output ('url      : ' + $UrlToCheck)
Write-Output ('strata   : ' + $(if (Strata-Exe) { Strata-Exe } else { 'NOT FOUND (' + $cfgCmd + ')' }))
Write-Output ('wizard   : ' + $(if (Strata-Wizard) { Strata-Wizard } else { 'START-HERE.bat not found (no start-here row)' }))

# the HTTP side of the picture: is anything answering, and is it busy?
$serving = $false; $busy = $false
try {
  $null = Invoke-RestMethod -Uri ($UrlToCheck.TrimEnd('/') + '/metrics') -TimeoutSec 3
  $serving = $true
} catch {}
try {
  $stt = Invoke-RestMethod -Uri ($UrlToCheck.TrimEnd('/') + '/status') -TimeoutSec 3
  $busy = [bool]$stt.busy
} catch {}
$st.snap = [ordered]@{ ok = $serving; state = '' }
Write-Output ('answering: ' + $serving + '   busy: ' + $busy)

$st.models = Get-Models
$st.modelsAt = Get-Date
$st.modelSrc = @{}
Write-Output ('models   : ' + $st.models.Count + ' installed')
foreach ($m in $st.models) {
  $st.modelSrc[$m.id] = $m.source
  $state = Get-Owned $m.id
  $owned = ($state -ne 'stopped' -and $state -ne 'unknown')
  Write-Output ('  - ' + $m.id + '  "' + $m.name + '"  ready=' + $m.ready + '  ctx=' + $m.ctx)
  Write-Output ('      profile source : ' + $m.source)
  Write-Output ('      runtime state  : ' + $state + $(if ($st.ctlPhase) { '  phase=' + $st.ctlPhase } else { '' }))
  Write-Output ('      tray can stop  : ' + $owned + $(if (-not $owned -and $serving) { '   <- answering, but started outside the tray' } else { '' }))
}

# the guard on the soft routes: a POST that is not application/json must be refused before it can
# unload. text/plain is sent on purpose, so this call can never reach the unload itself.
if (-not $serving) {
  Write-Output 'unload guard: not checked (nothing answering at this url)'
} else {
  try {
    $null = Invoke-WebRequest -Uri ($UrlToCheck.TrimEnd('/') + '/unload') -Method Post `
              -ContentType 'text/plain' -Body '{}' -TimeoutSec 5 -UseBasicParsing
    Write-Output 'unload guard: NOT REFUSED (unexpected - the route took a non-json POST)'
  } catch {
    $code = try { [int]$_.Exception.Response.StatusCode } catch { '?' }
    if ([string]$code -eq '415') {
      Write-Output 'unload guard: refused with HTTP 415 (as expected - application/json is required)'
    } else {
      Write-Output ('unload guard: refused with HTTP ' + $code + ' - expected 415, worth a look')
    }
  }
}
if ($st.ctlMsg) { Write-Output ('last cli note: ' + $st.ctlMsg) }
