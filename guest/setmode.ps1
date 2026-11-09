# Set the primary display to the egg's framebuffer size and keep it across boots.
# The VirtIO GPU driver comes up at 1024x768 whatever the EDID says; this is the
# same call Settings > Display makes, with CDS_UPDATEREGISTRY so it persists.
param([int]$W = 3840, [int]$H = 2160)
Add-Type @"
using System; using System.Runtime.InteropServices;
public class EggDisp {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Ansi)]
  public struct DEVMODE {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmDeviceName;
    public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra; public int dmFields;
    public int dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
    public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmFormName;
    public short dmLogPixels; public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
    public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
  }
  [DllImport("user32.dll")] public static extern bool EnumDisplaySettings(string n, int i, ref DEVMODE d);
  [DllImport("user32.dll")] public static extern int ChangeDisplaySettings(ref DEVMODE d, int flags);
}
"@
$d = New-Object EggDisp+DEVMODE; $d.dmSize = [int16][Runtime.InteropServices.Marshal]::SizeOf($d)
[void][EggDisp]::EnumDisplaySettings($null, -1, [ref]$d)
"current: $($d.dmPelsWidth)x$($d.dmPelsHeight) @ $($d.dmDisplayFrequency) Hz"
$modes = @(); $i = 0; $m = New-Object EggDisp+DEVMODE; $m.dmSize = $d.dmSize
while ([EggDisp]::EnumDisplaySettings($null, $i, [ref]$m)) { $modes += "$($m.dmPelsWidth)x$($m.dmPelsHeight)@$($m.dmDisplayFrequency)"; $i++ }
"modes: " + (($modes | Select-Object -Unique) -join ' ')
$d.dmPelsWidth = $W; $d.dmPelsHeight = $H
$d.dmFields = 0x80000 -bor 0x100000   # DM_PELSWIDTH | DM_PELSHEIGHT
$rc = [EggDisp]::ChangeDisplaySettings([ref]$d, 1)   # CDS_UPDATEREGISTRY
"ChangeDisplaySettings(${W}x${H}) = $rc (0 = ok, -2 = mode not supported)"
[void][EggDisp]::EnumDisplaySettings($null, -1, [ref]$d)
"now: $($d.dmPelsWidth)x$($d.dmPelsHeight) @ $($d.dmDisplayFrequency) Hz"
