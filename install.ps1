# install.ps1 - copy source to ~/bin and register the logon task
$src = $PSScriptRoot
$dst = "$env:USERPROFILE\bin"
if (-not (Test-Path $dst)) { New-Item -ItemType Directory -Path $dst | Out-Null }
Copy-Item "$src\*.ps1" $dst -Force
Copy-Item "$src\*.vbs" $dst -Force
Write-Output "copied to $dst"

powershell -NoProfile -ExecutionPolicy Bypass -File "$dst\ddc-probe.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File "$dst\register-idle-dim-task.ps1"
schtasks /run /tn IdleDimWatcher
Write-Output "installed. check: powershell $dst\idle-dim.ps1 status"
