# Prueba end-to-end de la pestaña Universal (solo UI Automation, sin clics).
param(
    [string]$ProjectRoot = "$PSScriptRoot\.."
)
. "$PSScriptRoot\win_uia.ps1"

function Get-ScreenShot([string]$path) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $b = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bmp = New-Object System.Drawing.Bitmap($b.Width, $b.Height)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($b.Left, $b.Top, 0, 0, $bmp.Size)
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
}

$exe = Join-Path $ProjectRoot "Entrega\PC\Video Downloader & Converter.exe"
$work = Join-Path $ProjectRoot "Entrega\PC"
$url = "https://archive.org/details/BigBuckBunny_124"
$shot = Join-Path $env:TEMP "uni_step.png"

$p = Start-Process $exe -WorkingDirectory $work -PassThru
Start-Sleep -Seconds 12
if ($p.HasExited) { "FALLO: la app salió al arrancar"; exit 1 }

$win = [VideoDownloaderUiA]::FindWindow("Video Downloader & Converter")
if ($win -eq $null) { "FALLO: ventana no encontrada"; Get-ScreenShot $shot; exit 1 }
"1) Ventana OK"

$tabU = [VideoDownloaderUiA]::FindByName($win, "Universal")
if ($tabU -eq $null) { "FALLO: pestaña Universal no encontrada"; [VideoDownloaderUiA]::Dump($win, 40); Get-ScreenShot $shot; exit 1 }
[VideoDownloaderUiA]::Invoke($tabU) | Out-Null
Start-Sleep -Seconds 2
"2) Pestaña Universal activada"

$edit = [VideoDownloaderUiA]::FindEdit($win)
if ($edit -eq $null -or -not [VideoDownloaderUiA]::SetValue($edit, $url)) {
    "FALLO: no se pudo escribir la URL"; Get-ScreenShot $shot; exit 1
}
"3) URL escrita: $url"

$btnSearch = [VideoDownloaderUiA]::FindButtonByText($win, "Buscar video")
if ($btnSearch -eq $null) { "FALLO: boton Buscar video no encontrado"; Get-ScreenShot $shot; exit 1 }
[VideoDownloaderUiA]::Invoke($btnSearch) | Out-Null
"4) Analizando..."
Start-Sleep -Seconds 18

Get-ScreenShot $shot
$dump = [VideoDownloaderUiA]::Dump($win, 250)
if ($dump -notlike "*Big Buck Bunny*") {
    "AVISO: no se vio la tarjeta del video aún"
} else {
    "5) Tarjeta del video visible (titulo + miniatura)"
}

$btnDl = [VideoDownloaderUiA]::FindButtonByText($win, "Descargar MP4")
if ($btnDl -eq $null) { $btnDl = [VideoDownloaderUiA]::FindButtonByText($win, "Descargar") }
if ($btnDl -eq $null) { "FALLO: boton de descarga no encontrado"; exit 1 }
[VideoDownloaderUiA]::Invoke($btnDl) | Out-Null
"6) Descarga iniciada"
Start-Sleep -Seconds 2

$tabHome = [VideoDownloaderUiA]::FindByName($win, "Inicio")
if ($tabHome) { [VideoDownloaderUiA]::Invoke($tabHome) | Out-Null }
Start-Sleep -Seconds 2

$done = $false
for ($i = 1; $i -le 40; $i++) {
    Start-Sleep -Seconds 5
    $d = [VideoDownloaderUiA]::Dump($win, 500)
    if ($d -like "*Completado*") { $done = $true; "7) Descarga COMPLETADA tras $($i * 5) s"; break }
    if ($d -like "*terminó con error*" -or $d -like "*Error de yt-dlp*" -or $d -like "*No se pudo*") {
        "7) ERROR REPORTADO POR LA APP:"; ($d -split "`n" | Where-Object { $_ -like "*rror*" } | Select-Object -First 3)
        $done = $true
        break
    }
    $mp4 = Get-ChildItem (Join-Path $env:USERPROFILE "Downloads\VideoDownloader") -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -gt (Get-Date).AddMinutes(-5) }
    if ($mp4) { $done = $true; "7) Archivo creado tras $($i * 5) s: $($mp4[-1].Name) (${[math]::Round($mp4[-1].Length/1MB,1)} MB)"; break }
}
if (-not $done) { "AVISO: no se confirmó la finalización en 200 s" }

Get-ScreenShot $shot
"PRUEBA TERMINADA"
