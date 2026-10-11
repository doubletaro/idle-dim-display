# register the IdleDimWatcher scheduled task (logon trigger, hidden, tray resident)
$action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument '"C:\Users\forev\bin\launch-idle-dim-tray.vbs"' -WorkingDirectory 'C:\Users\forev\bin'
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName 'IdleDimWatcher' -Action $action -Trigger $trigger -Settings $settings -Description 'Dim monitor backlight after input idle (DDC/CI), tray resident with settings GUI' -Force | Out-Null
Get-ScheduledTask -TaskName 'IdleDimWatcher' | Select-Object TaskName, State | Format-List
