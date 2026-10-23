[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$sourceRoot = $PSScriptRoot
$installRoot = 'C:\ProgramData\EcoFlowBLE'
$serviceName = 'Network UPS Tools'
$taskName = 'EcoFlowBLE'
$probeName = 'EcoFlowBLE-Probe'
$nutConfig = 'C:\NUT\etc\ups.conf'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw 'Run this installer with administrator rights.' }
function Invoke-UpSc([string]$UpsName) {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = 'C:\NUT\bin\upsc.exe'
    $info.Arguments = $UpsName
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    try {
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(10000)) { $process.Kill(); throw 'NUT query timed out.' }
        return [pscustomobject]@{Code=$process.ExitCode;Lines=@($stdout.Result -split '\r?\n');ErrorText=$stderr.Result}
    } finally { $process.Dispose() }
}
$userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
Start-Transcript -LiteralPath (Join-Path $sourceRoot 'install.log') -Append | Out-Null
$changedConfig = $false
$backup = "$nutConfig.bak-ble-$stamp"
try {
    if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot 'machine-user-id.dpapi'))) { throw 'Encrypted account ID has not been staged (run stage_machine.py).' }
    if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot 'serial.txt'))) { throw 'No serial.txt (run scan.py --save).' }
    $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existing) {
        if (Test-Path -LiteralPath (Join-Path $installRoot 'installation.json')) { throw 'EcoFlowBLE is already installed; refusing an implicit overwrite.' }
        Stop-ScheduledTask -TaskName $taskName
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }
    New-Item -ItemType Directory -Path $installRoot -Force | Out-Null
    & icacls.exe $installRoot /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' "*$($userSid):(OI)(CI)RX" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not protect install directory.' }
    $runtimeSource = (& (Join-Path $sourceRoot '.venv\Scripts\python.exe') -c 'import sys; print(sys.base_prefix)').Trim()
    if (-not (Test-Path -LiteralPath (Join-Path $runtimeSource 'python.exe'))) { throw 'Python runtime not found.' }
    $runtime = Join-Path $installRoot 'runtime'
    New-Item -ItemType Directory -Path $runtime -Force | Out-Null
    Get-ChildItem -LiteralPath $runtimeSource | Copy-Item -Destination $runtime -Recurse -Force
    $sitePackages = Join-Path $runtime 'Lib\site-packages'
    New-Item -ItemType Directory -Path $sitePackages -Force | Out-Null
    Get-ChildItem -LiteralPath (Join-Path $sourceRoot '.venv\Lib\site-packages') | Copy-Item -Destination $sitePackages -Recurse -Force
    foreach ($file in @('bridge.py', 'secure_store.py', 'serial.txt')) {
        Copy-Item -LiteralPath (Join-Path $sourceRoot $file) -Destination (Join-Path $installRoot $file)
    }
    $vendorTarget = Join-Path $installRoot 'vendor\ha-ef-ble\custom_components\ef_ble'
    New-Item -ItemType Directory -Path $vendorTarget -Force | Out-Null
    $eflibTarget = Join-Path $vendorTarget 'eflib'
    New-Item -ItemType Directory -Path $eflibTarget -Force | Out-Null
    Get-ChildItem -LiteralPath (Join-Path $sourceRoot 'vendor\ha-ef-ble\custom_components\ef_ble\eflib') | Copy-Item -Destination $eflibTarget -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'vendor\ha-ef-ble\LICENSE') -Destination (Join-Path $installRoot 'vendor\ha-ef-ble\LICENSE')
    $secret = Join-Path $installRoot 'user-id.dpapi'
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'machine-user-id.dpapi') -Destination $secret
    & icacls.exe $secret /inheritance:r /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not restrict encrypted account ID.' }
    $python = Join-Path $runtime 'pythonw.exe'
    $oldLog = Join-Path $installRoot 'bridge.log'
    $priorProbePassed = (Test-Path -LiteralPath $oldLog) -and [bool](Select-String -LiteralPath $oldLog -SimpleMatch 'Probe cycle 2 passed' -Quiet)
    if (Test-Path -LiteralPath $oldLog) { Move-Item -LiteralPath $oldLog -Destination (Join-Path $installRoot "bridge-before-$stamp.log") }
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
    if (-not $priorProbePassed) {
    $probeAction = New-ScheduledTaskAction -Execute $python -Argument ('"{0}" --probe' -f (Join-Path $installRoot 'bridge.py')) -WorkingDirectory $installRoot
    Register-ScheduledTask -TaskName $probeName -Action $probeAction -Settings $settings -User 'SYSTEM' -RunLevel Highest -Description 'Read-only EcoFlow Bluetooth validation; no NUT or power changes.' -Force | Out-Null
    Start-ScheduledTask -TaskName $probeName
    Write-Output 'Testing Bluetooth under SYSTEM, including reconnect. NUT configuration has not changed.'
    $deadline = (Get-Date).AddSeconds(110)
    $passed = $false
    do {
        Start-Sleep -Seconds 2
        $log = Join-Path $installRoot 'bridge.log'
        if (Test-Path -LiteralPath $log) {
            $passed = [bool](Select-String -LiteralPath $log -SimpleMatch 'Probe cycle 2 passed' -Quiet)
        }
        $probeState = (Get-ScheduledTask -TaskName $probeName).State
        if ($probeState -eq 'Ready' -and -not $passed) { throw 'SYSTEM Bluetooth probe exited before success. See protected bridge.log.' }
    } until ($passed -or (Get-Date) -ge $deadline)
    if (-not $passed) { throw 'SYSTEM Bluetooth probe did not complete in time.' }
    while ((Get-ScheduledTask -TaskName $probeName).State -eq 'Running' -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 1 }
    Stop-ScheduledTask -TaskName $probeName
    Unregister-ScheduledTask -TaskName $probeName -Confirm:$false
    } else {
        Write-Output 'Reusing the successful SYSTEM Bluetooth/reconnect test from this installation attempt.'
    }
    $action = New-ScheduledTaskAction -Execute $python -Argument ('"{0}"' -f (Join-Path $installRoot 'bridge.py')) -WorkingDirectory $installRoot
    $trigger = New-ScheduledTaskTrigger -AtStartup
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -User 'SYSTEM' -RunLevel Highest -Description 'Read-only EcoFlow DELTA 3 Plus Bluetooth telemetry for NUT; no output controls.' | Out-Null
    Start-ScheduledTask -TaskName $taskName
    $deadline = (Get-Date).AddSeconds(60)
    $ready = $false
    do {
        Start-Sleep -Seconds 2
        $healthFile = Join-Path $installRoot 'health.json'
        if (Test-Path -LiteralPath $healthFile) {
            $health = Get-Content -LiteralPath $healthFile -Raw | ConvertFrom-Json
            $ready = $health.fresh -and $health.connected
        }
    } until ($ready -or (Get-Date) -ge $deadline)
    if (-not $ready) { throw 'Persistent SYSTEM bridge did not produce fresh telemetry.' }
    Copy-Item -LiteralPath $nutConfig -Destination $backup
    $newConfig = @'
[ecoflow]
    driver = dummy-ups
    port = ecoflow_ble@127.0.0.1:3494
    mode = repeater
    repeater_disable_strict_start
    desc = "EcoFlow DELTA 3 Plus over Bluetooth"
    pollinterval = 2
'@
    Set-Content -LiteralPath $nutConfig -Value $newConfig -Encoding ASCII
    $changedConfig = $true
    Restart-Service -Name $serviceName
    $deadline = (Get-Date).AddSeconds(40)
    $verified = $false
    do {
        Start-Sleep -Seconds 2
        $response = Invoke-UpSc 'ecoflow@127.0.0.1'
        $query = $response.Lines
        $chargeLine = @($query -match '^battery\.charge:')
        $charge = if ($chargeLine.Count -eq 1) { [double](($chargeLine[0] -split ':',2)[1].Trim()) } else { -1 }
        $verified = $response.Code -eq 0 -and $charge -ge 0 -and $charge -le 100 -and [bool]($query -match '^ups\.status: (OL|OB)')
    } until ($verified -or (Get-Date) -ge $deadline)
    if (-not $verified) { throw 'NUT did not publish live Bluetooth telemetry after the switch.' }
    Write-Output 'SUCCESS: NUT is publishing live Bluetooth data. EcoFlowBLE starts at boot as SYSTEM.'
    $query | Where-Object { $_ -match '^(battery\.|ups\.status|ups\.realpower|input\.realpower|driver\.name)' } | Write-Output
    @{Installed=(Get-Date).ToString('o');Backup=$backup;Task=$taskName;Transport='Bluetooth LE';LowBatteryPercent=15} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $installRoot 'installation.json')
} catch {
    Write-Output "INSTALL FAILED: $($_.Exception.Message)"
    if ($changedConfig) {
        Copy-Item -LiteralPath $backup -Destination $nutConfig -Force
        Restart-Service -Name $serviceName
        Write-Output 'Previous NUT configuration restored.'
    }
    foreach ($name in @($taskName, $probeName)) {
        if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
            Stop-ScheduledTask -TaskName $name
            Disable-ScheduledTask -TaskName $name | Out-Null
        }
    }
    throw
} finally {
    Stop-Transcript | Out-Null
}
