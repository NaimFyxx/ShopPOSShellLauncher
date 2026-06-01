# ==============================================================
# Fyxx POS Kiosk — Panic Exit Listener
# Polls GetAsyncKeyState for Ctrl+Alt+Shift+Q and force-kills
# all kiosk processes when the combo is detected.
# Launched by start.bat alongside the HTTP server.
# ==============================================================

$LauncherDir = $PSScriptRoot
$LogFile     = Join-Path $LauncherDir "launcher.log"

function Write-Log($msg) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$ts  PANIC: $msg" | Out-File $LogFile -Append -Encoding UTF8
    Write-Host "$ts  PANIC: $msg"
}

# PInvoke GetAsyncKeyState — works from any process regardless of focus
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class KioskKeyboard {
    [DllImport("user32.dll")]
    public static extern short GetAsyncKeyState(int vKey);
}
"@ -ErrorAction SilentlyContinue

Write-Log "Panic listener started (Ctrl+Alt+Shift+Q to force-exit)"

while ($true) {
    # VK_CONTROL=0x11  VK_MENU(Alt)=0x12  VK_SHIFT=0x10  Q=0x51
    $ctrl  = ([KioskKeyboard]::GetAsyncKeyState(0x11) -band 0x8000) -ne 0
    $alt   = ([KioskKeyboard]::GetAsyncKeyState(0x12) -band 0x8000) -ne 0
    $shift = ([KioskKeyboard]::GetAsyncKeyState(0x10) -band 0x8000) -ne 0
    $q     = ([KioskKeyboard]::GetAsyncKeyState(0x51) -band 0x8000) -ne 0

    if ($ctrl -and $alt -and $shift -and $q) {
        Write-Log "Ctrl+Alt+Shift+Q detected — killing all kiosk processes"

        # Chrome (covers kiosk launcher + TGR Dine-In window)
        Stop-Process -Name "chrome"  -Force -ErrorAction SilentlyContinue

        # Sonos
        Stop-Process -Name "Sonos"   -Force -ErrorAction SilentlyContinue

        # Spotify
        Stop-Process -Name "Spotify" -Force -ErrorAction SilentlyContinue

        # Wine Monitor (process name has a space — match by wildcard)
        Get-Process | Where-Object { $_.Name -like "Wine Monitor*" } |
            Stop-Process -Force -ErrorAction SilentlyContinue

        # Launcher server (kill by command-line pattern; window-title
        # filtering is unreliable for hidden PS processes)
        Get-WmiObject Win32_Process | Where-Object {
            $_.Name -eq "powershell.exe" -and $_.CommandLine -like "*launcher_server*"
        } | ForEach-Object {
            Stop-Process -Id ([int]$_.ProcessId) -Force -ErrorAction SilentlyContinue
        }

        Write-Log "Panic exit complete"
        break
    }

    Start-Sleep -Milliseconds 150
}
