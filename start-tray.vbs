' start-tray.vbs - start the Strata tray monitor with NO console window.
'
' Double-click this, or put a shortcut to it in shell:startup to get the icon at logon.
' WScript runs it with the GUI subsystem, so unlike a .bat there is no black window that flashes
' and then lingers. The tray itself quits from its own right-click menu ("Quit the tray icon"),
' or with stop-tray.ps1 if it ever gets orphaned.
Option Explicit

Dim sh, dir, cmd
Set sh = CreateObject("WScript.Shell")
dir = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))

' Which server to watch is NOT decided here. The script reads settings.local.ps1 next to it (your
' port, not in the repo) and otherwise falls back to Strata's default port 8080. To force a server
' for this launcher only, add  -Url http://127.0.0.1:PORT  at the end of the command below.
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & dir & "strata-tray.ps1"""

sh.Run cmd, 0, False
