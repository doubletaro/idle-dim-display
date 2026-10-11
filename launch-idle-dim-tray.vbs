' hidden launcher for idle-dim-tray.ps1 (tray resident)
CreateObject("Wscript.Shell").Run "powershell -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File ""C:\Users\forev\bin\idle-dim-tray.ps1""", 0, False
