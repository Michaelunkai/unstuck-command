[CmdletBinding()]
param(
    [int]$SampleSeconds = 8,
    [int]$StaleLogSeconds = 45,
    [int]$PostActionWaitSeconds = 20,
    [switch]$DryRun,
    [switch]$Aggressive,
    [switch]$IncludeGenericReport,
    [switch]$RerunDism,
    [double]$MinCpuDelta = 0.01,
    [int]$MaxMonitorSeconds = 300,
    [int]$MonitorIntervalSeconds = 10,
    [string]$DismSource = "C:\Temp\codex-repair-source\sources\install.esd",
    [int]$DismSourceIndex = 6,
    [string]$LogPath = "$env:TEMP\unstuck-command.log"
)

$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Write-Host $line
    Add-Content -LiteralPath $LogPath -Value $line
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ProcByName {
    param([string[]]$Names)
    Get-Process -ErrorAction SilentlyContinue | Where-Object { $Names -contains $_.ProcessName }
}

function Get-ProcMap {
    $map = @{}
    Get-Process -ErrorAction SilentlyContinue | ForEach-Object { $map[[int]$_.Id] = $_ }
    return $map
}

function Get-CimProc {
    param([int]$Id)
    Get-CimInstance Win32_Process -Filter "ProcessId=$Id" -ErrorAction SilentlyContinue
}

function Get-CommandLine {
    param([int]$Id)
    $proc = Get-CimProc -Id $Id
    if ($proc) { return [string]$proc.CommandLine }
    return ""
}

function Get-CpuDelta {
    param(
        [object[]]$Before,
        [object[]]$After
    )
    $sum = 0.0
    foreach ($proc in $After) {
        $old = $Before | Where-Object { $_.Id -eq $proc.Id } | Select-Object -First 1
        if ($old) {
            $sum += [double]($proc.CPU - $old.CPU)
        }
    }
    return $sum
}

function Get-DismRepairProcess {
    param([object[]]$Processes)
    foreach ($proc in $Processes) {
        $cmd = Get-CommandLine -Id $proc.Id
        if ($cmd -match '(?i)/cleanup-image' -and $cmd -match '(?i)/restorehealth') {
            $proc
        }
    }
}

function Get-DismHostForParent {
    param(
        [object[]]$Hosts,
        [int[]]$ParentIds
    )
    foreach ($hostProc in $Hosts) {
        $cim = Get-CimProc -Id $hostProc.Id
        if ($cim -and ($ParentIds -contains [int]$cim.ParentProcessId)) {
            $hostProc
        }
    }
}

function Get-FileSnapshot {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path
        return [pscustomobject]@{
            Exists = $true
            LastWriteTime = $item.LastWriteTime
            Length = $item.Length
        }
    }
    [pscustomobject]@{ Exists = $false; LastWriteTime = [datetime]::MinValue; Length = 0 }
}

function Stop-TargetProcess {
    param(
        [System.Diagnostics.Process]$Process,
        [string]$Reason
    )
    if (-not $Process) { return }
    Write-Status ("ACTION stop PID={0} name={1} reason={2}" -f $Process.Id, $Process.ProcessName, $Reason)
    if (-not $DryRun) {
        Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
    }
}

function Start-DismRestoreHealth {
    if (-not $RerunDism) {
        Write-Status "DISM rerun not requested; use -RerunDism to relaunch RestoreHealth if the active one already failed."
        return
    }

    $dism = "$env:WINDIR\System32\dism.exe"
    if (-not (Test-Path -LiteralPath $dism)) {
        Write-Status "BLOCKED DISM executable not found at $dism"
        return
    }

    if (Test-Path -LiteralPath $DismSource) {
        $args = "/Online /Cleanup-Image /RestoreHealth /Source:esd:$DismSource`:$DismSourceIndex /LimitAccess"
    } else {
        $args = "/Online /Cleanup-Image /RestoreHealth"
    }

    Write-Status "ACTION start DISM $args"
    if (-not $DryRun) {
        $proc = Start-Process -FilePath $dism -ArgumentList $args -PassThru -WindowStyle Hidden
        Write-Status ("started DISM PID={0}" -f $proc.Id)
    }
}

function Stop-DismRepairSession {
    param(
        [object[]]$DismProcesses,
        [object[]]$DismHosts,
        [string]$Reason
    )
    $repairDism = @(Get-DismRepairProcess -Processes $DismProcesses)
    if ($repairDism.Count -eq 0) {
        Write-Status "no RestoreHealth DISM process found to recycle."
        return
    }

    $repairIds = @($repairDism | ForEach-Object { [int]$_.Id })
    $repairHosts = @(Get-DismHostForParent -Hosts $DismHosts -ParentIds $repairIds)
    foreach ($hostProc in $repairHosts) {
        Stop-TargetProcess -Process $hostProc -Reason ("DismHost for stale RestoreHealth: {0}" -f $Reason)
    }
    foreach ($dismProc in $repairDism) {
        Stop-TargetProcess -Process $dismProc -Reason ("stale RestoreHealth: {0}" -f $Reason)
    }
}

function Get-RecentDismFailure {
    $dismLog = "$env:WINDIR\Logs\DISM\dism.log"
    if (-not (Test-Path -LiteralPath $dismLog)) { return $false }
    $tail = Get-Content -LiteralPath $dismLog -Tail 80 -ErrorAction SilentlyContinue
    return [bool]($tail -match "HRESULT=800706BE|hr:0x800706be|Failed to restore the image health")
}

function Invoke-ServicingUnstuck {
    $dismLogPath = "$env:WINDIR\Logs\DISM\dism.log"
    $cbsLogPath = "$env:WINDIR\Logs\CBS\CBS.log"

    $before = @{
        Dism = @(Get-ProcByName @("Dism"))
        DismHost = @(Get-ProcByName @("DismHost"))
        Sfc = @(Get-ProcByName @("sfc"))
        TiWorker = @(Get-ProcByName @("TiWorker"))
        TrustedInstaller = @(Get-ProcByName @("TrustedInstaller"))
        DismLog = Get-FileSnapshot $dismLogPath
        CbsLog = Get-FileSnapshot $cbsLogPath
    }

    Start-Sleep -Seconds $SampleSeconds

    $after = @{
        Dism = @(Get-ProcByName @("Dism"))
        DismHost = @(Get-ProcByName @("DismHost"))
        Sfc = @(Get-ProcByName @("sfc"))
        TiWorker = @(Get-ProcByName @("TiWorker"))
        TrustedInstaller = @(Get-ProcByName @("TrustedInstaller"))
        DismLog = Get-FileSnapshot $dismLogPath
        CbsLog = Get-FileSnapshot $cbsLogPath
    }

    $dismActive = $after.Dism.Count -gt 0
    $repairDism = @(Get-DismRepairProcess -Processes $after.Dism)
    $repairDismActive = $repairDism.Count -gt 0
    $dismCpuDelta = Get-CpuDelta -Before $before.Dism -After $after.Dism
    $hostCpuDelta = Get-CpuDelta -Before $before.DismHost -After $after.DismHost
    $tiCpuDelta = Get-CpuDelta -Before $before.TiWorker -After $after.TiWorker
    $dismLogChanged = $after.DismLog.Exists -and (
        $after.DismLog.LastWriteTime -gt $before.DismLog.LastWriteTime -or
        $after.DismLog.Length -ne $before.DismLog.Length
    )
    $cbsLogChanged = $after.CbsLog.Exists -and (
        $after.CbsLog.LastWriteTime -gt $before.CbsLog.LastWriteTime -or
        $after.CbsLog.Length -ne $before.CbsLog.Length
    )
    $dismLogAge = if ($after.DismLog.Exists) { ((Get-Date) - $after.DismLog.LastWriteTime).TotalSeconds } else { [double]::PositiveInfinity }
    $cbsLogAge = if ($after.CbsLog.Exists) { ((Get-Date) - $after.CbsLog.LastWriteTime).TotalSeconds } else { [double]::PositiveInfinity }

    Write-Status ("sample DISM={0} RepairDISM={1} SFC={2} TiWorker={3} DISMCPU={4:n3} HostCPU={5:n3} TiCPU={6:n3} DISMLogChanged={7} CBSLogChanged={8} DISMLogAgeSec={9:n0} CBSLogAgeSec={10:n0}" -f `
        ($after.Dism.Id -join ","), ($repairDism.Id -join ","), ($after.Sfc.Id -join ","), ($after.TiWorker.Id -join ","), $dismCpuDelta, $hostCpuDelta, $tiCpuDelta, $dismLogChanged, $cbsLogChanged, $dismLogAge, $cbsLogAge)

    foreach ($sfc in $after.Sfc) {
        $cim = Get-CimProc -Id $sfc.Id
        $parentAlive = $false
        if ($cim -and $cim.ParentProcessId) {
            $parentAlive = [bool](Get-Process -Id $cim.ParentProcessId -ErrorAction SilentlyContinue)
        }
        $sfcBefore = $before.Sfc | Where-Object { $_.Id -eq $sfc.Id } | Select-Object -First 1
        $cpuDelta = if ($sfcBefore) { $sfc.CPU - $sfcBefore.CPU } else { 0 }
        $staleSfc = ($cpuDelta -lt $MinCpuDelta) -and (-not $cbsLogChanged) -and (($dismActive -and $dismLogAge -ge $StaleLogSeconds) -or (-not $parentAlive))
        if ($staleSfc) {
            Stop-TargetProcess -Process $sfc -Reason ("stale SFC blocks CBS; parentAlive={0}; cpuDelta={1:n3}" -f $parentAlive, $cpuDelta)
        } else {
            Write-Status ("keep SFC PID={0}; parentAlive={1}; cpuDelta={2:n3}; CBS moving={3}" -f $sfc.Id, $parentAlive, $cpuDelta, $cbsLogChanged)
        }
    }

    $recycledRepair = $false
    $dismSelfStale = $repairDismActive -and -not $dismLogChanged -and ($dismLogAge -ge $StaleLogSeconds) -and (($dismCpuDelta + $hostCpuDelta) -lt $MinCpuDelta)
    if ($dismSelfStale) {
        Write-Status "stalled DISM RestoreHealth detected: no DISM log movement and no DISM/DismHost CPU movement. CBS chatter is ignored for this decision."
        if ($Aggressive) {
            Stop-DismRepairSession -DismProcesses $after.Dism -DismHosts $after.DismHost -Reason "no repair progress"
            $recycledRepair = $true
        } else {
            Write-Status "would recycle stale DISM RestoreHealth; rerun with -Aggressive to force it."
        }

        foreach ($ti in $after.TiWorker) {
            if ($Aggressive) {
                Stop-TargetProcess -Process $ti -Reason "recycle TiWorker after stale DISM repair"
            } else {
                Write-Status ("would recycle TiWorker PID={0}; rerun with -Aggressive to force it" -f $ti.Id)
            }
        }
    }

    Start-Sleep -Seconds $PostActionWaitSeconds

    $postDism = @(Get-ProcByName @("Dism"))
    $postRepairDism = @(Get-DismRepairProcess -Processes $postDism)
    if ($DryRun -and $recycledRepair) {
        Write-Status "DRYRUN planned stale RestoreHealth recycle completed; relaunch check follows."
        Start-DismRestoreHealth
    } elseif (($recycledRepair -or (Get-RecentDismFailure)) -and $postRepairDism.Count -eq 0) {
        Write-Status "no active RestoreHealth remains after unstuck pass; relaunch check follows."
        Start-DismRestoreHealth
    } elseif ($postRepairDism.Count -gt 0) {
        Write-Status ("DISM RestoreHealth still running PID={0}; leaving active repair to continue." -f ($postRepairDism.Id -join ","))
    } elseif ($postDism.Count -gt 0) {
        Write-Status ("non-RepairHealth DISM still running PID={0}; not relaunching repair over unrelated DISM." -f ($postDism.Id -join ","))
    } else {
        Write-Status "no active DISM and no recent DISM failure requiring relaunch."
    }
}

function Show-GenericStaleReport {
    $names = "cmd","powershell","pwsh","python","node","git","robocopy","xcopy","chkdsk","tar","7z","winget","npm","pnpm","yarn"
    $before = @{}
    Get-ProcByName $names | ForEach-Object { $before[$_.Id] = $_.CPU }
    Start-Sleep -Seconds $SampleSeconds
    $map = Get-ProcMap
    foreach ($proc in (Get-ProcByName $names)) {
        $oldCpu = if ($before.ContainsKey($proc.Id)) { $before[$proc.Id] } else { $proc.CPU }
        $delta = $proc.CPU - $oldCpu
        if ($delta -lt 0.01) {
            $cim = Get-CimProc -Id $proc.Id
            $parentName = ""
            if ($cim -and $map.ContainsKey([int]$cim.ParentProcessId)) {
                $parentName = $map[[int]$cim.ParentProcessId].ProcessName
            }
            Write-Status ("STALE-CANDIDATE PID={0} name={1} parent={2} cpuDelta={3:n3} cmd={4}" -f $proc.Id, $proc.ProcessName, $parentName, $delta, $cim.CommandLine)
        }
    }
}

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $LogPath) | Out-Null
Write-Status "unstuck-command start DryRun=$DryRun Aggressive=$Aggressive RerunDism=$RerunDism IncludeGenericReport=$IncludeGenericReport SampleSeconds=$SampleSeconds MaxMonitorSeconds=$MaxMonitorSeconds"

if (-not (Test-IsAdmin)) {
    Write-Status "WARNING not elevated. Detection works, but stopping service-owned workers may fail. Run the .cmd launcher as Administrator for full repair."
}

$deadline = (Get-Date).AddSeconds([Math]::Max(1, $MaxMonitorSeconds))
$pass = 0
do {
    $pass++
    Write-Status "monitor pass $pass"
    Invoke-ServicingUnstuck
    $activeRepair = @(Get-DismRepairProcess -Processes @(Get-ProcByName @("Dism")))
    if ($activeRepair.Count -eq 0) {
        Write-Status "no active RestoreHealth repair after pass $pass."
        break
    }
    if ((Get-Date) -ge $deadline) {
        Write-Status ("monitor timeout reached with active RestoreHealth PID={0}" -f ($activeRepair.Id -join ","))
        break
    }
    Write-Status ("active RestoreHealth PID={0}; next monitor pass in {1}s" -f ($activeRepair.Id -join ","), $MonitorIntervalSeconds)
    Start-Sleep -Seconds $MonitorIntervalSeconds
} while ($true)

if ($IncludeGenericReport) {
    Show-GenericStaleReport
} else {
    Write-Status "generic stale-process report skipped; add -IncludeGenericReport for read-only candidate listing."
}
Write-Status "unstuck-command complete. Log: $LogPath"
