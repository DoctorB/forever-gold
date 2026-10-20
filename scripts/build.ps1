# Builds the installable ZIP: release/ForeverGold-<version>.zip with a single
# root folder ForeverGold/ holding the TOC, plus a SHA-256 checksum and a
# manifest. Never uploads anything.
#   powershell -ExecutionPolicy Bypass -File scripts/build.ps1 [-SkipTests]
# Works with Windows PowerShell 5.1 and PowerShell 7 (CI).
[CmdletBinding()]
param(
  [string]$OutDir = "release",
  [switch]$SkipTests
)
$ErrorActionPreference = "Stop"
Set-StrictMode -Version 3.0

$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$addonName = "ForeverGold"
$addonDir = Join-Path $root $addonName
$tocPath = Join-Path $addonDir "$addonName.toc"
if (-not (Test-Path -LiteralPath $tocPath)) { throw "TOC not found: $tocPath" }

function Fail([string]$message) { throw "build: $message" }

# Paths are only ever deleted inside <root>/<OutDir>.
$outRoot = [System.IO.Path]::GetFullPath((Join-Path $root $OutDir))
if (-not $outRoot.StartsWith($root + [System.IO.Path]::DirectorySeparatorChar)) { Fail "OutDir must stay inside the repository" }

# --- Read the TOC ---------------------------------------------------------
$tocLines = [System.IO.File]::ReadAllLines($tocPath)
$fields = @{}
$entries = New-Object System.Collections.Generic.List[string]
foreach ($line in $tocLines) {
  if ($line -match '^## ([\w\-]+):\s*(.*?)\s*$') { $fields[$Matches[1]] = $Matches[2] }
  elseif ($line -match '\S' -and -not $line.StartsWith('#')) { $entries.Add($line.Trim()) }
}
$version = $fields['Version']
if (-not $version) { Fail "TOC has no Version" }
if (-not $fields['Interface']) { Fail "TOC has no Interface" }
if ($version -notmatch '^\d+\.\d+\.\d+(-[0-9A-Za-z\.]+)?$') { Fail "Version '$version' is not SemVer" }

# --- Every TOC entry exists with exactly this case --------------------------
function Test-ExactPath([string]$base, [string]$relative) {
  $current = $base
  foreach ($segment in ($relative -split '[\\/]')) {
    $match = Get-ChildItem -LiteralPath $current -Force | Where-Object { $_.Name -ceq $segment }
    if (-not $match) { return $false }
    $current = $match.FullName
  }
  return $true
}
foreach ($entry in $entries) {
  if (-not (Test-ExactPath $addonDir $entry)) { Fail "TOC entry missing or with different case: $entry" }
}

# --- Versions agree ---------------------------------------------------------
$bootstrap = [System.IO.File]::ReadAllText((Join-Path $addonDir "Bootstrap.lua"))
if ($bootstrap -notmatch 'ns\.VERSION = "([^"]+)"') { Fail "ns.VERSION not found" }
if ($Matches[1] -ne $version) { Fail "Bootstrap version $($Matches[1]) differs from TOC $version" }
$changelog = [System.IO.File]::ReadAllText((Join-Path $root "CHANGELOG.md"))
if ($changelog -notmatch '(?m)^## \[?([\w\.\-]+)\]?') { Fail "CHANGELOG has no version heading" }
if ($Matches[1] -ne $version) { Fail "CHANGELOG top entry $($Matches[1]) differs from TOC $version" }

# --- Tests ------------------------------------------------------------------
if (-not $SkipTests) {
  $lua = Get-Command lua5.1 -ErrorAction SilentlyContinue
  if (-not $lua) { Fail "lua5.1 not found (use -SkipTests only for a documented reason)" }
  Push-Location $root
  try {
    & $lua.Source "tests/runner.lua"
    if ($LASTEXITCODE -ne 0) { Fail "offline tests failed" }
  } finally { Pop-Location }
}

# --- Stage ------------------------------------------------------------------
$staging = Join-Path $outRoot "staging"
if (Test-Path -LiteralPath $staging) {
  $resolved = (Resolve-Path -LiteralPath $staging).Path
  if (-not $resolved.StartsWith($outRoot)) { Fail "refusing to clean $resolved" }
  Remove-Item -LiteralPath $resolved -Recurse -Force
}
$stageAddon = Join-Path $staging $addonName
New-Item -ItemType Directory -Path $stageAddon -Force | Out-Null

$files = New-Object System.Collections.Generic.List[string]
$files.Add("$addonName.toc")
foreach ($entry in $entries) { $files.Add(($entry -replace '\\', '/')) }
$media = Join-Path $addonDir "Media/ForeverGold.tga"
if (Test-Path -LiteralPath $media) { $files.Add("Media/ForeverGold.tga") }
foreach ($relative in $files) {
  $from = Join-Path $addonDir $relative
  $to = Join-Path $stageAddon $relative
  New-Item -ItemType Directory -Path (Split-Path -Parent $to) -Force | Out-Null
  Copy-Item -LiteralPath $from -Destination $to
}
# Repository-level documents shipped inside the addon folder.
$licensePresent = $false
foreach ($doc in @("LICENSE", "README.md", "CHANGELOG.md")) {
  $path = Join-Path $root $doc
  if (Test-Path -LiteralPath $path) {
    Copy-Item -LiteralPath $path -Destination (Join-Path $stageAddon $doc)
    $files.Add($doc)
    if ($doc -eq "LICENSE") { $licensePresent = $true }
  }
}

# --- Zip with forward-slash entry names -------------------------------------
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zipName = "$addonName-$version.zip"
$zipPath = Join-Path $outRoot $zipName
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
$stream = [System.IO.File]::Open($zipPath, [System.IO.FileMode]::CreateNew)
$archive = New-Object System.IO.Compression.ZipArchive($stream, [System.IO.Compression.ZipArchiveMode]::Create)
try {
  foreach ($relative in ($files | Sort-Object)) {
    $entryName = "$addonName/" + ($relative -replace '\\', '/')
    $entry = $archive.CreateEntry($entryName, [System.IO.Compression.CompressionLevel]::Optimal)
    $entry.LastWriteTime = [DateTimeOffset]::new(2026, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
    $writer = $entry.Open()
    try {
      $bytes = [System.IO.File]::ReadAllBytes((Join-Path $stageAddon $relative))
      $writer.Write($bytes, 0, $bytes.Length)
    } finally { $writer.Dispose() }
  }
} finally {
  $archive.Dispose()
  $stream.Dispose()
}

# --- Verify the ZIP ---------------------------------------------------------
$check = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
try {
  $names = @($check.Entries | ForEach-Object { $_.FullName })
} finally { $check.Dispose() }
foreach ($name in $names) {
  if (-not $name.StartsWith("$addonName/")) { Fail "entry outside the root folder: $name" }
  if ($name -match '(^|/)(\.git|tests|fixtures|release|\.env)(/|$)' -or $name -match '\.(log|bak|tmp)$') { Fail "forbidden entry: $name" }
  if ($name.Contains('\')) { Fail "backslash in entry: $name" }
}
if ($names -notcontains "$addonName/$addonName.toc") { Fail "TOC is not directly under $addonName/" }
foreach ($entry in $entries) {
  if ($names -cnotcontains ("$addonName/" + ($entry -replace '\\', '/'))) { Fail "ZIP misses $entry" }
}

$hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
[System.IO.File]::WriteAllText("$zipPath.sha256", "$hash  $zipName`n")
$manifest = [ordered]@{
  addon = $addonName; version = $version; interface = $fields['Interface']; zip = $zipName; sha256 = $hash
  files = $names.Count; license = $licensePresent; inGameVerified = $false
}
[System.IO.File]::WriteAllText((Join-Path $outRoot "manifest.json"), ($manifest | ConvertTo-Json))
Remove-Item -LiteralPath $staging -Recurse -Force

Write-Output "Built $zipName ($($names.Count) files)"
Write-Output "SHA-256 $hash"
if (-not $licensePresent) { Write-Warning "No LICENSE at the repository root: the package is NOT ready for distribution." }
Write-Output "Status: alpha, not verified in game."
