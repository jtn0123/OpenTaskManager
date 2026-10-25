<#
.SYNOPSIS
  Makes the Windows and Linux app's icons from the Mac app's 1024-point icon:
  the rounded tile cropped from Apple's grid (which leaves a margin and a
  shadow around it), drawn at each size, as PNGs and a Windows .ico.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File cross\scripts\make-icons.ps1
#>
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$source = Join-Path $root 'App\Resources\Assets.xcassets\AppIcon.appiconset\icon_512x512@2x.png'
$out = Join-Path $root 'cross\app\icons'
New-Item -ItemType Directory -Force $out | Out-Null

# The tile on the 1024 canvas: an 824-point rounded square at (100, 100), as scripts/make-icon.swift draws it.
$tile = New-Object System.Drawing.Rectangle 100, 100, 824, 824
$original = [System.Drawing.Image]::FromFile($source)
function Render([int]$size) {
    $bitmap = New-Object System.Drawing.Bitmap $size, $size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
    $graphics.DrawImage($original, (New-Object System.Drawing.Rectangle 0, 0, $size, $size), $tile, [System.Drawing.GraphicsUnit]::Pixel)
    $graphics.Dispose()
    $stream = New-Object System.IO.MemoryStream
    $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
    $bitmap.Dispose()
    , $stream.ToArray()
}

# Linux: the sizes the hicolor theme commonly holds; the window icon uses 64.
foreach ($size in 32, 48, 64, 128, 256, 512) {
    [System.IO.File]::WriteAllBytes((Join-Path $out "opentaskmanager-$size.png"), (Render $size))
}

# Windows: one .ico with PNG images, each size Explorer and the taskbar ask for.
$sizes = 16, 20, 24, 32, 40, 48, 64, 128, 256
$images = @($sizes | ForEach-Object { , (Render $_) })
$ico = New-Object System.IO.MemoryStream
$writer = New-Object System.IO.BinaryWriter $ico
$writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $side = if ($sizes[$i] -ge 256) { 0 } else { $sizes[$i] }
    $writer.Write([byte]$side); $writer.Write([byte]$side); $writer.Write([byte]0); $writer.Write([byte]0)
    $writer.Write([uint16]1); $writer.Write([uint16]32)
    $writer.Write([uint32]$images[$i].Length); $writer.Write([uint32]$offset)
    $offset += $images[$i].Length
}
foreach ($image in $images) { $writer.Write($image) }
$writer.Flush()
[System.IO.File]::WriteAllBytes((Join-Path $out 'opentaskmanager.ico'), $ico.ToArray())
$original.Dispose()
Get-ChildItem $out | ForEach-Object { '{0,-28} {1,7} bytes' -f $_.Name, $_.Length }
