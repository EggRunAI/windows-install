@echo off
rem Runs once at the end of Windows Setup, as SYSTEM, before the first logon. deploy.cmd copied
rem the media's egg\ folder to C:\egg, so nothing here depends on the media still being attached.
rem VirtIO guest tools (network, input, display, balloon); no sleep, no screen blanking, no Fast
rem Startup (a hibernate-resume boots blind on a host that has none of the saved GPU state).
echo %DATE% %TIME% setupcomplete start > C:\egg-setupcomplete.txt
if exist C:\egg\virtio-win-guest-tools.exe C:\egg\virtio-win-guest-tools.exe /passive /norestart >> C:\egg-setupcomplete.txt 2>&1
powercfg /change standby-timeout-ac 0 >nul
powercfg /change monitor-timeout-ac 0 >nul
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power" /v HiberbootEnabled /t REG_DWORD /d 0 /f >nul
echo %DATE% %TIME% setupcomplete done >> C:\egg-setupcomplete.txt
