# Ícono de "Video Downloader & Converter":
# cuadrado redondeado con degradado rosa->naranja, marco de video blanco con
# triángulo de reproducción rosa, y flecha de descarga amarilla debajo.
param(
    [string]$ProjectRoot = "$PSScriptRoot\.."
)

Add-Type -AssemblyName System.Drawing

$iconDir = Join-Path $ProjectRoot "assets"
New-Item -ItemType Directory -Force -Path $iconDir | Out-Null

$cPink   = [System.Drawing.Color]::FromArgb(255, 255, 45, 120)   # #FF2D78 (reserva)
$cRed1   = [System.Drawing.Color]::FromArgb(255, 255, 54, 54)     # #FF3636 (rojo claro)
$cRed2   = [System.Drawing.Color]::FromArgb(255, 196, 0, 0)       # #C40000 (rojo oscuro)
$cRedTri = [System.Drawing.Color]::FromArgb(255, 224, 0, 0)       # #E00000 (triángulo)
$cWhite  = [System.Drawing.Color]::White

function New-RoundRect([System.Drawing.Graphics]$g, [float]$x, [float]$y, [float]$w, [float]$h, [float]$r) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $p.AddArc($x, $y, $r * 2, $r * 2, 180, 90)
    $p.AddArc($x + $w - $r * 2, $y, $r * 2, $r * 2, 270, 90)
    $p.AddArc($x + $w - $r * 2, $y + $h - $r * 2, $r * 2, $r * 2, 0, 90)
    $p.AddArc($x, $y + $h - $r * 2, $r * 2, $r * 2, 90, 90)
    $p.CloseFigure()
    return $p
}

function New-IconBitmap([int]$size) {
    $bmp = New-Object System.Drawing.Bitmap($size, $size)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)

    $s = [float]$size
    $pad = [float]($s * 0.035)
    $r = [float]($s * 0.19)

    # Fondo con degradado rojo (diagonal)
    $path = New-RoundRect $g $pad $pad ($s - 2 * $pad) ($s - 2 * $pad) $r
    $d = New-Object System.Drawing.RectangleF($pad, $pad, ($s - 2 * $pad), ($s - 2 * $pad))
    $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush($d, $cRed1, $cRed2, 50)
    $g.FillPath($brush, $path)
    $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(70, 255, 255, 255), ([Math]::Max(1, $s / 120)))
    $g.DrawPath($pen, $path)

    # Marco de video blanco — centrado exacto en el icono
    $vx = $s * 0.315; $vy = $s * 0.278; $vw = $s * 0.370; $vh = $s * 0.204; $vr = $s * 0.037
    $frame = New-RoundRect $g $vx $vy $vw $vh $vr
    $g.FillPath((New-Object System.Drawing.SolidBrush($cWhite)), $frame)

    # Triángulo de reproducción rojo (dentro del marco)
    $cx = $s * 0.50; $cy = $s * 0.380
    $tw = $s * 0.10; $th = $s * 0.115
    $pts = @(
        (New-Object System.Drawing.PointF(($cx - $tw * 0.4), ($cy - $th / 2))),
        (New-Object System.Drawing.PointF(($cx - $tw * 0.4), ($cy + $th / 2))),
        (New-Object System.Drawing.PointF(($cx + $tw * 0.6), $cy))
    )
    $g.FillPolygon((New-Object System.Drawing.SolidBrush($cRedTri)), $pts)

    # Flecha de descarga blanca debajo del video (centrada)
    $ax = $s * 0.50
    $shaftW = $s * 0.056
    $shaftTop = $s * 0.537
    $shaftBot = $s * 0.611
    $g.FillRectangle((New-Object System.Drawing.SolidBrush($cWhite)),
        ($ax - $shaftW / 2), $shaftTop, $shaftW, ($shaftBot - $shaftTop))

    $headW = $s * 0.204
    $headY1 = $s * 0.583
    $headY2 = $s * 0.713
    $head = @(
        (New-Object System.Drawing.PointF(($ax - $headW / 2), $headY1)),
        (New-Object System.Drawing.PointF(($ax + $headW / 2), $headY1)),
        (New-Object System.Drawing.PointF($ax, $headY2))
    )
    $g.FillPolygon((New-Object System.Drawing.SolidBrush($cWhite)), $head)

    $g.Dispose()
    return $bmp
}

# PNG maestro de 512px
$master = New-IconBitmap 512
$master.Save((Join-Path $iconDir "icon.png"), [System.Drawing.Imaging.ImageFormat]::Png)
$master.Dispose()

# PNGs legacy para Android (mipmap)
$resDir = Join-Path $ProjectRoot "android\app\src\main\res"
$densities = @{ "mdpi" = 48; "hdpi" = 72; "xhdpi" = 96; "xxhdpi" = 144; "xxxhdpi" = 192 }
foreach ($d in $densities.Keys) {
    $bmp = New-IconBitmap $densities[$d]
    $bmp.Save((Join-Path $resDir "mipmap-$d\ic_launcher.png"), [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    Write-Host "OK mipmap-$d ($($densities[$d])px)"
}

# ICO para Windows (PNGs incrustados)
$icoSizes = @(16, 24, 32, 48, 64, 128, 256)
$pngBlobs = @()
foreach ($sz in $icoSizes) {
    $b = New-IconBitmap $sz
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
Write-Host "Iconos generados correctamente."
