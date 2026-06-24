[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$NoDisplayReset,
    [switch]$NoExplorerRestart,
    [switch]$NoGenericAppRecovery,
    [switch]$NoServicingRecovery,
    [switch]$NoStaleTerminalCommandRecovery,
    [int]$SampleSeconds = 8,
    [int]$MaxMonitorSeconds = 45,
    [int]$AppHungConfirmSeconds = 2,
    [int]$TerminalCommandStaleSeconds = 45,
    [int]$GenericStaleMinAgeSeconds = 60
)

$ErrorActionPreference = 'Continue'
$script:Root = Split-Path -Path $PSCommandPath -Parent
$script:LogDir = Join-Path $script:Root 'logs'
New-Item -ItemType Directory -Force -Path $script:LogDir | Out-Null
$script:LogPath = Join-Path $script:LogDir ('mega-unfreeze-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

function Write-MegaLog {
    param([string]$Message)
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Message
    Add-Content -LiteralPath $script:LogPath -Value $line
    Write-Host $line
}

function Invoke-IfNotDryRun {
    param([scriptblock]$Action, [string]$DryRunMessage)
    if ($DryRun) { Write-MegaLog ('DRYRUN {0}' -f $DryRunMessage); return }
    & $Action
}

Write-MegaLog 'START Hermes Mega Unfreeze Win11 pass'
Write-MegaLog ('root={0}' -f $script:Root)

try { Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop } catch { Write-MegaLog ('WinForms-load-failed: {0}' -f $_.Exception.Message) }
try {
    Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class HermesMegaUnfreezeWin32 {
  public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lp);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
  [DllImport("user32.dll")] public static extern int GetClassName(IntPtr hWnd, StringBuilder text, int count);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
  [DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
}
'@ -ErrorAction Stop
} catch { Write-MegaLog ('Win32-type-load-failed: {0}' -f $_.Exception.Message) }

function Send-DisplayPipelineReset {
    if ($NoDisplayReset) { Write-MegaLog 'display-reset-skipped'; return }
    Invoke-IfNotDryRun -DryRunMessage 'send Win+Ctrl+Shift+B display pipeline reset' -Action {
        try {
            [byte]$VK_LWIN=0x5B; [byte]$VK_CONTROL=0x11; [byte]$VK_SHIFT=0x10; [byte]$VK_B=0x42; [uint32]$UP=0x0002
            [HermesMegaUnfreezeWin32]::keybd_event($VK_LWIN,0,0,[UIntPtr]::Zero)
            [HermesMegaUnfreezeWin32]::keybd_event($VK_CONTROL,0,0,[UIntPtr]::Zero)
            [HermesMegaUnfreezeWin32]::keybd_event($VK_SHIFT,0,0,[UIntPtr]::Zero)
            [HermesMegaUnfreezeWin32]::keybd_event($VK_B,0,0,[UIntPtr]::Zero)
            Start-Sleep -Milliseconds 80
            [HermesMegaUnfreezeWin32]::keybd_event($VK_B,0,$UP,[UIntPtr]::Zero)
            [HermesMegaUnfreezeWin32]::keybd_event($VK_SHIFT,0,$UP,[UIntPtr]::Zero)
            [HermesMegaUnfreezeWin32]::keybd_event($VK_CONTROL,0,$UP,[UIntPtr]::Zero)
            [HermesMegaUnfreezeWin32]::keybd_event($VK_LWIN,0,$UP,[UIntPtr]::Zero)
            Write-MegaLog 'display-driver-reset-hotkey-sent Win+Ctrl+Shift+B'
        } catch { Write-MegaLog ('display-reset-hotkey-failed: {0}' -f $_.Exception.Message) }
    }
}

function Get-VisibleWindows {
    $list = New-Object System.Collections.ArrayList
    try {
        $cb = [HermesMegaUnfreezeWin32+EnumWindowsProc]{ param([IntPtr]$h,[IntPtr]$l)
            if ([HermesMegaUnfreezeWin32]::IsWindowVisible($h)) {
                $titleBuilder = New-Object System.Text.StringBuilder 512
                $classBuilder = New-Object System.Text.StringBuilder 256
                [void][HermesMegaUnfreezeWin32]::GetWindowText($h,$titleBuilder,$titleBuilder.Capacity)
                [void][HermesMegaUnfreezeWin32]::GetClassName($h,$classBuilder,$classBuilder.Capacity)
                [uint32]$windowPid = 0
                [void][HermesMegaUnfreezeWin32]::GetWindowThreadProcessId($h,[ref]$windowPid)
                if ($windowPid -gt 0) { [void]$list.Add([pscustomobject]@{Handle=$h;Pid=[int]$windowPid;Title=$titleBuilder.ToString();Class=$classBuilder.ToString()}) }
            }
            return $true
        }
        [void][HermesMegaUnfreezeWin32]::EnumWindows($cb,[IntPtr]::Zero)
    } catch { Write-MegaLog ('window-enumeration-failed: {0}' -f $_.Exception.Message) }
    return $list
}

function Send-TerminalUnfreezeKeys {
    param([IntPtr]$Handle, [string]$Label)
    Invoke-IfNotDryRun -DryRunMessage ('terminal Esc Esc Ctrl+C Enter {0}' -f $Label) -Action {
        try {
            [HermesMegaUnfreezeWin32]::ShowWindow($Handle,9) | Out-Null
            Start-Sleep -Milliseconds 100
            [HermesMegaUnfreezeWin32]::SetForegroundWindow($Handle) | Out-Null
            Start-Sleep -Milliseconds 150
            [System.Windows.Forms.SendKeys]::SendWait('{ESC}')
            Start-Sleep -Milliseconds 80
            [System.Windows.Forms.SendKeys]::SendWait('{ESC}')
            Start-Sleep -Milliseconds 80
            [System.Windows.Forms.SendKeys]::SendWait('^c')
            Start-Sleep -Milliseconds 120
            [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
            Write-MegaLog ('terminal-unfreeze-keys-sent {0}' -f $Label)
        } catch { Write-MegaLog ('terminal-unfreeze-keys-failed {0}: {1}' -f $Label,$_.Exception.Message) }
    }
}

function Invoke-TerminalForegroundRecovery {
    $terminalNames = 'WindowsTerminal','wt','OpenConsole','ConsoleWindowHost','conhost','powershell','pwsh','cmd','ubuntu','wsl','Codex','claude','node','python'
    foreach ($w in @(Get-VisibleWindows)) {
        $p = $null
        try { $p = Get-Process -Id $w.Pid -ErrorAction Stop } catch {}
        $name = if ($p) { $p.ProcessName } else { '' }
        $hit = $false
        foreach ($n in $terminalNames) {
            if ($name -like "*$n*" -or $w.Title -like "*$n*" -or $w.Class -like '*ConsoleWindowClass*' -or $w.Class -like '*CASCADIA_HOSTING_WINDOW_CLASS*') { $hit = $true; break }
        }
        if ($hit) { Send-TerminalUnfreezeKeys -Handle $w.Handle -Label ("pid={0} name={1} title='{2}' class={3}" -f $w.Pid,$name,$w.Title,$w.Class) }
    }
}

function Invoke-InputAndShellRefresh {
    Invoke-IfNotDryRun -DryRunMessage 'start ctfmon input broker' -Action {
        try { Start-Process -FilePath 'ctfmon.exe' -WindowStyle Hidden -ErrorAction SilentlyContinue; Write-MegaLog 'ctfmon-input-broker-started-or-refreshed' } catch { Write-MegaLog ('ctfmon-refresh-failed: {0}' -f $_.Exception.Message) }
    }
    foreach ($svc in 'TabletInputService','ShellHWDetection') {
        try {
            $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
            if ($s -and $s.Status -eq 'Stopped') {
                Invoke-IfNotDryRun -DryRunMessage ('start service {0}' -f $svc) -Action { Start-Service -Name $svc -ErrorAction SilentlyContinue; Write-MegaLog ('service-start-attempt {0}' -f $svc) }
            } else { Write-MegaLog ('service-ok-or-missing {0}' -f $svc) }
        } catch { Write-MegaLog ('service-start-skip {0}: {1}' -f $svc,$_.Exception.Message) }
    }
}

function Stop-ChildTree {
    param([int]$RootProcessId)
    $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    $childrenByParent = @{}
    foreach ($c in $all) {
        $pp = [int]$c.ParentProcessId
        if (-not $childrenByParent.ContainsKey($pp)) { $childrenByParent[$pp] = New-Object System.Collections.Generic.List[int] }
        [void]$childrenByParent[$pp].Add([int]$c.ProcessId)
    }
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue($RootProcessId)
    $desc = New-Object System.Collections.Generic.List[int]
    while ($queue.Count -gt 0) {
        $id = [int]$queue.Dequeue()
        if ($childrenByParent.ContainsKey($id)) {
            foreach ($childId in @($childrenByParent[$id])) { [void]$desc.Add($childId); $queue.Enqueue($childId) }
        }
    }
    foreach ($childId in @($desc | Sort-Object -Descending)) {
        try { Stop-Process -Id $childId -Force -ErrorAction SilentlyContinue; Write-MegaLog ('stopped-child pid={0} root={1}' -f $childId,$RootProcessId) } catch {}
    }
    return $desc.Count
}

function Test-IsTerminalProcess {
    param([System.Diagnostics.Process]$Process)
    if (-not $Process) { return $false }
    if ($Process.ProcessName -match '^(?i:WindowsTerminal|OpenConsole|conhost|cmd|powershell|pwsh)$') { return $true }
    if ([string]$Process.MainWindowTitle -match '(?i)(administrator: windows powershell|powershell|command prompt|cmd|ubuntu|wsl|codex|claude|terminal)') { return $true }
    return $false
}

function Test-IsProtectedHungApp {
    param([System.Diagnostics.Process]$Process)
    if (-not $Process) { return $true }
    $name = $Process.ProcessName
    if ($name -match '^(?i:System|Idle|Registry|smss|csrss|wininit|winlogon|services|lsass|dwm|fontdrvhost)$') { return $true }
    if ($name -match '^(?i:Dism|DismHost|TiWorker|TrustedInstaller|msiexec|setup|setup\.tmp|fgpack|cleanmgr)$') { return $true }
    return $false
}

function Start-ReplacementTerminal {
    foreach ($candidate in 'wt.exe','powershell.exe','cmd.exe') {
        try { Start-Process -FilePath $candidate -ErrorAction SilentlyContinue | Out-Null; Write-MegaLog ('replacement-terminal-started {0}' -f $candidate); return } catch {}
    }
    Write-MegaLog 'replacement-terminal-start-failed'
}

function Invoke-HungWindowRecovery {
    if ($AppHungConfirmSeconds -gt 0) { Start-Sleep -Seconds $AppHungConfirmSeconds }
    $hung = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle -and -not $_.Responding })
    foreach ($app in $hung) {
        Write-MegaLog ('hung-window pid={0} name={1} title={2}' -f $app.Id,$app.ProcessName,$app.MainWindowTitle)
        if ($app.ProcessName -eq 'explorer') {
            if ($NoExplorerRestart) { Write-MegaLog 'explorer-hung-restart-skipped'; continue }
            Invoke-IfNotDryRun -DryRunMessage ('restart hung explorer pid={0}' -f $app.Id) -Action { Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue; Start-Process explorer.exe; Write-MegaLog ('explorer-restarted-from-hung pid={0}' -f $app.Id) }
            continue
        }
        if (Test-IsTerminalProcess -Process $app) {
            Invoke-IfNotDryRun -DryRunMessage ('restart hung terminal pid={0}' -f $app.Id) -Action { [void](Stop-ChildTree -RootProcessId ([int]$app.Id)); Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue; Start-ReplacementTerminal; Write-MegaLog ('terminal-restarted-from-hung pid={0}' -f $app.Id) }
            continue
        }
        if (-not $NoGenericAppRecovery -and -not (Test-IsProtectedHungApp -Process $app)) {
            $exe = $null
            try { $exe = $app.Path } catch {}
            Invoke-IfNotDryRun -DryRunMessage ('restart generic hung app pid={0} name={1}' -f $app.Id,$app.ProcessName) -Action {
                Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue
                Start-Sleep -Milliseconds 300
                if ($exe -and (Test-Path -LiteralPath $exe)) { Start-Process -FilePath $exe -ErrorAction SilentlyContinue | Out-Null; Write-MegaLog ('generic-app-restarted name={0} path={1}' -f $app.ProcessName,$exe) }
                else { Write-MegaLog ('generic-app-stopped-no-restart-path name={0}' -f $app.ProcessName) }
            }
        } else { Write-MegaLog ('hung-window-protected-or-skipped pid={0} name={1}' -f $app.Id,$app.ProcessName) }
    }
    if ($hung.Count -eq 0) { Write-MegaLog 'no-confirmed-hung-windows-found' }
}

function Invoke-ShellSurfaceRecovery {
    foreach ($name in 'StartMenuExperienceHost','ShellExperienceHost','SearchHost','TextInputHost','ApplicationFrameHost') {
        foreach ($p in @(Get-Process -Name $name -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 -and -not $_.Responding })) {
            Invoke-IfNotDryRun -DryRunMessage ('restart hung shell surface {0} pid={1}' -f $name,$p.Id) -Action { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; Write-MegaLog ('shell-surface-stopped-for-auto-restart name={0} pid={1}' -f $name,$p.Id) }
        }
    }
    if (-not $NoExplorerRestart) {
        $explorers = @(Get-Process explorer -ErrorAction SilentlyContinue)
        if ($explorers.Count -eq 0) { Invoke-IfNotDryRun -DryRunMessage 'start missing explorer shell' -Action { Start-Process explorer.exe; Write-MegaLog 'explorer-started-missing' } }
    }
}

function Invoke-UnstuckCommandMonitorPass {
    if ($NoServicingRecovery -and $NoStaleTerminalCommandRecovery -and $NoGenericAppRecovery) { Write-MegaLog 'unstuck-command-pass-skipped-by-switches'; return }
    $unstuck = Join-Path $script:Root 'Unstuck-Command.ps1'
    if (-not (Test-Path -LiteralPath $unstuck)) { Write-MegaLog ('unstuck-command-script-missing {0}' -f $unstuck); return }
    $unstuckLog = Join-Path $script:LogDir 'unstuck-command.log'
    $dismSource = Join-Path $script:Root 'repair-source\sources\install.esd'
    $unstuckParams = @{
        NoTray = $true
        Aggressive = $true
        IncludeAppReport = $true
        RecoverHungExplorer = $true
        RecoverHungTerminalWindows = $true
        RecoverHungGenericApps = $true
        SampleSeconds = $SampleSeconds
        AppHungConfirmSeconds = $AppHungConfirmSeconds
        MaxMonitorSeconds = $MaxMonitorSeconds
        TerminalCommandStaleSeconds = $TerminalCommandStaleSeconds
        GenericStaleMinAgeSeconds = $GenericStaleMinAgeSeconds
        LogPath = $unstuckLog
        DismSource = $dismSource
    }
    if (-not $NoStaleTerminalCommandRecovery) { $unstuckParams['IncludeGenericReport'] = $true; $unstuckParams['RecoverStaleTerminalCommands'] = $true }
    if (-not $NoServicingRecovery) { $unstuckParams['RerunDism'] = $true } else { $unstuckParams['NoServicingScan'] = $true }
    if ($DryRun) { $unstuckParams['DryRun'] = $true }
    if ($NoGenericAppRecovery) { $unstuckParams['NoRestartRecoveredApps'] = $true }
    Write-MegaLog ('invoke-existing-unstuck-command params={0}' -f (($unstuckParams.GetEnumerator() | Sort-Object Name | ForEach-Object { '{0}={1}' -f $_.Name,$_.Value }) -join ' '))
    try { & $unstuck @unstuckParams } catch { Write-MegaLog ('unstuck-command-pass-error: {0}' -f $_.Exception.Message) }
}

Invoke-TerminalForegroundRecovery
Invoke-InputAndShellRefresh
Send-DisplayPipelineReset
Invoke-ShellSurfaceRecovery
Invoke-HungWindowRecovery
Invoke-UnstuckCommandMonitorPass

Write-MegaLog ('END Hermes Mega Unfreeze Win11 pass log={0}' -f $script:LogPath)
