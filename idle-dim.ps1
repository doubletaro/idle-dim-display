# idle-dim.ps1 - control the idle display dimmer: start | stop | status
param([Parameter(Mandatory=$true)][string]$Action)

$Task = "IdleDimWatcher"
$LogFile = "$env:USERPROFILE\bin\idle-dim.log"

switch ($Action.ToLower()) {
    "start" {
        Remove-Item "$env:USERPROFILE\bin\idle-dim.stop" -Force -ErrorAction SilentlyContinue
        schtasks /run /tn $Task | Out-Null
        Start-Sleep -Seconds 2
        $t = Get-ScheduledTask -TaskName $Task
        Write-Output ("idle-dim: " + $t.State)
    }
    "stop" {
        schtasks /end /tn $Task | Out-Null
        New-Item -ItemType File -Path "$env:USERPROFILE\bin\idle-dim.stop" -Force | Out-Null
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
            Where-Object { $_.CommandLine -match 'idle-dim-tray|idle-dim-wrapper|idle-dim-watcher' } |
            ForEach-Object { Stop-Process -Id ([int]$_.ProcessId) -Force }
        # restore brightness to full (DDC)
        powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\bin\ddc-restore.ps1"
        Write-Output "idle-dim: stopped (brightness restored)"
    }
    "status" {
        $t = Get-ScheduledTask -TaskName $Task -ErrorAction SilentlyContinue
        if ($t) { Write-Output ("task: " + $t.State) } else { Write-Output "task: NOT-INSTALLED" }
        $alive = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match 'idle-dim-tray|idle-dim-wrapper|idle-dim-watcher' }
        Write-Output ("processes: " + (@($alive).Count))
        if (Test-Path "$env:USERPROFILE\bin\idle-dim-config.json") {
            Write-Output ("config: " + ((Get-Content "$env:USERPROFILE\bin\idle-dim-config.json" -Raw) -replace "\s+", " ").Trim())
        }
        if (Test-Path $LogFile) {
            Write-Output "--- last 5 log lines ---"
            Get-Content $LogFile -Tail 5
        }
    }
    default { Write-Output "usage: idle-dim.ps1 start|stop|status" }
}
