# ==============================================================
# Fyxx POS Kiosk — Launcher Server
# Runs an HTTP server on localhost:8080.
# Launched by start.bat; do not run this script directly.
# ==============================================================

# ==============================================================
#  CONFIG  — edit ONLY this block
# ==============================================================
$AdminPassword = "Fyxx2024!"           # <-- CHANGE BEFORE GOING LIVE

$ServerPort    = 8080

# Full path to the Chrome executable (auto-detected if left empty)
$ChromeExe     = ""

# Full path to the By The Glass executable
# Set this before going live — the tile will show an error until it is set.
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
    Write-Log "Server ready — http://localhost:$ServerPort/"
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

        # GET / — serve the launcher page
        if ($path -eq "/" -or $path -eq "/index.html") {
            if (Test-Path $indexPath) {
                $bytes = [System.IO.File]::ReadAllBytes($indexPath)
                Send-Bytes $context $bytes "text/html; charset=utf-8"
            } else {
                Send-Text $context "index.html not found at $indexPath" 404
            }

        # GET /ping — health check used by start.bat
        } elseif ($path -eq "/ping") {
            Send-Text $context "OK"

        # POST /launch/odoo — open Odoo POS in a second Chrome window
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

        # POST /launch/btg — launch the By The Glass executable
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

        # POST /admin/exit — verify password then kill Chrome and stop server
        } elseif ($path -eq "/admin/exit") {
            $body = Read-Body $context
            try   { $data = $body | ConvertFrom-Json; $pw = $data.password }
            catch { $pw = "" }

            if ($pw -eq $AdminPassword) {
                Write-Log "Admin exit AUTHORIZED — shutting down"
                Send-Json $context @{ success = $true }
                Start-Sleep -Milliseconds 400          # let response reach the browser
                Stop-Process -Name "chrome" -Force -ErrorAction SilentlyContinue
                $listener.Stop()                       # exits the while loop
            } else {
                Write-Log "Admin exit DENIED — wrong password"
                Send-Json $context @{ success = $false; error = "Incorrect password." } 401
            }

        } else {
            Send-Text $context "Not Found" 404
        }

    } catch [System.Net.HttpListenerException] {
        break   # listener was stopped — clean shutdown
    } catch {
        Write-Log "Request error: $_"
        try { $context.Response.OutputStream.Close() } catch {}
    }
}

Write-Log "Launcher server stopped."
