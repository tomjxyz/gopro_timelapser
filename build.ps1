# Builds publish\GoProTimelapser.exe: a single self-contained exe with ffmpeg embedded.
# Requirements: .NET 8 SDK and an internet connection (only needed at build time).
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

$ffmpegDir = 'src\GoProTimelapser\ffmpeg'
$ffmpegExe = Join-Path $ffmpegDir 'ffmpeg.exe'

if (-not (Test-Path $ffmpegExe)) {
    # Static GPL build from BtbN: includes libx264 and Intel QuickSync (libvpl) support.
    # Asset names change with each ffmpeg release, so look them up rather than hard-coding one.
    $headers = @{ 'User-Agent' = 'gopro-timelapser-build' }
    if ($env:GITHUB_TOKEN) { $headers['Authorization'] = "Bearer $env:GITHUB_TOKEN" }
    $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/BtbN/FFmpeg-Builds/releases/tags/latest' -Headers $headers
    $names = $release.assets | ForEach-Object { $_.name }
    # Prefer the newest stable release branch (e.g. ffmpeg-n8.0-latest-win64-gpl-8.0.zip), else master.
    $asset = $release.assets |
        Where-Object { $_.name -match '^ffmpeg-n(\d+)\.(\d+)-latest-win64-gpl-[\d.]+\.zip$' } |
        Sort-Object { [int]($_.name -replace '^ffmpeg-n(\d+)\.(\d+).*', '$1') }, { [int]($_.name -replace '^ffmpeg-n(\d+)\.(\d+).*', '$2') } |
        Select-Object -Last 1
    if (-not $asset) { $asset = $release.assets | Where-Object { $_.name -eq 'ffmpeg-master-latest-win64-gpl.zip' } | Select-Object -First 1 }
    if (-not $asset) { throw "No win64-gpl ffmpeg build found. Assets: $($names -join ', ')" }
    $url = $asset.browser_download_url
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
