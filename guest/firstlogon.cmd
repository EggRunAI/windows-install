@echo off
REM EggRun e2e install gate -- first logon on the fresh Windows egg.
REM Runs from the install media (egg\firstlogon.cmd) as the autologged-on
REM administrator `egg`, via autounattend.xml FirstLogonCommands. @DROPBOX@ is
REM the host drop box (install.sh fills it in when it stages the media).
setlocal
set DB=@DROPBOX@
set MEDIA=%~dp0
set P=%TEMP%\egg-proof1.txt
echo stage=firstlogon> "%P%"
echo media=%MEDIA%>> "%P%"
net session >nul 2>&1 && (echo elevated=yes>> "%P%") || (echo elevated=no>> "%P%")
ver>> "%P%"
echo SecureBoot:>> "%P%"
powershell -NoProfile -Command "Confirm-SecureBootUEFI" >> "%P%" 2>&1
tpmtool getdeviceinformation >> "%P%" 2>&1
curl.exe -s -T "%P%" %DB%/w11-proof1.txt

REM 200%% scaling: 1080p shown on a 3840x2160 framebuffer (DISPLAY ... scale=2).
reg add "HKCU\Control Panel\Desktop" /v LogPixels /t REG_DWORD /d 192 /f
reg add "HKCU\Control Panel\Desktop" /v Win8DpiScaling /t REG_DWORD /d 1 /f

REM Every later cold boot lands on the desktop (the gate's second run, Nash's use).
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v AutoAdminLogon /t REG_SZ /d 1 /f
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v DefaultUserName /t REG_SZ /d egg /f
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v DefaultPassword /t REG_SZ /d "" /f
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v AutoLogonCount /f >nul 2>&1
reg delete "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v AutoLogonCount /f >nul 2>&1

REM Fast Startup off: a hibernate-resume boots blind against a host GPU that
REM has none of the saved state (egg-drivers/win-gpu/install.cmd has the story).
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power" /v HiberbootEnabled /t REG_DWORD /d 0 /f
REM No screen blanking or sleep: a black screenshot must mean a dead guest, not a timer.
powercfg -change monitor-timeout-ac 0
powercfg -change standby-timeout-ac 0

REM VirtIO GPU 3D driver (attestation-signed; Secure Boot stays on).
pnputil /add-driver "%MEDIA%drivers\viogpu3d\viogpu3d.inf" /install
REM Parenthesised on purpose: `echo x=%ERRORLEVEL%>> f` expands to `x=0>> f`, and cmd
REM reads `0>>` as a redirection of handle 0 -- the line never reached the file.
(echo pnputil=%ERRORLEVEL%)>> "%P%"
curl.exe -s -T "%P%" %DB%/w11-proof1.txt

REM The media may get another letter next boot: keep the second stage on C:.
mkdir C:\egg >nul 2>&1
copy /y "%MEDIA%postboot.cmd" C:\egg\postboot.cmd >nul
copy /y "%MEDIA%setmode.ps1" C:\egg\setmode.ps1 >nul
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\RunOnce" /v EggPostboot /t REG_SZ /d "C:\egg\postboot.cmd" /f

shutdown /r /t 10 /c "EggRun e2e: reboot into the GPU driver and 200% scaling"
endlocal
