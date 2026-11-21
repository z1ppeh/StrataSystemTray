# stop-tray.ps1 - stop every running Strata tray monitor.
#
# The tray has no window to close, so if it is ever orphaned (a reboot race, a stray launch, several
# copies started at once and showing several icons) this is the way to clear it. Matching on the
# command line rather than the process name matters: powershell.exe runs many other things.
# This script's own name (stop-tray.ps1) does not contain "strata-tray.ps1", so it cannot match itself.
$ErrorActionPreference = 'Continue'

$procs = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object { $_.CommandLine -like '*strata-tray.ps1*' })

if ($procs.Count -eq 0) { Write-Output 'no Strata tray process is running'; exit 0 }
foreach ($p in $procs) {
  Write-Output ('stopping pid ' + $p.ProcessId)
  Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Milliseconds 600
$left = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object { $_.CommandLine -like '*strata-tray.ps1*' })
Write-Output ('still running: ' + $left.Count)
