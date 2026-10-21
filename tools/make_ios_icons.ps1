# Genera los iconos de iOS desde la imagen fuente (sin alfa, esquinas rojas).
param(
    [string]$Source = "C:\Users\aless\Downloads\Gemini_Generated_Image_52kg3w52kg3w52kg.jpeg",
    [string]$ProjectRoot = "$PSScriptRoot\.."
)

Add-Type -AssemblyName System.Drawing

if (-not (Test-Path $Source)) { Write-Error "Imagen no encontrada"; exit 1 }
$src = [System.Drawing.Image]::FromFile($Source)
$setDir = Join-Path $ProjectRoot "ios\Runner\Assets.xcassets\AppIcon.appiconset"

# Color de fondo (rojo de la imagen)
$probeBmp = New-Object System.Drawing.Bitmap(32, 32)
$g0 = [System.Drawing.Graphics]::FromImage($probeBmp)
$g0.DrawImage($src, (New-Object System.Drawing.Rectangle(0, 0, 32, 32)))
$g0.Dispose()
$c = $probeBmp.GetPixel(5, 16)
$red = [System.Drawing.Color]::FromArgb(255, $c.R, $c.G, $c.B)
$probeBmp.Dispose()
Write-Host "Rojo de fondo: $($c.R),$($c.G),$($c.B)"

function New-IosIcon([int]$px) {
    # Fondo rojo completo + imagen recortada con esquinas redondeadas:
    # la mascara de iOS ve todo el diseno y las esquinas quedan rojas.
    $bmp = New-Object System.Drawing.Bitmap($px, $px, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.Clear($red)

    $r = [int]($px * 0.18)
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddArc(0, 0, $r * 2, $r * 2, 180, 90)
    $path.AddArc($px - $r * 2, 0, $r * 2, $r * 2, 270, 90)
    $path.AddArc($px - $r * 2, $px - $r * 2, $r * 2, $r * 2, 0, 90)
    $path.AddArc(0, $px - $r * 2, $r * 2, $r * 2, 90, 90)
    $path.CloseFigure()
    $g.SetClip($path)
    $g.DrawImage($src, (New-Object System.Drawing.Rectangle(0, 0, $px, $px)))
    $g.Dispose()
    return $bmp
}

# filename -> pixeles (size x scale)
$slots = [ordered]@{
    "Icon-App-20x20@1x.png" = 20
    "Icon-App-20x20@2x.png" = 40
    "Icon-App-20x20@3x.png" = 60
    "Icon-App-29x29@1x.png" = 29
    "Icon-App-29x29@2x.png" = 58
    "Icon-App-29x29@3x.png" = 87
    "Icon-App-40x40@1x.png" = 40
    "Icon-App-40x40@2x.png" = 80
    "Icon-App-40x40@3x.png" = 120
    "Icon-App-60x60@2x.png" = 120
    "Icon-App-60x60@3x.png" = 180
    "Icon-App-76x76@1x.png" = 76
    "Icon-App-76x76@2x.png" = 152
    "Icon-App-83.5x83.5@2x.png" = 167
    "Icon-App-1024x1024@1x.png" = 1024
}

$done = 0
foreach ($entry in $slots.GetEnumerator()) {
    $bmp = New-IosIcon $entry.Value
    $bmp.Save((Join-Path $setDir $entry.Key), [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    $done++
}
$src.Dispose()
Write-Host "$done iconos iOS generados en AppIcon.appiconset (24bpp, sin alfa)"
