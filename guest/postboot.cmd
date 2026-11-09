@echo off
REM EggRun e2e install gate -- second logon (RunOnce), after the reboot that
REM activated the GPU driver and the 200%% scaling. Uploads the proof the gate
REM judges and shuts Windows down so `egg build` completes.
setlocal
set DB=@DROPBOX@
set P=%TEMP%\egg-proof2.txt
timeout /t 25 /nobreak >nul
echo stage=postboot> "%P%"
REM The VirtIO GPU driver comes up at 1024x768 whatever the EDID says: switch to the
REM egg's framebuffer and persist it (what Settings > Display would do).
powershell -NoProfile -ExecutionPolicy Bypass -File C:\egg\setmode.ps1 -W 3840 -H 2160 >> "%P%" 2>&1
timeout /t 5 /nobreak >nul
reg query "HKCU\Control Panel\Desktop" /v LogPixels >> "%P%"
powershell -NoProfile -Command "Get-CimInstance Win32_VideoController | Select-Object Name,Status,CurrentHorizontalResolution,CurrentVerticalResolution,DriverVersion | Format-List" >> "%P%" 2>&1
powershell -NoProfile -Command "Get-PnpDevice -Class Display | Select-Object FriendlyName,Status,Problem | Format-List" >> "%P%" 2>&1
reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v AutoAdminLogon >> "%P%"
curl.exe -s -T "%P%" %DB%/w11-proof2.txt
shutdown /s /t 5 /c "EggRun e2e: install complete"
endlocal
