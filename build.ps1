# Build the KernelSU module zip with Unix permissions preserved.
# Usage: powershell -ExecutionPolicy Bypass -File build.ps1
# Output: shark8-adb-wifi-lan-persistent-<version>.zip next to this script.

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$modVars = Get-Content (Join-Path $root "module\module.prop") | Where-Object { $_ -match "^(version|versionCode)=" }
$version = ($modVars | Where-Object { $_ -like "version=*" }) -replace "version=", ""
if ([string]::IsNullOrWhiteSpace($version)) { $version = "3.1" }

$zipPath = Join-Path $root "shark8-adb-wifi-lan-persistent-$version.zip"
Remove-Item $zipPath -Force -ErrorAction SilentlyContinue

# entry name -> source file -> unix mode (0755 for scripts, 0644 otherwise)
$files = @(
    @{ entry = "module.prop";   src = "module\module.prop";   mode = 0x81A4 },
    @{ entry = "service.sh";    src = "module\service.sh";    mode = 0x81ED },
    @{ entry = "config.example"; src = "config.example";      mode = 0x81A4 }
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

Write-Host ("built: {0}" -f $zipPath)