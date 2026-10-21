# Genera todos los íconos de la app a partir de una imagen fuente.
param(
    [string]$Source = "C:\Users\aless\Downloads\Gemini_Generated_Image_52kg3w52kg3w52kg.jpeg",
    [string]$ProjectRoot = "$PSScriptRoot\.."
)

Add-Type -AssemblyName System.Drawing

if (-not (Test-Path $Source)) { Write-Error "Imagen no encontrada: $Source"; exit 1 }

$src = [System.Drawing.Image]::FromFile($Source)
Write-Host "Fuente: $($src.Width)x$($src.Height)"

function New-SquareBitmap([System.Drawing.Image]$img, [int]$size) {
    # Recorte centrado al cuadrado + escala al tamaño pedido.
    $min = [Math]::Min($img.Width, $img.Height)
    $sx = [int](($img.Width - $min) / 2)
    $sy = [int](($img.Height - $min) / 2)
    $bmp = New-Object System.Drawing.Bitmap($size, $size)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.DrawImage($img, (New-Object System.Drawing.Rectangle(0, 0, $size, $size)),
        (New-Object System.Drawing.Rectangle($sx, $sy, $min, $min)),
        [System.Drawing.GraphicsUnit]::Pixel)
    $g.Dispose()
    return $bmp
}

# Color de fondo muestreado del borde de la imagen (zona roja)
$probe = New-SquareBitmap $src 64
$c = $probe.GetPixel(6, 32)
$hex = "#{0:X2}{1:X2}{2:X2}" -f $c.R, $c.G, $c.B
$probe.Dispose()
Write-Host "Color de fondo muestreado: $hex"

$iconDir = Join-Path $ProjectRoot "assets"
New-Item -ItemType Directory -Force -Path $iconDir | Out-Null

# Dibuja la imagen REDUCIDA y CENTRADA dentro de un lienzo, recortada con
# esquinas redondeadas, de modo que el lanzador la muestre COMPLETA.
function New-IconFgBitmap([System.Drawing.Image]$img, [int]$size, [double]$fill, [System.Drawing.Color]$bgColor) {
    $bmp = New-Object System.Drawing.Bitmap($size, $size)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    if ($bgColor.A -gt 0) { $g.Clear($bgColor) } else { $g.Clear([System.Drawing.Color]::Transparent) }
    $inner = [int]($size * $fill)
    $off = [int](($size - $inner) / 2)
    $r = [int]($inner * 0.18)
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $x = $off; $y = $off; $w = $inner; $h = $inner
    $path.AddArc($x, $y, $r * 2, $r * 2, 180, 90)
    $path.AddArc($x + $w - $r * 2, $y, $r * 2, $r * 2, 270, 90)
    $path.AddArc($x + $w - $r * 2, $y + $h - $r * 2, $r * 2, $r * 2, 0, 90)
    $path.AddArc($x, $y + $h - $r * 2, $r * 2, $r * 2, 90, 90)
    $path.CloseFigure()
    $g.SetClip($path)
    $g.DrawImage($img, (New-Object System.Drawing.Rectangle($off, $off, $inner, $inner)),
        (New-Object System.Drawing.Rectangle(0, 0, $img.Width, $img.Height)),
        [System.Drawing.GraphicsUnit]::Pixel)
    $g.Dispose()
    return $bmp
}

# PNG maestro (vista previa con el fondo rojo, como se ve en el teléfono)
$red = [System.Drawing.Color]::FromArgb(255, $c.R, $c.G, $c.B)
$master = New-IconFgBitmap $src 512 0.60 $red
$master.Save((Join-Path $iconDir "icon.png"), [System.Drawing.Imaging.ImageFormat]::Png)
$master.Dispose()

# Foreground adaptativo de Android (512px, fondo transparente: el color
# del lanzador rellena el resto y la imagen se ve SIEMPRE completa)
$resDir = Join-Path $ProjectRoot "android\app\src\main\res"
$fgDir = Join-Path $resDir "drawable-nodpi"
New-Item -ItemType Directory -Force -Path $fgDir | Out-Null
$transparent = [System.Drawing.Color]::Transparent
$fg = New-IconFgBitmap $src 512 0.60 $transparent
$fg.Save((Join-Path $fgDir "ic_launcher_fg.png"), [System.Drawing.Imaging.ImageFormat]::Png)
$fg.Dispose()
Write-Host "OK drawable-nodpi/ic_launcher_fg.png (imagen al 60%, centrada)"

# PNGs legacy (mipmap) — por si acaso
$densities = @{ "mdpi" = 48; "hdpi" = 72; "xhdpi" = 96; "xxhdpi" = 144; "xxxhdpi" = 192 }
foreach ($d in $densities.Keys) {
    $bmp = New-SquareBitmap $src $densities[$d]
    $bmp.Save((Join-Path $resDir "mipmap-$d\ic_launcher.png"), [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    Write-Host "OK mipmap-$d ($($densities[$d])px)"
}

# Color de fondo para el icono adaptativo
$colorsXml = @"
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="ic_launcher_background">$hex</color>
</resources>
"@
Set-Content -Path (Join-Path $resDir "values\colors.xml") -Value $colorsXml -Encoding UTF8
Write-Host "OK colors.xml ($hex)"

# ICO de Windows (PNGs incrustados, con esquinas redondeadas transparentes)
function New-RoundedBitmap([System.Drawing.Bitmap]$bmp) {
    $size = $bmp.Width
    $r = [int]($size * 0.18)
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $w = $size; $h = $size
    $path.AddArc(0, 0, $r * 2, $r * 2, 180, 90)
    $path.AddArc($w - $r * 2, 0, $r * 2, $r * 2, 270, 90)
    $path.AddArc($w - $r * 2, $h - $r * 2, $r * 2, $r * 2, 0, 90)
    $path.AddArc(0, $h - $r * 2, $r * 2, $r * 2, 90, 90)
    $path.CloseFigure()
    $out = New-Object System.Drawing.Bitmap($size, $size)
    $g = [System.Drawing.Graphics]::FromImage($out)
    $g.SetClip($path)
    $g.DrawImage($bmp, 0, 0, $size, $size)
    $g.Dispose()
    return $out
}

$icoSizes = @(16, 24, 32, 48, 64, 128, 256)
$pngBlobs = @()
foreach ($sz in $icoSizes) {
    $b0 = New-SquareBitmap $src $sz
    $b = New-RoundedBitmap $b0
    $b0.Dispose()
    $ms = New-Object System.IO.MemoryStream
    $b.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $pngBlobs += ,@($ms.ToArray(), $sz)
    $b.Dispose(); $ms.Dispose()
}
$icoPath = Join-Path $ProjectRoot "windows\runner\resources\app_icon.ico"
$fs = [System.IO.File]::Create($icoPath)
$bw = New-Object System.IO.BinaryWriter($fs)
$bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$icoSizes.Count)
$offset = 6 + 16 * $icoSizes.Count
foreach ($entry in $pngBlobs) {
    $data = $entry[0]; $sz = $entry[1]
    $byteSz = if ($sz -eq 256) { [byte]0 } else { [byte]$sz }
    $bw.Write($byteSz); $bw.Write($byteSz); $bw.Write([byte]0); $bw.Write([byte]0)
    $bw.Write([uint16]1); $bw.Write([uint16]32)
    $bw.Write([uint32]$data.Length); $bw.Write([uint32]$offset)
    $offset += $data.Length
}
foreach ($entry in $pngBlobs) { $bw.Write($entry[0]) }
$bw.Close(); $fs.Close()
Write-Host "OK app_icon.ico"

$src.Dispose()
Write-Host "Iconos generados desde la imagen fuente."
