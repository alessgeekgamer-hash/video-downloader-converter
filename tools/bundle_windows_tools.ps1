# Descarga yt-dlp.exe y ffmpeg.exe (build essentials) y los coloca en la
# carpeta de salida Release de la app de Windows.
param(
    [string]$ProjectRoot = "$PSScriptRoot\..",
    [string]$Config = "Release"
)

$ErrorActionPreference = "Stop"
$toolsDir = Join-Path $ProjectRoot "windows_tools"
New-Item -ItemType Directory -Force -Path $toolsDir | Out-Null

$ytdlpPath = Join-Path $toolsDir "yt-dlp.exe"
if (-not (Test-Path $ytdlpPath)) {
    Write-Host "Descargando yt-dlp.exe..."
    Invoke-WebRequest -Uri "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe" -OutFile $ytdlpPath
}

$ffmpegExe = Join-Path $toolsDir "ffmpeg.exe"
$ffprobeExe = Join-Path $toolsDir "ffprobe.exe"
if (-not (Test-Path $ffmpegExe)) {
    Write-Host "Descargando FFmpeg (puede tardar un par de minutos)..."
    $zip = Join-Path $toolsDir "ffmpeg.zip"
    Invoke-WebRequest -Uri "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip" -OutFile $zip
    Write-Host "Extrayendo FFmpeg..."
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zipFile = [System.IO.Compression.ZipFile]::OpenRead($zip)
    foreach ($entry in $zipFile.Entries) {
        if ($entry.Name -in @("ffmpeg.exe", "ffprobe.exe")) {
            $dest = Join-Path $toolsDir $entry.Name
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $dest, $true)
        }
    }
    $zipFile.Dispose()
    Remove-Item $zip -Force
}

$outDir = Join-Path $ProjectRoot "build\windows\x64\runner\$Config"
if (-not (Test-Path $outDir)) {
    Write-Host "No existe $outDir. Compila antes con: flutter build windows --release"
    exit 1
}
Copy-Item $ytdlpPath, $ffmpegExe, $ffprobeExe -Destination $outDir -Force
Write-Host "Herramientas copiadas en $outDir"
