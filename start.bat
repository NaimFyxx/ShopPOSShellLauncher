@echo off
setlocal EnableDelayedExpansion

:: ============================================================
:: Fyxx POS Kiosk — start.bat
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
:: WHY --kiosk and not --app + --start-fullscreen (v1 flags):
::   On Windows 10 Enterprise LTSC, --app mode creates a special
::   window type that conflicts with --start-fullscreen: Chrome opens
::   and immediately closes, producing the observed flicker loop.
::   --kiosk is Chrome's dedicated kiosk flag. It starts Chrome in
::   true fullscreen with no UI chrome (no address bar, no tabs, no
::   close button), is stable on Enterprise LTSC, and does not crash
::   on open. It is the correct flag for a locked-down POS kiosk.
::
:: WHY --user-data-dir:
::   An isolated profile directory prevents Chrome from showing the
::   "restore previous session?" bubble, which would block the kiosk
::   page from loading after any unexpected exit.
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
