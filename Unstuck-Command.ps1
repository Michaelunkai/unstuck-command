[CmdletBinding()]
param(
    [int]$SampleSeconds = 8,
    [int]$StaleLogSeconds = 45,
    [int]$PostActionWaitSeconds = 20,
    [switch]$DryRun,
    [switch]$Aggressive,
    [switch]$IncludeGenericReport,
    [switch]$RerunDism,
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
    $sfcActive = $after.Sfc.Count -gt 0
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

    Write-Status ("sample DISM={0} SFC={1} TiWorker={2} DISMLogChanged={3} CBSLogChanged={4} DISMLogAgeSec={5:n0} CBSLogAgeSec={6:n0}" -f `
        ($after.Dism.Id -join ","), ($after.Sfc.Id -join ","), ($after.TiWorker.Id -join ","), $dismLogChanged, $cbsLogChanged, $dismLogAge, $cbsLogAge)

    foreach ($sfc in $after.Sfc) {
        $cim = Get-CimProc -Id $sfc.Id
        $parentAlive = $false
        if ($cim -and $cim.ParentProcessId) {
            $parentAlive = [bool](Get-Process -Id $cim.ParentProcessId -ErrorAction SilentlyContinue)
        }
        $sfcBefore = $before.Sfc | Where-Object { $_.Id -eq $sfc.Id } | Select-Object -First 1
        $cpuDelta = if ($sfcBefore) { $sfc.CPU - $sfcBefore.CPU } else { 0 }
        $staleSfc = ($cpuDelta -lt 0.01) -and (-not $cbsLogChanged) -and (($dismActive -and $dismLogAge -ge $StaleLogSeconds) -or (-not $parentAlive))
        if ($staleSfc) {
            Stop-TargetProcess -Process $sfc -Reason ("stale SFC blocks CBS; parentAlive={0}; cpuDelta={1:n3}" -f $parentAlive, $cpuDelta)
        } else {
            Write-Status ("keep SFC PID={0}; parentAlive={1}; cpuDelta={2:n3}; CBS moving={3}" -f $sfc.Id, $parentAlive, $cpuDelta, $cbsLogChanged)
        }
    }

    if ($dismActive -and -not $dismLogChanged -and -not $cbsLogChanged -and $dismLogAge -ge $StaleLogSeconds -and $cbsLogAge -ge $StaleLogSeconds) {
        Write-Status "stalled servicing stack detected: active DISM with no DISM/CBS log movement."
        foreach ($ti in $after.TiWorker) {
            if ($Aggressive) {
                Stop-TargetProcess -Process $ti -Reason "aggressive stale TiWorker recycle for DISM/CBS deadlock"
            } else {
                Write-Status ("would recycle TiWorker PID={0}; rerun with -Aggressive to force it" -f $ti.Id)
            }
        }
    }

    Start-Sleep -Seconds $PostActionWaitSeconds

    $postDism = @(Get-ProcByName @("Dism"))
    if ($postDism.Count -eq 0 -and (Get-RecentDismFailure)) {
        Write-Status "recent DISM failure found after unstuck pass."
        Start-DismRestoreHealth
    } elseif ($postDism.Count -gt 0) {
        Write-Status ("DISM still running PID={0}; leaving active repair to continue." -f ($postDism.Id -join ","))
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
Write-Status "unstuck-command start DryRun=$DryRun Aggressive=$Aggressive RerunDism=$RerunDism IncludeGenericReport=$IncludeGenericReport SampleSeconds=$SampleSeconds"

if (-not (Test-IsAdmin)) {
    Write-Status "WARNING not elevated. Detection works, but stopping service-owned workers may fail. Run the .cmd launcher as Administrator for full repair."
}

Invoke-ServicingUnstuck
if ($IncludeGenericReport) {
    Show-GenericStaleReport
} else {
    Write-Status "generic stale-process report skipped; add -IncludeGenericReport for read-only candidate listing."
}
Write-Status "unstuck-command complete. Log: $LogPath"
