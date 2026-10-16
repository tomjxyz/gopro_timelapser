# Builds publish\GoProTimelapser.exe: a single self-contained exe with ffmpeg embedded.
# Requirements: .NET 8 SDK and an internet connection (only needed at build time).
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

$ffmpegDir = 'src\GoProTimelapser\ffmpeg'
$ffmpegExe = Join-Path $ffmpegDir 'ffmpeg.exe'

if (-not (Test-Path $ffmpegExe)) {
    # Static GPL build: includes libx264 and Intel QuickSync (libvpl) support.
    $url = 'https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-n7.1-latest-win64-gpl-7.1.zip'
    $zip = Join-Path $env:TEMP 'ffmpeg-win64.zip'
    $tmp = Join-Path $env:TEMP 'ffmpeg-win64'
    Write-Host "Downloading ffmpeg from $url"
    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    Expand-Archive -Path $zip -DestinationPath $tmp
    New-Item -ItemType Directory -Force -Path $ffmpegDir | Out-Null
    $found = Get-ChildItem -Path $tmp -Recurse -Filter 'ffmpeg.exe' | Select-Object -First 1
    if (-not $found) { throw 'ffmpeg.exe not found in downloaded archive' }
    Copy-Item $found.FullName $ffmpegExe
}

& $ffmpegExe -hide_banner -encoders | Select-String -Pattern 'h264_qsv|libx264'

dotnet publish src\GoProTimelapser\GoProTimelapser.csproj -c Release -o publish
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed" }

Get-Item publish\GoProTimelapser.exe | Format-Table Name, @{n='Size (MB)'; e={[math]::Round($_.Length / 1MB, 1)}}
