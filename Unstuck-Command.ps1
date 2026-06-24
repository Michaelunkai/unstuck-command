[CmdletBinding()]
param(
    [int]$SampleSeconds = 8,
    [int]$StaleLogSeconds = 45,
    [int]$PostActionWaitSeconds = 20,
    [switch]$DryRun,
    [switch]$Aggressive,
    [switch]$IncludeGenericReport,
    [switch]$IncludeAppReport,
    [switch]$RecoverHungExplorer,
    [switch]$RecoverHungTerminalWindows,
    [switch]$RecoverHungGenericApps,
    [switch]$RecoverStaleTerminalCommands,
    [switch]$RerunDism,
    [switch]$NoTray,
    [switch]$NoServicingScan,
    [switch]$NoRestartRecoveredApps,
    [switch]$NoDebugPrivilege,
    [switch]$ForceTestNotification,
    [int]$SelfExitAfterSeconds = 0,
    [double]$MinCpuDelta = 0.01,
    [int]$AppHungConfirmSeconds = 2,
    [int]$ImmediateScanIntervalSeconds = 1,
    [int]$ImmediateHungConfirmSeconds = 1,
    [int]$GenericStaleMinAgeSeconds = 60,
    [int]$TerminalCommandStaleSeconds = 45,
    [int]$MaxGenericCandidates = 20,
    [int]$GenericCandidateNotifyCooldownSeconds = 300,
    [int]$GenericAppRecoveryCooldownSeconds = 300,
    [switch]$IncludeBenignGenericCandidates,
    [int]$MaxMonitorSeconds = 300,
    [int]$MonitorIntervalSeconds = 10,
    [string]$DismSource = "",
    [int]$DismSourceIndex = 6,
    [string]$InstanceName = "Global\UnstuckCommandTrayMonitor",
    [string]$LogPath = ""
)

$ErrorActionPreference = "Stop"
$script:ScriptRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($script:ScriptRoot)) { $script:ScriptRoot = Split-Path -Path $PSCommandPath -Parent }
if ([string]::IsNullOrWhiteSpace($script:ScriptRoot)) { $script:ScriptRoot = Split-Path -Path $MyInvocation.MyCommand.Path -Parent }
if ([string]::IsNullOrWhiteSpace($script:ScriptRoot)) { $script:ScriptRoot = [IO.Directory]::GetCurrentDirectory() }
if ([string]::IsNullOrWhiteSpace($DismSource)) { $DismSource = Join-Path $script:ScriptRoot "repair-source\sources\install.esd" }
if ([string]::IsNullOrWhiteSpace($LogPath)) { $LogPath = Join-Path $script:ScriptRoot "logs\unstuck-command.log" }
$script:StopRequested = $false
$script:TrayIcon = $null
$script:TrayTimer = $null
$script:StartedDismIds = New-Object System.Collections.Generic.List[int]
$script:ContinuousTrayMode = (-not $NoTray)
$script:InstanceMutex = $null
$script:InstanceMutexOwned = $false
$script:LastGenericCandidateNotification = (Get-Date).AddSeconds(-1 * [Math]::Max(1, $GenericCandidateNotifyCooldownSeconds))
$script:LastImmediateScan = [datetime]::MinValue
$script:ImmediateHungSeen = @{}
$script:ImmediateRecoveredPids = @{}
$script:LastGenericAppRecoveryByKey = @{}
$script:DebugPrivilegeAttempted = $false
$script:DebugPrivilegeEnabled = $false
$script:RealtimePumpInProgress = $false

function Initialize-SingleInstance {
    if ($NoTray) { return $true }

    try {
        $createdNew = $false
        $script:InstanceMutex = [System.Threading.Mutex]::new($false, $InstanceName, [ref]$createdNew)
        try {
            $script:InstanceMutexOwned = $script:InstanceMutex.WaitOne(0, $false)
        } catch [System.Threading.AbandonedMutexException] {
            $script:InstanceMutexOwned = $true
            Write-Status "single-instance guard recovered abandoned mutex from a dead prior monitor."
        }

        if (-not $script:InstanceMutexOwned) {
            Write-Status "another unstuck-command tray monitor is already running; exiting this duplicate launch."
            return $false
        }
    } catch {
        Write-Status ("ERROR single-instance guard failed for {0}: {1}" -f $InstanceName, $_.Exception.Message)
        throw
    }

    Write-Status "single-instance guard acquired."
    return $true
}

function Write-Status {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Write-Host $line
    $logDir = Split-Path -Parent $LogPath
    if (-not [string]::IsNullOrWhiteSpace($logDir) -and -not (Test-Path -LiteralPath $logDir)) {
        New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    }

    $lastError = $null
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        $stream = $null
        $writer = $null
        try {
            $stream = [System.IO.File]::Open($LogPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
            $writer = [System.IO.StreamWriter]::new($stream, [System.Text.Encoding]::UTF8)
            $stream = $null
            $writer.WriteLine($line)
            return
        } catch {
            $lastError = $_.Exception
            Start-Sleep -Milliseconds (40 * $attempt)
        } finally {
            if ($writer -ne $null) { $writer.Dispose() }
            if ($stream -ne $null) { $stream.Dispose() }
        }
    }

    Write-Warning ("unstuck-command could not write log {0}: {1}" -f $LogPath, $lastError.Message)
}

function Initialize-TrayIcon {
    if ($NoTray) {
        Write-Status "tray icon disabled by -NoTray."
        return
    }

    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing

        $menu = [System.Windows.Forms.ContextMenuStrip]::new()
        $statusItem = [System.Windows.Forms.ToolStripMenuItem]::new("unstuck-command running")
        $statusItem.Enabled = $false
        $exitItem = [System.Windows.Forms.ToolStripMenuItem]::new("Exit and stop")
        $exitItem.Add_Click({
            $script:StopRequested = $true
            Write-Status "tray exit requested; stopping monitor."
        })
        [void]$menu.Items.Add($statusItem)
        [void]$menu.Items.Add("-")
        [void]$menu.Items.Add($exitItem)

        $script:TrayIcon = [System.Windows.Forms.NotifyIcon]::new()
        $script:TrayIcon.Icon = [System.Drawing.SystemIcons]::Shield
        $script:TrayIcon.Text = "unstuck-command running"
        $script:TrayIcon.ContextMenuStrip = $menu
        $script:TrayIcon.Visible = $true
        Write-Status "tray icon created; use Exit and stop to end this monitor."

        if ($SelfExitAfterSeconds -gt 0) {
            $script:TrayTimer = [System.Windows.Forms.Timer]::new()
            $script:TrayTimer.Interval = [Math]::Max(1, $SelfExitAfterSeconds) * 1000
            $script:TrayTimer.Add_Tick({
                $this.Stop()
                $this.Dispose()
                $script:StopRequested = $true
                Write-Status "self-exit timer requested stop; this uses the same stop path as tray exit."
            })
            $script:TrayTimer.Start()
        }
    } catch {
        Write-Status ("WARNING tray icon could not be created: {0}" -f $_.Exception.Message)
        throw
    }
}

function Send-TrayNotification {
    param(
        [string]$Title,
        [string]$Message,
        [string]$Icon = "Info"
    )
    if ($script:TrayIcon -eq $null) { return }
    try {
        $script:TrayIcon.BalloonTipTitle = $Title
        $script:TrayIcon.BalloonTipText = $Message
        $script:TrayIcon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::$Icon
        $script:TrayIcon.ShowBalloonTip(7000)
        Invoke-TrayEvents
    } catch {
        Write-Status ("WARNING tray notification failed: {0}" -f $_.Exception.Message)
    }
}

function Notify-RecoveryAction {
    param(
        [string]$Action,
        [string]$Target,
        [string]$Detail,
        [string]$Icon = "Info"
    )
    $message = "{0}: {1}" -f $Target, $Detail
    Write-Status ("NOTIFY-RECOVERY action={0} target={1} detail={2}" -f $Action, $Target, $Detail)
    Send-TrayNotification -Title ("unstuck-command {0}" -f $Action) -Message $message -Icon $Icon
}

function Invoke-TrayEvents {
    if ($script:TrayIcon -ne $null) {
        [System.Windows.Forms.Application]::DoEvents()
    }
}

function Invoke-RealtimePump {
    Invoke-TrayEvents
    if ($script:RealtimePumpInProgress) { return }
    try {
        $script:RealtimePumpInProgress = $true
        Invoke-ImmediateUnfreezeScan
    } finally {
        $script:RealtimePumpInProgress = $false
    }
}

function Test-IsTerminalWindowProcess {
    param([System.Diagnostics.Process]$Process)
    if (-not $Process) { return $false }
    if ($Process.ProcessName -match '^(?i:WindowsTerminal|OpenConsole|cmd|powershell|pwsh)$') { return $true }
    $title = [string]$Process.MainWindowTitle
    return ($title -match '(?i)\b(command prompt|cmd|powershell|windows powershell|terminal|pwsh)\b')
}

function Start-ReplacementTerminal {
    foreach ($candidate in 'wt.exe','powershell.exe','cmd.exe') {
        try {
            $cmd = Get-Command -Name $candidate -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($cmd) {
                Start-Process -FilePath $candidate -ErrorAction SilentlyContinue | Out-Null
                Write-Status ("replacement terminal started via PATH command={0}" -f $candidate)
                return
            }
        } catch {}
    }
    Write-Status "replacement terminal start skipped; no wt.exe/powershell.exe/cmd.exe command was resolvable from PATH."
}

function Test-IsProtectedHungApp {
    param([System.Diagnostics.Process]$Process)
    if (-not $Process) { return $true }

    $name = [string]$Process.ProcessName
    $title = [string]$Process.MainWindowTitle
    $cmd = Get-CommandLine -Id ([int]$Process.Id)

    if ($name -match '^(?i:System|Idle|Registry|smss|csrss|wininit|winlogon|services|lsass|dwm|fontdrvhost|sihost|ShellExperienceHost|StartMenuExperienceHost|TextInputHost|SearchHost|RuntimeBroker)$') { return $true }
    if ($name -match '^(?i:Dism|DismHost|TiWorker|TrustedInstaller|msiexec)$') { return $true }
    if ($name -match '^(?i:setup|setup\.tmp|fgpack|cleanmgr)$') { return $true }
    if ($cmd -match '(?i)\\FitGirl\\|qbittorrent-fitgirl-force-auto-install|\\runtime\\state\\inno-temp\\|fgpack\.exe|Force-QbitFitGirlAutoInstall') { return $true }
    if ($cmd -match '(?i)\\\.codex\\|CodexConnectivityGuardian|CodexHostResponsivenessGuardian|task-complete-alert-watcher|freeze-escape-guard') { return $true }
    if ($title -match '(?i)setup|installing|extracting|unpacking|fitgirl') { return $true }

    return $false
}

function Restart-HungGenericApp {
    param(
        [System.Diagnostics.Process]$Process,
        [string]$Reason
    )

    if (-not $Process) { return }
    $exePath = ""
    $cim = Get-CimProc -Id ([int]$Process.Id)
    if ($cim) {
        $exePath = [string]$cim.ExecutablePath
    }
    $recoveryKey = if (-not [string]::IsNullOrWhiteSpace($exePath)) {
        $exePath.ToLowerInvariant()
    } else {
        ([string]$Process.ProcessName).ToLowerInvariant()
    }
    $now = Get-Date
    $recentRecovery = $false
    $secondsSinceRecovery = 0
    if ($GenericAppRecoveryCooldownSeconds -gt 0 -and $script:LastGenericAppRecoveryByKey.ContainsKey($recoveryKey)) {
        $secondsSinceRecovery = ($now - $script:LastGenericAppRecoveryByKey[$recoveryKey]).TotalSeconds
        $recentRecovery = ($secondsSinceRecovery -ge 0 -and $secondsSinceRecovery -lt $GenericAppRecoveryCooldownSeconds)
    }

    Write-Status ("ACTION recover generic app PID={0} name={1} reason={2} exe={3}" -f $Process.Id, $Process.ProcessName, $Reason, $exePath)
    if ($DryRun) {
        Send-TrayNotification -Title "unstuck-command dry run" -Message ("Would recover hung app {0} PID {1}" -f $Process.ProcessName, $Process.Id) -Icon "Warning"
        return
    }

    Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 300
    $script:LastGenericAppRecoveryByKey[$recoveryKey] = $now
    if ($recentRecovery) {
        Notify-RecoveryAction -Action "unfroze app" -Target ("{0} PID {1}" -f $Process.ProcessName, $Process.Id) -Detail ("stopped repeated non-responding instance; restart suppressed because the same executable was recovered {0:n1}s ago: {1}" -f $secondsSinceRecovery, $Reason) -Icon "Warning"
        return
    }

    if ($NoRestartRecoveredApps) {
        Notify-RecoveryAction -Action "unfroze app" -Target ("{0} PID {1}" -f $Process.ProcessName, $Process.Id) -Detail ("stopped after confirmed non-responding state; restart suppressed by -NoRestartRecoveredApps: {0}" -f $Reason)
        return
    }

    if (-not [string]::IsNullOrWhiteSpace($exePath) -and (Test-Path -LiteralPath $exePath)) {
        Start-Process -FilePath $exePath -ErrorAction SilentlyContinue | Out-Null
        Notify-RecoveryAction -Action "unfroze app" -Target ("{0} PID {1}" -f $Process.ProcessName, $Process.Id) -Detail ("restarted after confirmed non-responding state: {0}" -f $Reason)
    } else {
        Notify-RecoveryAction -Action "unfroze app" -Target ("{0} PID {1}" -f $Process.ProcessName, $Process.Id) -Detail ("stopped after confirmed non-responding state; executable path unavailable: {0}" -f $Reason)
    }
}

function Invoke-ImmediateUnfreezeScan {
    if (-not ($RecoverHungExplorer -or $RecoverHungTerminalWindows -or $RecoverHungGenericApps -or $IncludeAppReport)) {
        return
    }

    $now = Get-Date
    if ((($now - $script:LastImmediateScan).TotalSeconds) -lt [Math]::Max(1, $ImmediateScanIntervalSeconds)) {
        return
    }
    $script:LastImmediateScan = $now

    $currentHung = @{}
    $hungApps = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle -and -not $_.Responding
    })

    foreach ($app in $hungApps) {
        $appPid = [int]$app.Id
        $currentHung[$appPid] = $true
        if (-not $script:ImmediateHungSeen.ContainsKey($appPid)) {
            $script:ImmediateHungSeen[$appPid] = $now
            Write-Status ("IMMEDIATE-HUNG-SEEN PID={0} name={1} title={2}" -f $app.Id, $app.ProcessName, $app.MainWindowTitle)
            continue
        }

        $hungForSeconds = ($now - $script:ImmediateHungSeen[$appPid]).TotalSeconds
        if ($hungForSeconds -lt [Math]::Max(0, $ImmediateHungConfirmSeconds)) {
            continue
        }
        if ($script:ImmediateRecoveredPids.ContainsKey($appPid)) {
            continue
        }

        if ($RecoverHungExplorer -and $app.ProcessName -eq "explorer") {
            $script:ImmediateRecoveredPids[$appPid] = $now
            Write-Status ("IMMEDIATE-ACTION restart Explorer PID={0} hungForSec={1:n1}" -f $app.Id, $hungForSeconds)
            if (-not $DryRun) {
                Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue
                Start-Process explorer.exe
                Notify-RecoveryAction -Action "unfroze Explorer" -Target ("Explorer PID {0}" -f $app.Id) -Detail "immediate watchdog restarted confirmed non-responding Explorer"
            } else {
                Send-TrayNotification -Title "unstuck-command dry run" -Message ("Would immediately restart hung Explorer PID {0}" -f $app.Id) -Icon "Warning"
            }
            continue
        }

        if ($RecoverHungTerminalWindows -and (Test-IsTerminalWindowProcess -Process $app)) {
            $script:ImmediateRecoveredPids[$appPid] = $now
            Write-Status ("IMMEDIATE-ACTION restart terminal PID={0} name={1} title={2} hungForSec={3:n1}" -f $app.Id, $app.ProcessName, $app.MainWindowTitle, $hungForSeconds)
            if (-not $DryRun) {
                [void](Stop-ProcessTree -RootProcessId ([int]$app.Id))
                Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue
                Start-ReplacementTerminal
                Notify-RecoveryAction -Action "unfroze terminal" -Target ("{0} PID {1}" -f $app.ProcessName, $app.Id) -Detail "immediate watchdog restarted confirmed non-responding terminal window"
            } else {
                Send-TrayNotification -Title "unstuck-command dry run" -Message ("Would immediately restart hung terminal PID {0}" -f $app.Id) -Icon "Warning"
            }
            continue
        }

        if ($RecoverHungGenericApps -and -not (Test-IsProtectedHungApp -Process $app)) {
            $script:ImmediateRecoveredPids[$appPid] = $now
            Write-Status ("IMMEDIATE-ACTION recover generic app PID={0} name={1} title={2} hungForSec={3:n1}" -f $app.Id, $app.ProcessName, $app.MainWindowTitle, $hungForSeconds)
            Restart-HungGenericApp -Process $app -Reason ("immediate watchdog confirmed non-responding for {0:n1}s" -f $hungForSeconds)
            continue
        }

        if ($RecoverHungGenericApps) {
            Write-Status ("IMMEDIATE-HUNG-PROTECTED PID={0} name={1} title={2} hungForSec={3:n1}" -f $app.Id, $app.ProcessName, $app.MainWindowTitle, $hungForSeconds)
            continue
        }

        Write-Status ("IMMEDIATE-HUNG-OBSERVED PID={0} name={1} title={2} hungForSec={3:n1} action=logged-only" -f $app.Id, $app.ProcessName, $app.MainWindowTitle, $hungForSeconds)
    }

    foreach ($hungPid in @($script:ImmediateHungSeen.Keys)) {
        if (-not $currentHung.ContainsKey([int]$hungPid)) {
            Write-Status ("IMMEDIATE-HUNG-RECOVERED PID={0} without action" -f $hungPid)
            $script:ImmediateHungSeen.Remove($hungPid)
            $script:ImmediateRecoveredPids.Remove($hungPid)
        }
    }
}

function Wait-WithTrayEvents {
    param([int]$Seconds)
    $end = (Get-Date).AddSeconds([Math]::Max(0, $Seconds))
    while ((Get-Date) -lt $end) {
        Invoke-RealtimePump
        if ($script:StopRequested) { return $false }
        Start-Sleep -Milliseconds 250
    }
    Invoke-RealtimePump
    return (-not $script:StopRequested)
}

function Stop-StartedDismProcesses {
    foreach ($id in @($script:StartedDismIds)) {
        $proc = Get-Process -Id $id -ErrorAction SilentlyContinue
        if ($proc) {
            Stop-TargetProcess -Process $proc -Reason "tray exit cleanup for DISM started by unstuck-command"
        }
    }
}

function Dispose-TrayIcon {
    if ($script:TrayTimer -ne $null) {
        $script:TrayTimer.Stop()
        $script:TrayTimer.Dispose()
        $script:TrayTimer = $null
    }
    if ($script:TrayIcon -ne $null) {
        $script:TrayIcon.Visible = $false
        $script:TrayIcon.Dispose()
        $script:TrayIcon = $null
        Write-Status "tray icon removed."
    }
}

function Dispose-SingleInstance {
    if ($script:InstanceMutex -ne $null) {
        if ($script:InstanceMutexOwned) {
            $script:InstanceMutex.ReleaseMutex()
            Write-Status "single-instance guard released."
        }
        $script:InstanceMutex.Dispose()
        $script:InstanceMutex = $null
        $script:InstanceMutexOwned = $false
    }
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Enable-DebugPrivilege {
    if ($script:DebugPrivilegeAttempted) {
        return $script:DebugPrivilegeEnabled
    }
    $script:DebugPrivilegeAttempted = $true

    $source = @"
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class UnstuckCommandPrivilege
{
    [StructLayout(LayoutKind.Sequential)]
    private struct LUID
    {
        public uint LowPart;
        public int HighPart;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct TOKEN_PRIVILEGES
    {
        public uint PrivilegeCount;
        public LUID Luid;
        public uint Attributes;
    }

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool OpenProcessToken(IntPtr ProcessHandle, UInt32 DesiredAccess, out IntPtr TokenHandle);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool LookupPrivilegeValue(string lpSystemName, string lpName, out LUID lpLuid);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool AdjustTokenPrivileges(IntPtr TokenHandle, bool DisableAllPrivileges, ref TOKEN_PRIVILEGES NewState, UInt32 BufferLength, IntPtr PreviousState, IntPtr ReturnLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr hObject);

    private const UInt32 TOKEN_ADJUST_PRIVILEGES = 0x20;
    private const UInt32 TOKEN_QUERY = 0x8;
    private const UInt32 SE_PRIVILEGE_ENABLED = 0x2;
    private const int ERROR_NOT_ALL_ASSIGNED = 1300;

    public static string Enable()
    {
        IntPtr token;
        if (!OpenProcessToken(System.Diagnostics.Process.GetCurrentProcess().Handle, TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, out token))
        {
            return "failed opening token: " + new Win32Exception(Marshal.GetLastWin32Error()).Message;
        }

        try
        {
            LUID luid;
            if (!LookupPrivilegeValue(null, "SeDebugPrivilege", out luid))
            {
                return "failed looking up SeDebugPrivilege: " + new Win32Exception(Marshal.GetLastWin32Error()).Message;
            }

            TOKEN_PRIVILEGES privileges = new TOKEN_PRIVILEGES();
            privileges.PrivilegeCount = 1;
            privileges.Luid = luid;
            privileges.Attributes = SE_PRIVILEGE_ENABLED;

            if (!AdjustTokenPrivileges(token, false, ref privileges, 0, IntPtr.Zero, IntPtr.Zero))
            {
                return "failed adjusting token: " + new Win32Exception(Marshal.GetLastWin32Error()).Message;
            }

            int lastError = Marshal.GetLastWin32Error();
            if (lastError == ERROR_NOT_ALL_ASSIGNED)
            {
                return "not assigned to this token";
            }

            return "enabled";
        }
        finally
        {
            CloseHandle(token);
        }
    }
}
"@

    try {
        Add-Type -TypeDefinition $source -ErrorAction Stop
        $result = [UnstuckCommandPrivilege]::Enable()
        $script:DebugPrivilegeEnabled = ($result -eq "enabled")
        Write-Status ("debug privilege {0}" -f $result)
    } catch {
        $script:DebugPrivilegeEnabled = $false
        Write-Status ("WARNING debug privilege enable failed: {0}" -f $_.Exception.Message)
    }

    return $script:DebugPrivilegeEnabled
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

function Get-ParentProcessName {
    param(
        [object]$CimProcess,
        [hashtable]$ProcessMap
    )
    if ($CimProcess -and $ProcessMap.ContainsKey([int]$CimProcess.ParentProcessId)) {
        return [string]$ProcessMap[[int]$CimProcess.ParentProcessId].ProcessName
    }
    return ""
}

function Get-DescendantProcessIds {
    param([int]$RootProcessId)

    $childrenByParent = @{}
    foreach ($proc in (Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
        $parentId = [int]$proc.ParentProcessId
        if (-not $childrenByParent.ContainsKey($parentId)) {
            $childrenByParent[$parentId] = New-Object System.Collections.Generic.List[int]
        }
        [void]$childrenByParent[$parentId].Add([int]$proc.ProcessId)
    }

    $result = New-Object System.Collections.Generic.List[int]
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue($RootProcessId)
    while ($queue.Count -gt 0) {
        $parentId = [int]$queue.Dequeue()
        if (-not $childrenByParent.ContainsKey($parentId)) { continue }
        foreach ($childId in $childrenByParent[$parentId]) {
            [void]$result.Add($childId)
            $queue.Enqueue($childId)
        }
    }

    return @($result)
}

function Stop-ProcessTree {
    param([int]$RootProcessId)

    $descendants = @(Get-DescendantProcessIds -RootProcessId $RootProcessId)
    foreach ($childId in @($descendants | Sort-Object -Descending)) {
        $child = Get-Process -Id $childId -ErrorAction SilentlyContinue
        if ($child) {
            Write-Status ("ACTION stop child PID={0} name={1} rootPID={2}" -f $child.Id, $child.ProcessName, $RootProcessId)
            Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue
        }
    }
    return $descendants.Count
}

function Test-HasTerminalAncestry {
    param(
        [int]$ProcessId,
        [hashtable]$ProcessMap,
        [int]$MaxDepth = 5
    )

    if ($ProcessMap.ContainsKey($ProcessId)) {
        $self = $ProcessMap[$ProcessId]
        if ($self.MainWindowHandle -ne 0 -and $self.ProcessName -match '^(?i:WindowsTerminal|OpenConsole|conhost|cmd|powershell|pwsh)$') {
            return $true
        }
    }

    $currentId = $ProcessId
    for ($depth = 0; $depth -lt $MaxDepth; $depth++) {
        $cim = Get-CimProc -Id $currentId
        if (-not $cim) { return $false }
        $parentId = [int]$cim.ParentProcessId
        if ($parentId -le 0 -or -not $ProcessMap.ContainsKey($parentId)) { return $false }
        $parent = $ProcessMap[$parentId]
        if ($parent.ProcessName -match '^(?i:WindowsTerminal|OpenConsole|conhost)$') {
            return $true
        }
        if ($parent.ProcessName -match '^(?i:cmd|powershell|pwsh)$' -and $parent.MainWindowHandle -ne 0) {
            return $true
        }
        $currentId = $parentId
    }

    return $false
}

function Test-IsInteractiveShellCommand {
    param(
        [string]$ProcessName,
        [string]$CommandLine
    )

    $name = [string]$ProcessName
    $cmd = ([string]$CommandLine).Trim()
    if ($name -notmatch '^(?i:cmd|powershell|pwsh)$') { return $false }
    if ([string]::IsNullOrWhiteSpace($cmd)) { return $true }
    if ($cmd -match '^(?i)\s*"?[^"]*\\(cmd|powershell|pwsh)(\.exe)?"?\s*$') { return $true }
    if ($cmd -match '^(?i)\s*"?(cmd|powershell|pwsh)(\.exe)?"?\s*$') { return $true }
    if ($cmd -notmatch '(?i)(\s-|/c|/k|\.ps1|\.cmd|\.bat|EncodedCommand|Command|File|NoProfile|ExecutionPolicy)') {
        return $true
    }
    return $false
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
        [string]$Reason,
        [switch]$IncludeDescendants
    )
    if (-not $Process) { return }
    Write-Status ("ACTION stop PID={0} name={1} reason={2}" -f $Process.Id, $Process.ProcessName, $Reason)
    if (-not $DryRun) {
        $descendantCount = 0
        if ($IncludeDescendants) {
            $descendantCount = Stop-ProcessTree -RootProcessId ([int]$Process.Id)
        }
        Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
        $detail = if ($IncludeDescendants) {
            "stopped with {0} descendant process(es): {1}" -f $descendantCount, $Reason
        } else {
            "stopped: {0}" -f $Reason
        }
        Notify-RecoveryAction -Action "recovered process" -Target ("{0} PID {1}" -f $Process.ProcessName, $Process.Id) -Detail $detail
    } else {
        $treeText = if ($IncludeDescendants) { " and descendants" } else { "" }
        Send-TrayNotification -Title "unstuck-command dry run" -Message ("Would stop {0} PID {1}{2}: {3}" -f $Process.ProcessName, $Process.Id, $treeText, $Reason) -Icon "Warning"
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
        [void]$script:StartedDismIds.Add([int]$proc.Id)
        Write-Status ("started DISM PID={0}" -f $proc.Id)
        Notify-RecoveryAction -Action "restarted repair" -Target ("DISM PID {0}" -f $proc.Id) -Detail "RestoreHealth relaunched after stale or failed repair"
    } else {
        Send-TrayNotification -Title "unstuck-command dry run" -Message ("Would start DISM {0}" -f $args) -Icon "Warning"
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

    if (-not (Wait-WithTrayEvents -Seconds $SampleSeconds)) {
        Write-Status "stop requested during sample wait."
        return
    }

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

    if (-not (Wait-WithTrayEvents -Seconds $PostActionWaitSeconds)) {
        Write-Status "stop requested during post-action wait."
        return
    }

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
    if (-not (Wait-WithTrayEvents -Seconds $SampleSeconds)) {
        Write-Status "stop requested during generic report wait."
        return
    }
    $map = Get-ProcMap
    $count = 0
    $skipped = 0
    $benign = 0
    $recovered = 0
    $scanIndex = 0
    foreach ($proc in (Get-ProcByName $names)) {
        try {
            if ($proc.Id -eq $PID) { continue }
            $scanIndex++
            if (($scanIndex % 5) -eq 0) {
                Invoke-RealtimePump
                if ($script:StopRequested) { return }
            }
            $oldCpu = if ($before.ContainsKey($proc.Id)) { $before[$proc.Id] } else { $proc.CPU }
            $delta = $proc.CPU - $oldCpu
            $ageSeconds = if ($proc.StartTime) { ((Get-Date) - $proc.StartTime).TotalSeconds } else { 0 }
            if ($delta -ge 0 -and $delta -lt $MinCpuDelta -and $ageSeconds -ge $GenericStaleMinAgeSeconds) {
                $cim = Get-CimProc -Id $proc.Id
                $parentName = Get-ParentProcessName -CimProcess $cim -ProcessMap $map
                if ((-not $IncludeBenignGenericCandidates) -and (Test-IsBenignGenericCandidate -ProcessName $proc.ProcessName -ParentName $parentName -CommandLine $cim.CommandLine)) {
                    $benign++
                    Write-Status ("STALE-CANDIDATE-IGNORED PID={0} name={1} parent={2} ageSec={3:n0} reason=known-benign cmd={4}" -f $proc.Id, $proc.ProcessName, $parentName, $ageSeconds, $cim.CommandLine)
                    continue
                }
                $canRecoverTerminalCommand = (
                    $RecoverStaleTerminalCommands -and
                    $Aggressive -and
                    $ageSeconds -ge $TerminalCommandStaleSeconds -and
                    (Test-HasTerminalAncestry -ProcessId ([int]$proc.Id) -ProcessMap $map) -and
                    -not (Test-IsInteractiveShellCommand -ProcessName $proc.ProcessName -CommandLine $cim.CommandLine)
                )
                if ($count -ge $MaxGenericCandidates) {
                    $skipped++
                    if (-not $canRecoverTerminalCommand) {
                        continue
                    }
                }
                $count++
                Write-Status ("STALE-CANDIDATE PID={0} name={1} parent={2} ageSec={3:n0} cpuDelta={4:n3} cmd={5}" -f $proc.Id, $proc.ProcessName, $parentName, $ageSeconds, $delta, $cim.CommandLine)
                if ($canRecoverTerminalCommand) {
                    $recovered++
                    Write-Status ("STALE-TERMINAL-RECOVERY PID={0} name={1} parent={2} ageSec={3:n0} cmd={4}" -f $proc.Id, $proc.ProcessName, $parentName, $ageSeconds, $cim.CommandLine)
                    Stop-TargetProcess -Process $proc -Reason ("stale terminal command idle for {0:n0}s; parent={1}" -f $ageSeconds, $parentName) -IncludeDescendants
                }
            }
        } catch {
            Write-Status ("WARNING stale candidate scan skipped PID={0} name={1}: {2}" -f $proc.Id, $proc.ProcessName, $_.Exception.Message)
            continue
        }
    }
    if ($count -gt 0) {
        Write-Status ("STALE-CANDIDATE-SUMMARY count={0} ignoredBenign={1} recovered={2} skippedAfterLimit={3}" -f $count, $benign, $recovered, $skipped)
        $cooldownElapsed = ((Get-Date) - $script:LastGenericCandidateNotification).TotalSeconds -ge $GenericCandidateNotifyCooldownSeconds
        if ($cooldownElapsed) {
            $script:LastGenericCandidateNotification = Get-Date
            Send-TrayNotification -Title "unstuck-command stale commands found" -Message ("Found {0} idle terminal/command candidates. See {1}" -f $count, $LogPath) -Icon "Warning"
        } else {
            Write-Status ("STALE-CANDIDATE-NOTIFY-SKIPPED cooldownSec={0}" -f $GenericCandidateNotifyCooldownSeconds)
        }
    } else {
        Write-Status ("no stale terminal/command candidates found. ignoredBenign={0}" -f $benign)
    }
}

function Test-IsBenignGenericCandidate {
    param(
        [string]$ProcessName,
        [string]$ParentName,
        [string]$CommandLine
    )
    $cmd = [string]$CommandLine
    $parent = [string]$ParentName

    if ($cmd -match '(?i)\\FitGirl\\|qbittorrent-fitgirl-force-auto-install|\\runtime\\state\\inno-temp\\|fgpack\.exe|build01\.bat|Force-QbitFitGirlAutoInstall|FitGirlInnoPopupRescue') { return $true }
    if ($cmd -match '(?i)\\\.codex\\plugins\\cache\\openai-bundled\\chrome\\|chrome-extension://|nativeMessaging|extension-host\.exe') { return $true }
    if ($cmd -match '(?i)\\\.codex\\hooks\\|task-complete-alert-watcher|CodexConnectivityGuardian|CodexScheduledTaskNoPopupSanitizer|CodexHostResponsivenessGuardian') { return $true }
    if ($cmd -match '(?i)freeze-escape-guard|FreezeEscapeGuard') { return $true }
    if ($cmd -match '(?i)node\.exe [A-Z]:[/\\]Users[/\\].*[/\\]windows-system-mcp|mcp/server\.mjs') { return $true }
    if ($cmd -match '(?i)hardware-truth-scanner|cpu-live-certainty-scanner') { return $true }
    if ($cmd -match '(?i)core\.hooksPath=NUL -c core\.fsmonitor=false (remote -v|rev-parse HEAD|status --porcelain)') { return $true }
    if ($parent -match '(?i)codex|wscript|wslhost|chrome|setup\.tmp|fgpack') { return $true }
    if ([string]::IsNullOrWhiteSpace($cmd)) { return $true }

    return $false
}

function Invoke-AppAndCommandScan {
    if (-not $IncludeAppReport -and -not $IncludeGenericReport -and -not $RecoverHungExplorer -and -not $RecoverHungTerminalWindows -and -not $RecoverHungGenericApps -and -not $RecoverStaleTerminalCommands) {
        return
    }

    Write-Status "generic app/command scan start."

    if ($IncludeAppReport -or $RecoverHungExplorer -or $RecoverHungTerminalWindows -or $RecoverHungGenericApps) {
        $firstHung = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
            $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle -and -not $_.Responding
        })
        if ($firstHung.Count -gt 0 -and $AppHungConfirmSeconds -gt 0) {
            if (-not (Wait-WithTrayEvents -Seconds $AppHungConfirmSeconds)) {
                Write-Status "stop requested during app hang confirmation wait."
                return
            }
        }

        $secondHungIds = @{}
        foreach ($hung in (Get-Process -ErrorAction SilentlyContinue | Where-Object {
            $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle -and -not $_.Responding
        })) {
            $secondHungIds[[int]$hung.Id] = $hung
        }

        $apps = @()
        foreach ($candidate in $firstHung) {
            if ($secondHungIds.ContainsKey([int]$candidate.Id)) {
                $apps += $secondHungIds[[int]$candidate.Id]
            } else {
                Write-Status ("TRANSIENT-HUNG-APP PID={0} name={1} title={2} recovered before action." -f $candidate.Id, $candidate.ProcessName, $candidate.MainWindowTitle)
            }
        }

        foreach ($app in $apps) {
            Write-Status ("HUNG-APP PID={0} name={1} title={2}" -f $app.Id, $app.ProcessName, $app.MainWindowTitle)
            if ($RecoverHungExplorer -and $app.ProcessName -eq "explorer") {
                Write-Status "ACTION restart Explorer because it is not responding."
                if (-not $DryRun) {
                    Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue
                    Start-Process explorer.exe
                    Notify-RecoveryAction -Action "unfroze Explorer" -Target ("Explorer PID {0}" -f $app.Id) -Detail "restarted after confirmed non-responding state"
                } else {
                    Send-TrayNotification -Title "unstuck-command dry run" -Message ("Would restart hung Explorer PID {0}" -f $app.Id) -Icon "Warning"
                }
            } elseif ($RecoverHungTerminalWindows -and (Test-IsTerminalWindowProcess -Process $app)) {
                Write-Status "ACTION restart terminal because it is not responding."
                if (-not $DryRun) {
                    [void](Stop-ProcessTree -RootProcessId ([int]$app.Id))
                    Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue
                    Start-ReplacementTerminal
                    Notify-RecoveryAction -Action "unfroze terminal" -Target ("{0} PID {1}" -f $app.ProcessName, $app.Id) -Detail "restarted after confirmed non-responding terminal state"
                } else {
                    Send-TrayNotification -Title "unstuck-command dry run" -Message ("Would restart hung terminal PID {0}" -f $app.Id) -Icon "Warning"
                }
            } elseif ($RecoverHungGenericApps -and -not (Test-IsProtectedHungApp -Process $app)) {
                Restart-HungGenericApp -Process $app -Reason "confirmed non-responding GUI app scan"
            } elseif ($RecoverHungGenericApps) {
                Write-Status ("HUNG-APP-PROTECTED PID={0} name={1} title={2}" -f $app.Id, $app.ProcessName, $app.MainWindowTitle)
            }
        }
        if (-not $apps) {
            Write-Status "no non-responding GUI apps found."
        }
    }

    if ($IncludeGenericReport -or $RecoverStaleTerminalCommands) {
        Show-GenericStaleReport
    }

    Write-Status "generic app/command scan complete."
}

try {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $LogPath) | Out-Null
    Write-Status "unstuck-command start DryRun=$DryRun Aggressive=$Aggressive RerunDism=$RerunDism IncludeGenericReport=$IncludeGenericReport IncludeAppReport=$IncludeAppReport RecoverHungExplorer=$RecoverHungExplorer RecoverHungTerminalWindows=$RecoverHungTerminalWindows RecoverHungGenericApps=$RecoverHungGenericApps RecoverStaleTerminalCommands=$RecoverStaleTerminalCommands NoTray=$NoTray NoServicingScan=$NoServicingScan NoRestartRecoveredApps=$NoRestartRecoveredApps NoDebugPrivilege=$NoDebugPrivilege SampleSeconds=$SampleSeconds MaxMonitorSeconds=$MaxMonitorSeconds ImmediateScanIntervalSeconds=$ImmediateScanIntervalSeconds ImmediateHungConfirmSeconds=$ImmediateHungConfirmSeconds TerminalCommandStaleSeconds=$TerminalCommandStaleSeconds GenericAppRecoveryCooldownSeconds=$GenericAppRecoveryCooldownSeconds"
    if (-not (Initialize-SingleInstance)) {
        return
    }
    Initialize-TrayIcon
    if ($ForceTestNotification) {
        Notify-RecoveryAction -Action "notification test" -Target "test target" -Detail "tray notification plumbing verified"
        return
    }

    if (-not (Test-IsAdmin)) {
        Write-Status "WARNING not elevated. Detection works, but stopping service-owned workers may fail. Run the .cmd launcher as Administrator for full repair."
    }
    if ($Aggressive -and -not $NoDebugPrivilege) {
        [void](Enable-DebugPrivilege)
    } elseif ($NoDebugPrivilege) {
        Write-Status "debug privilege skipped by -NoDebugPrivilege."
    }

    $deadline = $null
    if ($MaxMonitorSeconds -gt 0) {
        $deadline = (Get-Date).AddSeconds($MaxMonitorSeconds)
    }
    $pass = 0
    do {
        Invoke-TrayEvents
        if ($script:StopRequested) {
            Write-Status "monitor stopped by tray exit before pass."
            break
        }

        $pass++
        try {
            Write-Status "monitor pass $pass"
            if ($NoServicingScan) {
                Write-Status "servicing scan skipped by -NoServicingScan."
            } else {
                Invoke-ServicingUnstuck
            }
            if (-not $script:StopRequested) {
                Invoke-ImmediateUnfreezeScan
                Invoke-AppAndCommandScan
            }
        } catch {
            Write-Status ("ERROR monitor pass {0} failed but tray monitor will continue: {1}" -f $pass, $_.Exception.Message)
            Write-Status ("ERROR detail: {0}" -f $_.ScriptStackTrace)
            if (-not $script:ContinuousTrayMode) { throw }
            if ($script:StopRequested) {
                Write-Status "monitor stopped by tray exit during failed pass."
                break
            }
            if (-not (Wait-WithTrayEvents -Seconds 2)) {
                Write-Status "monitor stopped by tray exit after failed pass."
                break
            }
            continue
        }

        if ($script:StopRequested) {
            Write-Status "monitor stopped by tray exit after pass $pass."
            break
        }

        $activeRepair = @(Get-DismRepairProcess -Processes @(Get-ProcByName @("Dism")))
        if ($activeRepair.Count -eq 0) {
            if ($script:ContinuousTrayMode) {
                Write-Status ("no active RestoreHealth repair after pass {0}; tray monitor remains active and will rescan in {1}s." -f $pass, $MonitorIntervalSeconds)
                if (-not (Wait-WithTrayEvents -Seconds $MonitorIntervalSeconds)) {
                    Write-Status "monitor stopped by tray exit during idle interval wait."
                    break
                }
                continue
            } else {
                Write-Status "no active RestoreHealth repair after pass $pass."
                break
            }
        }
        if ($deadline -ne $null -and (Get-Date) -ge $deadline) {
            if ($script:ContinuousTrayMode) {
                Write-Status ("active RestoreHealth PID={0}; monitor time window reached, resetting window because tray mode is still active." -f ($activeRepair.Id -join ","))
                $deadline = (Get-Date).AddSeconds($MaxMonitorSeconds)
            } else {
                Write-Status ("monitor timeout reached with active RestoreHealth PID={0}" -f ($activeRepair.Id -join ","))
                break
            }
        }
        Write-Status ("active RestoreHealth PID={0}; next monitor pass in {1}s" -f ($activeRepair.Id -join ","), $MonitorIntervalSeconds)
        if (-not (Wait-WithTrayEvents -Seconds $MonitorIntervalSeconds)) {
            Write-Status "monitor stopped by tray exit during interval wait."
            break
        }
    } while ($true)

    if (-not $script:StopRequested -and -not $script:ContinuousTrayMode) {
        Invoke-AppAndCommandScan
    }
    if (-not $IncludeGenericReport -and -not $IncludeAppReport -and -not $RecoverHungExplorer -and -not $RecoverHungTerminalWindows -and -not $RecoverHungGenericApps -and -not $RecoverStaleTerminalCommands) {
        Write-Status "generic app/command scan skipped; add -IncludeGenericReport or -IncludeAppReport for read-only candidate listing."
    }
} finally {
    if ($script:StopRequested) {
        Stop-StartedDismProcesses
    }
    Dispose-TrayIcon
    Dispose-SingleInstance
    Write-Status "unstuck-command complete. Log: $LogPath"
}
