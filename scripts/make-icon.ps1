# Generates ForeverGold/Media/ForeverGold.tga (64x64, 32-bit, uncompressed)
# from the logo (docs/ForeverGold-CurseForge.png). The TGA is NOT referenced
# by the TOC until it has been seen loading in the client (docs/STATUS.md).
#   powershell -ExecutionPolicy Bypass -File scripts/make-icon.ps1
[CmdletBinding()]
param(
  [string]$Source = "docs/ForeverGold-CurseForge.png",
  [string]$Target = "ForeverGold/Media/ForeverGold.tga",
  [int]$Size = 64
)
$ErrorActionPreference = "Stop"
$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$sourcePath = Join-Path $root $Source
$targetPath = Join-Path $root $Target
if (-not (Test-Path -LiteralPath $sourcePath)) { throw "Source image not found: $sourcePath" }
if (($Size -band ($Size - 1)) -ne 0) { throw "Size must be a power of two" }

Add-Type -AssemblyName System.Drawing
$image = [System.Drawing.Image]::FromFile($sourcePath)
try {
  $bitmap = New-Object System.Drawing.Bitmap $Size, $Size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
  $graphics.DrawImage($image, 0, 0, $Size, $Size)
  $graphics.Dispose()

  # TGA header: uncompressed true-colour, 32 bpp, 8 alpha bits, origin bottom-left.
  $header = New-Object byte[] 18
  $header[2] = 2
  $header[12] = $Size -band 0xFF; $header[13] = ($Size -shr 8) -band 0xFF
  $header[14] = $Size -band 0xFF; $header[15] = ($Size -shr 8) -band 0xFF
  $header[16] = 32
  $header[17] = 8
  $pixels = New-Object byte[] ($Size * $Size * 4)
  $offset = 0
  for ($y = $Size - 1; $y -ge 0; $y--) {
    for ($x = 0; $x -lt $Size; $x++) {
      $color = $bitmap.GetPixel($x, $y)
      $pixels[$offset] = $color.B; $pixels[$offset + 1] = $color.G
      $pixels[$offset + 2] = $color.R; $pixels[$offset + 3] = $color.A
      $offset += 4
    }
  }
  $bitmap.Dispose()
  $directory = Split-Path -Parent $targetPath
  if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory | Out-Null }
  $stream = [System.IO.File]::Create($targetPath)
  try {
    $stream.Write($header, 0, $header.Length)
    $stream.Write($pixels, 0, $pixels.Length)
  } finally {
    $stream.Dispose()
  }
} finally {
  $image.Dispose()
}
Write-Output ("Wrote {0} ({1}x{1}, {2} bytes)" -f $Target, $Size, (Get-Item -LiteralPath $targetPath).Length)
