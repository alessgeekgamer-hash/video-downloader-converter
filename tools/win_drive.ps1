# Helpers para controlar la app de Windows (clics + capturas).
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class WinDrive {
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, int dx, int dy, uint dwData, UIntPtr dwExtraInfo);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    public struct RECT { public int Left, Top, Right, Bottom; }
}
"@

function Get-ScreenShot([string]$path) {
    $b = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bmp = New-Object System.Drawing.Bitmap($b.Width, $b.Height)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($b.Left, $b.Top, 0, 0, $bmp.Size)
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
}

function Invoke-LeftClick([int]$x, [int]$y) {
    [WinDrive]::SetCursorPos($x, $y) | Out-Null
    Start-Sleep -Milliseconds 100
    [WinDrive]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero) | Out-Null
    Start-Sleep -Milliseconds 60
    [WinDrive]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero) | Out-Null
}

function Focus-App([string]$title) {
    $ws = New-Object -ComObject WScript.Shell
    $null = $ws.AppActivate($title)
    Start-Sleep -Milliseconds 400
}

function Send-AppKeys([string]$keys) {
    $ws = New-Object -ComObject WScript.Shell
    $ws.SendKeys($keys)
    Start-Sleep -Milliseconds 200
}
