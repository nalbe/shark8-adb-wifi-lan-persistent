# Build the KernelSU module zip with Unix permissions preserved.
# Usage: powershell -ExecutionPolicy Bypass -File build.ps1
# Output: release\shark8-adb-wifi-lan-persistent-<version>.zip
#         update.json at the repo root (KernelSU in-app update manifest, commit it)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$repo = "nalbe/shark8-adb-wifi-lan-persistent"

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$propPath = Join-Path $root "module\module.prop"

# version and versionCode are the single source of truth for the zip name,
# the tag and the update manifest
$version = $null
$versionCode = $null
foreach ($line in Get-Content $propPath) {
    if ($line -match "^version=(.+)$") { $version = $Matches[1].Trim() }
    elseif ($line -match "^versionCode=(\d+)$") { $versionCode = [int]$Matches[1] }
}
if (-not $version -or -not $versionCode) {
    throw "module\module.prop must define version= and versionCode="
}

# one paragraph per release, consumed by update.json and the release body
$notesPath = Join-Path $root "notes.txt"
if (-not (Test-Path $notesPath)) {
    throw "notes.txt is missing: write the changelog for v$version there before building"
}
$changelog = ((Get-Content $notesPath -Raw).Trim() -replace "\s*\r?\n\s*", " ")

$releaseDir = Join-Path $root "release"
if (-not (Test-Path $releaseDir)) { New-Item -ItemType Directory -Path $releaseDir | Out-Null }
$zipName = "shark8-adb-wifi-lan-persistent-$version.zip"
$zipPath = Join-Path $releaseDir $zipName
Remove-Item $zipPath -Force -ErrorAction SilentlyContinue

# entry name -> source file -> unix mode (0755 for scripts, 0644 otherwise)
$files = @(
    @{ entry = "module.prop"; src = "module\module.prop"; mode = 0x81A4 },
    @{ entry = "common.sh";   src = "module\common.sh";   mode = 0x81ED },
    @{ entry = "service.sh";  src = "module\service.sh";  mode = 0x81ED },
    @{ entry = "watch.sh";    src = "module\watch.sh";    mode = 0x81ED }
)

$fs = [System.IO.File]::Open($zipPath, [System.IO.FileMode]::CreateNew)
$archive = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($f in $files) {
        $entry = $archive.CreateEntry($f.entry, [System.IO.Compression.CompressionLevel]::Optimal)
        $entry.ExternalAttributes = $f.mode
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path $root $f.src))
        $stream = $entry.Open()
        try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
        Write-Host ("added {0} ({1} bytes, mode 0x{2:X4})" -f $f.entry, $bytes.Length, $f.mode)
    }
} finally {
    $archive.Dispose()
    $fs.Dispose()
}

$update = [ordered]@{
    version     = $version
    versionCode = $versionCode
    zipUrl      = "https://github.com/$repo/releases/download/v$version/$zipName"
    changelog   = $changelog
}
$json = ($update | ConvertTo-Json) -replace "\r\n", "`n"
[System.IO.File]::WriteAllText((Join-Path $root "update.json"), $json + "`n", (New-Object System.Text.UTF8Encoding($false)))

Write-Host ("built:   {0}" -f $zipPath)
Write-Host ("written: {0}" -f (Join-Path $root "update.json"))
