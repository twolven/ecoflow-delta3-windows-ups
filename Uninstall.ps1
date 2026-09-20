<#
.SYNOPSIS
  Remove the NUT service and tray icon installed by Install.ps1. Run elevated.
  NUT files in -InstallDir are kept unless -Purge. Use -RestoreHidDriver to drop the WinUSB binding so
  Windows tries its own HID stack again (useful after an EcoFlow firmware update to test native support).
#>
[CmdletBinding()]
param([string]$InstallDir = 'C:\NUT', [switch]$RestoreHidDriver, [switch]$Purge)
$ErrorActionPreference = 'Continue'

Get-Process NutTray -ErrorAction SilentlyContinue | Stop-Process -Force
Unregister-ScheduledTask -TaskName 'NutTray' -Confirm:$false -ErrorAction SilentlyContinue
Get-ChildItem 'HKCU:\Control Panel\NotifyIconSettings' -ErrorAction SilentlyContinue | Where-Object {
    (Get-ItemProperty $_.PSPath).ExecutablePath -like '*\NutTray.exe' } | Remove-Item -Recurse
Write-Host 'tray icon removed'

if (Test-Path "$InstallDir\bin\nut.exe") {
    & "$InstallDir\bin\nut.exe" stop | Out-Null
    & "$InstallDir\bin\nut.exe" -U | Out-Null
    Write-Host 'NUT service removed'
}

if ($RestoreHidDriver) {
    # Delete the Zadig-generated WinUSB driver package for Interface 0; Windows falls back to hidusb on rescan.
    foreach ($d in (Get-PnpDevice | Where-Object { $_.InstanceId -like 'USB\VID_3746&PID_FFFF&MI_00\*' })) {
        pnputil /remove-device "$($d.InstanceId)" | Out-Null
    }
    $blocks = (pnputil /enum-drivers) -join "`n" -split "`n(?=Published Name)"
    foreach ($b in $blocks) {
        if ($b -match 'libwdi' -or $b -match 'EF-UPS') {
            $inf = [regex]::Match($b, 'oem\d+\.inf').Value
            if ($inf) { pnputil /delete-driver $inf /uninstall /force | Out-Null; Write-Host "removed driver package $inf" }
        }
    }
    pnputil /scan-devices | Out-Null
    Write-Host 'Interface 0 handed back to the Windows HID stack (expect Code 10 again unless the firmware is fixed)'
}

if ($Purge -and (Test-Path $InstallDir)) { Remove-Item $InstallDir -Recurse -Force; Write-Host "deleted $InstallDir" }
