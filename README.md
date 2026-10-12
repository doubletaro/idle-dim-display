# idle-dim-display

English | [日本語](README.ja.md) | [中文](README.zh.md)

A power-saving **system-tray resident** for Windows: dims the monitor backlight via DDC/CI when the keyboard/mouse is idle, and restores it within 1 second of any input. Designed for desktop PCs on AC power — the built-in Windows "dim display" option only applies on battery, so this tool talks to the monitor directly.

**Why it's useful:** you can change your desktop monitor's brightness from the app — no more poking the physical buttons on the monitor bezel through its clunky OSD menu. The tray icon and slider give you instant control from your chair, and the idle-dim cycle cuts power waste on top.

## Behavior

| Setting | Default |
|---|---|
| Idle time before dim | 3 min |
| Dimmed brightness | 30% |
| Poll interval | 1 s (restore latency ≤ 1 s; DDC traffic only at dim time) |
| Restore condition | Any input detected (idle < 10 s) |
| Re-dim protection after restore | 30 s |

- **Tray icon resident** (round icon: gold = watching, orange half-moon = dimmed, gray = paused). If hidden, drag it out of the taskbar overflow (`▲`) to keep it visible.
- **Double-click the icon** (or right-click → Settings) to open the settings dialog:
  - Idle minutes / dimmed brightness / poll interval as numeric fields → "Save and Apply" persists to JSON and takes effect immediately.
  - **Live brightness slider** applies via DDC/CI instantly while dragging (like the monitor's OSD). Slider changes also update the restore point, so the next idle-dim cycle returns to the right level.
  - **Language group**: 日本語 / English / 中文 — the dialog, tray menu and tooltip switch immediately; persisted on save.
- Tray menu: Settings / Dim test now / Restore to 100% / Pause / Exit.
- Restore always returns to the brightness captured right before dimming — manual brightness changes are respected.
- If no DDC/CI monitor responds, the tool does nothing (safe no-op).
- Single-instance guard (process enumeration + self-PID exclusion).
- **Self-healing**: `idle-dim-wrapper.ps1` (started by the logon task) restarts the tray automatically if it crashes (non-zero exit). Unhandled exceptions are logged to `~/bin/idle-dim.log` (`UI-EXCEPTION:` / `DOMAIN-EXCEPTION:` lines) instead of dying silently. `idle-dim.ps1 stop` writes an `idle-dim.stop` flag file so the wrapper stays stopped.

## Files

| File | Purpose |
|---|---|
| `idle-dim-tray.ps1` | **Main**: tray resident + settings GUI + DDC control (must be UTF-8 **with BOM** — BOM-less breaks PS 5.1 parsing) |
| `idle-dim-wrapper.ps1` | Keep-alive wrapper: auto-restarts the tray on crash; honors `idle-dim.stop` |
| `idle-dim.ps1` | CLI control: start / stop / status |
| `idle-dim-config.json` | Settings (deployed to `~/bin/`, written by the GUI) |
| `ddc-probe.ps1` | Check DDC/CI support and current brightness |
| `ddc-test.ps1` | One-shot dim → restore test |
| `ddc-restore.ps1` | Force brightness back to 100% |
| `restart-idle-dim.ps1` | Kill all instances → restore brightness → restart from the scheduled task |
| `register-idle-dim-task.ps1` | Register the `IdleDimWatcher` logon task |
| `launch-idle-dim-tray.vbs` | Hidden window launcher (tray app) |
| `launch-idle-dim.vbs` | (Legacy launcher for the old CLI watcher, kept for reference) |
| `install.ps1` | One-command setup (copy → probe → register → start) |

## Install (other PCs / re-setup)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

What it does: copies scripts to `~/bin` → probes DDC/CI → registers the logon task → starts the tray app.

## Usage

```powershell
# GUI: double-click the tray icon → settings dialog
# CLI:
powershell $env:USERPROFILE\bin\idle-dim.ps1 status   # state + config + last log lines
powershell $env:USERPROFILE\bin\idle-dim.ps1 stop     # stop + restore brightness to 100%
powershell $env:USERPROFILE\bin\idle-dim.ps1 start    # start again
powershell $env:USERPROFILE\bin\restart-idle-dim.ps1  # full restart
```

## Configuration

The GUI is the primary way to configure ("Save and Apply" takes effect immediately). To edit directly, change `~/bin/idle-dim-config.json`:

```json
{ "IdleMinutes": 3, "DimLevel": 30, "PollSec": 1, "Language": "ja" }
```

Then run `restart-idle-dim.ps1`.

## Gotchas (learned the hard way)

- **`schtasks /end` does not kill the child powershell** — the task's wscript exits immediately and the powershell survives. Always stop/restart via `restart-idle-dim.ps1` (process enumeration + kill).
- **Japanese/Chinese strings in `.ps1` require UTF-8 with BOM** — BOM-less files are read as ANSI (Shift-JIS) by PowerShell 5.1 and fail with nonsense token errors.
- **`New-Object Type(a, b + c)` passes 3 arguments** — comma binds tighter than `+`, so `(12, $y + 3)` becomes `(12, $y, 3)` and the constructor throws at runtime when the dialog opens. Parenthesize: `Point(12, ($y + 3))`.
- **`Add-Type` compiles with warnings-as-errors** — even an unused C# field is a build failure.
- **Event-handler scriptblocks cannot see function-local variables** — but `.GetNewClosure()` is not the fix: it re-binds `$script:` names to the closure module where they are all null ("Path cannot be null" on `Set-Content`). Store dialog controls in `$script:` variables and keep handlers un-closed.
- **A named mutex guard is unreliable via `New-Object` + `[ref]`** — use process enumeration with `$PID` self-exclusion instead.
- **Self-match when listing processes by command line** — a checker whose own command line contains the script name matches itself; always filter `$_.ProcessId -ne $PID`.
- **Inline PowerShell from git-bash mangles `$_`** — write a `.ps1` file instead.
- Log: `~/bin/idle-dim.log` — every state transition gets one timestamped line, which is the only practical way to verify a headless resident.
