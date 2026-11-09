@echo off
rem Runs once at the end of Windows Setup, as SYSTEM, before the first logon.
rem VirtIO guest tools (network, input, display, balloon) so the first desktop has them;
rem no sleep or screen blanking: a black frame must mean a dead guest, not a timer.
echo %DATE% %TIME% setupcomplete start > C:\egg-setupcomplete.txt
for %%d in (D E F G H I J) do if exist %%d:\egg\virtio-win-guest-tools.exe set M=%%d:
if defined M %M%\egg\virtio-win-guest-tools.exe /passive /norestart >> C:\egg-setupcomplete.txt 2>&1
if defined M (mkdir C:\egg >nul 2>&1 & xcopy /e /y /q %M%\egg C:\egg\ >nul)
powercfg /change standby-timeout-ac 0 >nul
powercfg /change monitor-timeout-ac 0 >nul
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power" /v HiberbootEnabled /t REG_DWORD /d 0 /f >nul
echo %DATE% %TIME% setupcomplete done >> C:\egg-setupcomplete.txt
