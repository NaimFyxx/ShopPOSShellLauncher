# ============================================================
# Fyxx POS Kiosk — v2 One-Step Deployment
#
# HOW TO USE:
#   1. Open Notepad on the Windows machine.
#   2. Copy this entire file and paste into Notepad.
#   3. Save as  C:\POS_Launcher\deploy_v2.ps1
#   4. Open an Admin PowerShell window.
#   5. Run:  powershell -ExecutionPolicy Bypass -File "C:\POS_Launcher\deploy_v2.ps1"
#   6. Edit the CONFIG block in launcher_server.ps1 (password + BTG path).
#   7. Double-click start.bat (as Admin) to test.
# ============================================================

$D = "C:\POS_Launcher"

Write-Host ""
Write-Host "  Fyxx POS — deploying v2" -ForegroundColor Cyan
Write-Host "  Target: $D"
Write-Host ""

# Stop running launcher (chrome + the launcher_server PS process)
Stop-Process -Name chrome -Force -ErrorAction SilentlyContinue
Get-WmiObject Win32_Process | Where-Object {
    $_.Name -eq "powershell.exe" -and $_.CommandLine -like "*launcher_server*"
} | ForEach-Object {
    Stop-Process -Id ([int]$_.ProcessId) -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Milliseconds 1500

# Backup v1 files
foreach ($f in @("start.bat", "launcher_server.ps1", "index.html")) {
    $src = Join-Path $D $f
    if (Test-Path $src) {
        Copy-Item $src "$src.v1.bak" -Force
        Write-Host "  Backed up $f -> $f.v1.bak"
    }
}
Write-Host ""

# ── start.bat ────────────────────────────────────────────────
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

:: ---- Detect Chrome (64-bit then 32-bit install) -----------
set "CHROME=%ProgramFiles%\Google\Chrome\Application\chrome.exe"
if not exist "!CHROME!" (
    set "CHROME=%ProgramFiles(x86)%\Google\Chrome\Application\chrome.exe"
)
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
timeout /t 2 /nobreak >nul

:: ---- Start the PowerShell HTTP server (hidden window) -----
echo [!date! !time!] Starting launcher server... >> "!LOG!"
start "FyxxServer" /min powershell.exe ^
    -ExecutionPolicy Bypass ^
    -WindowStyle Hidden ^
    -NonInteractive ^
    -File "!DIR!launcher_server.ps1"

:: ---- Wait up to 30 s for the server to respond to /ping ---
echo [!date! !time!] Waiting for server on localhost:8080... >> "!LOG!"
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
    echo [!date! !time!] ERROR: Server did not respond within 30 s. >> "!LOG!"
    echo.
    echo  Launcher server failed to start. See launcher.log for details.
    echo.
    pause
    exit /b 1

:SERVER_READY
echo [!date! !time!] Server ready. Launching Chrome kiosk... >> "!LOG!"

:: ---- Launch Chrome in true kiosk mode ----------------------
::
:: --kiosk replaces the v1 --start-fullscreen flag.
:: Root cause of the v1 loop: Chrome was exiting after every load
:: because the restart loop in the old start.bat unconditionally
:: killed and restarted it every 3 seconds. Removing that loop
:: (and using --kiosk for a proper fullscreen lock) is the fix.
::
"!CHROME!" ^
    --kiosk ^
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

:: ---- Chrome has exited (admin exit or unexpected crash) ----
echo [!date! !time!] Chrome exited. Stopping server. >> "!LOG!"
taskkill /FI "WINDOWTITLE eq FyxxServer" /F >nul 2>&1
taskkill /IM powershell.exe /F            >nul 2>&1
echo [!date! !time!] Kiosk stopped. >> "!LOG!"

endlocal
'@

# ── launcher_server.ps1 ──────────────────────────────────────
$serverPs1 = @'
# ==============================================================
# Fyxx POS Kiosk -- Launcher Server
# Runs an HTTP server on localhost:8080.
# Launched by start.bat; do not run this script directly.
# ==============================================================

# ==============================================================
#  CONFIG  -- edit ONLY this block
# ==============================================================
$AdminPassword = "Fyxx2024!"           # <-- CHANGE BEFORE GOING LIVE

$ServerPort    = 8080

# Full path to the Chrome executable (auto-detected if left empty)
$ChromeExe     = ""

# Full path to the By The Glass executable
# Set this before going live -- the tile will show an error until it is set.
$BTGExe        = "C:\PLACEHOLDER\ByTheGlass.exe"   # <-- FILL IN BEFORE GOING LIVE

# Odoo POS URL
$OdooUrl       = "https://fyxx.odoo.com/odoo/point-of-sale"
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
    $candidates = @(
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { $ChromeExe = $c; break }
    }
}
if ([string]::IsNullOrEmpty($ChromeExe) -or -not (Test-Path $ChromeExe)) {
    Write-Log "ERROR: Chrome not found. Install Google Chrome or set ChromeExe in the CONFIG block."
    exit 1
}
Write-Log "Chrome:      $ChromeExe"
Write-Log "BTG exe:     $BTGExe"
Write-Log "Odoo URL:    $OdooUrl"

# ---------- HTTP helpers -------------------------------------
function Send-Bytes($context, $bytes, $contentType, $statusCode = 200) {
    $context.Response.StatusCode      = $statusCode
    $context.Response.ContentType     = $contentType
    $context.Response.ContentLength64 = $bytes.Length
    $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $context.Response.OutputStream.Close()
}

function Send-Json($context, $obj, $statusCode = 200) {
    $json  = $obj | ConvertTo-Json -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    Send-Bytes $context $bytes "application/json; charset=utf-8" $statusCode
}

function Send-Text($context, $text, $statusCode = 200) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
    Send-Bytes $context $bytes "text/plain; charset=utf-8" $statusCode
}

function Read-Body($context) {
    $reader = [System.IO.StreamReader]::new(
        $context.Request.InputStream,
        $context.Request.ContentEncoding
    )
    return $reader.ReadToEnd()
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

        # GET / -- serve the launcher page
        if ($path -eq "/" -or $path -eq "/index.html") {
            if (Test-Path $indexPath) {
                $bytes = [System.IO.File]::ReadAllBytes($indexPath)
                Send-Bytes $context $bytes "text/html; charset=utf-8"
            } else {
                Send-Text $context "index.html not found at $indexPath" 404
            }

        # GET /ping -- health check used by start.bat
        } elseif ($path -eq "/ping") {
            Send-Text $context "OK"

        # POST /launch/odoo -- open Odoo POS in a second Chrome window
        } elseif ($path -eq "/launch/odoo") {
            Write-Log "Launching Odoo POS"
            $odooProfile = Join-Path $LauncherDir "chrome_profile_odoo"
            $args = @(
                "--app=$OdooUrl",
                "--start-fullscreen",
                "--no-first-run",
                "--disable-infobars",
                "--disable-session-crashed-bubble",
                "--disable-restore-session-state",
                "--no-default-browser-check",
                "--password-store=basic",
                "--user-data-dir=`"$odooProfile`""
            )
            Start-Process $ChromeExe -ArgumentList $args
            Send-Json $context @{ success = $true; app = "odoo" }

        # POST /launch/btg -- launch the By The Glass executable
        } elseif ($path -eq "/launch/btg") {
            Write-Log "Launching By The Glass"
            if (Test-Path $BTGExe) {
                Start-Process $BTGExe
                Send-Json $context @{ success = $true; app = "btg" }
            } else {
                Write-Log "BTG exe not found: $BTGExe"
                Send-Json $context @{
                    success = $false
                    error   = "By The Glass executable not found. Update the BTGExe path in the CONFIG block of launcher_server.ps1."
                } 503
            }

        # POST /admin/exit -- verify password then kill Chrome and stop server
        } elseif ($path -eq "/admin/exit") {
            $body = Read-Body $context
            try   { $data = $body | ConvertFrom-Json; $pw = $data.password }
            catch { $pw = "" }

            if ($pw -eq $AdminPassword) {
                Write-Log "Admin exit AUTHORIZED -- shutting down"
                Send-Json $context @{ success = $true }
                Start-Sleep -Milliseconds 400
                Stop-Process -Name "chrome" -Force -ErrorAction SilentlyContinue
                $listener.Stop()
            } else {
                Write-Log "Admin exit DENIED -- wrong password"
                Send-Json $context @{ success = $false; error = "Incorrect password." } 401
            }

        } else {
            Send-Text $context "Not Found" 404
        }

    } catch [System.Net.HttpListenerException] {
        break
    } catch {
        Write-Log "Request error: $_"
        try { $context.Response.OutputStream.Close() } catch {}
    }
}

Write-Log "Launcher server stopped."
'@

# ── index.html ───────────────────────────────────────────────
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

    .header {
      flex: 0 0 22vh;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      gap: 0.5rem;
      padding: 1.5rem 2rem 1rem;
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
      font-size: clamp(3rem, 7.5vw, 5.5rem);
      font-weight: 300;
      letter-spacing: 0.45em;
      color: var(--gold-light);
      line-height: 1;
      cursor: default;
      padding: 0.25em 0.5em;
      touch-action: manipulation;
    }

    .tagline {
      font-size: clamp(0.65rem, 1.4vw, 0.85rem);
      font-weight: 400;
      letter-spacing: 0.3em;
      text-transform: uppercase;
      color: var(--text-sub);
    }

    .main {
      flex: 1;
      display: flex;
      align-items: center;
      justify-content: center;
      padding: 2vh 6vw;
      gap: 3vw;
    }

    .tile {
      flex: 1;
      min-width: 240px;
      max-width: 44vw;
      min-height: 220px;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      gap: 1.2rem;
      padding: clamp(1.5rem, 3vh, 2.5rem) clamp(1.5rem, 3vw, 2.5rem);
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

    .tile.pressed, .tile:active {
      background: var(--surface-hi);
      border-color: var(--gold);
      transform: scale(0.968);
      box-shadow: 0 0 0 2px var(--gold-dim), 0 20px 60px rgba(0,0,0,0.45);
    }

    .tile.pressed::after, .tile:active::after { opacity: 1; }

    .tile.launching {
      pointer-events: none;
      border-color: rgba(201,168,76,0.5);
    }

    .tile-icon {
      width: clamp(60px, 7.5vw, 90px);
      height: clamp(60px, 7.5vw, 90px);
      color: var(--gold);
      flex-shrink: 0;
    }

    .tile-icon svg { width: 100%; height: 100%; }

    .tile-spinner {
      display: none;
      width: clamp(28px, 3.5vw, 40px);
      height: clamp(28px, 3.5vw, 40px);
      border: 2px solid var(--gold-border);
      border-top-color: var(--gold);
      border-radius: 50%;
      animation: spin 0.65s linear infinite;
      flex-shrink: 0;
    }

    .tile.launching .tile-spinner { display: block; }
    .tile.launching .tile-icon    { display: none; }

    @keyframes spin { to { transform: rotate(360deg); } }

    .tile-label {
      font-size: clamp(1.1rem, 2.4vw, 1.65rem);
      font-weight: 600;
      letter-spacing: 0.04em;
      color: var(--text);
      text-align: center;
    }

    .tile-sub {
      font-size: clamp(0.7rem, 1.3vw, 0.9rem);
      font-weight: 300;
      letter-spacing: 0.1em;
      color: var(--text-sub);
      text-align: center;
      text-transform: uppercase;
    }

    .footer {
      flex: 0 0 14vh;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      gap: 0.35rem;
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
      font-size: clamp(1.6rem, 3.5vw, 2.6rem);
      font-weight: 300;
      color: var(--text-sub);
      letter-spacing: 0.12em;
    }

    .date-str {
      font-size: clamp(0.6rem, 1.1vw, 0.78rem);
      font-weight: 400;
      letter-spacing: 0.22em;
      text-transform: uppercase;
      color: var(--text-sub);
      opacity: 0.55;
    }

    #toast-container {
      position: fixed;
      bottom: 2.5rem;
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
      padding: 0.8rem 1.8rem;
      border-radius: 100px;
      font-size: clamp(0.8rem, 1.5vw, 0.9rem);
      font-weight: 500;
      letter-spacing: 0.04em;
      animation: toastIn 0.2s ease forwards, toastOut 0.25s ease 2.75s forwards;
    }

    .toast.info  { background: rgba(40,36,55,0.97);  border: 1px solid var(--gold-border); color: var(--text); }
    .toast.error { background: rgba(70,18,28,0.97);  border: 1px solid rgba(201,76,90,0.45); color: #f08090; }
    .toast.success { background: rgba(18,55,35,0.97); border: 1px solid rgba(76,180,110,0.45); color: #80d0a0; }

    @keyframes toastIn  { from { opacity:0; transform: translateY(12px) scale(0.96); } to { opacity:1; transform: translateY(0) scale(1); } }
    @keyframes toastOut { from { opacity:1; } to { opacity:0; transform: translateY(-6px); } }

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
      padding: clamp(1.8rem,4vh,2.8rem) clamp(2rem,5vw,3.2rem);
      width: min(500px, 88vw);
      display: flex;
      flex-direction: column;
      align-items: center;
      gap: 1.4rem;
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
      font-size: clamp(1.6rem, 3.5vw, 2rem);
      font-weight: 400;
      letter-spacing: 0.1em;
      color: var(--text);
    }

    .admin-modal p {
      font-size: clamp(0.75rem, 1.5vw, 0.88rem);
      font-weight: 300;
      color: var(--text-sub);
      text-align: center;
      line-height: 1.65;
    }

    #admin-pw {
      width: 100%;
      padding: 1rem 1.25rem;
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
      min-height: 58px;
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

    .admin-buttons { display: flex; gap: 0.85rem; width: 100%; }

    .btn {
      flex: 1;
      padding: 1rem;
      border: none;
      border-radius: var(--radius-btn);
      font-family: 'Raleway', sans-serif;
      font-size: 0.88rem;
      font-weight: 600;
      letter-spacing: 0.1em;
      text-transform: uppercase;
      cursor: pointer;
      min-height: 58px;
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

  <header class="header">
    <div class="wordmark" id="logo" role="button" aria-label="Fyxx -- triple-tap for admin">FYXX</div>
    <div class="tagline">Wine &amp; Spirits &nbsp;&middot;&nbsp; Amman</div>
  </header>

  <main class="main">

    <div class="tile" id="tile-odoo" role="button" aria-label="Launch Odoo Point of Sale">
      <div class="tile-icon" aria-hidden="true">
        <svg viewBox="0 0 48 48" fill="none" stroke="currentColor" stroke-width="1.8"
             stroke-linecap="round" stroke-linejoin="round">
          <rect x="6" y="10" width="36" height="28" rx="3.5"/>
          <rect x="12" y="17" width="10" height="8" rx="1.5"/>
          <line x1="26" y1="19" x2="36" y2="19"/>
          <line x1="26" y1="23" x2="36" y2="23"/>
          <line x1="12" y1="31" x2="36" y2="31"/>
          <rect x="16" y="38" width="16" height="4" rx="2"/>
          <line x1="9"  y1="38" x2="16" y2="38"/>
          <line x1="32" y1="38" x2="39" y2="38"/>
        </svg>
      </div>
      <div class="tile-spinner" aria-hidden="true"></div>
      <div class="tile-label">Odoo POS</div>
      <div class="tile-sub">Point of Sale</div>
    </div>

    <div class="tile" id="tile-btg" role="button" aria-label="Launch By The Glass">
      <div class="tile-icon" aria-hidden="true">
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
      <div class="tile-sub">Inventory &amp; Management</div>
    </div>

  </main>

  <footer class="footer">
    <div class="clock"    id="clock">--:--</div>
    <div class="date-str" id="date-str"></div>
  </footer>

  <div id="toast-container" aria-live="polite"></div>

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

    (function () {
      const clockEl  = document.getElementById('clock');
      const dateEl   = document.getElementById('date-str');
      const DAYS     = ['Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday'];
      const MONTHS   = ['January','February','March','April','May','June',
                        'July','August','September','October','November','December'];

      function tick() {
        const now = new Date();
        const h   = String(now.getHours()).padStart(2, '0');
        const m   = String(now.getMinutes()).padStart(2, '0');
        clockEl.textContent = h + ':' + m;
        dateEl.textContent  =
          DAYS[now.getDay()] + '  ·  ' + now.getDate() + ' ' +
          MONTHS[now.getMonth()] + ' ' + now.getFullYear();
      }

      tick();
      setInterval(tick, 15000);
    })();

    function showToast(message, type) {
      var container = document.getElementById('toast-container');
      var el = document.createElement('div');
      el.className   = 'toast ' + (type || 'info');
      el.textContent = message;
      container.appendChild(el);
      setTimeout(function () { el.remove(); }, 3200);
    }

    async function launchApp(endpoint, label, tileEl) {
      if (tileEl.classList.contains('launching')) return;
      tileEl.classList.add('launching');
      showToast('Launching ' + label + '…', 'info');
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
      var el = document.getElementById(id);
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

    bindTile('tile-odoo', '/launch/odoo', 'Odoo POS');
    bindTile('tile-btg',  '/launch/btg',  'By The Glass');

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
            errEl.textContent = 'Shutting down kiosk…';
          } else {
            errEl.style.color = 'var(--danger)';
            errEl.textContent = data.error || 'Incorrect password.';
            pwInput.classList.add('input-error');
            setTimeout(function () { pwInput.classList.remove('input-error'); }, 400);
            btnExit.disabled = false;
          }
        } catch (fetchErr) {
          errEl.style.color = '#5cc990';
          errEl.textContent = 'Kiosk shutting down…';
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

# ── Write all three files ─────────────────────────────────────
Write-Host "  Writing start.bat..."
[System.IO.File]::WriteAllText("$D\start.bat", $startBat, [System.Text.Encoding]::Default)

Write-Host "  Writing launcher_server.ps1..."
[System.IO.File]::WriteAllText("$D\launcher_server.ps1", $serverPs1, [System.Text.Encoding]::UTF8)

Write-Host "  Writing index.html..."
[System.IO.File]::WriteAllText("$D\index.html", $indexHtml, [System.Text.Encoding]::UTF8)

Write-Host ""
Write-Host "  v2 deployed successfully." -ForegroundColor Green
Write-Host ""
Write-Host "  BEFORE RUNNING start.bat:" -ForegroundColor Yellow
Write-Host "  Open C:\POS_Launcher\launcher_server.ps1 in Notepad."
Write-Host "  Find the CONFIG block at the top and change:"
Write-Host '    $AdminPassword = "Fyxx2024!"       <- set your real password'
Write-Host '    $BTGExe        = "C:\PLACEHOLDER\..." <- set real path to ByTheGlass.exe'
Write-Host ""
Write-Host "  Then right-click start.bat -> Run as administrator."
Write-Host ""
