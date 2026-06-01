# ==============================================================
# Fyxx POS Kiosk — Launcher Server
# Runs an HTTP server on localhost:8080.
# Launched by start.bat; do not run this script directly.
# ==============================================================

# ==============================================================
#  CONFIG  — edit ONLY this block
# ==============================================================
$AdminPassword = "admin1234"

$ServerPort    = 8080

# Full path to Chrome executable (auto-detected if left empty)
$ChromeExe     = ""

# TGR Dine-In — launched as a Chrome App via chrome_proxy
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
$BTGExe        = "C:\Users\NCR\AppData\Local\WineMonitor\Wine Monitor.exe"
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

        # GET / or /index.html — serve the launcher page
        if ($path -eq "/" -or $path -eq "/index.html") {
            if (Test-Path $indexPath) {
                Send-Bytes $context ([System.IO.File]::ReadAllBytes($indexPath)) "text/html; charset=utf-8"
            } else {
                Send-Text $context "index.html not found at $indexPath" 404
            }

        # GET /ping — health check used by start.bat readiness loop
        } elseif ($path -eq "/ping") {
            Send-Text $context "OK"

        # POST /launch/tgr — TGR Dine-In Chrome App
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
                Start-Process $SonosExe
                Send-Json $context @{ success = $true; app = "sonos" }
            } else {
                Write-Log "Sonos exe not found: $SonosExe"
                Send-Json $context @{ success = $false; error = "Sonos not found. Check SonosExe in CONFIG." } 503
            }

        # POST /launch/spotify
        } elseif ($path -eq "/launch/spotify") {
            Write-Log "Launching Spotify"
            if (Test-Path $SpotifyExe) {
                Start-Process $SpotifyExe
                Send-Json $context @{ success = $true; app = "spotify" }
            } else {
                Write-Log "Spotify exe not found: $SpotifyExe"
                Send-Json $context @{ success = $false; error = "Spotify not found. Check SpotifyExe in CONFIG." } 503
            }

        # POST /launch/btg — By The Glass (Wine Monitor)
        } elseif ($path -eq "/launch/btg") {
            Write-Log "Launching By The Glass"
            if (Test-Path $BTGExe) {
                Start-Process $BTGExe
                Send-Json $context @{ success = $true; app = "btg" }
            } else {
                Write-Log "BTG exe not found: $BTGExe"
                Send-Json $context @{ success = $false; error = "By The Glass not found. Check BTGExe in CONFIG." } 503
            }

        # POST /admin/exit — verify password, kill Chrome, stop server
        } elseif ($path -eq "/admin/exit") {
            $body = Read-Body $context
            try   { $data = $body | ConvertFrom-Json; $pw = $data.password }
            catch { $pw = "" }

            if ($pw -eq $AdminPassword) {
                Write-Log "Admin exit AUTHORIZED — shutting down"
                Send-Json $context @{ success = $true }
                Start-Sleep -Milliseconds 400    # let response reach browser
                Stop-Process -Name "chrome" -Force -ErrorAction SilentlyContinue
                $listener.Stop()                 # exits the while loop
            } else {
                Write-Log "Admin exit DENIED — wrong password"
                Send-Json $context @{ success = $false; error = "Incorrect password." } 401
            }

        } else {
            Send-Text $context "Not Found" 404
        }

    } catch [System.Net.HttpListenerException] {
        break   # listener stopped — clean shutdown
    } catch {
        Write-Log "Request error: $_"
        try { $context.Response.OutputStream.Close() } catch {}
    }
}

Write-Log "Launcher server stopped."
