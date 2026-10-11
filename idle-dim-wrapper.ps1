# idle-dim-wrapper.ps1 - keeps the tray app alive: auto-restarts on crash,
# unless ~/bin/idle-dim.stop exists (written by idle-dim.ps1 stop) or the app exited 0 (user Exit).
$stopFile = "$env:USERPROFILE\bin\idle-dim.stop"
if (Test-Path $stopFile) { Remove-Item $stopFile -Force }
while ($true) {
    if (Test-Path $stopFile) { Remove-Item $stopFile -Force; break }
    $p = Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-STA','-WindowStyle','Hidden','-File',"$env:USERPROFILE\bin\idle-dim-tray.ps1" -PassThru -WindowStyle Hidden
    $p.WaitForExit()
    $rc = $p.ExitCode
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') tray exited rc=$rc" | Out-File "$env:USERPROFILE\bin\idle-dim.log" -Append -Encoding utf8
    if ((Test-Path $stopFile) -or ($rc -eq 0)) {
        if (Test-Path $stopFile) { Remove-Item $stopFile -Force }
        break
    }
    Start-Sleep -Seconds 3
}
