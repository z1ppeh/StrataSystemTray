#Requires -Version 5.1
<#
  strata-tray.ps1 - a live system-tray monitor for a Strata server.

  Hover the tray icon for a card: decode/prefill speed, context fill, VRAM, experts cached,
  system RAM, GPU / CPU / disk load and the last request. The numbers are the
  same ones the web Monitor tab reads: this polls the server's own GET /metrics (plus GET /status),
  nothing else.

    hover the icon      show the card (it fades out when the mouse leaves)
    left click          open the Monitor tab in the browser (<url>/#monitor)
    left double click   pin / unpin the card (keeps it open; when it is pinned the card shows a
                        'pinned' badge and the menu item carries a tick)
    right click         menu: Monitor page, chat page, API, model control, refresh, pin, quit

  Model control: the menu can start and stop the model as well as watch it. That goes through
  Strata's own command line, so it needs `strata` on PATH (see strata-control.ps1 for how the stop is
  made the same graceful stop as Ctrl+C in the server window). -NoControl, or $Control = $false in
  settings.local.ps1, turns it back into a pure viewer.

  Switches:  -Url http://host:port   -Every 1.5   -Page <url to open on click, default <url>/#monitor>
             -NoControl   viewer only: no Start / Stop / Unload in the menu

  Which server to watch, in order: -Url on the command line, then settings.local.ps1 next to
  this script (your machine's port - not in the repo), then Strata's own default port 8080.
             -Preview out.png   draw the card once and save it (no tray, for checking the look)
             -Once              print one text summary and exit
             -CtlSelfTest       print the right-click menu (control rows included) and exit: lets the
                                model-control code be checked without a mouse on a tray icon
             -NoModels          with -CtlSelfTest: pretend nothing is installed, to check that row
             -TraceOn           write hover / click / menu events to strata-tray.trace.log next to this
                                script (or -Trace file.log to put it somewhere else). OFF by default: it
                                is how the menu bugs were found and fixed (docs/DEV-NOTES.md 18-21), so
                                switch it on the next time a menu misbehaves. -NoTrace forces it off.

  No admin rights, no installs: Windows Forms + System.Drawing only.
#>
param(
  [string] $Url     = '',      # empty -> settings.local.ps1, else the default below
  [double] $Every   = 0,       # 0    -> settings.local.ps1, else the default below
  [string] $Page    = '',
  [string] $Preview = '',
  [string] $Trace   = '',
  [switch] $Once,
  [switch] $CtlSelfTest,
  [switch] $NoModels,
  [switch] $NoControl,
  [switch] $TraceOn,
  [switch] $NoTrace
)

$ErrorActionPreference = 'SilentlyContinue'

# Tracing is OFF by default. It was switched on while the right-click menu was being debugged, because
# that bug only shows with a real mouse on a real icon and the daily driver (start-tray.vbs) passes no
# command line at all - the log it produced is what found the cause (docs/DEV-NOTES.md 18-21). The bug is
# closed, so normal running writes nothing. To diagnose again: -TraceOn (default path) or -Trace <file>;
# -NoTrace forces it off either way. When it is on, the file is rotated at start and while running.
$TraceFile = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'strata-tray.trace.log'
if ($NoTrace) { $Trace = '' }
elseif (-not $Trace -and $TraceOn) { $Trace = $TraceFile }
if ($Trace -and (Test-Path -LiteralPath $Trace)) {
  try {
    if ((Get-Item -LiteralPath $Trace -ErrorAction SilentlyContinue).Length -gt 400KB) {
      Remove-Item -LiteralPath $Trace -Force -ErrorAction SilentlyContinue
    }
  } catch {}
}

# Which server to watch. Precedence: -Url, then settings.local.ps1 next to this script, then
# Strata's own default. The default is 8080 because that is what Strata itself uses
# (terminal/strata_cli/launch/settings.py: DEFAULT_PORT = 8080) - a machine-specific port belongs in
# settings.local.ps1, which is gitignored, so the script itself carries no local assumptions.
$DefaultUrl   = 'http://127.0.0.1:8080'
$DefaultEvery = 1.5
# The command line has to win over settings.local.ps1, but dot-sourcing that file writes $Url and
# $Every into THIS scope - it overwrote an explicit -Url, so a `-Url` switch did nothing on a machine
# that has local settings. What -Url / -Every said is kept aside and put back after the dot-source.
$CliUrl   = $Url
$CliEvery = $Every
$localCfg = Join-Path $PSScriptRoot 'settings.local.ps1'
if (Test-Path $localCfg) { . $localCfg }        # may set $Url, $Every, $StrataCmd, $Control, $Wizard
if ($CliUrl)         { $Url = $CliUrl }
if ($CliEvery -gt 0) { $Every = $CliEvery }
if (-not $Url)    { $Url = $DefaultUrl }
if ($Every -le 0) { $Every = $DefaultEvery }

# Model control (start / stop / unload). On unless -NoControl, or $Control = $false in
# settings.local.ps1. It needs the `strata` command on PATH; $StrataCmd in settings.local.ps1 points
# at it somewhere else. Control off = the viewer it was before.
$DefaultStrataCmd = 'strata'
if (-not $StrataCmd) { $StrataCmd = $DefaultStrataCmd }
if ($null -eq $Wizard) { $Wizard = '' }   # START-HERE.bat: empty = Strata-Wizard finds it by itself
# Soft control = the Load / Unload rows (drop the model but keep the server). On by default so the
# menu shows everything the server can do; $SoftControl = $false in settings.local.ps1 hides those two
# rows for a machine where they are never used. Start / Stop are NOT part of this: they are the whole
# point of the menu for most people.
if ($null -eq $SoftControl) { $SoftControl = $true }
if ($null -eq $Control) { $Control = $true }
$Control = ([bool]$Control) -and (-not [bool]$NoControl)

. (Join-Path $PSScriptRoot 'strata-control.ps1')   # no param block in it, so this cannot steal our args
# What a left click opens. Strata's web app is a single-page app: the tabs are picked by the URL
# fragment, not by a path. So the Monitor tab is "<url>/#monitor", and "/monitor" is NOT a route - a
# GET of it answers 404 (checked against a running server). "/api-monitor" does exist but it is a
# different page (the API request monitor) and it is off unless the server was started with
# --api-monitor, so it 404s on a normal run too.
# The fragment is inside a string on purpose: a bare "/#monitor" written straight into PowerShell
# source is a comment from the "#" onwards and silently truncates the line.
if (-not $Page)   { $Page = $Url.TrimEnd('/') + '/#monitor' }

foreach ($a in 'System.Windows.Forms', 'System.Drawing') { try { Add-Type -AssemblyName $a } catch {} }

# The card is a real borderless window that repaints end to end, so it must be double buffered:
# without it Windows shows the underlying desktop between erase and redraw, which looks like a
# violent flicker while the pointer sits on the tray icon.
#
# IMPORTANT: -ReferencedAssemblies is NOT optional here. The C# compiler Add-Type drives does not
# inherit the assemblies PowerShell has already loaded, so "using System.Windows.Forms;" fails to
# compile - and with $ErrorActionPreference=SilentlyContinue that failure is invisible: the type does
# not exist, New-Object returns $null, and the card window never appears while everything else keeps
# running happily. Verified on this PC: no refs -> compile error, refs -> compiles and shows.
$cardSrc = @'
using System.Windows.Forms;
public class StrataCardForm : Form {
  public StrataCardForm() {
    this.DoubleBuffered = true;
    this.SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
  }
  // shown without stealing focus from whatever the user is doing (overridden, not set from
  // PowerShell: ShowWithoutActivation is protected, and a protected setter silently does nothing)
  protected override bool ShowWithoutActivation { get { return true; } }
  protected override CreateParams CreateParams {
    get {
      CreateParams cp = base.CreateParams;
      cp.ExStyle |= 0x00000080;   // WS_EX_TOOLWINDOW: keep the card out of Alt+Tab
      return cp;
    }
  }
}
'@
$cardFormOk = [bool]('StrataCardForm' -as [type])
if (-not $cardFormOk) {
  $refs = @()
  foreach ($asm in [AppDomain]::CurrentDomain.GetAssemblies()) {
    try {
      if ($asm.Location -and (Split-Path -Leaf $asm.Location) -match '^(System|System\.Core|System\.Drawing|System\.Windows\.Forms)\.dll$') {
        $refs += $asm.Location
      }
    } catch {}
  }
  try {
    Add-Type -TypeDefinition $cardSrc -ReferencedAssemblies $refs -ErrorAction Stop
    $cardFormOk = $true
  } catch {
    try {
      Add-Type -TypeDefinition $cardSrc -ReferencedAssemblies 'System.Windows.Forms.dll', 'System.Drawing.dll' -ErrorAction Stop
      $cardFormOk = $true
    } catch {
      $cardFormOk = $false        # fall back to a plain Form (handled where the form is built)
    }
  }
}

# --------------------------------------------------------------- win32 ----- 
# The menu problem has two questions the trace could not answer: when a menu ends with CloseReason
# AppFocusChange, WHO took the focus, and when a row cannot be clicked, whether the menu window is
# really the window under the pointer. These calls answer both, and Describe-Win is the only place
# they get combined into one line of log. Compiled always (not only in the plain-form fallback, which
# has its own Win32Card type): the diagnostics must exist even when the card class compiles fine.
$focusApiOk = $false
try {
  Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class Win32Tray {
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int x; public int y;
    public POINT(int a, int b) { x = a; y = b; } }
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int left, top, right, bottom; }
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="GetWindowTextW")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
}
'@ -ErrorAction Stop
  $focusApiOk = $true
} catch { $focusApiOk = $false }

function Win-Title([IntPtr]$h) {
  if (-not $focusApiOk -or $h -eq [IntPtr]::Zero) { return '' }
  $sb = New-Object System.Text.StringBuilder 160
  try { [void][Win32Tray]::GetWindowText($h, $sb, 160) } catch { return '' }
  $t = (([string]$sb.ToString()) -replace '\s+', ' ')
  if ($t.Length -gt 60) { $t = $t.Substring(0, 57) + '...' }
  return $t
}

# One line that names a window: handle, owning process, and title. Cross-process GetWindowText is
# allowed for most windows, so this usually says something useful about a window we do not own.
function Describe-Win([IntPtr]$h) {
  if (-not $focusApiOk) { return 'win32 not available' }
  if ($h -eq [IntPtr]::Zero) { return 'no window' }
  $pid2 = [uint32]0
  try { [void][Win32Tray]::GetWindowThreadProcessId($h, [ref]$pid2) } catch {}
  $nm = ''
  try { $nm = (Get-Process -Id ([int]$pid2) -ErrorAction SilentlyContinue).ProcessName } catch {}
  $t = Win-Title $h
  return ('hwnd ' + [string]$h + ' pid ' + [int]$pid2 + ' ' + $(if ($nm) { $nm } else { '?' }) +
         $(if ($t) { ' "' + $t + '"' } else { '' }))
}
function Describe-Foreground() {
  if (-not $focusApiOk) { return 'win32 not available' }
  return Describe-Win ([Win32Tray]::GetForegroundWindow())
}

# ---------------------------------------------------------------- palette ----
$C = [ordered]@{
  bg       = [System.Drawing.Color]::FromArgb(255, 16, 20, 26)
  card     = [System.Drawing.Color]::FromArgb(255, 26, 32, 40)
  line     = [System.Drawing.Color]::FromArgb(255, 42, 50, 60)
  text     = [System.Drawing.Color]::FromArgb(255, 230, 237, 243)
  muted    = [System.Drawing.Color]::FromArgb(255, 139, 152, 165)
  green    = [System.Drawing.Color]::FromArgb(255, 63, 185, 80)
  blue     = [System.Drawing.Color]::FromArgb(255, 88, 166, 255)
  teal     = [System.Drawing.Color]::FromArgb(255, 45, 212, 191)
  amber    = [System.Drawing.Color]::FromArgb(255, 210, 153, 34)
  red      = [System.Drawing.Color]::FromArgb(255, 248, 81, 73)
  grey     = [System.Drawing.Color]::FromArgb(255, 110, 123, 138)
  barbg    = [System.Drawing.Color]::FromArgb(255, 30, 36, 45)
}
function Cof([string]$k) { $C[$k] }

# Brushes, pens and tray icons are made once per colour and reused. The card repaints on every
# poll and the tray icon changes on every poll, so anything allocated inline is a slow leak of
# GDI handles in a process that is meant to run for days.
$BR  = @{}
function BrushOf([string]$k) {
  if (-not $BR.ContainsKey($k)) { $BR[$k] = New-Object System.Drawing.SolidBrush((Cof $k)) }
  return $BR[$k]
}
function TintOf([string]$k) {
  $key = 'tint-' + $k
  if (-not $BR.ContainsKey($key)) {
    $c = Cof $k
    $BR[$key] = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(38, $c.R, $c.G, $c.B))
  }
  return $BR[$key]
}
$ICONS = @{}
function Get-TrayIcon([string]$k) {
  if (-not $ICONS.ContainsKey($k)) { $ICONS[$k] = New-Icon (Cof $k) }   # New-Icon is defined below
  return $ICONS[$k].icon
}
$bT  = BrushOf 'text'
$bM  = BrushOf 'muted'
$bL  = BrushOf 'line'
$bBg = BrushOf 'barbg'
# one right-aligned StringFormat for the whole life of the tray: a StringFormat per paint is another
# unmanaged object, and the card repaints on every poll while it is open
$sfr = New-Object System.Drawing.StringFormat
$sfr.Alignment = [System.Drawing.StringAlignment]::Far

# ----------------------------------------------------------------- fonts ----
# Sizes were stepped up by about half a point each when the decode sparkline was dropped: that graph
# was inconsistent (it only moves while a run is in flight) and the space it took went into legibility.
$FTitle  = New-Object System.Drawing.Font('Segoe UI', 12.0, [System.Drawing.FontStyle]::Bold)
$FBig    = New-Object System.Drawing.Font('Segoe UI', 16.0, [System.Drawing.FontStyle]::Bold)
$FUnit   = New-Object System.Drawing.Font('Segoe UI', 9.0)
$FLabel  = New-Object System.Drawing.Font('Segoe UI', 9.0)
$FBody   = New-Object System.Drawing.Font('Segoe UI', 9.75)
$FNum    = New-Object System.Drawing.Font('Consolas', 9.75)
$FSmall  = New-Object System.Drawing.Font('Segoe UI', 8.5)

# --------------------------------------------------------------- helpers ----
function N0($v) { if ($null -eq $v) { '-' } else { ('{0:N0}' -f [double]$v) } }
function N1($v) { if ($null -eq $v) { '-' } else { ('{0:N1}' -f [double]$v) } }
function N0orDash([double[]]$a) { if (-not $a) { '-' } else { N0 $a[-1] } }
function LastNonZero([array]$a) {
  if (-not $a) { return $null }
  for ($i = $a.Count - 1; $i -ge 0; $i--) { if ($null -ne $a[$i] -and [double]$a[$i] -gt 0) { return [double]$a[$i] } }
  return $null
}

function New-Icon([System.Drawing.Color]$color) {
  $size = 32
  $bmp  = New-Object System.Drawing.Bitmap($size, $size)
  $g    = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.Clear([System.Drawing.Color]::Transparent)
  $bOuter = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 22, 27, 34))
  $g.FillEllipse($bOuter, 1, 1, 30, 30); $bOuter.Dispose()
  $bInner = New-Object System.Drawing.SolidBrush($color)
  $g.FillEllipse($bInner, 6, 6, 20, 20); $bInner.Dispose()
  $p = New-Object System.Drawing.Drawing2D.GraphicsPath
  $p.AddArc(9, 9, 14, 14, 200, 120)
  $bHi = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(120, 255, 255, 255))
  $g.FillPath($bHi, $p); $bHi.Dispose(); $p.Dispose()
  $h = $bmp.GetHicon()
  $icon = [System.Drawing.Icon]::FromHandle($h)
  $g.Dispose()
  # GetHicon handles are not freed by Dispose(); keep the icon alive for the life of the tray.
  return @{ icon = $icon; handle = $h }
}

function Round-Path([int]$x, [int]$y, [int]$w, [int]$h, [int]$r) {
  $p = New-Object System.Drawing.Drawing2D.GraphicsPath
  $p.AddArc($x, $y, $r, $r, 180, 90)
  $p.AddArc($x + $w - $r, $y, $r, $r, 270, 90)
  $p.AddArc($x + $w - $r, $y + $h - $r, $r, $r, 0, 90)
  $p.AddArc($x, $y + $h - $r, $r, $r, 90, 90)
  $p.CloseFigure()
  return $p
}

function Trace([string]$m) {
  if (-not $Trace) { return }
  if ($null -eq $st) { return }
  if ($st.traceDead) { return }
  $st.traceN = $st.traceN + 1
  if ($st.traceN -gt 100000) { return }        # a hard cap: mousemove can fire hundreds of times a second
  # One open handle + AutoFlush instead of Add-Content per line. Add-Content opens and closes the file on
  # every call, and the menu diagnostics now log on every row hover: file I/O inside a menu's modal mouse
  # tracking loop is itself one of the things that can make a menu stick, so the tracer must not add the
  # very delay it is here to find. AutoFlush keeps the lines even when the tray is killed mid-run.
  if ($null -eq $st.traceWriter) {
    try {
      # UTF8 without a BOM: the file is appended to across restarts, and a BOM mid-file shows as junk.
      $st.traceWriter = New-Object System.IO.StreamWriter($Trace, $true,
                            (New-Object System.Text.UTF8Encoding($false)))
      $st.traceWriter.AutoFlush = $true
    } catch { $st.traceDead = $true; return }   # no writable log: stop trying, never throw into a handler
  }
  # Rotating while running is what lets the trace stay on all day: the file is capped, not the log.
  if (($st.traceN % 200) -eq 0) {
    try {
      if ($st.traceWriter.BaseStream.Length -gt 400KB) {
        $st.traceWriter.Close()
        # $false = start the file over (the append=$true above is what keeps earlier runs' lines).
        $st.traceWriter = New-Object System.IO.StreamWriter($Trace, $false,
                              (New-Object System.Text.UTF8Encoding($false)))
        $st.traceWriter.AutoFlush = $true
        $st.traceWriter.WriteLine((Get-Date -Format 'HH:mm:ss.fff') + '  (trace rotated)')
      }
    } catch { $st.traceDead = $true; return }
  }
  try { $st.traceWriter.WriteLine((Get-Date -Format 'HH:mm:ss.fff') + '  ' + $m) } catch { $st.traceDead = $true }
}

# The state words the server uses (live.state): idle / reading / generating / queued / error.
function StateColor([string]$s) {
  switch ($s) {
    'generating' { 'green' }
    'reading'    { 'blue' }
    'queued'     { 'amber' }
    'error'      { 'red' }
    'unloaded'   { 'grey' }
    default      { 'grey' }
  }
}

# ------------------------------------------------------------ data fetch ----
function Get-Snapshot([string]$base) {
  $s = [ordered]@{ ok = $false; at = (Get-Date) }
  try {
    $m = Invoke-RestMethod -Uri ($base.TrimEnd('/') + '/metrics') -TimeoutSec 3
    $s.ok      = $true
    $s.engine  = $m.engine
    $s.live    = $m.live
    $s.hard    = $m.hardware
    $s.hstatic = $m.hardware_static
    $s.hist    = $m.history
    $s.totals  = $m.totals
    $s.req     = @($m.requests)
    $s.last    = if ($s.req.Count) { $s.req[-1] } else { $null }
    $state = if ($m.live) { [string]$m.live.state } else { 'idle' }
    if (-not $state) { $state = 'idle' }
    $s.state = $state
  } catch { $s.state = 'offline'; return $s }
  # /status adds the live phase line ("answering", "writing a tool call: ...") that the card shows.
  try {
    $st = Invoke-RestMethod -Uri ($base.TrimEnd('/') + '/status') -TimeoutSec 3
    # /status keeps the last phase string after the run ends, so only show it while work is in flight.
    if ($st.busy) {
      $s.phase = $st.phase
      if ($s.state -eq 'idle') { $s.state = if ($st.queued) { 'queued' } else { 'generating' } }
    } else { $s.phase = $null }
  } catch {}
  # Context fill: prefer the in-flight numbers, else the last finished request.
  $max = if ($s.engine) { [double]$s.engine.max_context } else { 0 }
  $prompt = $gen = $cached = 0.0
  if ($s.live -and $null -ne $s.live.prompt_tokens) {
    $prompt = [double]$s.live.prompt_tokens
    $gen    = [double]($s.live.generated)
    $cached = [double]($s.live.reused)
  } elseif ($s.last) {
    $prompt = [double]$s.last.prompt_tokens
    $gen    = [double]$s.last.output_tokens
    $cached = [double]$s.last.reused
  }
  $s.ctxMax = $max; $s.ctxPrompt = $prompt; $s.ctxGen = $gen
  if ($cached -lt 0) { $cached = 0 }
  if ($cached -gt $prompt) { $cached = $prompt }
  $s.ctxCached = $cached
  $s.ctxUsed = $prompt + $gen
  # Speeds: idle samples read 0, so fall back to the last non-zero value the server kept in its
  # history. Prefill is per token actually READ (a 90%-cached prompt is not 90% of the work), so
  # prompt_read / prompt_ms is the honest derivation when the engine has no mean to offer.
  if ($s.live -and $null -ne $s.live.tok_s -and [double]$s.live.tok_s -gt 0) {
    $s.decode = [double]$s.live.tok_s; $s.decodeHow = 'answer speed'
  } elseif ($s.hard -and [double]$s.hard.tok_s -gt 0) {
    $s.decode = [double]$s.hard.tok_s; $s.decodeHow = 'answer speed'
  } else {
    $s.decode = LastNonZero $s.hist.tok_s; $s.decodeHow = 'last run'
  }
  if ($s.live -and $null -ne $s.live.prefill_tok_s_mean -and [double]$s.live.prefill_tok_s_mean -gt 0) {
    $s.prefill = [double]$s.live.prefill_tok_s_mean; $s.prefillHow = 'prompt reading'
  } else {
    $s.prefill = LastNonZero $s.hist.prefill_tok_s_mean; $s.prefillHow = 'last run'
  }
  # No engine mean (this engine keeps prefill_tok_s_mean at 0), so weight the server's own per-request
  # prompt_read / prompt_ms over the requests it still remembers. A single request is noise: a 95%
  # cached prompt reads few tokens but the cache lookup still costs its milliseconds. And
  # prompt_tokens / prompt_ms is simply wrong while caching is active (it implies 100k+ t/s).
  if ($null -eq $s.prefill) {
    $read = 0.0; $ms = 0.0
    foreach ($r in $s.req) {
      if ($null -ne $r.prompt_read) { $read += [double]$r.prompt_read }
      if ($null -ne $r.prompt_ms)   { $ms   += [double]$r.prompt_ms }
    }
    if ($read -ge 512 -and $ms -gt 0) {
      $s.prefill    = 1000 * $read / $ms
      $s.prefillHow = ('last {0} requests' -f $s.req.Count)
    }
  }
  if ($null -eq $s.prefill) { $s.prefillHow = 'no prompt data yet' }
  $s
}

# ------------------------------------------------------------- the drawing --
# NOTE: keep this file ASCII-only. Windows PowerShell 5.1 reads a .ps1 as ANSI unless it
# has a BOM, so a literal U+00B7 middle dot arrives as mojibake in the drawn text.
$W = 566; $H = 376

function Draw-Card($g, $s) {
  $g.SmoothingMode  = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
  $g.Clear($C.bg)

  $pad = 14
  # The control state matters for the card: while a start is loading, the port does not answer yet, so
  # a plain "no server" would be wrong (and alarming) for the minute or two the experts take to arrive.
  $ctlState = ''
  if ($st -and $st.control -and $st.ctl -in @('starting', 'draining', 'failed', 'stale')) { $ctlState = [string]$st.ctl }
  $stateCol = if ($ctlState -eq 'starting' -or $ctlState -eq 'draining') { 'amber' }
              elseif ($ctlState -eq 'failed' -or $ctlState -eq 'stale') { 'red' }
              elseif (-not $s.ok) { 'red' }
              else { StateColor $s.state }
  $stateTxt = if ($ctlState -and -not $s.ok) { if ($ctlState -eq 'starting') { 'loading' } else { $ctlState } }
              elseif (-not $s.ok) { 'no server' }
              else { $s.state }

  # --- title row
  $model = if ($s.engine) { [string]$s.engine.model } elseif ($s.ok) { 'Strata' } else { 'Strata' }
  $g.DrawString($model, $FTitle, $bT, $pad, 12)
  $chipW = 88; $chipX = $W - $pad - $chipW
  $cp = Round-Path $chipX 13 $chipW 22 11
  $g.FillPath((TintOf $stateCol), $cp); $cp.Dispose()
  $g.DrawString($stateTxt, $FLabel, (BrushOf $stateCol), ($chipX + 7), 17)

  # Pin badge: a pinned card looks exactly like a card that is stuck open, and the tooltip cannot say
  # so either (it is blanked while the card is up). So the card itself says it. $st is read, never
  # written, here - and on -Preview $st does not exist yet, hence the -not $null test.
  if ($st -and $st.pinned) {
    $pinW = 62; $pinX = $chipX - 8 - $pinW
    $pp = Round-Path $pinX 13 $pinW 22 11
    $g.FillPath((TintOf 'amber'), $pp); $pp.Dispose()
    $g.DrawString('pinned', $FLabel, (BrushOf 'amber'), ($pinX + 9), 17)
  }

  # --- subtitle
  $sub = @(
    ('engine {0}' -f $(if ($s.engine) { $s.engine.version } else { '?' })),
    ('kv {0}' -f $(if ($s.engine) { $s.engine.kv } else { '?' })),
    ('spec {0}' -f $(if ($s.engine) { $s.engine.spec } else { '?' })),
    ('ctx {0:N0}' -f $(if ($s.engine) { $s.engine.max_context } else { 0 }))
  ) -join '  |  '
  $g.DrawString($sub, $FSmall, $bM, $pad, 35)
  if ($s.phase) {
    $ph = [string]$s.phase; if ($ph.Length -gt 46) { $ph = $ph.Substring(0, 43) + '...' }
    $g.DrawString($ph, $FSmall, (BrushOf $stateCol), $pad, 51)
  } elseif ($ctlState) {
    $ph = $ctlState + $(if ($st.ctlPhase -and $st.ctlPhase -ne $ctlState) { ': ' + $st.ctlPhase } else { '' })
    if ($ph.Length -gt 46) { $ph = $ph.Substring(0, 43) + '...' }
    $g.DrawString($ph, $FSmall, (BrushOf $stateCol), $pad, 51)
  }

  # --- four headline stats
  $decode = $s.decode; $decodeHow = $s.decodeHow; $prefill = $s.prefill
  $ctxPct = if ($s.ctxMax -gt 0) { 100 * $s.ctxUsed / $s.ctxMax } else { $null }
  $vramGB = if ($s.hard) { $s.hard.gpu_mem_used / 1GB } else { $null }
  $vramTot = if ($s.hard) { $s.hard.gpu_mem_total / 1GB } else { $null }

  $stats = @(
    @{ l = 'Decode t/s';    v = (N1 $decode);  u = $decodeHow;      c = 'green' },
    @{ l = 'Prefill t/s';   v = (N0 $prefill); u = $s.prefillHow;    c = 'blue' },
    @{ l = 'Context';       v = (N1 $ctxPct);  u = ('{0:N0} / {1:N0}' -f $s.ctxUsed, $s.ctxMax); c = 'teal' },
    @{ l = 'VRAM';          v = (N1 $vramGB);  u = ('of {0:N0} GB' -f $vramTot); c = 'amber' }
  )
  $bw = [int](($W - 2 * $pad - 3 * 8) / 4); $y0 = 72
  for ($i = 0; $i -lt $stats.Count; $i++) {
    $x = $pad + $i * ($bw + 8)
    $p = Round-Path $x $y0 $bw 68 7
    $g.FillPath((BrushOf 'card'), $p); $p.Dispose()
    $g.DrawString($stats[$i].l, $FSmall, $bM, ($x + 9), ($y0 + 8))
    $g.DrawString($stats[$i].v, $FBig, (BrushOf $stats[$i].c), ($x + 8), ($y0 + 22))
    $g.DrawString($stats[$i].u, $FSmall, $bM, ($x + 9), ($y0 + 49))
  }

  # --- context fill bar (cached / reading / answer / free, like the page)
  $y = 152
  $g.DrawString('Context fill', $FLabel, $bT, $pad, $y)
  $g.DrawString(('{0:N0} / {1:N0}' -f $s.ctxUsed, $s.ctxMax), $FNum, $bM, ($W - $pad - 170), $y)
  $y += 19
  $barW = $W - 2 * $pad
  $gp = Round-Path $pad $y $barW 11 5; $g.FillPath($bBg, $gp); $gp.Dispose()
  $done = 0
  if ($s.ctxMax -gt 0) {
    $wCache = [int]($barW * $s.ctxCached / $s.ctxMax)
    $wRead  = [int]($barW * ($s.ctxPrompt - $s.ctxCached) / $s.ctxMax)
    $wAns   = [int]($barW * $s.ctxGen / $s.ctxMax)
    foreach ($seg in @(@($wCache, 'green'), @($wRead, 'blue'), @($wAns, 'teal'))) {
      if ($seg[0] -gt 0) {
        $sp = Round-Path ($pad + $done) $y ([Math]::Max(2, $seg[0])) 11 5
        $g.FillPath((BrushOf $seg[1]), $sp); $sp.Dispose()
      }
      $done += $seg[0]
    }
  }
  $y += 14
  $leg = @(
    ('cached  ' + (N0 $s.ctxCached)),
    ('reading ' + (N0 ($s.ctxPrompt - $s.ctxCached))),
    ('answer  ' + (N0 $s.ctxGen)),
    ('free    ' + (N0 ($s.ctxMax - $s.ctxUsed)))
  ) -join '   |   '
  $g.DrawString($leg, $FSmall, $bM, $pad, $y)

  # --- bars: experts in VRAM, system RAM
  # (GPU temp / power / PCIe gen are left out on purpose: they never move on this box and the full
  #  Monitor page has them if they ever do.)
  function Bar($g, $label, $valTxt, $frac, $color, $y, $x, $w) {
    $g.DrawString($label, $FLabel, $bT, $x, $y)
    # right-aligned in a rect that ends at the bar's right edge, so a long value cannot run off the card
    $rect = New-Object System.Drawing.RectangleF([single]$x, [single]$y, [single]$w, [single]15)
    $g.DrawString($valTxt, $FNum, $bM, $rect, $sfr)
    $yy = $y + 17
    $p = Round-Path $x $yy $w 7 3; $g.FillPath($bBg, $p); $p.Dispose()
    # Clamp in PowerShell, not with [Math]::Min(1, $frac): given an int literal and a double, the binder
    # picks Min(Int32,Int32) and rounds the fraction to 0 or 1 first, so every bar came out empty or full.
    $f = [double]$frac
    if ($f -lt 0) { $f = 0 } elseif ($f -gt 1) { $f = 1 }
    $fw = [int]($f * $w)
    if ($fw -gt 2) {
      $q = Round-Path $x $yy $fw 7 3
      $g.FillPath((BrushOf $color), $q); $q.Dispose()
    }
  }
  $y += 25
  $eSlots = $null; $eTotal = $null; $eMib = $null
  if ($s.engine) {
    $eSlots = if ($null -ne $s.engine.expert_slots_primary) { $s.engine.expert_slots_primary } else { $s.engine.expert_slots }
    $eTotal = $s.engine.experts
    $eMib   = if ($null -ne $s.engine.expert_cache_primary_mib) { $s.engine.expert_cache_primary_mib } else { $s.engine.expert_cache_mib }
  }
  $eTxt = if ($null -ne $eSlots) { ('{0:N0} / {1:N0} slots  |  {2:N1} GB' -f $eSlots, $eTotal, ($eMib / 1024)) } else { '-' }
  Bar $g 'Experts in VRAM' $eTxt $(if ($eTotal) { $eSlots / $eTotal } else { 0 }) 'green' $y $pad ($W - 2 * $pad); $y += 36

  $ramTxt = if ($s.hard) { ('{0:N1} / {1:N0} GB' -f ($s.hard.ram_used / 1GB), ($s.hard.ram_total / 1GB)) } else { '-' }
  Bar $g 'System RAM' $ramTxt $(if ($s.hard) { $s.hard.ram_used / $s.hard.ram_total } else { 0 }) $(if ($s.hard -and ($s.hard.ram_used / $s.hard.ram_total) -gt 0.93) { 'red' } else { 'teal' }) $y $pad ($W - 2 * $pad); $y += 34

  # --- one-line strip
  $strip = @()
  if ($s.hard) {
    $strip += ('GPU {0:N0}%' -f $s.hard.gpu_util)
    $strip += ('to GPU {0:N1} MB/s' -f $s.hard.gpu_pcie_rx_mb)   # expert streaming over PCIe, this does move
    $strip += ('CPU {0:N0}%' -f $s.hard.cpu)
    $strip += ('Disk {0:N1} MB/s' -f $s.hard.disk_read_mb)
  }
  if ($s.hstatic) { $strip += $s.hstatic.gpu_name }
  $g.DrawString(($strip -join '  |  '), $FSmall, $bM, $pad, $y); $y += 28

  # --- last request + footer
  # (the decode sparkline that used to sit here is gone: the history buffer only fills while a run is
  #  in flight, so on a hover it was mostly a flat or half-empty line - the Monitor page has it.)
  if ($s.last) {
    # wall time of the last request, not a per-request prefill rate: that rate is meaningless when the
    # prompt was 90%+ cached (almost no tokens were actually read, but the cache lookup still cost ms)
    $l = ('last: {0:N0} in ({1:N0}% cached) | {2:N0} out | {3:N1} t/s | {4:N1}s total' -f
      $s.last.prompt_tokens, (100 * $s.last.hit_rate), $s.last.output_tokens, $s.last.decode_tok_s, $s.last.duration_s)
    $g.DrawString($l, $FNum, $bT, $pad, $y)
  } elseif ($s.ok) { $g.DrawString('no requests yet', $FBody, $bM, $pad, $y) }
  else {
    # Why it is not answering, in one short line. The widths here nearly fill the card, so keep every
    # variant under ~90 characters. Nothing here may name a shortcut or a model of one person's PC.
    $why = if ($st -and $st.ctlMsg) { $st.ctlMsg }
           elseif ($ctlState -eq 'starting') {
             'loading ' + $(if ($st.ctlPhase) { $st.ctlPhase } else { '...' }) + ' - it answers once the experts are in RAM'
           }
           elseif ($ctlState -eq 'draining') { 'stopping: draining in-flight requests, then it releases the memory' }
           elseif ($st -and -not $st.control) { "$Url is not answering" }
           else { "$Url is not answering - Start it from this menu" }
    if ($why.Length -gt 92) { $why = $why.Substring(0, 89) + '...' }
    $g.DrawString($why, $FBody, (BrushOf $(if ($ctlState -eq 'starting' -or $ctlState -eq 'draining') { 'amber' } else { 'red' })), $pad, $y)
  }
  $y += 26
  $foot = @(
    ('requests {0:N0}' -f $(if ($s.totals) { $s.totals.requests } else { 0 })),
    ('reused {0:N0}%' -f $(if ($s.totals -and $s.totals.prompt_tokens) { 100 * $s.totals.reused / $s.totals.prompt_tokens } else { 0 })),
    ('uptime {0}' -f $(if ($s.totals -and $s.totals.since) { $up = (Get-Date) - [DateTimeOffset]::FromUnixTimeSeconds([double]$s.totals.since).LocalDateTime; '{0}h{1:D2}m' -f [int]$up.TotalHours, $up.Minutes } else { '-' })),
    # 'Monitor' not 'full Monitor': the widths below nearly fill the card (measured, Segoe UI 8.5:
    # the longest footer line below is 515 px against 538 px of usable width)
    'click = Monitor',
    $(if ($st -and $st.pinned) { 'pinned: dbl-click = unpin' } else { 'double-click = pin' })
  ) -join '   |   '
  $g.DrawString($foot, $FSmall, $bM, $pad, $y)

  # brushes / pen / icons live in the script-scope caches and are released at exit
}

# ---------------------------------------------------------------- preview ---
if ($Preview) {
  $s = Get-Snapshot $Url
  $bmp = New-Object System.Drawing.Bitmap($W, $H)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  Draw-Card $g $s
  $g.Dispose()
  $bmp.Save($Preview, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
  Write-Output "wrote $Preview (ok=$($s.ok) state=$($s.state))"
  return
}
if ($Once) {
  $s = Get-Snapshot $Url
  if (-not $s.ok) { Write-Output "no Strata at $Url"; exit 1 }
  Write-Output ("state {0} | decode {1} t/s | prefill {2} t/s | ctx {3:N0}/{4:N0} | VRAM {5:N1} GB | RAM {6:N1} GB | GPU {7:N0}%" -f
    $s.state, (N1 $s.decode), (N0 $s.prefill), $s.ctxUsed, $s.ctxMax, ($s.hard.gpu_mem_used / 1GB), ($s.hard.ram_used / 1GB), $s.hard.gpu_util)
  exit 0
}

# -------------------------------------------------------------- the tray ----
$ctxLoop  = New-Object System.Windows.Forms.ApplicationContext
$GraceMs  = 700      # keep the card through short absences (a stray repaint, a fast mouse twitch)
$TipGap   = 56       # the card floats this far above the taskbar: the native tooltip lands there

# Every piece of mutable state lives in ONE hashtable.
# Why: an event handler can READ a script-scope variable, but on this PC a WRITE to a $script:
# variable made inside a handler does not survive to the next handler call (proved by
# tray-probe/scope-probe.ps1: "$n = $n + 1" in a handler counted 1 forever). So the "already open"
# latch never held: every mousemove re-positioned and re-Show()ed a borderless topmost window, and
# moving such a window repaints the desktop behind it - that was the flicker, and the card then
# closed. Mutating a KEY of an existing object is not a variable write, so it always works.
$st = [ordered]@{
  open      = $false   # the card window is up
  openAt    = $null    # when it was opened (the latch is only re-synced a second later)
  pinned    = $false   # keep the card up until it is unpinned
  outside   = $null    # when the pointer first left the card + taskbar strip (grace period)
  snap      = $null    # last /metrics + /status snapshot the card draws
  wantClick = $false   # a left click is waiting to see whether a second one follows
  lastClick = $null
  fg        = [IntPtr]::Zero   # (fallback window only) the window that had focus before we showed
  tweaks    = $false           # (fallback window only) exstyle applied once
  moves     = 0        # mousemove events seen (diagnostics, -Trace only)
  traceN    = 0        # lines written to -Trace (capped)
  traceWriter = $null  # the open -Trace file (StreamWriter, AutoFlush); see Trace()
  traceDead   = $false # writing it failed once: stop trying
  col       = 'grey'   # current tray icon colour (kept so hide can restore the tooltip)
  tip       = 'Strata' # current tray tooltip text

  # ---- model control (all of it read by Build-CtlMenu on right click, none of it a variable write:
  # see the note above about why every mutable thing is a key of this hashtable)
  control   = $Control
  url       = $Url           # the module needs it too, and a handler cannot write script variables
  strataCmd = $StrataCmd
  strataExe = $null          # resolved once by Strata-Exe
  wizard    = $Wizard        # START-HERE.bat from settings.local.ps1; empty = find it near strata
  wizardPath = $null         # resolved once by Strata-Wizard
  models    = @()            # what `strata models list` says is installed
  modelsAt  = $null
  modelSrc  = @{}            # id -> run config path, for the one-time profile create
  ctl       = ''             # runtime state of $ownedId: '' | stopped | starting | ready | draining | failed | stale
  ctlPhase  = ''             # what a start is doing right now (checking_engine / loading / ...)
  ctlMsg    = ''             # last refusal or reason, shown on the card and in the menu
  ctlAt     = $null
  ctlId     = ''             # which profile $ctl / $ctlPhase describes (set by either status path)
  cli       = $null          # the read-only CLI call in flight: @{kind;seq;pid;out;err;forId;at}
  cliSeq    = 0              # temp file names, so two calls never share one
  ownedId   = ''             # the profile a runtime owns (empty = the tray did not start this server)
  action    = ''             # 'start' | 'stop' | '' while one of those is in flight
  actionId  = ''
  actionOut = ''
  actionErr = ''
  actionAt  = $null
  menuOpen  = $false         # the right-click menu is up (the card must stay down while it is)
  menuAt    = $null          # when menuOpen was set: bounds how long that latch may be trusted
  cardWasOpen = $false       # the card was up when the menu opened: a pinned card comes back after
  softControl = [bool]$SoftControl   # false = no Load / Unload rows (see settings.local.example.ps1)
}

$ni = New-Object System.Windows.Forms.NotifyIcon
$ni.Icon = Get-TrayIcon 'grey'
$ni.Visible = $true
$ni.Text = 'Strata'

if ($cardFormOk) {
  $form = New-Object StrataCardForm
} else {
  # Fallback: a plain Form. The three things the subclass gave us (double buffering, showing without
  # activation, WS_EX_TOOLWINDOW) are protected or need CreateParams, so they are applied by
  # reflection and by Win32 instead. Functional, just slightly less tidy.
  Write-Output 'note: the card window class did not compile; using a plain window (it may take focus briefly)'
  try {
    Add-Type -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern int  GetWindowLong(IntPtr h, int i);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern int  SetWindowLong(IntPtr h, int i, int v);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool  SetForegroundWindow(IntPtr h);
'@ -Name Win32Card -Namespace Win
  } catch {}
  $form = New-Object System.Windows.Forms.Form
  $bf  = [System.Reflection.BindingFlags]::Instance -bor [System.Reflection.BindingFlags]::NonPublic
  $bdp = [System.Windows.Forms.Control].GetProperty('DoubleBuffered', $bf)
  if ($null -ne $bdp) { $bdp.SetValue($form, $true, $null) }
}
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$form.ShowInTaskbar = $false
$form.TopMost = $true
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$form.Size = New-Object System.Drawing.Size($W, $H)
$form.BackColor = $C.bg

$st.snap = Get-Snapshot $Url
$form.Add_Paint({ param($sender, $e) Draw-Card $e.Graphics $st.snap })

function Set-TrayIcon([string]$key, [string]$tip) {
  # While the right-click menu is being tracked, do not touch the icon at all: a Shell_NotifyIcon update
  # (NIF_ICON / NIF_TIP) is a message to the shell, and the shell answering it can end the menu the
  # person is reaching into. The next poll (<= 1.5 s later) or the menu's Closed handler puts it right.
  if ($st.menuOpen) { return }
  $ni.Icon = Get-TrayIcon $key   # cached per state colour: no new icon per poll
  # The card replaces the native tooltip: while it is open the tip must stay blank, otherwise a
  # stray empty tooltip sits on the taskbar under the card. The guard lives HERE, not only in
  # Show-Card, because the poll timer re-writes the tip every 1.5 s and was silently undoing the
  # blank a moment after the card opened (the tooltip re-appeared on screen). $st.open is set before
  # Show-Card blanks and cleared before Hide-Card restores, so this cannot lock the tip off forever.
  if ($st.open) { $tip = '' }
  if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 60) + '...' }   # Windows caps tray tips at 63
  $ni.Text = $tip
}

# The card does NOT follow the pointer: it is anchored to the taskbar edge once per hover, so a
# few pixels of pointer jitter inside the icon cannot drag the window (that was the flicker).
function Card-Anchor() {
  # anchored on whichever screen the pointer is on when the hover starts (that is the screen the
  # tray icon belongs to), snapped to the bottom-right of its working area
  $p  = [System.Windows.Forms.Cursor]::Position
  $sc = [System.Windows.Forms.Screen]::FromPoint($p)
  $wa = $sc.WorkingArea
  $x  = $wa.Right - $W - 8
  $y  = $wa.Bottom - $H - $TipGap
  if ($wa.Top -gt $sc.Bounds.Top) { $y = $wa.Top + $TipGap }  # taskbar along the top of that screen
  return New-Object System.Drawing.Point($x, $y)
}

# Anywhere on the taskbar strip counts as "still hovering": the pointer does not have to stay on the
# 24px icon for the card to stick.
function CursorOnTaskbar() {
  # the taskbar strip of the card's own screen is the gap between its bounds and its working area
  $p  = [System.Windows.Forms.Cursor]::Position
  $sc = [System.Windows.Forms.Screen]::FromPoint($form.Location)
  $b  = $sc.Bounds; $wa = $sc.WorkingArea
  if ($wa.Bottom -lt $b.Bottom) { return ($p.Y -ge ($wa.Bottom - 8)) }
  if ($wa.Top    -gt $b.Top)    { return ($p.Y -lt $wa.Top) }
  if ($wa.Left   -gt $b.Left)   { return ($p.X -lt $wa.Left) }
  if ($wa.Right  -lt $b.Right)  { return ($p.X -ge $wa.Right) }
  return $false
}

# the hover zone is the card itself plus the whole taskbar strip: the pointer only has to stay in
# that, it does not have to sit on the 24 px icon.
function Inside-HoverZone() {
  if (CursorOnTaskbar) { return $true }
  $p = [System.Windows.Forms.Cursor]::Position
  $r = $form.Bounds
  $r.Inflate(30, 80)   # generous: it also bridges the $TipGap band between the card and the taskbar
  return $r.Contains($p)
}

# move the window only when the anchor actually changed (a window move is a repaint)
function Position-Card() {
  $p = Card-Anchor
  if ($form.Location.X -ne $p.X -or $form.Location.Y -ne $p.Y) { $form.Location = $p }
}

# Idempotent: while the latch is up a hover event does nothing at all, so under a moving pointer the
# window is never re-positioned, never re-Shown and never re-painted.
function Show-Card([string]$why) {
  $st.outside = $null
  if ($st.open) { return }
  if ($form.Visible) { Trace ('latch was down but the card was visible: re-latching'); $st.open = $true; return }
  Position-Card
  if ($cardFormOk) {
    $form.Visible = $true                      # ShowWithoutActivation is overridden: no focus theft
  } else {
    $st.fg = [Win.Win32Card]::GetForegroundWindow()
    $form.Visible = $true
    if ($form.IsHandleCreated -and -not $st.tweaks) {
      $h = $form.Handle
      [void] [Win.Win32Card]::SetWindowLong($h, -20, ([Win.Win32Card]::GetWindowLong($h, -20) -bor 0x80))   # WS_EX_TOOLWINDOW
      $st.tweaks = $true
    }
    if ($st.fg -ne [IntPtr]::Zero) { [void] [Win.Win32Card]::SetForegroundWindow($st.fg) }                  # give focus back
  }
  $st.open = $true
  $st.openAt = Get-Date
  # blank the native tooltip while the card is up (Set-TrayIcon keeps it blank from here on)
  Set-TrayIcon $st.col ''
  $loc = $form.Location
  Trace ('card shown (' + $why + ') at ' + $loc.X + ',' + $loc.Y + ' size ' + $form.Size.Width + 'x' + $form.Size.Height)
}
function Hide-Card([string]$why) {
  if ($st.pinned) { return }
  if (-not $st.open -and -not $form.Visible) { return }
  $form.Visible = $false
  $st.open = $false
  $st.openAt = $null
  Set-TrayIcon $st.col $st.tip      # tooltip comes back once the card is gone
  Trace ('card hidden (' + $why + ')')
}
function Toggle-Pin([string]$why) {
  $st.pinned = -not $st.pinned
  Trace ('pin=' + $st.pinned + ' (' + $why + ')')
  # The tick and the wording are set HERE, not on the menu's Opening event: this is the only place the
  # pin state ever changes, so the menu can never disagree with it. ($miPin is a script-scope object;
  # setting one of its properties is not a variable write, so it does survive the handler boundary -
  # see the $st note below.)
  if ($miPin) {
    $miPin.Checked = [bool]$st.pinned
    $miPin.Text = if ($st.pinned) { 'Unpin the card' } else { 'Pin the card' }
  }
  if ($st.pinned) { Show-Card 'pin' } else { Hide-Card 'pin' }
}

# One mousemove is enough to open the card. Windows only raises mouse-move while the pointer is
# actually moving over the icon, so opening is latched and closing is done by the watcher timer.
$ni.Add_MouseMove({
  param($sender, $e)
  $st.moves = $st.moves + 1
  if (($st.moves % 40) -eq 1) {                       # sampled, not every event: file I/O is slow
    $p = [System.Windows.Forms.Cursor]::Position
    Trace ('mousemove #' + $st.moves + ' at ' + $p.X + ',' + $p.Y)
  }
  # While the right-click menu is up the card stays down. It is TopMost and it is anchored at the bottom
  # right of the working area - which is exactly where a tray menu opens - so a window sitting under the
  # pointer is one way a menu can look fine and still never get the click.
  if ($st.menuOpen) { return }
  Show-Card 'hover'
})

# Left click opens the Monitor page, left double click pins the card. One of them cannot own its own
# event: a double click also raises two MouseUp events (Clicks=2 on the second), so the old code
# toggled pin twice per double click = nothing ever pinned. Instead the first click starts a short
# one-shot timer; a second click inside it cancels the single click and pins.
$clickTimer = New-Object System.Windows.Forms.Timer
$clickTimer.Interval = 320
$clickTimer.Add_Tick({
  $clickTimer.Stop()
  if (-not $st.wantClick) { return }
  $st.wantClick = $false
  Trace 'single click: opening the Monitor page'
  Start-Process $Page
})
$ni.Add_MouseUp({
  param($sender, $e)
  if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }   # right click = the menu
  $now = Get-Date
  if ($st.wantClick -and ($now - $st.lastClick).TotalMilliseconds -lt 400) {
    $st.wantClick = $false; $clickTimer.Stop(); Toggle-Pin 'double click'; return
  }
  $st.wantClick = $true; $st.lastClick = $now; $clickTimer.Start()
})

# ------------------------------------------------- model control in the menu --
# The control rows are rebuilt on every right click, but ONLY from the cache Refresh-Control keeps:
# one `strata` call costs about half a second (it starts a Python), and a right click must feel
# instant. Nothing here talks to the CLI.
function Cut-Line([string]$s, [int]$n) {
  $t = (([string]$s) -replace '\s+', ' ').Trim()
  if ($t.Length -gt $n) { return $t.Substring(0, [Math]::Max(1, $n - 3)) + '...' }
  return $t
}

function Ctl-Row([string]$text, [string]$kind, [string]$id, [bool]$enabled) {
  return [ordered]@{ text = $text; kind = $kind; id = $id; enabled = $enabled }
}

function On-CtlClick($item) {
  $t = $item.Tag
  if (-not $t -or -not $t.kind) { return }
  Trace ('menu: ' + $t.kind + ' ' + $t.id)
  switch ($t.kind) {
    'start'  { Start-Strata ([string]$t.id) ([string]$st.modelSrc[[string]$t.id]) }
    # One click stops. A two-click confirm was in here (and was approved once), but on 2026-11-21 the
    # person who uses it said the single click is what they want: a Stop that needs a second click reads
    # as a row that does nothing, which is exactly the "I cannot select anything" complaint. Stop is
    # still the graceful one (drain in-flight requests, then QUIT to the engine), never a kill.
    'stop'   { Stop-Strata ([string]$t.id) }
    'unload' { Post-Route 'unload' }
    'load'   { Post-Route 'load' }
    'wizard' { Open-Strata-Wizard }   # nothing installed: let Strata's own wizard deal with that
  }
}

function Build-CtlMenu() {
  # drop the rows from the last open, then re-insert from the cache
  if ($st.ctlItems) { foreach ($it in $st.ctlItems) { [void]$menu.Items.Remove($it) } }
  $st.ctlItems = @()
  $at = $menu.Items.IndexOf($miCtlSep) + 1
  if ($at -le 0) { return }

  $answering = [bool]($st.snap -and $st.snap.ok)
  $owned  = ($st.ctl -in @('starting', 'ready', 'draining', 'failed', 'stale'))
  # which profile $st.ctl describes. It is NOT just $st.ownedId: that is only set when the tray itself
  # started the model, but a model started from run-iq3_s.bat is runtime-owned too, and Stop has to know
  # its profile id to work. Reading it only from ownedId gave a blank `Stop ` row that did nothing.
  $ctlId  = if ($st.ctlId) { [string]$st.ctlId } else { [string]$st.ownedId }
  $rows   = @()

  if (-not $st.control) {
    $rows += Ctl-Row 'control is off (viewer only)' '' '' $false
  }
  elseif (-not (Strata-Exe)) {
    $rows += Ctl-Row ('"' + $st.strataCmd + '" is not on PATH - no control') '' '' $false
  }
  else {
    if ($st.ctl -eq 'starting') { $rows += Ctl-Row ('loading: ' + $(if ($st.ctlPhase) { $st.ctlPhase } else { '...' })) '' '' $false }
    if ($st.ctl -eq 'draining') { $rows += Ctl-Row 'stopping: draining in-flight requests' '' '' $false }

    # one row per installed model, straight from `strata models list`: a model this Strata will not
    # run (a retired DeepSeek pack) is not in that list, so it can never be offered here
    if (-not $st.models -or -not @($st.models).Count) {
      # Empty means one of two things: nothing is installed yet, or the call failed. Both go to the same
      # place - Strata's own start-here, in its own window, where a model gets installed (and where a
      # broken install says what is wrong). The tray never installs anything by itself.
      if (Strata-Wizard) {
        $rows += Ctl-Row 'no models installed: open the Strata start-here' 'wizard' '' $true
      } else {
        $rows += Ctl-Row 'no models listed, and START-HERE.bat was not found' '' '' $false
      }
      $rows += Ctl-Row 'asking strata again in a few seconds' '' '' $false
    }
    foreach ($m in $st.models) {
      $nm = if ($m.name) { $m.name } else { $m.id }
      # startable = nothing answering AND no model loaded anywhere according to the runtime. Checking
      # only the port would offer a second start when the tray's url is stale but a model really is up
      # (a failed / stale record is deliberately still startable - the next start cleans those up).
      $en = (-not $answering) -and ($st.ctl -notin @('starting', 'ready', 'draining')) -and [bool]$m.ready
      $tx = 'Start ' + $nm
      # a greyed row with no reason reads as a stuck menu, which is what this used to look like
      if (-not $m.ready)                      { $tx += '  (not downloaded)' }
      elseif ($owned -and $ctlId -eq $m.id)   { $tx += '  (running here)' }
      elseif ($answering)                     { $tx += '  (another server is answering)' }
      elseif ($st.ctl -eq 'starting')         { $tx += '  (loading now)' }
      elseif ($st.ctl -eq 'draining')         { $tx += '  (a stop is finishing)' }
      elseif ($st.ctl -eq 'ready')            { $tx += '  (a model is loaded elsewhere)' }
      $rows += Ctl-Row $tx $(if ($en) { 'start' } else { '' }) $(if ($en) { [string]$m.id } else { '' }) $en
    }

    # Stop only when a runtime owns this server. A model started from a console window is not owned,
    # and `runtime stop` would answer runtime_not_owned for it, so it gets an explanation instead.
    if ($st.ctl -eq 'ready') {
      $tx = 'Stop ' + $ctlId
      $rows += Ctl-Row $tx 'stop' $ctlId $true
    }
    if ($answering -and -not $owned) {
      $rows += Ctl-Row 'answering, but not started from here' '' '' $false
      $rows += Ctl-Row 'stop it with Ctrl+C in its own window' '' '' $false
    }
    # Load / Unload are the two "soft" rows: they keep the server up and only move the model in or out
    # of graphics memory. They stay in the menu for everyone unless $SoftControl = $false is set in
    # settings.local.ps1 (this box never swaps a model without stopping the server first).
    if ($st.softControl -and $answering -and $st.ctl -eq 'ready') {
      if ($st.snap.state -eq 'unloaded') {
        $rows += Ctl-Row 'Load the model back (a few seconds)' 'load' $ctlId $true
      } else {
        $rows += Ctl-Row 'Unload the model (VRAM back, RAM stays)' 'unload' $ctlId $true
      }
    }
    if ($st.ctlMsg) { $rows += Ctl-Row (Cut-Line $st.ctlMsg 62) '' '' $false }
  }

  foreach ($r in $rows) {
    # Items.Insert takes an ITEM, not a string: `Items.Insert($n, 'text')` has no overload, and with
    # $ErrorActionPreference = SilentlyContinue it fails quietly - the row simply never appears. So the
    # item is built first and then inserted (this is exactly what bit the first version of this code).
    $it = New-Object System.Windows.Forms.ToolStripMenuItem
    $it.Text = [string]$r.text
    if ($r.kind) {
      $it.Tag = @{ kind = $r.kind; id = $r.id }
      [void]$it.Add_Click({ param($s, $e) On-CtlClick $s })
    } else { $it.Enabled = $false }
    $menu.Items.Insert($at, $it)
    $at = $at + 1
    Wire-MouseLog $it                 # the control rows are new on every open, so they are wired here
    $st.ctlItems += ,$it
  }
}

$menu = New-Object System.Windows.Forms.ContextMenuStrip
[void]$menu.Items.Add('Open the Monitor page').Add_Click({ Start-Process $Page })
# The old click target, kept reachable: the SPA root opens the chat tab.
[void]$menu.Items.Add('Open the chat page').Add_Click({ Start-Process ($Url.TrimEnd('/') + '/#chat') })
[void]$menu.Items.Add('Open the API (/v1)').Add_Click({ Start-Process ($Url.TrimEnd('/') + '/v1/models') })
$miCtlSep = $menu.Items.Add('-')        # the control rows are inserted after this one, on each open

# Opening: put the rows on, then write what the menu looks like. This log is the only way to tell an
# "unselectable menu" that means rows disabled by design from one that is killed before the click lands.
$menu.Add_Opening({
  param($s, $e)
  # Two right clicks on the icon: the trace caught a second Opening arriving with the first menu still
  # open and no Closed between them (17:26:15 / 17:26:18 on 2026-11-21), i.e. WinForms re-Shows an
  # already-visible dropdown instead of closing it, which means two mouse-tracking loops over one menu.
  # That is a good way to get a menu that paints but takes no clicks, so the second open is refused the
  # supported way: Opening is cancelable. The menu that is already up stays up where it is.
  # But a latch stuck at true (a build that threw half way, a Closed that never fired) would refuse every
  # right click for the rest of the session, which is a worse bug than the one it prevents. So the latch
  # is only trusted for as long as a menu can realistically stay up: the two opens in the trace were 3 s
  # apart, and nothing is open for 30 s, so past that age it is stale - clear it and open normally.
  if ($st.menuOpen) {
    $ageS = if ($null -ne $st.menuAt) { [int]((Get-Date) - $st.menuAt).TotalSeconds } else { 999 }
    if ($ageS -gt 30) {
      Trace ('menuOpen latch is stale (' + $ageS + ' s old): clearing it and opening normally')
      $st.menuOpen = $false
    }
  }
  if ($st.menuOpen) {
    Trace 'Opening while a menu was already open: refusing the second open (one tracking loop at a time)'
    $e.Cancel = $true
    return
  }
  # Drop the card for the length of the menu. NOT via Hide-Card: that re-writes the tray tip, and a
  # Shell_NotifyIcon tip change in the middle of menu tracking is itself a good way to dismiss a menu.
  if ($form.Visible) {
    $st.cardWasOpen = $true
    $form.Visible = $false
    $st.open = $false; $st.openAt = $null
  } else { $st.cardWasOpen = $false }
  $st.menuOpen = $true
  $st.menuAt = Get-Date
  Build-CtlMenu                          # the only safe place to add items
  $c = [System.Windows.Forms.Cursor]::Position
  Trace ('menu open: items=' + $menu.Items.Count + ' control=' + [bool]$st.control +
         ' ctl=' + $(if ($st.ctl) { $st.ctl } else { '-' }) +
         ' ctlId=' + $(if ($st.ctlId) { $st.ctlId } else { '-' }) +
         ' models=' + @($st.models).Count + ' cardWasOpen=' + [bool]$st.cardWasOpen +
         ' pinned=' + [bool]$st.pinned + ' cursor ' + $c.X + ',' + $c.Y +
         ' card ' + $form.Bounds + ' menu ' + $menu.Size.Width + 'x' + $menu.Size.Height)
  foreach ($it in $menu.Items) {         # every row, with its enabled state: the reason is in the text
    Trace ('  ' + (Row-Name $it))
  }
})

# Opened: the menu is on screen, so its window exists and its real position can be read. Two things
# this answers for the unclickable-menu report:
#   rect   - is the menu where the pointer is, or is it under the taskbar / off the working area?
#   under  - is OUR window the window the pointer hits at the centre of the menu, or is something else
#            painted over it (a window on top would eat the click and close the menu as AppFocusChange)
$menu.Add_Opened({
  param($s, $e)
  if (-not $focusApiOk) { Trace 'menu shown: (win32 not available, no rect / no hit test)'; return }
  $h = [IntPtr]::Zero
  try { $h = $menu.Handle } catch {}
  $r = New-Object Win32Tray+RECT
  if ($h -ne [IntPtr]::Zero -and [Win32Tray]::GetWindowRect($h, [ref]$r)) {
    Trace ('menu shown: rect ' + $r.left + ',' + $r.top + ' ' + ($r.right - $r.left) + 'x' + ($r.bottom - $r.top))
    $cx = [int](($r.left + $r.right) / 2); $cy = [int](($r.top + $r.bottom) / 2)
    $hit = [IntPtr]::Zero
    try { $hit = [Win32Tray]::WindowFromPoint((New-Object Win32Tray+POINT($cx, $cy))) } catch {}
    $own = if ($hit -eq $h) { 'own menu' } else { 'NOT the menu' }
    Trace ('  at ' + $cx + ',' + $cy + ' the window there is ' + $own + ': ' + (Describe-Win $hit))
  } else {
    Trace 'menu shown: (no handle / no rect)'
  }
  $c = [System.Windows.Forms.Cursor]::Position
  Trace ('  cursor at open+0: ' + $c.X + ',' + $c.Y + '  foreground: ' + (Describe-Foreground))
})

# The missing half of the evidence: did the mouse ever reach the row, and did a button go down on it?
# ToolStrip.ItemMouseHover is NOT a public event in .NET Framework 4.x (PowerShell has no
# Add_ItemMouseHover - checked by reflection), but every ToolStripItem does expose MouseEnter and
# MouseUp, which answer the same question. Reading the log:
#   row logs nothing at all  -> the pointer never got that row (the menu was not taking the mouse)
#   "mouse up on row" but no "menu: <action>" -> the row was greyed out by design, or the click landed
#                                                     on a separator / the menu's padding
#   "mouse up on row" + "menu: <action>"      -> the click worked
function Row-Name($it) {
  $t = (([string]$it.Text) -replace '\s+', ' ')
  if (-not $t) { $t = '(separator)' }
  if ($t.Length -gt 60) { $t = $t.Substring(0, 57) + '...' }
  return (( $(if ($it.Enabled) { '[on] ' } else { '[off]' }) ) + ' ' + $t)
}
function Wire-MouseLog($it) {
  if ($null -eq $it) { return }
  $it.Add_MouseEnter({
    param($s, $e)
    $c = [System.Windows.Forms.Cursor]::Position
    Trace ('  mouse enters row: ' + (Row-Name $s) + ' at cursor ' + $c.X + ',' + $c.Y)
  })
  $it.Add_MouseUp({
    param($s, $e)
    Trace ('  mouse up on row: ' + (Row-Name $s) + ' button ' + [string]$e.Button)
  })
}

# Closed: CloseReason names whoever ended the menu. MenuItemSelect means the click landed; FocusOut /
# FormDeactivate / ClickAway means something took the menu away first, which is what "no row works" looks
# like from the outside.
$menu.Add_Closed({
  param($s, $e)
  $st.menuOpen = $false
  # AppFocusChange is what a menu that never took the click reports: WinForms has no separate
  # "click away" reason, so every close that is not a row, a key or an explicit Close() says this. The
  # foreground window at that moment is the closest thing to a name for the culprit.
  Trace ('menu closed: ' + [string]$e.CloseReason + $(if ([string]$e.CloseReason -eq 'AppFocusChange') {
                '  foreground now: ' + (Describe-Foreground) } else { '' }))
  if ($st.cardWasOpen) { Set-TrayIcon $st.col $st.tip }              # tip back on (see Opening note)
  if ($st.pinned -and $st.cardWasOpen) { Show-Card 'menu closed (pinned)' }
  $st.cardWasOpen = $false
})
$menu.Add_ItemClicked({ param($s, $e) Trace ('menu clicked: ' + (([string]$e.ClickItem.Text) -replace '\s+', ' ')) })
[void]$menu.Items.Add('Refresh now').Add_Click({ $st.snap = Get-Snapshot $Url; $form.Invalidate() })
$miPin = $menu.Items.Add('Pin the card')   # the only named item: Toggle-Pin relabels and ticks it
[void]$miPin.Add_Click({ Toggle-Pin 'menu' })
$menu.Items.Add('-') | Out-Null
[void]$menu.Items.Add('Quit the tray icon').Add_Click({ $ctxLoop.ExitThread() })
foreach ($it in $menu.Items) { Wire-MouseLog $it }   # the fixed rows: wired once, here; control rows are
                                                     # rebuilt on every open and wired in Build-CtlMenu
$ni.ContextMenuStrip = $menu   # right click shows this on its own

# Build the menu once and print it, then leave: the control rows are made on right click, so there is
# no other way to check that path without hovering a real icon. Rows come from the cache that
# Refresh-Control fills, so this also proves the CLI side (list / status) works on this machine.
# Refresh-Control only FIRES the calls now (that is the whole point of Fire-Cli), so this pumps the
# timer by hand: fire, wait for the answer, fire the next one, until both kinds have answered.
if ($CtlSelfTest) {
  $t0 = Get-Date
  while (((Get-Date) - $t0).TotalSeconds -lt 25) {
    [void](Refresh-Control)                # both return booleans: without [void] they print as noise
    if (-not $st.control) { break }        # nothing to fetch: do not sit out the timeout
    $tw = Get-Date
    while ($st.cli -and ((Get-Date) - $tw).TotalSeconds -lt 20) { Start-Sleep -Milliseconds 400; [void](Collect-Cli) }
    if (@($st.models).Count -and $st.ctl) { break }
  }
  if ($st.cli) { Write-Output '  (a CLI call still had not answered after 25 s)' }
  if ($NoModels) { $st.models = @(); $st.modelSrc = @{} }   # check the "nothing installed" row for real
  Build-CtlMenu          # normally done by the menu's Opening event; there is no mouse here
  $exeTxt = if (Strata-Exe) { Strata-Exe } else { ('not found: ' + $st.strataCmd) }
  Write-Output ('menu for ' + $Url + '   control=' + $st.control + '   strata=' + $exeTxt)
  Write-Output ('control state: ' + $(if ($st.ctl) { $st.ctl } else { 'unknown' }) + $(if ($st.ctlPhase) { ' phase=' + $st.ctlPhase } else { '' }) + ' owned=' + $(if ($st.ownedId) { $st.ownedId } else { '-' }) + ' status-of=' + $(if ($st.ctlId) { $st.ctlId } else { '-' }))
  foreach ($it in $menu.Items) {
    Write-Output ('  ' + $(if ($it.Enabled) { '[on]  ' } else { '[off] ' }) + $it.Text)
  }
  $ni.Visible = $false; $ni.Dispose(); $form.Close(); $form.Dispose()
  exit 0
}

$poll = New-Object System.Windows.Forms.Timer
$poll.Interval = [int]($Every * 1000)
$poll.Add_Tick({
  # Nothing here runs while the right-click menu is open. A WinForms menu tracks the mouse in a modal
  # message loop, and this tick used to run two Invoke-RestMethod calls inside that loop: the menu
  # looked normal on screen but stopped answering the mouse ("mini freeze", "sticking on screen").
  # The card is built from $st.snap, which does not need to be current while a menu is up, and the tick
  # right after the menu closes catches up. Same guard on the other two timers.
  if ($st.menuOpen) { return }
  $t0 = Get-Date
  $st.snap = Get-Snapshot $Url
  $ms = [int]((Get-Date) - $t0).TotalMilliseconds
  if ($ms -gt 400) { Trace ('poll took ' + $ms + ' ms') }   # a slow poll is the other half of that bug
  $col = if (-not $st.snap.ok) { 'red' } else { StateColor $st.snap.state }
  # while the tray is loading or stopping the model there is no server to describe, and "no server" is
  # not the truth - say which of the two it is
  $cs = if ($st.control -and $st.ctl -in @('starting', 'draining', 'failed', 'stale')) { [string]$st.ctl } else { '' }
  $tip = if (-not $st.snap.ok -and $cs -eq 'starting') { 'Strata: loading' + $(if ($st.ctlPhase) { ' (' + $st.ctlPhase + ')' } else { '' }) }
         elseif (-not $st.snap.ok -and $cs) { 'Strata: ' + $cs }
         elseif (-not $st.snap.ok) { "Strata: no server on $Url" } else {
    'Strata {0} | {1} t/s | ctx {2:N0}% | VRAM {3:N1}/{4:N0} GB' -f
      $st.snap.state, (N1 $st.snap.hard.tok_s), (100 * $st.snap.ctxUsed / $st.snap.ctxMax),
      ($st.snap.hard.gpu_mem_used / 1GB), ($st.snap.hard.gpu_mem_total / 1GB)
  }
  Set-TrayIcon $col $tip
  $st.col = $col; $st.tip = $tip
  if ($form.Visible) { $form.Invalidate() }   # repaint only, never move or re-Show
})
$poll.Start()

# Control state on its own timer: a `strata` call is a Python start-up (~0.5 s here), so it must not
# sit in the 1.5 s card poll. This ticks every second and Refresh-Control paces the calls themselves
# (about every 3 s while a start or a stop is in flight, minutes apart when nothing is happening).
$ctlTimer = New-Object System.Windows.Forms.Timer
$ctlTimer.Interval = 1000
# Same guard: Refresh-Control starts a process (Fire-Cli -> Start-Process), and a process spawned in
# the middle of menu tracking is a very good way to lose the menu (its focus change closes it, which
# is what CloseReason AppFocusChange means).
$ctlTimer.Add_Tick({ if ($st.menuOpen) { return }; Refresh-Control })
$ctlTimer.Start()
Refresh-Control      # once at start, so the first right click already has the model list

$watch = New-Object System.Windows.Forms.Timer
$watch.Interval = 200
$watch.Add_Tick({
  if ($st.menuOpen) { return }     # the card is deliberately down while the menu is up
  # if the card window went away by some other route (Alt+F4 on a borderless window), clear the latch
  # so the next hover opens it again. Only checked a second after opening, so this can never race the
  # Show() itself.
  if ($st.open -and $null -ne $st.openAt -and ((Get-Date) - $st.openAt).TotalSeconds -ge 1) {
    if (-not $form.IsHandleCreated -or -not $form.Visible) { Trace 'card window is gone: clearing the latch'; $st.open = $false }
  }
  if (-not $st.open -or $st.pinned) { $st.outside = $null; return }
  if (Inside-HoverZone) { $st.outside = $null; return }
  if ($null -eq $st.outside) { $st.outside = Get-Date; return }
  if (((Get-Date) - $st.outside).TotalMilliseconds -ge $GraceMs) { Hide-Card 'pointer left the taskbar' }
})
$watch.Start()

Set-TrayIcon 'grey' 'Strata'
Trace ('start url=' + $Url + ' every=' + $Every)
Write-Output "Strata tray: watching $Url (close this window or right-click the icon to quit)"
[System.Windows.Forms.Application]::Run($ctxLoop)

$poll.Stop(); $watch.Stop(); $ctlTimer.Stop()
$ni.Visible = $false; $ni.Dispose()
$form.Close(); $form.Dispose()
foreach ($k in @($BR.Keys)) { $BR[$k].Dispose() }
