# ==============================================================
# Fyxx POS Kiosk -- Deploy v3
# Run from an Administrator PowerShell window on the POS unit.
#
# Usage:
#   1. Copy this entire file to C:\POS_Launcher\deploy_v3.ps1
#   2. Open PowerShell as Administrator
#   3. cd C:\POS_Launcher
#   4. Set-ExecutionPolicy Bypass -Scope Process -Force
#   5. .\deploy_v3.ps1
#
# What it does:
#   - Creates C:\POS_Launcher\ if it does not exist
#   - Backs up existing v2 files to *.v2.bak
#   - Writes all four v3 files: start.bat, launcher_server.ps1,
#     panic_exit.ps1 (new), index.html
# ==============================================================

$Target = "C:\POS_Launcher"

if (-not (Test-Path $Target)) {
    New-Item -ItemType Directory -Path $Target -Force | Out-Null
    Write-Host "Created $Target"
}

function Backup-IfExists($name) {
    $src = Join-Path $Target $name
    $dst = Join-Path $Target ($name + ".v2.bak")
    if (Test-Path $src) {
        Copy-Item $src $dst -Force
        Write-Host "Backed up  $name  ->  $name.v2.bak"
    }
}

Backup-IfExists "start.bat"
Backup-IfExists "launcher_server.ps1"
Backup-IfExists "index.html"
# panic_exit.ps1 is new in v3 -- no prior backup needed

# ==============================================================
# 1 of 4 -- start.bat
# ==============================================================
$startBat = @'
@echo off
setlocal EnableDelayedExpansion

:: ============================================================
:: Fyxx POS Kiosk -- start.bat
:: Run as Administrator from C:\POS_Launcher\
:: ============================================================

set "DIR=%~dp0"
set "LOG=!DIR!launcher.log"

echo. >> "!LOG!"
echo [!date! !time!] ========== KIOSK SESSION START ========== >> "!LOG!"

:: ---- Detect Chrome ----------------------------------------
set "CHROME=%ProgramFiles%\Google\Chrome\Application\chrome.exe"
if not exist "!CHROME!" set "CHROME=%ProgramFiles(x86)%\Google\Chrome\Application\chrome.exe"
if not exist "!CHROME!" (
    echo [!date! !time!] ERROR: chrome.exe not found. >> "!LOG!"
    echo.
    echo  Chrome not found. Install Google Chrome and try again.
    echo.
    pause
    exit /b 1
)
echo [!date! !time!] Chrome: !CHROME! >> "!LOG!"

:: ---- Kill any Chrome leftover from a previous session -----
taskkill /IM chrome.exe /F >nul 2>&1
timeout /t 3 /nobreak >nul

:: ---- Start the PowerShell HTTP server (hidden window) -----
echo [!date! !time!] Starting launcher server... >> "!LOG!"
start "FyxxServer" /min powershell.exe ^
    -ExecutionPolicy Bypass ^
    -WindowStyle Hidden ^
    -NonInteractive ^
    -File "!DIR!launcher_server.ps1"

:: ---- Wait up to 30 s for server /ping --------------------
echo [!date! !time!] Waiting for server... >> "!LOG!"
set TRIES=0
:WAIT_LOOP
    set /a TRIES+=1
    if !TRIES! GTR 30 goto :SERVER_TIMEOUT
    powershell -NoProfile -NonInteractive -Command ^
      "try{Invoke-WebRequest -Uri 'http://localhost:8080/ping' -UseBasicParsing -TimeoutSec 1|Out-Null;exit 0}catch{exit 1}" ^
      >nul 2>&1
    if !errorlevel! EQU 0 goto :SERVER_READY
    timeout /t 1 /nobreak >nul
    goto :WAIT_LOOP

:SERVER_TIMEOUT
    echo [!date! !time!] ERROR: Server did not respond in 30 s. >> "!LOG!"
    echo.
    echo  Launcher server failed to start. See launcher.log for details.
    echo.
    pause
    exit /b 1

:SERVER_READY
echo [!date! !time!] Server ready. >> "!LOG!"

:: ---- Start the panic exit listener -----------------------
echo [!date! !time!] Starting panic listener (Ctrl+Alt+Shift+Q)... >> "!LOG!"
start "FyxxPanic" /min powershell.exe ^
    -ExecutionPolicy Bypass ^
    -WindowStyle Hidden ^
    -NonInteractive ^
    -File "!DIR!panic_exit.ps1"

:: ---- Clear stale Chrome singleton files ------------------
:: Chrome's launcher process checks these files to detect an existing
:: instance. If they survived a crash or force-kill, Chrome delegates
:: to the dead instance and the launcher process exits in ~180ms --
:: making start.bat see a false "exit" while the browser window is
:: still visible. Deleting them before launch prevents this.
if exist "!DIR!chrome_profile_kiosk\SingletonLock"   del /f /q "!DIR!chrome_profile_kiosk\SingletonLock"
if exist "!DIR!chrome_profile_kiosk\SingletonCookie" del /f /q "!DIR!chrome_profile_kiosk\SingletonCookie"
if exist "!DIR!chrome_profile_kiosk\SingletonSocket" del /f /q "!DIR!chrome_profile_kiosk\SingletonSocket"

:: ---- Launch Chrome ----------------------------------------
:: Launched with 'start ""' (non-blocking / fire-and-forget).
::
:: WHY: Chrome's initial chrome.exe is a singleton-checker/launcher.
:: It forks to a child "browser" process and exits in ~180ms. Running
:: Chrome synchronously (as v2 did) made start.bat see this fast exit,
:: skip to cleanup, and kill the server -- leaving the visible Chrome
:: window with no backend. The fix is to launch async and then poll
:: tasklist until ALL chrome.exe processes are gone.
::
:: --start-fullscreen is used instead of --kiosk during testing:
:: visually identical but Alt+F4 and OS-level exits still work.
:: Switch back to --kiosk only after end-to-end verification.
echo [!date! !time!] Launching Chrome... >> "!LOG!"
start "" "!CHROME!" ^
    --start-fullscreen ^
    --no-first-run ^
    --disable-infobars ^
    --disable-session-crashed-bubble ^
    --disable-restore-session-state ^
    --no-default-browser-check ^
    --disable-translate ^
    --disable-features=TranslateUI ^
    --password-store=basic ^
    --use-mock-keychain ^
    --user-data-dir="!DIR!chrome_profile_kiosk" ^
    "http://localhost:8080"

:: Give Chrome time to fork from launcher process to browser process
timeout /t 4 /nobreak >nul
echo [!date! !time!] Chrome launched -- polling for close... >> "!LOG!"

:: ---- Poll until all chrome.exe processes are gone --------
:CHROME_WAIT
    tasklist /FI "IMAGENAME eq chrome.exe" /NH 2>nul | findstr /i /c:"chrome.exe" >nul 2>&1
    if !errorlevel! EQU 0 (
        timeout /t 2 /nobreak >nul
        goto :CHROME_WAIT
    )

:: ---- Cleanup: kill server and panic listener by window title
:: Does NOT use 'taskkill /IM powershell.exe' -- that would kill
:: every PowerShell on the machine including the admin window.
echo [!date! !time!] Chrome closed -- stopping server and panic listener. >> "!LOG!"
taskkill /FI "WINDOWTITLE eq FyxxServer" /F /T >nul 2>&1
taskkill /FI "WINDOWTITLE eq FyxxPanic"  /F /T >nul 2>&1
echo [!date! !time!] Kiosk stopped. >> "!LOG!"

endlocal
'@

Set-Content -Path (Join-Path $Target "start.bat") -Value $startBat -Encoding ASCII
Write-Host "Written     start.bat"

# ==============================================================
# 2 of 4 -- launcher_server.ps1
# ==============================================================
$launcherServer = @'
# ==============================================================
# Fyxx POS Kiosk -- Launcher Server
# Runs an HTTP server on localhost:8080.
# Launched by start.bat; do not run this script directly.
# ==============================================================

# ==============================================================
#  CONFIG  -- edit ONLY this block
# ==============================================================
$AdminPassword = "admin1234"

$ServerPort    = 8080

# Full path to Chrome executable (auto-detected if left empty)
$ChromeExe     = ""

# TGR Dine-In -- launched as a Chrome App via chrome_proxy
$TGRExe        = "C:\Program Files\Google\Chrome\Application\chrome_proxy.exe"
$TGRArgs       = @(
    "--profile-directory=`"Profile 4`"",
    "--app-id=jpofjnaefngkijignheehkddokdjbglo"
)

# Sonos
$SonosExe      = "C:\Program Files (x86)\SonosV2\Sonos.exe"

# Spotify
$SpotifyExe    = "C:\Users\NCR\AppData\Roaming\Spotify\Spotify.exe"

# By The Glass (Wine Monitor)
$BTGExe        = "C:\Users\NCR\AppData\Local\WineMonitor\app-1.1.1\Wine Monitor.exe"
# ==============================================================
#  END CONFIG
# ==============================================================

$LauncherDir = $PSScriptRoot
$LogFile     = Join-Path $LauncherDir "launcher.log"

function Write-Log($msg) {
    $ts   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "$ts  $msg"
    $line | Out-File $LogFile -Append -Encoding UTF8
    Write-Host $line
}

# ---------- Auto-detect Chrome if path not specified ----------
if ([string]::IsNullOrEmpty($ChromeExe)) {
    foreach ($c in @(
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
    )) {
        if (Test-Path $c) { $ChromeExe = $c; break }
    }
}
if (-not (Test-Path $ChromeExe)) {
    Write-Log "ERROR: Chrome not found. Set ChromeExe in CONFIG block."
    exit 1
}
Write-Log "Chrome:  $ChromeExe"

# ---------- Win32 foreground-focus helper --------------------
# AttachThreadInput to Chrome's input thread gives reliable foreground
# lock so SetForegroundWindow actually steals focus from fullscreen Chrome.
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class KioskFocus {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmd);
    [DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    [DllImport("user32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
    public static void BringToFront(IntPtr hWnd) {
        uint dummy;
        IntPtr fg = GetForegroundWindow();
        uint fgThread = GetWindowThreadProcessId(fg, out dummy);
        uint myThread = GetCurrentThreadId();
        bool attached = (fgThread != myThread) && AttachThreadInput(myThread, fgThread, true);
        keybd_event(0, 0, 2, UIntPtr.Zero);
        ShowWindow(hWnd, 9);
        SetForegroundWindow(hWnd);
        if (attached) AttachThreadInput(myThread, fgThread, false);
    }
}
"@ -ErrorAction SilentlyContinue

function Start-AppFocused($exe, $argList = $null) {
    $name = [IO.Path]::GetFileNameWithoutExtension($exe)
    # Already running with a visible window: bring it front, skip relaunch
    $visible = Get-Process -Name $name -ErrorAction SilentlyContinue |
               Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero } |
               Select-Object -First 1
    if ($visible) { [KioskFocus]::BringToFront($visible.MainWindowHandle); return }
    # Not running, or tray-only: launch / wake it, then poll up to 5 s for a window
    if ($argList) { Start-Process $exe -ArgumentList $argList }
    else          { Start-Process $exe }
    for ($i = 0; $i -lt 50; $i++) {
        Start-Sleep -Milliseconds 100
        $w = Get-Process -Name $name -ErrorAction SilentlyContinue |
             Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero } |
             Select-Object -First 1
        if ($w) { [KioskFocus]::BringToFront($w.MainWindowHandle); break }
    }
}

# ---------- HTTP helpers -------------------------------------
function Send-Bytes($context, $bytes, $contentType, $statusCode = 200) {
    $context.Response.StatusCode      = $statusCode
    $context.Response.ContentType     = $contentType
    $context.Response.ContentLength64 = $bytes.Length
    $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $context.Response.OutputStream.Close()
}

function Send-Json($context, $obj, $statusCode = 200) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes(($obj | ConvertTo-Json -Compress))
    Send-Bytes $context $bytes "application/json; charset=utf-8" $statusCode
}

function Send-Text($context, $text, $statusCode = 200) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
    Send-Bytes $context $bytes "text/plain; charset=utf-8" $statusCode
}

function Read-Body($context) {
    ([System.IO.StreamReader]::new(
        $context.Request.InputStream,
        $context.Request.ContentEncoding
    )).ReadToEnd()
}

# ---------- Start the HTTP listener --------------------------
Write-Log "Starting server on port $ServerPort"
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://localhost:$ServerPort/")
try {
    $listener.Start()
    Write-Log "Server ready -- http://localhost:$ServerPort/"
} catch {
    Write-Log "ERROR starting server: $_"
    exit 1
}

$indexPath = Join-Path $LauncherDir "index.html"

# ---------- Request loop -------------------------------------
while ($listener.IsListening) {
    $context = $null
    try {
        $context = $listener.GetContext()
        $method  = $context.Request.HttpMethod
        $path    = $context.Request.Url.AbsolutePath
        Write-Log "$method $path"

        # GET / or /index.html -- serve the launcher page
        if ($path -eq "/" -or $path -eq "/index.html") {
            if (Test-Path $indexPath) {
                Send-Bytes $context ([System.IO.File]::ReadAllBytes($indexPath)) "text/html; charset=utf-8"
            } else {
                Send-Text $context "index.html not found at $indexPath" 404
            }

        # GET /ping -- health check used by start.bat readiness loop
        } elseif ($path -eq "/ping") {
            Send-Text $context "OK"

        # POST /launch/tgr -- TGR Dine-In Chrome App
        } elseif ($path -eq "/launch/tgr") {
            Write-Log "Launching TGR Dine-In"
            if (Test-Path $TGRExe) {
                Start-Process $TGRExe -ArgumentList $TGRArgs
                Send-Json $context @{ success = $true; app = "tgr" }
            } else {
                Write-Log "TGR exe not found: $TGRExe"
                Send-Json $context @{ success = $false; error = "TGR Dine-In not found. Check TGRExe in CONFIG." } 503
            }

        # POST /launch/sonos
        } elseif ($path -eq "/launch/sonos") {
            Write-Log "Launching Sonos"
            if (Test-Path $SonosExe) {
                Start-AppFocused $SonosExe
                Send-Json $context @{ success = $true; app = "sonos" }
            } else {
                Write-Log "Sonos exe not found: $SonosExe"
                Send-Json $context @{ success = $false; error = "Sonos not found. Check SonosExe in CONFIG." } 503
            }

        # POST /launch/spotify
        } elseif ($path -eq "/launch/spotify") {
            Write-Log "Launching Spotify"
            if (Test-Path $SpotifyExe) {
                Start-AppFocused $SpotifyExe
                Send-Json $context @{ success = $true; app = "spotify" }
            } else {
                Write-Log "Spotify exe not found: $SpotifyExe"
                Send-Json $context @{ success = $false; error = "Spotify not found. Check SpotifyExe in CONFIG." } 503
            }

        # POST /launch/btg -- By The Glass (Wine Monitor)
        } elseif ($path -eq "/launch/btg") {
            Write-Log "Launching By The Glass"
            if (Test-Path $BTGExe) {
                Start-AppFocused $BTGExe
                Send-Json $context @{ success = $true; app = "btg" }
            } else {
                Write-Log "BTG exe not found: $BTGExe"
                Send-Json $context @{ success = $false; error = "By The Glass not found. Check BTGExe in CONFIG." } 503
            }

        # POST /admin/exit -- verify password, kill Chrome, stop server
        } elseif ($path -eq "/admin/exit") {
            $body = Read-Body $context
            try   { $data = $body | ConvertFrom-Json; $pw = $data.password }
            catch { $pw = "" }

            if ($pw -eq $AdminPassword) {
                Write-Log "Admin exit AUTHORIZED -- shutting down"
                Send-Json $context @{ success = $true }
                Start-Sleep -Milliseconds 400    # let response reach browser
                Stop-Process -Name "chrome" -Force -ErrorAction SilentlyContinue
                $listener.Stop()                 # exits the while loop
            } else {
                Write-Log "Admin exit DENIED -- wrong password"
                Send-Json $context @{ success = $false; error = "Incorrect password." } 401
            }

        } else {
            Send-Text $context "Not Found" 404
        }

    } catch [System.Net.HttpListenerException] {
        break   # listener stopped -- clean shutdown
    } catch {
        Write-Log "Request error: $_"
        try { $context.Response.OutputStream.Close() } catch {}
    }
}

Write-Log "Launcher server stopped."
'@

Set-Content -Path (Join-Path $Target "launcher_server.ps1") -Value $launcherServer -Encoding UTF8
Write-Host "Written     launcher_server.ps1"

# ==============================================================
# 3 of 4 -- panic_exit.ps1  (new in v3)
# ==============================================================
$panicExit = @'
# ==============================================================
# Fyxx POS Kiosk -- Panic Exit Listener
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

# PInvoke GetAsyncKeyState -- works from any process regardless of focus
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
        Write-Log "Ctrl+Alt+Shift+Q detected -- killing all kiosk processes"

        # Chrome (covers kiosk launcher + TGR Dine-In window)
        Stop-Process -Name "chrome"  -Force -ErrorAction SilentlyContinue

        # Sonos
        Stop-Process -Name "Sonos"   -Force -ErrorAction SilentlyContinue

        # Spotify
        Stop-Process -Name "Spotify" -Force -ErrorAction SilentlyContinue

        # Wine Monitor (process name has a space -- match by wildcard)
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
'@

Set-Content -Path (Join-Path $Target "panic_exit.ps1") -Value $panicExit -Encoding UTF8
Write-Host "Written     panic_exit.ps1"

# ==============================================================
# 4 of 4 -- index.html
# ==============================================================
$indexHtml = @'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
  <meta name="theme-color" content="#16141a">
  <title>Fyxx -- POS Launcher</title>
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link href="https://fonts.googleapis.com/css2?family=Cormorant+Garamond:ital,wght@0,300;0,400;0,600;1,300&family=Raleway:wght@300;400;500;600&display=swap" rel="stylesheet">

  <style>
    :root {
      --bg:           #16141a;
      --surface:      #1c1920;
      --surface-hi:   #232030;
      --gold:         #c9a84c;
      --gold-light:   #dfc06a;
      --gold-dim:     rgba(201,168,76,0.15);
      --gold-border:  rgba(201,168,76,0.30);
      --text:         #f0ebe0;
      --text-sub:     #8a8090;
      --danger:       #c94c5a;
      --overlay:      rgba(10,8,14,0.94);
      --radius-tile:  20px;
      --radius-btn:   12px;
      --easing:       cubic-bezier(0.22, 1, 0.36, 1);
    }

    *, *::before, *::after {
      box-sizing: border-box;
      margin: 0;
      padding: 0;
      -webkit-tap-highlight-color: transparent;
    }

    html, body {
      width: 100%;
      height: 100%;
      overflow: hidden;
      background: var(--bg);
      color: var(--text);
      font-family: 'Raleway', 'Segoe UI', system-ui, sans-serif;
      user-select: none;
      -webkit-user-select: none;
      touch-action: manipulation;
    }

    body {
      display: flex;
      flex-direction: column;
      min-height: 100vh;
    }

    body::before {
      content: '';
      position: fixed;
      top: -30vh;
      left: 50%;
      transform: translateX(-50%);
      width: 70vw;
      height: 70vw;
      background: radial-gradient(circle, rgba(201,168,76,0.05) 0%, transparent 65%);
      pointer-events: none;
    }

    /* -- HEADER --------------------------------------------- */
    .header {
      flex: 0 0 18vh;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      gap: 0.4rem;
      padding: 1rem 2rem 0.75rem;
      position: relative;
    }

    .header::after {
      content: '';
      position: absolute;
      bottom: 0;
      left: 50%;
      transform: translateX(-50%);
      width: 60px;
      height: 1px;
      background: linear-gradient(90deg, transparent, var(--gold-border), transparent);
    }

    .wordmark {
      font-family: 'Cormorant Garamond', Georgia, 'Times New Roman', serif;
      font-size: clamp(2.5rem, 6vw, 4.5rem);
      font-weight: 300;
      letter-spacing: 0.45em;
      color: var(--gold-light);
      line-height: 1;
      cursor: default;
      padding: 0.25em 0.5em;
      touch-action: manipulation;
    }

    .tagline {
      font-size: clamp(0.6rem, 1.2vw, 0.8rem);
      font-weight: 400;
      letter-spacing: 0.3em;
      text-transform: uppercase;
      color: var(--text-sub);
    }

    /* -- MAIN -- 2x2 TILE GRID ------------------------------- */
    .main {
      flex: 1;
      display: grid;
      grid-template-columns: 1fr 1fr;
      grid-template-rows: 1fr 1fr;
      padding: 1.5vh 5vw;
      gap: 2vh 3vw;
      align-items: stretch;
    }

    /* -- TILES ---------------------------------------------- */
    .tile {
      min-width: 0;
      min-height: 120px;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      gap: 0.9rem;
      padding: clamp(1rem, 2.5vh, 2rem) clamp(1rem, 2.5vw, 2rem);
      background: var(--surface);
      border: 1px solid var(--gold-border);
      border-radius: var(--radius-tile);
      cursor: pointer;
      position: relative;
      overflow: hidden;
      transition:
        background 180ms var(--easing),
        border-color 180ms var(--easing),
        transform 150ms var(--easing),
        box-shadow 180ms var(--easing);
      touch-action: manipulation;
    }

    .tile::after {
      content: '';
      position: absolute;
      inset: 0;
      background: radial-gradient(ellipse at 50% -10%, var(--gold-dim) 0%, transparent 65%);
      opacity: 0;
      transition: opacity 180ms ease;
      pointer-events: none;
    }

    .tile.pressed,
    .tile:active {
      background: var(--surface-hi);
      border-color: var(--gold);
      transform: scale(0.968);
      box-shadow: 0 0 0 2px var(--gold-dim), 0 16px 48px rgba(0,0,0,0.45);
    }

    .tile.pressed::after,
    .tile:active::after { opacity: 1; }

    .tile.launching {
      pointer-events: none;
      border-color: rgba(201,168,76,0.5);
    }

    /* -- TILE ICON ------------------------------------------ */
    .tile-icon {
      width: clamp(44px, 5.5vw, 72px);
      height: clamp(44px, 5.5vw, 72px);
      color: var(--gold);
      flex-shrink: 0;
    }

    .tile-icon svg { width: 100%; height: 100%; }

    /* -- SPINNER (shown while launching) -------------------- */
    .tile-spinner {
      display: none;
      width: clamp(24px, 3vw, 36px);
      height: clamp(24px, 3vw, 36px);
      border: 2px solid var(--gold-border);
      border-top-color: var(--gold);
      border-radius: 50%;
      animation: spin 0.65s linear infinite;
      flex-shrink: 0;
    }

    .tile.launching .tile-spinner { display: block; }
    .tile.launching .tile-icon    { display: none; }

    @keyframes spin { to { transform: rotate(360deg); } }

    /* -- TILE TEXT ------------------------------------------ */
    .tile-label {
      font-size: clamp(0.95rem, 2vw, 1.45rem);
      font-weight: 600;
      letter-spacing: 0.04em;
      color: var(--text);
      text-align: center;
    }

    .tile-sub {
      font-size: clamp(0.65rem, 1.1vw, 0.85rem);
      font-weight: 300;
      letter-spacing: 0.1em;
      color: var(--text-sub);
      text-align: center;
      text-transform: uppercase;
    }

    /* -- FOOTER --------------------------------------------- */
    .footer {
      flex: 0 0 12vh;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      gap: 0.3rem;
      position: relative;
    }

    .footer::before {
      content: '';
      position: absolute;
      top: 0;
      left: 50%;
      transform: translateX(-50%);
      width: 60px;
      height: 1px;
      background: linear-gradient(90deg, transparent, var(--gold-border), transparent);
    }

    .clock {
      font-family: 'Cormorant Garamond', Georgia, serif;
      font-size: clamp(1.4rem, 3vw, 2.2rem);
      font-weight: 300;
      color: var(--text-sub);
      letter-spacing: 0.12em;
    }

    .date-str {
      font-size: clamp(0.55rem, 1vw, 0.72rem);
      font-weight: 400;
      letter-spacing: 0.22em;
      text-transform: uppercase;
      color: var(--text-sub);
      opacity: 0.55;
    }

    /* -- TOAST NOTIFICATIONS -------------------------------- */
    #toast-container {
      position: fixed;
      bottom: 2rem;
      left: 50%;
      transform: translateX(-50%);
      z-index: 300;
      display: flex;
      flex-direction: column;
      align-items: center;
      gap: 0.5rem;
      pointer-events: none;
      white-space: nowrap;
    }

    .toast {
      padding: 0.75rem 1.6rem;
      border-radius: 100px;
      font-size: clamp(0.75rem, 1.4vw, 0.88rem);
      font-weight: 500;
      letter-spacing: 0.04em;
      animation: toastIn 0.2s ease forwards, toastOut 0.25s ease 2.75s forwards;
    }

    .toast.info    { background: rgba(40,36,55,0.97);  border: 1px solid var(--gold-border); color: var(--text); }
    .toast.error   { background: rgba(70,18,28,0.97);  border: 1px solid rgba(201,76,90,0.45); color: #f08090; }
    .toast.success { background: rgba(18,55,35,0.97);  border: 1px solid rgba(76,180,110,0.45); color: #80d0a0; }

    @keyframes toastIn  { from { opacity:0; transform: translateY(10px) scale(0.96); } to { opacity:1; transform: translateY(0) scale(1); } }
    @keyframes toastOut { from { opacity:1; } to { opacity:0; transform: translateY(-6px); } }

    /* -- ADMIN OVERLAY -------------------------------------- */
    #admin-overlay {
      position: fixed;
      inset: 0;
      background: var(--overlay);
      z-index: 200;
      display: flex;
      align-items: center;
      justify-content: center;
      opacity: 0;
      pointer-events: none;
      transition: opacity 0.2s ease;
    }

    #admin-overlay.visible {
      opacity: 1;
      pointer-events: all;
    }

    .admin-modal {
      background: var(--surface);
      border: 1px solid var(--gold-border);
      border-radius: 24px;
      padding: clamp(1.6rem,4vh,2.6rem) clamp(1.8rem,5vw,3rem);
      width: min(500px, 88vw);
      display: flex;
      flex-direction: column;
      align-items: center;
      gap: 1.3rem;
      box-shadow: 0 40px 100px rgba(0,0,0,0.65);
      position: relative;
    }

    .admin-modal::before {
      content: '';
      position: absolute;
      top: 0; left: 50%;
      transform: translateX(-50%);
      width: 80%; height: 1px;
      background: linear-gradient(90deg, transparent, var(--gold-border), transparent);
    }

    .admin-modal h2 {
      font-family: 'Cormorant Garamond', Georgia, serif;
      font-size: clamp(1.5rem, 3vw, 1.9rem);
      font-weight: 400;
      letter-spacing: 0.1em;
      color: var(--text);
    }

    .admin-modal p {
      font-size: clamp(0.72rem, 1.4vw, 0.86rem);
      font-weight: 300;
      color: var(--text-sub);
      text-align: center;
      line-height: 1.65;
    }

    #admin-pw {
      width: 100%;
      padding: 0.9rem 1.2rem;
      background: var(--bg);
      border: 1px solid var(--gold-border);
      border-radius: var(--radius-btn);
      color: var(--text);
      font-family: 'Raleway', sans-serif;
      font-size: 1.1rem;
      letter-spacing: 0.18em;
      outline: none;
      transition: border-color 0.15s;
      touch-action: manipulation;
      min-height: 54px;
      -webkit-appearance: none;
    }

    #admin-pw:focus       { border-color: var(--gold); }
    #admin-pw.input-error { border-color: var(--danger); animation: shake 0.35s ease; }

    @keyframes shake {
      0%,100% { transform: translateX(0); }
      20%     { transform: translateX(-8px); }
      50%     { transform: translateX(8px); }
      75%     { transform: translateX(-5px); }
    }

    .modal-error {
      font-size: 0.8rem;
      font-weight: 400;
      min-height: 1.1em;
      text-align: center;
    }

    .admin-buttons { display: flex; gap: 0.8rem; width: 100%; }

    .btn {
      flex: 1;
      padding: 0.9rem;
      border: none;
      border-radius: var(--radius-btn);
      font-family: 'Raleway', sans-serif;
      font-size: 0.86rem;
      font-weight: 600;
      letter-spacing: 0.1em;
      text-transform: uppercase;
      cursor: pointer;
      min-height: 54px;
      transition: transform 130ms var(--easing), background 150ms ease;
      touch-action: manipulation;
    }

    .btn:active:not(:disabled) { transform: scale(0.96); }

    .btn-cancel {
      background: rgba(255,255,255,0.06);
      color: var(--text-sub);
      border: 1px solid rgba(255,255,255,0.08);
    }
    .btn-cancel:active { background: rgba(255,255,255,0.1); }

    .btn-exit { background: var(--gold); color: #0e0c12; }
    .btn-exit:active:not(:disabled) { background: var(--gold-light); }
    .btn-exit:disabled {
      background: rgba(201,168,76,0.3);
      color: rgba(14,12,18,0.5);
      cursor: default;
    }
  </style>
</head>
<body>

  <!-- -- HEADER (triple-tap FYXX wordmark to open admin modal) -->
  <header class="header">
    <div class="wordmark" id="logo" role="button" aria-label="Fyxx -- triple-tap for admin">FYXX</div>
    <div class="tagline">Wine &amp; Spirits &nbsp;&middot;&nbsp; Amman</div>
  </header>

  <!-- -- 2x2 TILE GRID ---------------------------------------- -->
  <main class="main">

    <!-- Row 1, Col 1 -- TGR Dine-In -->
    <div class="tile" id="tile-tgr" role="button" aria-label="Launch TGR Dine-In">
      <div class="tile-icon" aria-hidden="true">
        <!-- Fork + knife -->
        <svg viewBox="0 0 48 48" fill="none" stroke="currentColor" stroke-width="1.8"
             stroke-linecap="round" stroke-linejoin="round">
          <line x1="15" y1="6"  x2="15" y2="42"/>
          <line x1="11" y1="6"  x2="11" y2="16"/>
          <line x1="19" y1="6"  x2="19" y2="16"/>
          <path d="M11 16 Q15 21 19 16"/>
          <path d="M33 6 Q39 16 33 22"/>
          <line x1="33" y1="22" x2="33" y2="42"/>
        </svg>
      </div>
      <div class="tile-spinner" aria-hidden="true"></div>
      <div class="tile-label">TGR Dine-In</div>
      <div class="tile-sub">Table Service</div>
    </div>

    <!-- Row 1, Col 2 -- Sonos -->
    <div class="tile" id="tile-sonos" role="button" aria-label="Launch Sonos">
      <div class="tile-icon" aria-hidden="true">
        <!-- Speaker + sound waves -->
        <svg viewBox="0 0 48 48" fill="none" stroke="currentColor" stroke-width="1.8"
             stroke-linecap="round" stroke-linejoin="round">
          <path d="M8 18 L18 12 L18 36 L8 30 Z"/>
          <path d="M23 17 Q29 24 23 31"/>
          <path d="M27 12 Q38 24 27 36"/>
        </svg>
      </div>
      <div class="tile-spinner" aria-hidden="true"></div>
      <div class="tile-label">Sonos</div>
      <div class="tile-sub">Music Control</div>
    </div>

    <!-- Row 2, Col 1 -- Spotify -->
    <div class="tile" id="tile-spotify" role="button" aria-label="Launch Spotify">
      <div class="tile-icon" aria-hidden="true">
        <!-- Two musical notes on a shared beam -->
        <svg viewBox="0 0 48 48" fill="none" stroke="currentColor" stroke-width="1.8"
             stroke-linecap="round" stroke-linejoin="round">
          <line x1="19" y1="10" x2="19" y2="36"/>
          <line x1="19" y1="10" x2="37" y2="7"/>
          <line x1="37" y1="7"  x2="37" y2="32"/>
          <circle cx="15" cy="36" r="4"/>
          <circle cx="33" cy="32" r="4"/>
        </svg>
      </div>
      <div class="tile-spinner" aria-hidden="true"></div>
      <div class="tile-label">Spotify</div>
      <div class="tile-sub">Streaming</div>
    </div>

    <!-- Row 2, Col 2 -- By The Glass -->
    <div class="tile" id="tile-btg" role="button" aria-label="Launch By The Glass">
      <div class="tile-icon" aria-hidden="true">
        <!-- Wine glass -->
        <svg viewBox="0 0 48 48" fill="none" stroke="currentColor" stroke-width="1.8"
             stroke-linecap="round" stroke-linejoin="round">
          <path d="M14 6 H34 L30 22 A8 8 0 0 1 18 22 Z"/>
          <line x1="24" y1="30" x2="24" y2="42"/>
          <line x1="15" y1="42" x2="33" y2="42"/>
          <path d="M17.5 17 Q24 20.5 30.5 17" opacity="0.45"/>
        </svg>
      </div>
      <div class="tile-spinner" aria-hidden="true"></div>
      <div class="tile-label">By The Glass</div>
      <div class="tile-sub">Inventory</div>
    </div>

  </main>

  <!-- -- FOOTER ----------------------------------------------- -->
  <footer class="footer">
    <div class="clock"    id="clock">--:--</div>
    <div class="date-str" id="date-str"></div>
  </footer>

  <!-- -- TOAST CONTAINER -------------------------------------- -->
  <div id="toast-container" aria-live="polite"></div>

  <!-- -- ADMIN OVERLAY ---------------------------------------- -->
  <div id="admin-overlay" role="dialog" aria-modal="true" aria-label="Admin exit">
    <div class="admin-modal">
      <h2>Admin Exit</h2>
      <p>Enter the admin password to shut down the kiosk<br>and return to the Windows desktop.</p>
      <input type="password" id="admin-pw"
             placeholder="Password"
             autocomplete="off" autocorrect="off"
             autocapitalize="off" spellcheck="false">
      <div class="modal-error" id="modal-error" aria-live="polite"></div>
      <div class="admin-buttons">
        <button class="btn btn-cancel" id="btn-cancel">Cancel</button>
        <button class="btn btn-exit"   id="btn-exit">Exit Kiosk</button>
      </div>
    </div>
  </div>

  <script>
    'use strict';

    // -- CLOCK -------------------------------------------------
    (function () {
      var clockEl = document.getElementById('clock');
      var dateEl  = document.getElementById('date-str');
      var DAYS    = ['Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday'];
      var MONTHS  = ['January','February','March','April','May','June',
                     'July','August','September','October','November','December'];

      function tick() {
        var now = new Date();
        var h   = String(now.getHours()).padStart(2, '0');
        var m   = String(now.getMinutes()).padStart(2, '0');
        clockEl.textContent = h + ':' + m;
        dateEl.textContent  = DAYS[now.getDay()] + '  .  ' +
          now.getDate() + ' ' + MONTHS[now.getMonth()] + ' ' + now.getFullYear();
      }

      tick();
      setInterval(tick, 15000);
    })();

    // -- TOAST -------------------------------------------------
    function showToast(message, type) {
      var container = document.getElementById('toast-container');
      var el = document.createElement('div');
      el.className   = 'toast ' + (type || 'info');
      el.textContent = message;
      container.appendChild(el);
      setTimeout(function () { el.remove(); }, 3200);
    }

    // -- TILE LAUNCH -------------------------------------------
    async function launchApp(endpoint, label, tileEl) {
      if (tileEl.classList.contains('launching')) return;
      tileEl.classList.add('launching');
      showToast('Launching ' + label + '...', 'info');
      try {
        var res  = await fetch(endpoint, { method: 'POST' });
        var data = await res.json();
        if (!data.success) {
          showToast(data.error || 'Failed to launch. Check launcher.log.', 'error');
        }
      } catch (e) {
        showToast('Server not responding -- restart start.bat', 'error');
      } finally {
        setTimeout(function () { tileEl.classList.remove('launching'); }, 900);
      }
    }

    function bindTile(id, endpoint, label) {
      var el     = document.getElementById(id);
      var active = false;

      el.addEventListener('pointerdown', function () {
        active = true;
        el.classList.add('pressed');
      });
      el.addEventListener('pointerup', function () {
        el.classList.remove('pressed');
        if (active) launchApp(endpoint, label, el);
        active = false;
      });
      el.addEventListener('pointercancel', function () { el.classList.remove('pressed'); active = false; });
      el.addEventListener('pointerleave',  function () { el.classList.remove('pressed'); active = false; });
    }

    bindTile('tile-tgr',     '/launch/tgr',     'TGR Dine-In');
    bindTile('tile-sonos',   '/launch/sonos',   'Sonos');
    bindTile('tile-spotify', '/launch/spotify', 'Spotify');
    bindTile('tile-btg',     '/launch/btg',     'By The Glass');

    // -- TRIPLE-TAP ADMIN --------------------------------------
    (function () {
      var logo    = document.getElementById('logo');
      var overlay = document.getElementById('admin-overlay');
      var pwInput = document.getElementById('admin-pw');
      var errEl   = document.getElementById('modal-error');
      var btnExit = document.getElementById('btn-exit');
      var btnCan  = document.getElementById('btn-cancel');

      var tapCount = 0;
      var tapTimer = null;

      function recordTap() {
        tapCount++;
        clearTimeout(tapTimer);
        if (tapCount >= 3) {
          tapCount = 0;
          openModal();
        } else {
          tapTimer = setTimeout(function () { tapCount = 0; }, 1800);
        }
      }

      logo.addEventListener('touchstart', function (e) {
        e.preventDefault();
        recordTap();
      }, { passive: false });

      logo.addEventListener('click', recordTap);

      function openModal() {
        errEl.textContent = '';
        errEl.style.color = '';
        pwInput.value     = '';
        btnExit.disabled  = false;
        overlay.classList.add('visible');
        setTimeout(function () { pwInput.focus(); }, 120);
      }

      function closeModal() {
        overlay.classList.remove('visible');
        pwInput.value     = '';
        errEl.textContent = '';
        errEl.style.color = '';
      }

      overlay.addEventListener('pointerdown', function (e) {
        if (e.target === overlay) closeModal();
      });

      btnCan.addEventListener('pointerup', function (e) {
        e.stopPropagation();
        closeModal();
      });

      async function tryExit() {
        var pw = pwInput.value;
        if (!pw) {
          errEl.style.color = 'var(--danger)';
          errEl.textContent = 'Please enter the admin password.';
          return;
        }

        btnExit.disabled  = true;
        errEl.textContent = '';

        try {
          var res  = await fetch('/admin/exit', {
            method:    'POST',
            headers:   { 'Content-Type': 'application/json' },
            body:      JSON.stringify({ password: pw }),
            keepalive: true
          });
          var data = await res.json().catch(function () { return { success: true }; });

          if (data.success) {
            errEl.style.color = '#5cc990';
            errEl.textContent = 'Shutting down kiosk...';
          } else {
            errEl.style.color = 'var(--danger)';
            errEl.textContent = data.error || 'Incorrect password.';
            pwInput.classList.add('input-error');
            setTimeout(function () { pwInput.classList.remove('input-error'); }, 400);
            btnExit.disabled = false;
          }
        } catch (fetchErr) {
          // Chrome being killed causes fetch to throw -- that is the success path
          errEl.style.color = '#5cc990';
          errEl.textContent = 'Kiosk shutting down...';
        }
      }

      btnExit.addEventListener('pointerup', function (e) {
        e.stopPropagation();
        tryExit();
      });

      pwInput.addEventListener('keydown', function (e) {
        if (e.key === 'Enter')  tryExit();
        if (e.key === 'Escape') closeModal();
      });
    })();
  </script>

</body>
</html>
'@

Set-Content -Path (Join-Path $Target "index.html") -Value $indexHtml -Encoding UTF8
Write-Host "Written     index.html"

Write-Host ""
Write-Host "============================================="
Write-Host " v3 deployment complete."
Write-Host " Files written to: $Target"
Write-Host "============================================="
Write-Host ""
Write-Host "Next step:"
Write-Host "  cmd /c `"$Target\start.bat`""
Write-Host ""
Write-Host "Test sequence:"
Write-Host "  1. Immediately press Ctrl+Alt+Shift+Q -- should kill everything"
Write-Host "  2. Only if panic exit works: test tiles and admin modal"
