# Dev notes

Not needed to use the tray. This is the internals and maintenance side: where each number comes from,
what is deliberately left out, the bugs that cost hours, and the measurements from the box it was
built on.

## Starting at logon

Installed on this box as `Strata Tray.lnk` in the per-user Startup folder
(`GetFolderPath('Startup')`), targeting `start-tray.vbs`. Deliberately not a service and not a
`HKCU\...\Run` key: the tray dies at logoff with the session, and Task Scheduler stays clean. Two icons
therefore means logon *and* a manual `start-tray.vbs` - `stop-tray.ps1` clears every copy.

The **desktop** carries the same shortcut (`Strata Tray.lnk`, same target, plus `IconLocation` set to
`strata-tray.ico`) for the case where the tray was quit by hand after logon and needs bringing back.
Nothing about it is special - a `.lnk` to `start-tray.vbs` is all a launcher has to be.

On another machine, put a shortcut to `start-tray.vbs` in `shell:startup`:

```powershell
$ws  = New-Object -ComObject WScript.Shell
$lnk = $ws.CreateShortcut((Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\Strata Tray.lnk'))
$lnk.TargetPath = 'C:\Tools\StrataSystemTray\start-tray.vbs'   # your checkout path
$lnk.WorkingDirectory = 'C:\Tools\StrataSystemTray'
$lnk.Save()
```

## Where the numbers come from

Two endpoints, both from the running server - nothing else is read:

- `GET /metrics` - engine block (model, version, kv, spec tokens, `max_context`, expert cache size and
  slots), `live` (state, tokens in / out / reused, current tok/s), `hardware` (VRAM used / total, RAM
  used / total, GPU %, PCIe bytes to the GPU, CPU %, disk read), `hardware_static` (GPU name),
  `history`, `totals` and the `requests` ring.
- `GET /status` - the live phase string (`thinking`, `answering`, `writing a tool call: ...`), which is
  only shown while `busy` is true, because the server keeps the last phase after a run ends.

Derivations worth knowing, because each one fixed a wrong number:

- **Context fill** = prompt + generated for the in-flight request, otherwise for the last finished one.
- **Prefill t/s** uses the engine mean when it has one; this engine keeps `prefill_tok_s_mean` at 0, so
  it falls back to `1000 * sum(prompt_read) / sum(prompt_ms)` over the requests the server still
  remembers. `prompt_tokens / prompt_ms` is *not* the same number and it is wrong while prompt caching
  is on: a 92 % cached prompt reads very few tokens but still pays the cache lookup, so that ratio
  implies a fantasy 100k+ t/s.
- **Decode t/s** falls back to the last non-zero sample when the server is idle, so the card is not a
  wall of zeros between runs; the small label under the number says which source was used
  (`answer speed` / `last run`).
- The last-request line prints **wall time**, not a per-request prefill rate, for the caching reason above.

## Deliberately not shown

GPU temperature, power draw and PCIe link generation: they never move on the tested box and the full
Monitor page has them if they ever do. A decode sparkline was in here and was removed - the server's
history buffer only fills while a run is in flight, so on a hover it was a flat or half-empty line.
The request log is on the Monitor page.

## Model control (start / stop / unload)

`strata-control.ps1` drives Strata through Strata's own command line (`strata runtime start`,
`strata runtime stop`, `strata profile create`) rather than inventing a way of its own. Everything
below was read in the Strata tree (0.2.17 / engine 0.1.63) or measured on this box.

**Why the CLI and not an HTTP call for a Stop.** Strata has no HTTP shutdown route. `runtime stop`
asks the *owner host* for that profile; the host closes its end of the pipe it passed the server as
stdin (`--owner-fd 0`), and `serve/owner_guard.py` turns that EOF into `_thread.interrupt_main()`.
That is the same `KeyboardInterrupt` Ctrl+C in the server window produces: drain (30 s default) ->
`httpd.shutdown` -> `engine.close` (QUIT to `strata.exe`) -> `vision.shutdown` -> `hub.close` ->
`[strata] stopped`. It is also how Strata's own desktop app runs its engines
(`app/host/server/native-control.mjs`: "The app starts a model with `strata runtime start --wait`"),
so it is the supported lifecycle and not a side door.

**Why not sending Ctrl+Break to the console instead.** It was tried and it fails. The interpreter under
`terminal\.venv\Scripts` is a *shim* that re-execs the real one under
`AppData\Local\Python\pythoncore-3.14-64`, so the pid the tray can see is not the pid holding the
signal handlers (the probe answered `err=87`). And a console
control event goes to every process attached to that console, `cmd` included, which is exactly the
"Terminate batch job (Y/N)?" prompt the user hates. Console *close* is not better either: the server's
own lifeline caps it at ~4.5 s and then the kill-on-close job object ends the tree
(`serve/lifeline.py`).

**Timers (Strata's shipped defaults, deliberately not overridden anywhere).**

| what | default | where |
|---|---|---|
| a start watches the load for | 300 s | `strata_cli/cli.py:238` |
| a stop allows for the teardown | 330 s | `cli.py:257` |
| drain before cancelling requests | 30 s | `cli.py:239` |
| extra during `verifying_generation` | 180 s | `runtime.py` `VERIFY_BUDGET` |
| hard kill after a clean stop | 8 s | `STOP_KILL_GRACE` |
| reap wait | 10 s | `STOP_REAP_WAIT` |

`runtime start --wait 0` is **not** a shorter timeout: `runtime.py:708` passes
`str(wait if wait else 300)` to the host it spawns, so the load budget stays 300 s. `--wait 0` only
makes the CLI return at once (it answers `{ok:true, state:"starting"}`, `runtime.py:728`), which the
tray needs because a menu click handler must not block for two minutes. A start that runs out of its
wait is *reporting only* (`_await_start` returns `startup_wait_expired`, nothing is killed).

**Ownership is a real distinction.** A server started by a console window is not owned: `runtime stop`
answers `runtime_not_owned` (exit 6, `runtime.py:792`). `runtime status` for an unowned profile simply
reads `stopped`. The menu reflects that - it explains how to stop such a server instead of offering a
Stop that cannot work. The point of `terminal/run-iq3_s.bat` going through `runtime start` is that the
tray then *can* stop it.

**A profile is only a pointer.** `strata_control/profiles.py:261` writes
`{schema_version, id, source_config, overrides}` where `source_config` is the absolute path of the run
config and `overrides` is empty. No setting is copied, so `strata-iq3_s.json` stays the single place
settings live - which is why `profile set` is never used here: that *would* create a second source of
truth. Creating the profile is one command per model (`profile create <id> --from-config <path>`), and
`create` refuses if it already exists, so running it again is harmless.

**Where the output goes.** A runtime start has no console, so nothing is lost, it just moves:
the engine's own lines still go to the run config's `log` (`terminal/strata-iq3_s.log`, opened in
append mode through `serve/appendlog.py`), the lines that used to print in the cmd window go to
`%LOCALAPPDATA%\Strata\runtime\<profile>.server.log` (`runtime.py:1046`), and the owner host's lines to
`<profile>.host.log`. Both are opened `O_APPEND`, 0600, and **not rotated** - they grow at about the
rate the console used to print (this box: ~1 MB per heavy day in the engine log). Housekeeping is by
hand: stop the model, then delete the two `.log` files.

**The tray never calls the CLI from the 1.5 s poll.** One `strata` call is a Python start-up (0.4-0.7 s
measured), so `Refresh-Control` paces them instead: the model list every 10 minutes, the runtime status
every 3 s while a start or a stop is in flight and every 60-120 s otherwise. The 1 s `Timer` only reads
cached values. `Build-CtlMenu` (menu) likewise only reads the cache, so right click stays instant.

**Two states need a short lie.** After `runtime start --wait 0` the host has not written its state file
yet, so `runtime status` still says `stopped`; after `runtime stop` it still says `ready` until the
teardown begins. Taken literally the card flickers `loading <-> no server` on every start, so while an
action is in flight the expected state is held for up to 60 s and the real answer takes over when it
arrives. A start whose CLI answered a refusal ends the action at once.

**Stop is one click.** It was two clicks for a while (first click armed the row, it read
`STOP ... (click again)`, and the arm expired after 8 s). Changed on 2026-11-21 at the request of the
person who uses it daily: a row that needs a second click is indistinguishable from a row that does
nothing, and "I cannot select anything" was one of the complaints about the menu. What makes a Stop
safe is not the extra click, it is that `runtime stop` is the graceful path (drain in-flight requests,
then QUIT to the engine) and never a kill. Do not replace it with a dialog either - a tray has no dialog
that can be missed and found again.

**`/unload` and `/load`** are server routes (`serve/server.py`), guarded the way `/settings` is by
`_own_page`: they need `Content-Type: application/json` and no foreign Origin (a `text/plain` POST is
answered **415**, which is what `test-control.ps1` sends on purpose so it can never unload a live
model). `/unload` frees **VRAM only** - the ~47 GB of locked expert RAM stays - and the menu says so.

**Retired models cannot be offered.** `strata models list` does not even list the DeepSeek packs (last
supported on 0.2.13; `strata_control/retired.py` refuses them before any process exists), so the menu is
built generically from that list and currently yields one row.

**Nothing installed goes to Strata's own wizard.** An empty list means either "nothing installed" or
"the call failed", and both want the same next step, so the menu offers a clickable
`no models installed: open the Strata start-here` row that opens `START-HERE.bat` in its own console
window. The tray never installs or downloads anything itself - that wizard is interactive and it is the
person who decides what to pull. The .bat is found by walking up from the `strata` command
(`<root>\terminal\bin\strata.cmd` -> `<root>\START-HERE.bat`, and `terminal\START-HERE.bat` first for an
older clone); `$Wizard` in `settings.local.ps1` overrides the search. Empty list is retried after 30 s,
not after the usual 600 s, because an empty list is usually a failure rather than a fact.

**Checking the control rows without a mouse: `-CtlSelfTest`.** The rows only exist once the menu's
`Opening` event has run, so there is no way to see them by reading the code alone - and the first
version of this code was broken in a way that was invisible for exactly that reason (trap 13). The
switch pumps `Refresh-Control` / `Collect-Cli` by hand (the calls are asynchronous now, trap 15), calls
`Build-CtlMenu`, prints every menu row with `[on]` / `[off]` and exits before any tray timer exists.
Nothing it prints can start or stop anything, so it is safe to run against a live server. On this box,
with the model loaded and owned by `strata runtime`:

```
menu for http://127.0.0.1:8080   control=True   strata=C:\Strata\terminal\bin\strata.cmd
control state: ready owned=- status-of=iq3_s
  [on]  Open the Monitor page
  [on]  Open the chat page
  [on]  Open the API (/v1)
  [on]
  [off] Start qwen3.8-flash-next-iq3_s  (running here)
  [on]  Stop iq3_s
  [on]  Unload the model (VRAM back, RAM stays)
  [on]  Refresh now
  ...
```

`-NoModels` with `-CtlSelfTest` clears the cached list to check the "open the Strata start-here" row.
`-NoControl` should print `control is off (viewer only)` and nothing else under the separator.

**Smoke test, live:** start a second hidden instance with `-Trace <file>` while capturing its stdout and
stderr, let it run ~15 s, and read the capture. A healthy run prints the `strata exe:` and
`models: iq3_s` control lines, `Strata tray: watching ...`, and nothing on stderr. Two tray icons can
coexist, so this does not disturb the running one; `stop-tray.ps1` then clears both and `start-tray.vbs`
puts one back.

## Things that cost hours to find (read before editing)

1. **`Add-Type -TypeDefinition` needs explicit `-ReferencedAssemblies`.** The C# compiler driver does
   not inherit the assemblies PowerShell already loaded, so `using System.Windows.Forms;` fails to
   compile. With `$ErrorActionPreference='SilentlyContinue'` that failure is *invisible*: the type does
   not exist, `New-Object` returns `$null`, every `$form.X` silently does nothing, and the card never
   appears while the tray icon keeps working. The script compiles it with references, checks it worked
   (`$cardFormOk`) and falls back to a plain `Form` with reflection + Win32 if it did not.
2. **Writes to `$script:` variables from inside an event handler do not persist** on this PC (a
   `$n = $n + 1` in a handler counted 1 forever). All mutable state therefore lives in **one
   hashtable** (`$st`) and only its keys are mutated. Getting this wrong made the "already open" latch
   never hold: every mouse-move re-positioned and re-`Show()`ed a borderless topmost window, and moving
   such a window repaints the desktop - that was a violent flicker that then closed the card.
   Related rules: `Show-Card` is idempotent, and `Position-Card` only moves the window when the anchor
   actually changed.
3. **A double click also raises two `MouseUp` events.** A pin bound to `Clicks >= 2` or
   `MouseDoubleClick` plus `MouseUp` toggles twice = nothing ever pins. Instead the first click starts
   a 320 ms one-shot timer; a second click inside it cancels the single click and pins.
4. **The native tray tooltip must be blanked while the card is open**, and that guard has to live in
   `Set-TrayIcon`, not only in `Show-Card`: the 1.5 s poll re-writes the tooltip text and was silently
   undoing the blank a second after the card opened. The card is additionally lifted `$TipGap` (56 px)
   above the taskbar so that if a tooltip does appear it cannot sit on the card's bottom rows.
5. **Keep the file ASCII-only.** Windows PowerShell 5.1 reads a `.ps1` as ANSI unless it has a BOM, so a
   literal middle dot arrives as mojibake in the drawn text. No BOM either: ASCII plus no BOM.
6. **Clamp fractions in PowerShell, not `[Math]::Min(1, $frac)`**: given an `int` literal and a double,
   the binder picks `Min(Int32,Int32)`, rounds the fraction to 0 or 1 first, and every bar comes out
   either empty or full.
7. **Verify hover with the tray's own `-Trace` output, not by enumerating windows.** P/Invoke
   `EnumWindows` with `out RECT` / `out int` marshalling through `[ref]` did not read back reliably, and
   `GetWindowLong`/`GetClassName` gave confusing results. The trace lines
   `card shown (hover) at x,y size WxH` / `card hidden (...)` are ground truth.
8. **`-MemberDefinition` cannot declare delegates or structs** as top-level types (they become nested),
   and a cast like `[string]$obj.Prop` parses as `([string]$obj).Prop` - assign to a temp first.
9. **The Monitor page has no path - it is a URL fragment.** Strata's web app is a single-page app, so
   the tab is selected by `location.hash` (`web/app.js`: `showTab(location.hash.slice(1) || "chat")`,
   and a `hashchange` listener). A click must therefore open **`<url>/#monitor`**. `GET /monitor`
   answers **404** (measured against a running server). `GET /api-monitor` does exist, but it is a
   different page - the API request monitor - and it 404s unless the server was started with
   `--api-monitor`, because that page keeps the last 100 requests' prompts and answers in memory.
   The tabs are `#chat`, `#monitor`, `#images` and `#experts`; `#images` and `#experts` are hidden
   unless the server offers them. And keep the fragment inside a string: a bare `/#monitor` typed into
   PowerShell source is a comment from the `#` on, so the line silently truncates. Inside quotes it is
   an ordinary character, and `Start-Process $Page` passes the variable through without re-parsing it,
   so the fragment survives. Checked by running the top of the script with a probe exit: it printed
   `PAGE=[http://127.0.0.1:8080/#monitor]`. Do not "test" it by calling `Start-Process` for real -
   that opens a browser tab on the user's screen; check the resolved string instead.
10. **A trace written with `Write-Output` becomes part of the function's return value.** `Get-Models`
    logged `  . models: iq3_s` and then returned the list, so the caller got
    `['  . models: iq3_s', <model>]` and `foreach` later died on "array index evaluated to null".
    Every trace in `strata-control.ps1` goes through `CtlTrace`, which uses `Write-Host` (side-effect
    only). The same trap catches `return ,$list`-style returns: a single-element list is only a list if
    you comma-wrap it.
11. **Dynamic `ContextMenuStrip` rows belong in the `Opening` handler.** Adding items after the menu has
    been shown does nothing visible, and `Add_Click({ ... })` handlers need `param($s, $e)` if they use
    `$s`. `Build-CtlMenu` removes the rows it added last time (by keeping the item objects in
    `$st.ctlItems`), inserts fresh ones after a saved separator, and never touches the pin item, whose
    tick is only ever set by `Toggle-Pin`.
12. **The tray's own start/stop helpers must not block.** Start the CLI with `Start-Process -WindowStyle
    Hidden`, redirecting its output to a temp file, with `-PassThru`, and then poll `runtime status`;
    reading that temp file is guarded because it can be empty or half-written while the CLI is still
    starting. Never call the CLI inline from a click handler.
13. **`$menu.Items.Insert($n, 'some text')` does not exist.** `ToolStripItemCollection.Add(string)` does
    take a string (and returns the new item), but `Insert` only has `Insert(int, ToolStripItem)`. In
    PowerShell the bad call raises "Cannot find an overload for Insert and the argument count: 2", which
    `$ErrorActionPreference='SilentlyContinue'` swallows, `$it` stays `$null`, and the control rows are
    silently never added - the menu looked fine and simply had no Start/Stop in it. Build the item first
    (`New-Object System.Windows.Forms.ToolStripMenuItem`, set `.Text`, `.Tag`, `.Enabled`, `Add_Click`)
    and then `Insert($at, $it)`. This is why `-CtlSelfTest` exists: it prints the rows, so a broken
    insert is visible without a mouse.
14. **Dot-sourcing `settings.local.ps1` writes into the caller's scope, so it clobbers `-Url` and
    `-Every`.** The param block runs first, then `. $localCfg` assigns `$Url = ...`, and the documented
    precedence (command line, then local settings, then the default) silently became "local settings
    always": `-Url http://127.0.0.1:8099` watched the port from `settings.local.ps1` instead. What the
    command line said is now kept in `$CliUrl` / `$CliEvery` before the dot-source and put back
    afterwards. Found with
    `-CtlSelfTest -Url ...`, which printed the wrong url. `test-control.ps1` reads its config before
    looking at `$args`, so its precedence was already right.
15. **A CLI call inside a WinForms `Timer` tick blocks the whole tray, and a right-click menu is the
    first thing to show it.** `Refresh-Control` used to call `strata models list` / `runtime status`
    inline. Warm, one call is 0.2-0.45 s; right after a model is torn down (tens of GB being freed, page
    cache churning) the same Python start-up takes seconds. During that the message loop is not running,
    so the icon's menu either does not open or opens and takes no clicks - which is exactly the report
    that came in: "I right-clicked while the server was down and could not select anything; once the
    server was up it was fine". Note that this is **not** Strata being slow: `runtime status` answers
    `stopped` / `stale` without touching a socket when nothing is owned (`runtime.py:status()` -> the
    cheap path). The fix is `Fire-Cli` / `Collect-Cli` in `strata-control.ps1`: the call is started
    hidden with its output redirected to a temp file and harvested on a later tick, one call in flight,
    abandoned after 20 s. Only `Start-Strata` (one-time profile create) and the Stop / Unload handlers
    still call the CLI inline, and those are deliberate clicks.
16. **The Stop row needs the profile the status is *about*, not the profile the tray started.**
    `$st.ownedId` is only set when the tray itself started a model, but a model started with
    `strata runtime start` (or by `run-iq3_s.bat`) is owned by the runtime just the same. Building the
    label and the click target from `ownedId` alone gave `Stop ` with an empty id, and `Stop-Strata`
    returns immediately when the id is empty - so the row looked clickable and did nothing. The state
    cache now carries `ctlId` (which profile `ctl` / `ctlPhase` describe) and the Stop / Unload / Load
    rows use it.
17. **A greyed row with no reason reads as a broken tray, and an empty list read as a fact.** Disabled
    Start rows used to say nothing about why, and a failed `models list` was cached for 600 s, so the
    control rows were simply absent for ten minutes. Every disabled row now carries its reason
    (`(not downloaded)`, `(running here)`, `(another server is answering)`, `(loading now)`,
    `(a stop is finishing)`, `(a model is loaded elsewhere)`), and an empty list is retried in 30 s with
    its own row explaining it. Also worth knowing: `Start` is keyed on **both** the port and the runtime
    state, because a tray pointed at the wrong port would otherwise offer a second start while a model
    really is loaded (`failed` / `stale` records stay startable on purpose - the next start cleans them
    up).
18. **Trap 15 was not the whole story, so the menu now logs itself.** The same report came back after the
    async fix ("I can't select anything" when trying to **load** from the tray), while the UIA check
    showed exactly one live tray, exactly one icon, and a tooltip that keeps updating - so the message
    loop was alive and there was no ghost icon. That rules trap 15 in as *a* cause but not as *the*
    cause, and guessing twice is how hours get lost. `strata-tray.ps1` therefore:
    - traces to `strata-tray.trace.log` next to the script when asked: `-TraceOn`, or `-Trace <file>` to
      put it elsewhere. Rotated at start and while running above 400 KB. It was **on by default** for the
      whole investigation, because start-tray.vbs passes no command line and the instance people actually
      run had never written a line of evidence. The bugs are closed (trap 19), so the default is now
      **off** and normal running writes nothing - switch it on again before guessing at a menu problem.
      One way to lose an hour on that: **two tracing instances cannot share one file**. The writer opens it
      with `FileShare.Read`, so the second process gets `The process cannot access the file ... because it
      is being used by another process`, `traceDead` latches, and tracing then writes nothing at all - which
      looks like the switch is broken. Confirmed in isolation (two `StreamWriter`s, one file). Before
      concluding anything, list the copies (`Get-CimInstance Win32_Process -Filter "Name='powershell.exe'"`
      filtered on `strata-tray.ps1`), stop them, or give the new run its own `-Trace <file>`.
    - logs `menu open:` with control state, ctl state, model count, the card's bounds, the cursor and
      **every row with its enabled state**, plus `menu clicked: <text>` and `menu closed: <CloseReason>`.
      `ItemClicked` = the click landed. `AppFocusChange` = something took the menu away before the click,
      which is what an "unselectable menu" looks like from outside; the line now names the foreground
      window at that moment (`foreground now: hwnd ... pid ... explorer`). Note `ToolStripDropDownCloseReason`
      has no `MenuItemSelect` - that name is from the retired Win32 `ContextMenu`, and every close in the
      real log is `ItemClicked` / `AppFocusChange`.
    Two suspects are also now suppressed while the menu is open, because both are cheap and both can end
    a tracked menu: (a) the hover card - it is `TopMost` and anchored to the bottom-right of the working
    area, which is precisely where a tray menu opens, so it can sit under the pointer; (b) the 1.5 s poll
    writing `Shell_NotifyIcon` (NIF_ICON / NIF_TIP) mid-tracking. `Set-TrayIcon` returns early while
    `$st.menuOpen`, and the Opening handler hides the card **without** touching the tip (Hide-Card would
    re-write the tip, i.e. it would do the very thing being avoided). If the complaint survives this
    build, the log says which of the two families it is - read it before changing anything else.

19. **The click killer was our own timers firing inside the menu's mouse-tracking loop.** Two runs of
    the same trace log, either side of the fix, settled it. Before (17:25-17:26): a menu opens with every
    row `[on]` and closes `AppFocusChange` with no click, while the `ctlTimer` is still spawning CLI
    processes *inside* that window (`cli: status (pid 33324)` at 17:26:10 and 17:26:12, in a menu that
    closed at 17:26:14) and the 1.5 s card poll is doing two `Invoke-RestMethod` calls. A WinForms menu
    tracks the mouse in a modal loop, so anything running on the message loop during it is a candidate for
    "the menu paints but takes no clicks" / "the tray mini-freezes and sticks on screen". After: all three
    timers (`poll`, `ctlTimer`, `watch`) return early while `$st.menuOpen`, and six right-clicks in a row
    all end `ItemClicked` with the click landing. Trap 15 (a CLI call blocking a tick) is *a* cause - the
    async CLI is what lets the menu open at all - the freeze is what makes the rows clickable.
    Two rules came out of it:
    - `Opening` refuses a second open while one is live (the old log has pairs of `menu open:` 3.1 s and
      3.3 s apart with no `Closed` between them: two tracking loops over one dropdown). That latch must
      **expire**. A `menuOpen` stuck true - from a build that threw half way, or a `Closed` that never
      fired - would refuse every right click for the rest of the session, a worse bug than the one it
      prevents. It is trusted for 30 s only (`$st.menuAt`); the double opens it guards are ~3 s apart.
    - `Trace` must not open the file per line. It used `Add-Content`, which opens and closes the file on
      every call, and row-hover logging fires inside that same modal loop: the diagnostic adding the very
      delay it is looking for. It is now one `StreamWriter` (AutoFlush, no BOM), reopened on rotation.
20. **`$menu.Handle` is the popup window, and nothing is painted over it.** Settled by the `Opened`
    handler, so nobody has to relitigate it: `GetWindowRect($menu.Handle)` = `1913,1247 316x192`, and
    `WindowFromPoint` at that rect's centre returns *the same handle*, owned by the tray's own pid
    (`the window there is own menu`). So both remaining theories are dead - no foreign window eats the
    click, and the menu does not need showing by hand (`Show(Cursor.Position)` + `SetForegroundWindow`, or
    `SetWindowLongPtr(GWL_HWNDPARENT)`): WinForms already owns the window under the pointer. Two related
    facts:
    - A tray menu opens **upward from the cursor**, so the pointer lands ~23 px above the menu's bottom
      edge, on the bottom-most row. Keep destructive rows away from the bottom of the list; "the row I
      want is nowhere near where the pointer landed" is normal geometry, not a bug.
    - `ToolStrip.ItemMouseHover` is **not a public event** in .NET Framework 4.x, so there is no
      `Add_ItemMouseHover` in PowerShell - with `SilentlyContinue` it fails as a silent no-op, which is
      how it got mistaken for working. `ToolStripItem` does expose `MouseEnter` / `MouseUp`, which answer
      the same question (`mouse enters row:` / `mouse up on row:` in the log).
21. **A CLI `error` can be an object, not a string.** A refusal such as `runtime_not_owned` arrives as
    `{code: 3, message: "The helper program ..."}`, so `ctlMsg = [string]$j.error` puts a hashtable in a
    menu label. The row was literally named `@{code=3; message=The helper program that runs this model...`
    (still in the trace log at 17:26:09, sitting among the rows it disabled). `Err-Text` in
    `strata-control.ps1` takes `.message` when it is not a string - use it for every `$j.error`.

22. **The shortcut icon is art, the tray icon is code, and they are meant to differ.** `strata-tray.ico`
    is the author's own artwork and is only the picture on the `Strata Tray.lnk` launcher (it carries
    128 and 256 as 32-bit BMP entries, opaque, so the shell resamples it for smaller sizes). The icon in
    the tray is drawn at run time by `New-Icon` (dark ring + state-coloured disc + highlight arc)
    because its **colour is the server state**: grey idle, green generating, blue reading the prompt,
    amber queued, red no server answering. Swapping the artwork in there would throw away the only thing
    the tray icon says at a glance, so do not "make them match".
    `make-icon-ico.ps1` is the optional way to build an `.ico` from a square PNG
    (`-Source art.png -Out my.ico`): it resamples, it never draws or crops. It writes 16 / 32 / 48 as
    32-bit BMP entries plus 256 as a PNG entry, because `Icon.Save()` writes exactly one image and 4K
    desktop icon sizes want the 256. Container details that are easy to get wrong (each gives a file
    that parses happily and then shows up blank): a 256-wide entry puts **0** in the directory's width
    and height bytes; a BMP entry's `biHeight` is **2 x** the image height (XOR + AND mask); the AND
    mask stays all zeros and the alpha channel carries the shape. The shell caches an `.ico` by path, so
    replacing the file in place can leave the old picture on the shortcut until `ie4uinit.exe -show`, a
    logoff, or an explorer restart repaints it.

## Behaviour notes

- The card does **not** follow the pointer. It is anchored once per hover to the bottom-right of the
  work area of the screen the pointer is on, so a few pixels of jitter cannot drag a window.
- Anywhere on the taskbar strip counts as "still hovering", plus an inflated band around the card, and
  there is a 700 ms grace period. You do not have to keep the pointer on a 24 px icon.
- Repaints happen on poll only while the card is visible (`$form.Invalidate()`); the window is never
  moved or re-shown while open.
- Brushes, pens and tray icons are cached per colour for the life of the process: `GetHicon()` handles
  are not released by `Dispose()`, and the tray icon changes with the state, so allocating inline leaks
  GDI handles in a process meant to run for days. Measured steady at 21 GDI / 18 USER objects.
- The watcher timer also self-heals the latch if the card window disappears some other way
  (e.g. Alt+F4 on a borderless window).
- **Pin is visible in three places**, because a pinned card looks identical to a card that is stuck
  open: an amber `pinned` chip in the card header (left of the state chip), the footer line, and a
  ticked + relabelled menu item. The tick and the label are set inside `Toggle-Pin`, which is the only
  place the pin state ever changes - not on the menu's `Opening` event, so the two cannot drift apart.
  `Draw-Card` only *reads* `$st` (see trap 2), and it is guarded with `if ($st -and $st.pinned)`
  because `-Preview` draws before `$st` exists.
- The footer line is close to the card's width limit. Measured with `Graphics.MeasureString` at
  Segoe UI 8.5 against **538 px** of usable width (card 566 px, 14 px padding each side), for a typical
  line (`requests 1,234 | reused 88% | uptime 12h34m | ...`): the shipped wording is **479.6 px**
  unpinned and **514.9 px** pinned. Writing `click = full Monitor` instead of `click = Monitor` costs
  19 px and would put the pinned line at **534.0 px** - still inside the card, but with nothing left
  for a bigger request count or a three-digit uptime. Measure before changing the wording.

## Tested environment

Record of the kind of box the numbers below were taken on, so they can be read in context. Nothing here
is a requirement: the script assumes no port, model or hardware.

Strata engine 0.1.63 serving one installed model on `127.0.0.1:8080` (Strata's own default port; a
non-default port belongs in `settings.local.ps1`, never in the script), `max_context 143360`, a 32 GB
GPU, 64 GB system RAM, Windows 11 (26300).

Displays: primary **3840x2160 (4K) at 150 % scaling**, secondary 1920x1080 at 100 %, off to the left
and below. This is the trap: WinForms reports the primary as **2560x1440** because every coordinate in
the script is a *logical* (DIP) value, not a physical pixel count - 3840/2560 = 1.5 is the scale
factor, so `$W = 566; $H = 376` draws as about 849x564 real pixels on this screen. Do not "fix" the
card size by multiplying by the scale factor: `Screen.FromPoint` and `Cursor.Position` are already in
the same logical space, and mixing the two puts the card off screen. Multi-monitor anchoring is
handled per-screen (including a taskbar along the top of a screen). The card has been checked both as
a `-Preview` render and as an on-screen capture of the live tray window.

## Measured cost

Idle, tray running, nothing hovered, 60 s sample: **0.36 % of one core** (109-156 ms per 30 s).
Working set steady at 147.7 MB; private bytes 119 MB -> 92 MB after GC, so it shrinks rather than
leaks. About 140 MB of that is the floor cost of `powershell.exe` + CLR + WinForms, not the script.

Re-measured 2026-11-21 with 30 s samples over 9 min, because "does it leak after days?" is the one thing
a process meant to live in the tray for weeks has to answer:

| what | values |
|---|---|
| CPU | 0.11-0.21 s per 30 s = **0.37-0.70 % of one core** (the top of the range is the GC pass) |
| working set | 154.6 -> 157.9 -> **125.8** MB: creeps between GCs, then drops back |
| GDI / USER objects (`GetGuiResources`) | **37 / 34-35**, flat for the whole 9 min. This is the leak that actually kills a tray app (`GetHicon` handles are never released), and it is not happening |
| kernel handle count (`Process.HandleCount`) | saw-tooth **972 -> 998 -> 1040 -> 742 -> 737 -> 755**, i.e. not a leak: `Invoke-RestMethod` leaves socket / response handles until the finaliser runs and GC reaps them every few minutes. A single snapshot mid-slope reads as a leak, so sample three times |
| threads | 16-20, no trend (the CLR pool, not our code) |

For scale: the 1.5 s poll costs 49 ms of wall time (both requests) and ~5 ms of CPU, 40 times a minute -
about 12 CPU-seconds an hour, against a model that costs tens of GB and a few hundred watts.

Traffic: 2 requests per 1.5 s poll = ~4,800/hour. Round trip, measured from a PowerShell client:
`GET /metrics` ~19 ms / 13.9 KB on the wire (12.6 KB of JSON), `GET /status` ~12 ms / 192 bytes. Most
of that 19 ms is client and HTTP overhead, not server compute - firing 20 calls 4-way parallel barely
changed the per-call wall time (19.6 -> 16.0 ms), so there is no contention cliff on `/metrics`.
The tray's own measured CPU (0.36 % of a core above) already includes both requests.

**Why 1.5 s is the right ballpark, not a compromise:** the server samples the hardware on its *own*
background thread at **1 Hz** (`serve/telemetry.py`: "A background thread samples once a second and
keeps the last 60 readings of each series"), and `/metrics` only takes a cached `telemetry.snapshot()`
under a short lock. So the GPU / RAM / PCIe numbers can never be fresher than 1 s no matter how often
you poll - a 0.25 s poll would re-read identical samples 4 times over and just burn requests. Polling
much slower than that is what loses information: the card's fill and phase would visibly lag a busy
run.

The payload is dominated by things the card barely uses: 60 samples x 10 series of history, plus the
last 12 of 500 kept requests. If it ever needs to be lighter, in this order: skip `/status` when
`/metrics` already reports not busy (halves the request count), poll slowly (5 s) while the card is
closed and the state is idle and go fast only when open or busy, or stretch the 200 ms watcher timer.
None of them are worth doing on this hardware.

Control calls are a different cost entirely: each `strata ...` is a Python start-up, measured warm at
**0.16-0.19 s** for `runtime status` and **0.42-0.44 s** for `models list`. At the pacing above that is a
few calls a minute at most, which is why they sit on their own timer and never in the poll. Warm numbers
are misleading, though: the same call a moment after a model was released took seconds, which is how
trap 15 got noticed - so these calls are asynchronous (`Fire-Cli` / `Collect-Cli`) rather than merely
infrequent.

## Git remote and pushing

Push with a **dedicated deploy key** for this repository, not a general account key. A deploy key is
scoped to one repository, so it cannot be reused elsewhere if it leaks - a key that reaches everything
on the account is the wrong thing to hand a single tool.

Generate one (`ssh-keygen -t ed25519`), register the public half on the repo as a deploy key with
**Allow write access** (Settings -> Deploy keys), and point the clone at it per-clone, so no
`~/.ssh/config` entry and no `ssh-agent` juggling is needed:

```
git config core.sshCommand "ssh -i <path-to-your-private-key> -o IdentitiesOnly=yes"
```

Keep the private key out of the repo, and do not paste key filenames, comments or fingerprints into
files that get published - they are not secret material, but they are a map of how the repo is
guarded. No key name, path or fingerprint appears anywhere in this repo, and that is deliberate.

`IdentitiesOnly=yes` is not decoration: if the agent offers a different key first, authentication
succeeds *as that key* for the whole connection, and a deploy key scoped to another repo then fails
on the repo operation - the right key offered second never gets a chance.

**Rotating a key is boring if the order is right:** add the replacement on the repo first (two deploy
keys can be registered at once), point the clone at it with `core.sshCommand`, confirm
`git ls-remote origin` answers, push something, and only then delete the old deploy key and remove the
old private key file locally. Deleting first is what turns a two-minute job into a repo you cannot
write to until you re-provision.

Until the deploy key is registered, `git ls-remote` answers `Permission denied (publickey)`, which is
the expected state rather than a broken remote. After it is registered, the health check is
`git ls-remote origin` (exit 0), **not** `ssh -T git@github.com`: because deploy keys are repo-scoped
that greeting answers `Permission denied` even when pushes work.
