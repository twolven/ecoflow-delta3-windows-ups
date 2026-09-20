<#
.SYNOPSIS
  Set up an EcoFlow DELTA 3 Plus / RIVER 3 Plus (USB ID 3746:FFFF) as a monitored UPS on Windows using
  Network UPS Tools, with a taskbar battery icon. Works around the firmware HID-descriptor bug that makes
  Windows' native "HID UPS Battery" fail with Code 10.

.DESCRIPTION
  Steps (each is idempotent; re-run freely):
    1. Download the NUT for Windows release and unpack it to -InstallDir (default C:\NUT).
    2. Write NUT config (standalone, upsd on 127.0.0.1 only, random upsmon password).
    3. Bind the WinUSB driver to the UPS's HID interface (Interface 0) with Zadig — ONE manual click.
    4. Install + start the "Network UPS Tools" service and verify it reads the battery.
    5. Install the tray icon (tray\NutTray.ps1) as a logon task and start it.

  Must be run elevated (service install, driver install).

.PARAMETER InstallDir
  Where NUT lives. Default C:\NUT.
.PARAMETER NutVersion
  NUT release tag to download. Default 2.8.5 (first release with the EcoFlow HID subdriver).
.PARAMETER LowBatteryPercent
  Charge % at which NUT declares LB and shuts the PC down. The EcoFlow reports its own LB threshold as 0,
  which would mean "never", so this is overridden. Default 15.
.PARAMETER SkipZadig
  Skip the driver step (already done, or you did it by hand).
.PARAMETER NoTray
  Don't install the tray icon.
#>
[CmdletBinding()]
param(
    [string]$InstallDir = 'C:\NUT',
    [string]$NutVersion = '2.8.5',
    [ValidateRange(5, 90)][int]$LowBatteryPercent = 15,
    [switch]$SkipZadig,
    [switch]$NoTray
)
$ErrorActionPreference = 'Stop'
$VidPid = 'VID_3746&PID_FFFF'
$UpsName = 'ecoflow'

function Step($m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "    $m" -ForegroundColor Green }
function Warn($m) { Write-Host "    $m" -ForegroundColor Yellow }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrators')
if (-not $isAdmin) { throw 'Run this from an elevated PowerShell (service + driver install need it).' }

# ---------------------------------------------------------------- 0. is the UPS even here?
Step "Looking for the EcoFlow on USB ($VidPid)"
$root = Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -like "USB\$VidPid\*" } | Select-Object -First 1
if (-not $root) { throw "No EcoFlow (USB\$VidPid) present. Plug the USB-C 'HID' port into this PC with a DATA cable and re-run." }
$hidIf = Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -like "USB\$VidPid&MI_00\*" } | Select-Object -First 1
$desc = (Get-PnpDeviceProperty -InstanceId $root.InstanceId -KeyName DEVPKEY_Device_BusReportedDeviceDesc).Data
Ok "Found: $desc ($($root.InstanceId))"
if ($hidIf) {
    $svc = (Get-PnpDeviceProperty -InstanceId $hidIf.InstanceId -KeyName DEVPKEY_Device_Service).Data
    $prob = (Get-PnpDeviceProperty -InstanceId $hidIf.InstanceId -KeyName DEVPKEY_Device_ProblemCode).Data
    Ok "HID interface: driver=$svc problem=$prob"
    if ($svc -eq 'HidUsb' -and $prob -eq 0) {
        Warn "Interface 0 is running under Windows' own HID stack with no error — your firmware may not have the bug."
        Warn "Check Device Manager > Batteries for 'HID UPS Battery' before continuing; if it is there you don't need this."
    }
} else {
    Warn 'No MI_00 child found — single-interface firmware? Continuing anyway.'
}

# ---------------------------------------------------------------- 1. NUT
Step "NUT for Windows $NutVersion -> $InstallDir"
if (Test-Path "$InstallDir\bin\usbhid-ups.exe") {
    Ok "already installed: $(& "$InstallDir\bin\usbhid-ups.exe" -V 2>&1 | Select-Object -First 1)"
} else {
    $rel = Invoke-RestMethod "https://api.github.com/repos/networkupstools/nut/releases/tags/v$NutVersion"
    $asset = $rel.assets | Where-Object { $_.name -like 'NUT-for-Windows-x86_64-RELEASE-*.7z' } |
             Sort-Object name -Descending | Select-Object -First 1     # prefers the "-fixNSS" respin if present
    if (-not $asset) { throw "No NUT-for-Windows asset on release v$NutVersion" }
    $tmp = Join-Path $env:TEMP "nut-$NutVersion"
    New-Item -ItemType Directory -Force $tmp | Out-Null
    $7z = @("$env:ProgramFiles\7-Zip\7z.exe", "$env:LOCALAPPDATA\Programs\7-Zip\7z.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $7z) { throw '7-Zip is required to unpack the NUT release (winget install 7zip.7zip).' }
    Write-Host "    downloading $($asset.name) ($([math]::Round($asset.size/1MB)) MB)"
    Invoke-WebRequest $asset.browser_download_url -OutFile "$tmp\nut.7z"
    & $7z x "$tmp\nut.7z" -o"$tmp\x" -y | Out-Null
    $mingw = Get-ChildItem "$tmp\x" -Recurse -Directory -Filter mingw64 | Select-Object -First 1
    if (-not $mingw) { throw 'mingw64 directory not found inside the NUT archive' }
    New-Item -ItemType Directory -Force $InstallDir | Out-Null
    Copy-Item "$($mingw.FullName)\*" $InstallDir -Recurse -Force
    Ok "installed: $(& "$InstallDir\bin\usbhid-ups.exe" -V 2>&1 | Select-Object -First 1)"
}

# ---------------------------------------------------------------- 2. config
Step 'NUT configuration'
$etc = "$InstallDir\etc"
$pw = -join ((48..57 + 65..90 + 97..122) | Get-Random -Count 24 | ForEach-Object { [char]$_ })
Set-Content "$etc\nut.conf" "MODE=standalone`n"
Set-Content "$etc\ups.conf" @"
[$UpsName]
    driver = usbhid-ups
    port = auto
    vendorid = 3746
    productid = ffff
    desc = "$desc"
    pollfreq = 10
    # The firmware reports battery.charge.low = 0, so NUT would never raise LB. Compute it ourselves.
    ignorelb
    override.battery.charge.low = $LowBatteryPercent
    override.battery.runtime.low = 0
"@
Set-Content "$etc\upsd.conf" "LISTEN 127.0.0.1 3493`n"
Set-Content "$etc\upsd.users" @"
[monuser]
    password = $pw
    upsmon primary
"@
Set-Content "$etc\upsmon.conf" @"
MONITOR $UpsName@127.0.0.1 1 monuser $pw primary
MINSUPPLIES 1
SHUTDOWNCMD "C:\\Windows\\System32\\shutdown.exe /s /t 30 /c \"UPS battery low - NUT is shutting the PC down\""
POLLFREQ 5
POLLFREQALERT 5
HOSTSYNC 15
DEADTIME 30
POWERDOWNFLAG "$($etc -replace '\\','\\')\\killpower"
RBWARNTIME 43200
NOCOMMWARNTIME 300
FINALDELAY 5
"@
Ok "wrote nut.conf ups.conf upsd.conf upsd.users upsmon.conf (LB at $LowBatteryPercent%)"

# ---------------------------------------------------------------- 3. WinUSB on Interface 0
Step 'Driver for the HID interface (Interface 0)'
$svcNow = if ($hidIf) { (Get-PnpDeviceProperty -InstanceId $hidIf.InstanceId -KeyName DEVPKEY_Device_Service).Data } else { '' }
if ($svcNow -in 'WinUSB', 'libusbK', 'libusb0') {
    Ok "already bound to $svcNow"
} elseif ($SkipZadig) {
    Warn "-SkipZadig given; interface is on '$svcNow'. usbhid-ups will not be able to open it until it is on WinUSB."
} else {
    $tmp = Join-Path $env:TEMP 'zadig'; New-Item -ItemType Directory -Force $tmp | Out-Null
    if (-not (Test-Path "$tmp\zadig.exe")) {
        $z = Invoke-RestMethod 'https://api.github.com/repos/pbatard/libwdi/releases/latest'
        $za = $z.assets | Where-Object { $_.name -like 'zadig-*.exe' } | Select-Object -First 1
        Invoke-WebRequest $za.browser_download_url -OutFile "$tmp\zadig.exe"
    }
    Set-Content "$tmp\zadig.ini" "[general]`nadvanced_mode = false`nexit_on_success = true`n[device]`nlist_all = true`ninclude_hubs = false`ntrim_whitespaces = true`n[driver]`ndefault_driver = 0`n"
    Write-Host ''
    Write-Host '    Zadig will open. In it:' -ForegroundColor Yellow
    Write-Host "      1. Dropdown -> '$desc (Interface 0)'   (NOT Interface 1/2 - those are the serial port)" -ForegroundColor Yellow
    Write-Host '      2. Target driver should read WinUSB -> click "Replace Driver"' -ForegroundColor Yellow
    Write-Host '    It closes itself on success.' -ForegroundColor Yellow
    Start-Process "$tmp\zadig.exe" -WorkingDirectory $tmp -Wait
    $svcNow = (Get-PnpDeviceProperty -InstanceId $hidIf.InstanceId -KeyName DEVPKEY_Device_Service).Data
    if ($svcNow -ne 'WinUSB') { throw "Interface 0 is on '$svcNow', not WinUSB. Re-run Zadig and pick Interface 0." }
    Ok 'Interface 0 -> WinUSB'
}

# ---------------------------------------------------------------- 4. service
Step 'NUT service'
& "$InstallDir\bin\nut.exe" restart | Out-Null
Start-Sleep 8
$vars = & "$InstallDir\bin\upsc.exe" "$UpsName@127.0.0.1" 2>$null
if (-not ($vars -match '^ups\.status:')) {
    Write-Host ($vars -join "`n")
    throw 'upsd is up but the driver is not reporting. Check: usbhid-ups.exe -a ecoflow -DD'
}
$status = ($vars | Select-String '^ups\.status: (.*)').Matches[0].Groups[1].Value
$charge = ($vars | Select-String '^battery\.charge: (.*)').Matches[0].Groups[1].Value
Ok "service running — ups.status=$status battery.charge=$charge%"

# ---------------------------------------------------------------- 5. tray
if (-not $NoTray) {
    Step 'Tray icon'
    $trayDir = "$InstallDir\tray"
    New-Item -ItemType Directory -Force $trayDir | Out-Null
    # Build NutTray.exe from source with the C# compiler that ships in every Windows install (no SDK needed).
    $csc = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    if (-not (Test-Path $csc)) { throw "csc.exe not found at $csc (needs .NET Framework 4.x, present on all supported Windows)." }
    Get-Process NutTray -ErrorAction SilentlyContinue | Stop-Process -Force
    & $csc /nologo /target:winexe /out:"$trayDir\NutTray.exe" /r:System.Drawing.dll /r:System.Windows.Forms.dll "$PSScriptRoot\tray\NutTray.cs"
    if ($LASTEXITCODE -ne 0) { throw 'NutTray.cs failed to compile' }
    Ok "built $trayDir\NutTray.exe"

    # Tray icons are per-session, so the task is registered for the console user (may differ from the elevated one).
    $user = (Get-CimInstance Win32_ComputerSystem).UserName
    if (-not $user) { $user = "$env:USERDOMAIN\$env:USERNAME" }
    $act = New-ScheduledTaskAction -Execute "$trayDir\NutTray.exe" -Argument "$UpsName 127.0.0.1 3493" -WorkingDirectory $trayDir
    $trig = New-ScheduledTaskTrigger -AtLogOn -User $user
    $trig.Delay = 'PT10S'
    $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName 'NutTray' -Action $act -Trigger $trig -Settings $set -User $user -RunLevel Limited -Force | Out-Null
    Start-ScheduledTask -TaskName 'NutTray'
    Ok "logon task 'NutTray' registered for $user and started"

    # Windows 11 hides new tray icons in the overflow flyout by default. The per-app "always show" switch is
    # HKCU\Control Panel\NotifyIconSettings\<id>\IsPromoted; the key appears the first time the icon is shown.
    # This runs as the elevated user, so it can only flip it when that is also the console user.
    $promoted = $false
    for ($i = 0; $i -lt 10 -and -not $promoted; $i++) {
        Start-Sleep 1
        Get-ChildItem 'HKCU:\Control Panel\NotifyIconSettings' -ErrorAction SilentlyContinue | ForEach-Object {
            if ((Get-ItemProperty $_.PSPath).ExecutablePath -like '*\NutTray.exe') {
                Set-ItemProperty $_.PSPath -Name IsPromoted -Value 1 -Type DWord; $promoted = $true
            }
        }
    }
    if ($promoted) { Ok 'tray icon set to always-visible' }
    else { Warn 'could not auto-pin the icon: Settings > Personalization > Taskbar > Other system tray icons > NutTray = On' }
}

Write-Host ''
Write-Host "Done. Query any time:  $InstallDir\bin\upsc.exe $UpsName@127.0.0.1" -ForegroundColor Green
