# Fyxx POS Kiosk — Setup Guide

Device: **NCR_Bar** · Windows 10 Enterprise LTSC · `C:\POS_Launcher\`

---

## What Was Wrong (v1 Diagnosis)

v1 used `--app=http://localhost:8080 --start-fullscreen` to launch Chrome.
On Windows 10 Enterprise LTSC this flag combination is broken: Chrome opens
the app-mode window, attempts to go fullscreen, and immediately closes. The
3-second restart loop in `start.bat` then reopened it, producing the
continuous flicker loop. The PowerShell server itself was fine — the log
shows apps launching correctly on the rare frame when the page was visible.

## What Changed (v2 Fix)

| Area | v1 | v2 |
|---|---|---|
| Chrome launch flag | `--app=URL --start-fullscreen` | `--kiosk URL` |
| Restart loop | every 3 s unconditionally | Chrome stays open; no loop |
| Chrome profile | default profile | isolated `chrome_profile_kiosk\` |
| Session restore bubble | not suppressed | `--disable-restore-session-state` |
| Server readiness | Chrome started immediately | `start.bat` waits up to 30 s for `/ping` |
| Admin exit | not implemented | triple-tap logo → password modal → `POST /admin/exit` |
| Odoo window | same Chrome instance (broken) | new `--app` Chrome process on top of kiosk |

`--kiosk` is Chrome's dedicated kiosk mode: true fullscreen, no address bar,
no tabs, no close button, and stable on Enterprise LTSC.

---

## Pre-Flight Checklist

Before running anything, complete these steps:

### 1. Set the admin password

Open `launcher_server.ps1` and find the `CONFIG` block near the top.
Change the default password to something secure:

```powershell
$AdminPassword = "YourRealPassword"   # <-- change this
```

### 2. Set the By The Glass executable path

In the same `CONFIG` block:

```powershell
$BTGExe = "C:\ActualPath\ByTheGlass.exe"   # <-- fill in real path
```

Until this is set, tapping the **By The Glass** tile will show an error
toast but will not crash anything else.

### 3. Verify Chrome is installed

The server auto-detects Chrome at:
- `C:\Program Files\Google\Chrome\Application\chrome.exe`
- `C:\Program Files (x86)\Google\Chrome\Application\chrome.exe`

If Chrome is somewhere else, set the `$ChromeExe` variable in the same
`CONFIG` block.

---

## Testing (before registry change)

> **Do this before touching the registry.** Run `start.bat` manually from
> an admin CMD prompt. The Shell value stays as `explorer.exe` during all tests.

1. Open **Command Prompt as Administrator**.
2. `cd C:\POS_Launcher`
3. `start.bat`

**Expected sequence:**
- A minimised PowerShell window appears briefly, then hides.
- `launcher.log` gains a "Server ready" line within ~5 seconds.
- Chrome opens in full-screen kiosk mode showing the Fyxx launcher.
- The address bar, tabs, and window chrome are completely gone.
- The clock updates every 15 seconds.

**Test each feature:**

| Action | Expected result |
|---|---|
| Tap **Odoo POS** tile | Spinner shows briefly; a second Chrome window opens full-screen at the Odoo URL |
| Close Odoo Chrome (Alt+F4 or its own UI — it has an `×` title bar) | Kiosk launcher reappears |
| Tap **By The Glass** tile | BTG app launches (or error toast if path not yet set) |
| Triple-tap the **FYXX** wordmark | Admin password modal appears |
| Enter wrong password → tap Exit Kiosk | "Incorrect password" shakes the input |
| Enter correct password → tap Exit Kiosk | Chrome closes; the batch window exits cleanly |
| Check `launcher.log` | All events timestamped with no errors |

If Chrome closes immediately on step 3, check `launcher.log` for an error
line and verify the Chrome path in the CONFIG block.

---

## Enabling Shell Replacement (final step — do this last)

Once testing is complete, run this command in an **elevated CMD** to
replace Explorer as the shell for the `FyxxKiosk` user (or the user
account that runs the POS):

```cmd
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" ^
    /v Shell /t REG_SZ /d "C:\POS_Launcher\start.bat" /f
```

> **Warning:** This affects ALL users on the machine (HKLM key).
> To restrict it to a single user, use the HKCU equivalent while
> logged in as that user:
>
> ```cmd
> reg add "HKCU\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" ^
>     /v Shell /t REG_SZ /d "C:\POS_Launcher\start.bat" /f
> ```
>
> HKCU takes precedence over HKLM for that user only.

**To revert to Explorer** (recovery):
```cmd
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" ^
    /v Shell /t REG_SZ /d "explorer.exe" /f
```

---

## Exiting the Kiosk (staff procedure)

1. **Triple-tap** the FYXX wordmark in the header.
2. Enter the admin password.
3. Tap **Exit Kiosk**.

Chrome and the PowerShell server both shut down. If Shell Launcher is
active, Windows will restart `start.bat` automatically. To get a desktop,
use the registry revert command above from a remote session (AnyDesk) or
boot to Safe Mode.

---

## File Reference

| File | Purpose |
|---|---|
| `start.bat` | Entry point — starts server, launches Chrome, cleans up on exit |
| `launcher_server.ps1` | PowerShell HTTP server on `localhost:8080` |
| `index.html` | Branded launcher UI served by the PS server |
| `launcher.log` | Runtime event log (append-only, human-readable) |
| `chrome_profile_kiosk\` | Isolated Chrome profile for the launcher (auto-created) |
| `chrome_profile_odoo\` | Isolated Chrome profile for Odoo window (auto-created) |

---

## Troubleshooting

**Chrome still closes immediately**
→ Delete `chrome_profile_kiosk\` and retry. A corrupt profile can cause
  the same symptom.

**Server doesn't start**
→ Check if port 8080 is already in use:
  `netstat -ano | findstr :8080`
  Change `$ServerPort` in the CONFIG block if needed, and update the URL
  in `start.bat` to match.

**Fonts don't load (Cormorant Garamond / Raleway)**
→ The machine needs internet access for Google Fonts. The fallbacks
  (Georgia, Segoe UI) kick in automatically — the launcher still works.

**Admin password prompt doesn't accept keyboard input**
→ The Windows on-screen keyboard should pop up automatically on a
  touchscreen. If not, tap the password field to focus it, then tap
  the keyboard icon in the taskbar (Shell Launcher may hide the taskbar —
  test this before enabling Shell Launcher).
