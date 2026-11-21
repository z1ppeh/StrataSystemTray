#Requires -Version 5.1
<#
  make-icon-ico.ps1 - build a Windows .ico from a square PNG. Optional: the shipped strata-tray.ico
  is the author's own art and does not need this script. Use it if you want your own picture on the
  shortcut that starts the tray.

    powershell -NoProfile -ExecutionPolicy Bypass -File make-icon-ico.ps1 -Source C:\some\art.png -Out my.ico

  The source must be square and should be at least 256 px on a side. This script only resamples it -
  it never draws, crops or adds transparency - so what you see in the PNG is what you get.

  Writes 16 / 32 / 48 as 32-bit BMP entries (every reader, including GDI+ Icon and
  ExtractAssociatedIcon) plus 256 as a PNG entry (crisp at 4K icon sizes). The shipped strata-tray.ico
  instead carries 128 and 256 as BMP entries, which is all a desktop shortcut needs.

  The tray icon is NOT built here: strata-tray.ps1 draws that at run time (New-Icon) because its
  colour changes with the server state. This .ico is only the shortcut's picture.
#>
param(
  [Parameter(Mandatory = $true)] [string] $Source,
  [string] $Out = ''
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Out) { $Out = Join-Path $dir 'strata-tray.ico' }
if (-not (Test-Path -LiteralPath $Source)) { throw "no source art at $Source" }

$src = [System.Drawing.Image]::FromFile($Source)
$srcW = $src.Width; $srcH = $src.Height
if ($srcW -ne $srcH) {
  $src.Dispose(); throw "source art must be square (it is $srcW x $srcH): $Source"
}
if ($srcW -lt 256) {
  Write-Warning ("source art is only $srcW px wide, so the 256 entry is an upscale")
}

function Get-Scaled([int] $n) {
  $bmp = New-Object System.Drawing.Bitmap($n, $n, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $g.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
  $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
  $g.DrawImage($src, 0, 0, $n, $n)
  $g.Dispose()
  return $bmp
}

function Get-BmpBytes([System.Drawing.Bitmap] $bmp) {
  # 32-bit BGRA, rows bottom-up (ICO order), + an all-zero AND mask: the alpha channel does the shape.
  $w = $bmp.Width; $h = $bmp.Height
  $rect  = New-Object System.Drawing.Rectangle(0, 0, $w, $h)
  $flags = [System.Drawing.Imaging.ImageLockMode]::ReadOnly
  $fmt   = [System.Drawing.Imaging.PixelFormat]::Format32bppArgb
  $data  = $bmp.LockBits($rect, $flags, $fmt)
  $stride = $data.Stride
  $s = New-Object byte[] ($stride * $h)
  [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $s, 0, $s.Length)
  [void]$bmp.UnlockBits($data)

  $ms = New-Object System.IO.MemoryStream
  $bw = New-Object System.IO.BinaryWriter($ms)
  $bw.Write([int32]40)          # BITMAPINFOHEADER size
  $bw.Write([int32]$w)
  $bw.Write([int32]($h * 2))    # ICO: height is XOR + AND mask
  $bw.Write([int16]1)           # planes
  $bw.Write([int16]32)          # bits per pixel
  $bw.Write([int32]0)           # no compression
  $bw.Write([int32]0)           # size (ignored for BI_RGB)
  $bw.Write([int32]0); $bw.Write([int32]0)   # x/y ppm
  $bw.Write([int32]0); $bw.Write([int32]0)   # colours used / important
  $px = New-Object byte[] ($stride * $h)
  for ($y = 0; $y -lt $h; $y++) {
    [Array]::Copy($s, (($h - 1 - $y) * $stride), $px, ($y * $stride), $stride)
  }
  $bw.Write($px)
  $andRow = [int](($w + 31) / 32) * 4
  $bw.Write((New-Object byte[] ($andRow * $h)))
  $bw.Flush()
  return ,($ms.ToArray())
}

function Get-PngBytes([System.Drawing.Bitmap] $bmp) {
  $ms = New-Object System.IO.MemoryStream
  $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
  return ,($ms.ToArray())
}

$ico = $Out

$plan = @(16, 32, 48, 256)
$art = @{}
foreach ($s in $plan) { $art[$s] = Get-Scaled $s }

$entries = @()
foreach ($s in $plan) {
  if ($s -eq 256) {
    $bytes = Get-PngBytes $art[$s]
    $wByte = 0; $hByte = 0                          # 256 is written as 0 in an ICO directory
    $type = 'png'
  } else {
    $bytes = Get-BmpBytes $art[$s]
    $wByte = $s; $hByte = $s
    $type = 'bmp'
  }
  $entries += [pscustomobject]@{ w = $wByte; h = $hByte; bytes = $bytes; type = $type; size = $s }
}

$fs = New-Object System.IO.FileStream($ico, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
$bw = New-Object System.IO.BinaryWriter($fs)
$bw.Write([int16]0)                                  # reserved
$bw.Write([int16]1)                                  # type 1 = icon
$bw.Write([int16]$entries.Count)
$offset = 6 + (16 * $entries.Count)
foreach ($e in $entries) {
  $bw.Write([byte]$e.w); $bw.Write([byte]$e.h)
  $bw.Write([byte]0); $bw.Write([byte]0)             # palette count / reserved
  $bw.Write([int16]1); $bw.Write([int16]32)          # planes, bits per pixel
  $bw.Write([int32]$e.bytes.Length)
  $bw.Write([int32]$offset)
  $offset += $e.bytes.Length
}
foreach ($e in $entries) { $bw.Write($e.bytes) }
$bw.Flush(); $fs.Close()
foreach ($s in $plan) { $art[$s].Dispose() }
$src.Dispose()

Write-Output ("source " + $Source)
Write-Output ("wrote " + $ico + "  (" + (Get-Item -LiteralPath $ico).Length + " bytes)")
foreach ($e in $entries) { Write-Output ("  entry {0,3} x {0,-3} {1}  {2} bytes" -f $e.size, $e.type, $e.bytes.Length) }
