# kill all idle-dim-watcher instances, restore brightness, restart via task, verify count
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -match 'idle-dim-tray|idle-dim-watcher' } |
    ForEach-Object {
        Stop-Process -Id ([int]$_.ProcessId) -Force
        Write-Output ("killed " + $_.ProcessId)
    }
& "$env:USERPROFILE\bin\ddc-restore.ps1"
schtasks /run /tn IdleDimWatcher | Out-Null
Start-Sleep -Seconds 5
$alive = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match 'idle-dim-tray|idle-dim-watcher' }
Write-Output ("dimmer instances now: " + (@($alive).Count))
$alive | ForEach-Object { Write-Output ("  PID " + $_.ProcessId + " started " + $_.CreationDate) }
