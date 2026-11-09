@echo on
rem EggRun x86 Windows deploy, run by WinPE (winpeshl.ini) from the media image: load the VirtIO
rem drivers, find the media volume and the empty system disk, apply the Windows image with DISM,
rem add the drivers to it, plant the answer file and the egg scripts, write the boot entries,
rem and power off. The host detaches the media and boots the disk; Windows' own specialize and
rem OOBE passes then run from the planted unattend. @INDEX@ is the edition's image index,
rem filled in by install.sh (Windows 11 Pro).
drvload X:\drivers\viostor\viostor.inf
drvload X:\drivers\vioinput\vioinput.inf
drvload X:\drivers\netkvm\netkvm.inf
ping -n 6 127.0.0.1 >nul
set M=
for %%d in (C D E F G H) do if exist %%d:\sources\install.swm set M=%%d:
if "%M%"=="" (
  for /f "tokens=1,2,4" %%a in ('echo list volume ^| diskpart') do if /i "%%a"=="Volume" if /i "%%c"=="WIN11EGG" set V=%%b
  echo media volume %V% has no letter, assigning M:
  (echo select volume %V% & echo assign letter=M) > X:\av.txt
  diskpart /s X:\av.txt
  if exist M:\sources\install.swm set M=M:
)
if "%M%"=="" (echo NO MEDIA FOUND & echo list disk ^& list volume | diskpart & goto :fail)
echo media at %M%
set T=
for /f "tokens=1,2,4,5" %%a in ('echo list disk ^| diskpart') do if /i "%%a"=="Disk" if /i "%%d"=="GB" if %%c GTR 30 set T=%%b
if "%T%"=="" (echo NO TARGET DISK & echo list disk | diskpart & goto :fail)
echo target disk %T%
(echo select disk %T% & echo clean & echo convert gpt & echo create partition efi size=300 & echo format fs=fat32 quick label=System & echo assign letter=S & echo create partition msr size=16 & echo create partition primary & echo format fs=ntfs quick label=Windows & echo assign letter=W) > X:\part.txt
diskpart /s X:\part.txt || goto :fail
dism /Apply-Image /ImageFile:%M%\sources\install.swm /SWMFile:%M%\sources\install*.swm /Index:@INDEX@ /ApplyDir:W:\ || goto :fail
dism /Image:W:\ /Add-Driver /Driver:X:\drivers /Recurse || goto :fail
mkdir W:\Windows\Panther
copy /y X:\autounattend.xml W:\Windows\Panther\unattend.xml
mkdir W:\egg
xcopy /e /y %M%\egg W:\egg\
mkdir W:\Windows\Setup\Scripts
copy /y X:\SetupComplete.cmd W:\Windows\Setup\Scripts\SetupComplete.cmd
bcdboot W:\Windows /s S: /f UEFI || goto :fail
bcdedit /store S:\EFI\Microsoft\Boot\BCD /set {default} bootmenupolicy legacy
echo DEPLOY DONE > W:\egg-deploy-done.txt
wpeutil shutdown
exit
:fail
echo DEPLOY FAILED
cmd /k
