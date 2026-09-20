# Dump-UsbDescriptors.ps1 — read a USB device's configuration descriptor (and the HID class descriptor's
# advertised report-descriptor length) through the parent hub's IOCTL_USB_GET_DESCRIPTOR_FROM_NODE_CONNECTION.
# No driver changes, no admin needed. Written to document the EcoFlow DELTA 3 Plus HID bug; works for any device.
param([string]$VidPid = 'VID_3746&PID_FFFF')

$dev = (Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -like "USB\$VidPid\*" } | Select-Object -First 1).InstanceId
if (-not $dev) { throw "No present USB device matching $VidPid" }
"device=$dev"
$parent = (Get-PnpDeviceProperty -InstanceId $dev -KeyName DEVPKEY_Device_Parent).Data
$loc = (Get-PnpDeviceProperty -InstanceId $dev -KeyName DEVPKEY_Device_LocationInfo).Data
$port = [int]([regex]::Match($loc,'Port_#(\d+)').Groups[1].Value)
$hubPath = "\\.\" + ($parent -replace '\\','#') + "#{f18a0e88-c30c-11d0-8815-00a0c906bed8}"
"hub=$hubPath port=$port"

Add-Type @"
using System; using System.Runtime.InteropServices; using Microsoft.Win32.SafeHandles;
public static class U {
 [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
 public static extern SafeFileHandle CreateFile(string f, uint a, uint s, IntPtr sa, uint c, uint fl, IntPtr t);
 [DllImport("kernel32.dll", SetLastError=true)]
 public static extern bool DeviceIoControl(SafeFileHandle h, uint code, byte[] i, int il, byte[] o, int ol, out int ret, IntPtr ov);
}
"@
$h = [U]::CreateFile($hubPath, 3221225472u, [uint32]3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
if ($h.IsInvalid) { throw "open hub failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())" }

function Req($type, $index, $wIndex, $len) {
  # USB_DESCRIPTOR_REQUEST: ULONG ConnectionIndex; SetupPacket{bmRequest,bRequest,wValue,wIndex,wLength}; Data[]
  $buf = New-Object byte[] (12 + $len)
  [BitConverter]::GetBytes([uint32]$port).CopyTo($buf,0)
  $buf[4]=0x80; $buf[5]=6
  [BitConverter]::GetBytes([uint16](($type -shl 8) -bor $index)).CopyTo($buf,6)
  [BitConverter]::GetBytes([uint16]$wIndex).CopyTo($buf,8)
  [BitConverter]::GetBytes([uint16]$len).CopyTo($buf,10)
  $out = New-Object byte[] (12 + $len); $ret=0
  $ok = [U]::DeviceIoControl($h, 0x220410, $buf, $buf.Length, $out, $out.Length, [ref]$ret, [IntPtr]::Zero)
  if (-not $ok) { return $null }
  return $out[12..($ret-1)]
}

$cfg = Req 2 0 0 9
$total = [BitConverter]::ToUInt16($cfg,2)
$cfg = Req 2 0 0 $total
"CONFIG descriptor ($($cfg.Length) bytes):"
($cfg | ForEach-Object { $_.ToString('x2') }) -join ' '
$i=0
while ($i -lt $cfg.Length) {
  $l=$cfg[$i]; $t=$cfg[$i+1]; if ($l -eq 0) { break }
  $d=$cfg[$i..($i+$l-1)]
  switch ($t) {
    4 { "  INTERFACE num=$($d[2]) alt=$($d[3]) eps=$($d[4]) class=0x$($d[5].ToString('x2')) sub=$($d[6]) prot=$($d[7])" }
    0x21 { "  HID descr: bcdHID=$($d[3].ToString('x2'))$($d[2].ToString('x2')) numDescr=$($d[5]) type=0x$($d[6].ToString('x2')) wDescriptorLength=$([BitConverter]::ToUInt16($d,7))" }
    5 { "  ENDPOINT addr=0x$($d[2].ToString('x2')) attr=$($d[3]) maxpkt=$([BitConverter]::ToUInt16($d,4)) interval=$($d[6])" }
    default { "  descr type=0x$($t.ToString('x2')) len=$l" }
  }
  $i += $l
}
# The hub IOCTL only issues device-recipient requests, so interface-level HID (0x21) / REPORT (0x22)
# descriptors usually cannot be fetched this way. Left in so the attempt is visible in the output.
$hid = Req 0x21 0 0 9
if ($hid) { "HID descr via GET_DESCRIPTOR(0x21): " + (($hid | ForEach-Object { $_.ToString('x2') }) -join ' ') } else { "GET_DESCRIPTOR(HID 0x21) via hub IOCTL: not returned" }
$rep = Req 0x22 0 0 1024
if ($rep) { "REPORT descriptor via GET_DESCRIPTOR(0x22): $($rep.Length) bytes`n" + (($rep | ForEach-Object { $_.ToString('x2') }) -join ' ') } else { "GET_DESCRIPTOR(REPORT 0x22) via hub IOCTL: not returned" }
$h.Close()
