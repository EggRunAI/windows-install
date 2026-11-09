@echo off
rem First logon of the autologged-on administrator `egg` (autounattend FirstLogonCommands).
rem Persists autologon, runs C:\egg\provision.cmd when the media carried one (your software,
rem e.g. Fusion), uploads proof1 to the host's drop box, plants the cold-boot proof, shuts down.
rem @DROPBOX@ is filled in by install.sh when it stages the media.
setlocal
set DB=@DROPBOX@
set P=%TEMP%\egg-proof1.txt
echo stage=firstlogon> "%P%"
net session >nul 2>&1 && (echo elevated=yes>> "%P%") || (echo elevated=no>> "%P%")
ver>> "%P%"
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v AutoAdminLogon /t REG_SZ /d 1 /f >nul
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v DefaultUserName /t REG_SZ /d egg /f >nul
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v DefaultPassword /t REG_SZ /d "" /f >nul
reg delete "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v AutoLogonCount /f >nul 2>&1
reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v AutoAdminLogon >> "%P%"
if exist C:\egg\provision.cmd (
  echo provision=start>> "%P%"
  call C:\egg\provision.cmd >> C:\egg-provision.txt 2>&1
  echo provision=%ERRORLEVEL%>> "%P%"
)
rem The cold-boot proof: a Startup entry that uploads proof2 on the next desktop, removes itself,
rem and shuts Windows down from inside (never cut a Windows egg from outside). The golden
rem carries nothing of this lane.
set SU=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup
(echo @echo off
 echo set P=%%TEMP%%\egg-proof2.txt
 echo echo stage=coldboot^> "%%P%%"
 echo reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v AutoAdminLogon ^>^> "%%P%%"
 echo wmic path win32_videocontroller get name,currenthorizontalresolution,currentverticalresolution ^>^> "%%P%%"
 echo curl.exe -s -T "%%P%%" %DB%/w11-proof2.txt
 echo shutdown /s /t 20 /f
 echo del "%%~f0") > "%SU%\egg-postboot.cmd"
curl.exe -s -T "%P%" %DB%/w11-proof1.txt
shutdown /s /t 10 /f
