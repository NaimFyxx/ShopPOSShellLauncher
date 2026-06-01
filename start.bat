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

:: ---- Clear any orphaned port 8080 binding -----------------
:: If a previous session was killed abruptly the PowerShell HttpListener
:: process or HTTP.sys reservation can hold port 8080, causing the next
:: start to fail with "conflicts with an existing registration".
echo [!date! !time!] Clearing any orphaned port 8080... >> "!LOG!"
for /f "tokens=5" %%p in ('netstat -ano 2^>nul ^| findstr /i "LISTENING" ^| findstr ":8080"') do (
    taskkill /PID %%p /F >nul 2>&1
)
netsh http delete urlacl url=http://localhost:8080/ >nul 2>&1

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
