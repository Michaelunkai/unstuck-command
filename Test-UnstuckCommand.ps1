[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$script = Join-Path $root "Unstuck-Command.ps1"
$launcher = Join-Path $root "unstuck-command.cmd"
$launcherSource = Join-Path $root "UnstuckCommandLauncher.cs"
$launcherExe = Join-Path $root "UnstuckCommandLauncher.exe"

function Read-TextShared {
    param([string]$Path)
    $lastError = $null
    for ($attempt = 1; $attempt -le 20; $attempt++) {
        try {
            $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            try {
                $reader = [System.IO.StreamReader]::new($stream)
                try {
                    return $reader.ReadToEnd()
                } finally {
                    $reader.Dispose()
                }
            } finally {
                $stream.Dispose()
            }
        } catch {
            $lastError = $_
            Start-Sleep -Milliseconds 100
        }
    }
    throw $lastError
}

if (-not (Test-Path -LiteralPath $script)) {
    throw "Missing script: $script"
}

if (-not (Test-Path -LiteralPath $launcher)) {
    throw "Missing launcher: $launcher"
}

if (-not (Test-Path -LiteralPath $launcherSource)) {
    throw "Missing executable launcher source: $launcherSource"
}

if (-not (Test-Path -LiteralPath $launcherExe)) {
    throw "Missing compiled executable launcher: $launcherExe"
}

$tokens = $null
$errors = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$tokens, [ref]$errors)
if ($errors -and $errors.Count -gt 0) {
    $errors | Format-List | Out-String | Write-Error
    throw "Parser failed"
}

Write-Host "Parser PASS"

$proc = Start-Process -FilePath "cmd.exe" -ArgumentList @("/c", "`"$launcher`" -DryRun -NoTray -SampleSeconds 1 -PostActionWaitSeconds 1 -MaxMonitorSeconds 1") -Wait -PassThru -NoNewWindow
if ($proc.ExitCode -ne 0) {
    throw "Launcher dry-run failed with exit code $($proc.ExitCode)"
}

Write-Host "Launcher dry-run PASS"

$log = Join-Path $env:TEMP "unstuck-command-test-exe.log"
Remove-Item -LiteralPath $log -ErrorAction SilentlyContinue
$testInstance = "Local\UnstuckCommandTest_{0}_{1}" -f $PID, ([guid]::NewGuid().ToString("N"))
$null = Start-Process -FilePath $launcherExe -ArgumentList @("-DryRun", "-SelfExitAfterSeconds", "8", "-NoServicingScan", "-SampleSeconds", "1", "-PostActionWaitSeconds", "1", "-MaxMonitorSeconds", "5", "-MonitorIntervalSeconds", "1", "-IncludeAppReport", "-InstanceName", $testInstance, "-LogPath", $log) -PassThru
$deadline = (Get-Date).AddSeconds(60)
$logText = ""
do {
    Start-Sleep -Milliseconds 500
    if (Test-Path -LiteralPath $log) {
        $logText = Read-TextShared -Path $log
    }
} while ((Get-Date) -lt $deadline -and ($logText -notmatch "tray icon removed"))

if (-not (Test-Path -LiteralPath $log)) {
    throw "Executable launcher did not create log: $log"
}
if ($logText -notmatch "tray icon created" -or $logText -notmatch "tray icon removed") {
    throw "Executable launcher tray lifecycle proof missing from log: $log"
}

Write-Host "Executable tray lifecycle PASS"

$notifyLog = Join-Path $env:TEMP "unstuck-command-test-notification.log"
Remove-Item -LiteralPath $notifyLog -ErrorAction SilentlyContinue
$notifyInstance = "Local\UnstuckCommandNotifyTest_{0}_{1}" -f $PID, ([guid]::NewGuid().ToString("N"))
$null = Start-Process -FilePath $launcherExe -ArgumentList @("-ForceTestNotification", "-SelfExitAfterSeconds", "2", "-InstanceName", $notifyInstance, "-LogPath", $notifyLog) -PassThru
$deadline = (Get-Date).AddSeconds(20)
$notifyText = ""
do {
    Start-Sleep -Milliseconds 500
    if (Test-Path -LiteralPath $notifyLog) {
        $notifyText = Read-TextShared -Path $notifyLog
    }
} while ((Get-Date) -lt $deadline -and ($notifyText -notmatch "NOTIFY-RECOVERY action=notification test"))

if ($notifyText -notmatch "NOTIFY-RECOVERY action=notification test") {
    throw "Notification proof missing from log: $notifyLog"
}

Write-Host "Recovery notification path PASS"

$watchdogLog = Join-Path $env:TEMP "unstuck-command-test-watchdog.log"
$probeSource = Join-Path $env:TEMP "UnstuckHungTerminalProbe.cs"
$probeExe = Join-Path $env:TEMP "UnstuckHungTerminalProbe.exe"
Remove-Item -LiteralPath $watchdogLog,$probeSource,$probeExe -ErrorAction SilentlyContinue
@"
using System;
using System.Threading;
using System.Windows.Forms;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        Application.EnableVisualStyles();
        using (var form = new Form())
        {
            form.Text = "Windows PowerShell";
            form.Width = 320;
            form.Height = 120;
            form.Shown += (sender, args) => Thread.Sleep(120000);
            Application.Run(form);
        }
    }
}
"@ | Set-Content -LiteralPath $probeSource -Encoding ASCII
& "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /target:winexe /out:$probeExe $probeSource
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $probeExe)) {
    throw "Failed to compile hung terminal watchdog probe"
}

$hungProbe = Start-Process -FilePath $probeExe -PassThru
try {
    $deadline = (Get-Date).AddSeconds(15)
    do {
        Start-Sleep -Milliseconds 250
        $probeProcess = Get-Process -Id $hungProbe.Id -ErrorAction SilentlyContinue
    } while ((Get-Date) -lt $deadline -and (-not $probeProcess -or $probeProcess.MainWindowHandle -eq 0 -or $probeProcess.Responding))

    if (-not $probeProcess -or $probeProcess.MainWindowHandle -eq 0) {
        throw "Hung terminal watchdog probe did not create a visible window"
    }
    if ($probeProcess.Responding) {
        throw "Hung terminal watchdog probe did not enter a non-responding state"
    }

    $watchdog = Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile", "-STA", "-ExecutionPolicy", "Bypass", "-File", $script, "-DryRun", "-NoTray", "-NoServicingScan", "-IncludeAppReport", "-RecoverHungTerminalWindows", "-ImmediateScanIntervalSeconds", "1", "-ImmediateHungConfirmSeconds", "0", "-SampleSeconds", "1", "-PostActionWaitSeconds", "1", "-MaxMonitorSeconds", "1", "-LogPath", $watchdogLog) -Wait -PassThru -NoNewWindow
    if ($watchdog.ExitCode -ne 0) {
        throw "Immediate watchdog dry-run failed with exit code $($watchdog.ExitCode)"
    }
    $watchdogText = Read-TextShared -Path $watchdogLog
    if ($watchdogText -notmatch "IMMEDIATE-HUNG-SEEN" -or $watchdogText -notmatch "IMMEDIATE-ACTION restart terminal") {
        throw "Immediate terminal watchdog proof missing from log: $watchdogLog"
    }
} finally {
    Stop-Process -Id $hungProbe.Id -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $probeSource,$probeExe -ErrorAction SilentlyContinue
}

Write-Host "Immediate terminal watchdog PASS"

$genericAppLog = Join-Path $env:TEMP "unstuck-command-test-generic-app-recover.log"
$genericAppSource = Join-Path $env:TEMP "UnstuckHungGenericApp.cs"
$genericAppExe = Join-Path $env:TEMP "UnstuckHungGenericApp.exe"
Remove-Item -LiteralPath $genericAppLog,$genericAppSource,$genericAppExe -ErrorAction SilentlyContinue
@"
using System;
using System.Threading;
using System.Windows.Forms;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        Application.EnableVisualStyles();
        using (var form = new Form())
        {
            form.Text = "Frozen Generic App";
            form.Width = 340;
            form.Height = 120;
            form.Shown += (sender, args) => Thread.Sleep(120000);
            Application.Run(form);
        }
    }
}
"@ | Set-Content -LiteralPath $genericAppSource -Encoding ASCII
& "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /target:winexe /out:$genericAppExe $genericAppSource
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $genericAppExe)) {
    throw "Failed to compile hung generic app probe"
}

$genericProbe = Start-Process -FilePath $genericAppExe -PassThru
try {
    $deadline = (Get-Date).AddSeconds(15)
    do {
        Start-Sleep -Milliseconds 250
        $genericProbeProcess = Get-Process -Id $genericProbe.Id -ErrorAction SilentlyContinue
    } while ((Get-Date) -lt $deadline -and (-not $genericProbeProcess -or $genericProbeProcess.MainWindowHandle -eq 0 -or $genericProbeProcess.Responding))

    if (-not $genericProbeProcess -or $genericProbeProcess.MainWindowHandle -eq 0) {
        throw "Hung generic app probe did not create a visible window"
    }
    if ($genericProbeProcess.Responding) {
        throw "Hung generic app probe did not enter a non-responding state"
    }

    $genericRecover = Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile", "-STA", "-ExecutionPolicy", "Bypass", "-File", $script, "-NoTray", "-NoServicingScan", "-NoRestartRecoveredApps", "-Aggressive", "-IncludeAppReport", "-RecoverHungGenericApps", "-ImmediateScanIntervalSeconds", "1", "-ImmediateHungConfirmSeconds", "0", "-SampleSeconds", "1", "-PostActionWaitSeconds", "1", "-MaxMonitorSeconds", "1", "-LogPath", $genericAppLog) -Wait -PassThru -NoNewWindow
    if ($genericRecover.ExitCode -ne 0) {
        throw "Generic hung app recovery run failed with exit code $($genericRecover.ExitCode)"
    }
    $genericAppText = Read-TextShared -Path $genericAppLog
    if ($genericAppText -notmatch "IMMEDIATE-HUNG-SEEN PID=\d+ name=UnstuckHungGenericApp") {
        throw "Generic hung app detection proof missing from log: $genericAppLog"
    }
    if ($genericAppText -notmatch "ACTION recover generic app PID=\d+ name=UnstuckHungGenericApp") {
        throw "Generic hung app recovery action proof missing from log: $genericAppLog"
    }
    if ($genericAppText -notmatch "NOTIFY-RECOVERY action=unfroze app target=UnstuckHungGenericApp PID") {
        throw "Generic hung app recovery notification proof missing from log: $genericAppLog"
    }
    if (Get-Process -Name "UnstuckHungGenericApp" -ErrorAction SilentlyContinue) {
        throw "Generic hung app recovery left a frozen test process running"
    }
} finally {
    Get-Process -Name "UnstuckHungGenericApp" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $genericAppSource,$genericAppExe -ErrorAction SilentlyContinue
}

Write-Host "Generic hung app recovery PASS"

$genericLoopLog = Join-Path $env:TEMP "unstuck-command-test-generic-app-loop.log"
$genericLoopSource = Join-Path $env:TEMP "UnstuckHungGenericApp.cs"
$genericLoopExe = Join-Path $env:TEMP "UnstuckHungGenericApp.exe"
Remove-Item -LiteralPath $genericLoopLog,$genericLoopSource,$genericLoopExe -ErrorAction SilentlyContinue
@"
using System;
using System.Threading;
using System.Windows.Forms;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        Application.EnableVisualStyles();
        using (var form = new Form())
        {
            form.Text = "Frozen Generic App";
            form.Width = 340;
            form.Height = 120;
            form.Shown += (sender, args) => Thread.Sleep(120000);
            Application.Run(form);
        }
    }
}
"@ | Set-Content -LiteralPath $genericLoopSource -Encoding ASCII
& "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /target:winexe /out:$genericLoopExe $genericLoopSource
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $genericLoopExe)) {
    throw "Failed to compile hung generic app loop probe"
}

$genericLoopProbe = Start-Process -FilePath $genericLoopExe -PassThru
try {
    $deadline = (Get-Date).AddSeconds(15)
    do {
        Start-Sleep -Milliseconds 250
        $genericLoopProbeProcess = Get-Process -Id $genericLoopProbe.Id -ErrorAction SilentlyContinue
    } while ((Get-Date) -lt $deadline -and (-not $genericLoopProbeProcess -or $genericLoopProbeProcess.MainWindowHandle -eq 0 -or $genericLoopProbeProcess.Responding))

    if (-not $genericLoopProbeProcess -or $genericLoopProbeProcess.MainWindowHandle -eq 0) {
        throw "Hung generic loop probe did not create a visible window"
    }
    if ($genericLoopProbeProcess.Responding) {
        throw "Hung generic loop probe did not enter a non-responding state"
    }

    $genericLoopInstance = "Local\UnstuckCommandGenericLoopTest_{0}_{1}" -f $PID, ([guid]::NewGuid().ToString("N"))
    $genericLoopRecover = Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile", "-STA", "-ExecutionPolicy", "Bypass", "-File", $script, "-SelfExitAfterSeconds", "90", "-InstanceName", $genericLoopInstance, "-NoServicingScan", "-Aggressive", "-IncludeAppReport", "-RecoverHungGenericApps", "-GenericAppRecoveryCooldownSeconds", "120", "-ImmediateScanIntervalSeconds", "1", "-ImmediateHungConfirmSeconds", "0", "-SampleSeconds", "1", "-PostActionWaitSeconds", "1", "-MonitorIntervalSeconds", "1", "-MaxMonitorSeconds", "0", "-LogPath", $genericLoopLog) -Wait -PassThru -NoNewWindow
    if ($genericLoopRecover.ExitCode -ne 0) {
        throw "Generic hung app loop recovery run failed with exit code $($genericLoopRecover.ExitCode)"
    }
    $genericLoopText = Read-TextShared -Path $genericLoopLog
    if ($genericLoopText -notmatch "NOTIFY-RECOVERY action=unfroze app target=UnstuckHungGenericApp PID \d+ detail=restarted after confirmed non-responding state") {
        throw "Generic hung app loop first restart proof missing from log: $genericLoopLog"
    }
    if ($genericLoopText -notmatch "debug privilege (enabled|not assigned|failed)") {
        throw "Generic hung app loop did not exercise the aggressive debug-privilege path: $genericLoopLog"
    }
    if ($genericLoopText -notmatch "restart suppressed because the same executable was recovered") {
        throw "Generic hung app loop suppression proof missing from log: $genericLoopLog"
    }
    if (Get-Process -Name "UnstuckHungGenericApp" -ErrorAction SilentlyContinue) {
        throw "Generic hung app loop suppression left a frozen test process running"
    }
} finally {
    Get-Process -Name "UnstuckHungGenericApp" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $genericLoopSource,$genericLoopExe -ErrorAction SilentlyContinue
}

Write-Host "Generic hung app restart-loop suppression PASS"

$staleRecoverLog = Join-Path $env:TEMP "unstuck-command-test-stale-terminal-recover.log"
Remove-Item -LiteralPath $staleRecoverLog -ErrorAction SilentlyContinue
$fakeTerminalDir = Join-Path $env:TEMP ("UnstuckFakeTerminal_{0}" -f ([guid]::NewGuid().ToString("N")))
$fakeTerminalSource = Join-Path $fakeTerminalDir "FakeTerminal.cs"
$fakeTerminalExe = Join-Path $fakeTerminalDir "powershell.exe"
New-Item -ItemType Directory -Force -Path $fakeTerminalDir | Out-Null
@"
using System;
using System.Diagnostics;
using System.Windows.Forms;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        foreach (string arg in Environment.GetCommandLineArgs())
        {
            if (arg.IndexOf("UNSTUCK_TEST_TERMINAL_RECOVER", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                Process.Start("cmd.exe", "/c ping -n 120 127.0.0.1 > nul & rem UNSTUCK_TEST_TERMINAL_CHILD");
                break;
            }
        }
        Application.EnableVisualStyles();
        using (var form = new Form())
        {
            form.Text = "Windows PowerShell";
            form.Width = 360;
            form.Height = 120;
            var timer = new Timer();
            timer.Interval = 120000;
            timer.Tick += (sender, args) => form.Close();
            timer.Start();
            Application.Run(form);
        }
    }
}
"@ | Set-Content -LiteralPath $fakeTerminalSource -Encoding ASCII
& "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /target:winexe /out:$fakeTerminalExe $fakeTerminalSource
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $fakeTerminalExe)) {
    throw "Failed to compile fake stale terminal command probe"
}

$terminalProbe = $null
$terminalProbe = Start-Process -FilePath $fakeTerminalExe -ArgumentList @("-Command", "UNSTUCK_TEST_TERMINAL_RECOVER") -PassThru
try {
    $deadline = (Get-Date).AddSeconds(20)
    $probeProcess = $null
    do {
        Start-Sleep -Milliseconds 500
        $probeCim = Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match "UNSTUCK_TEST_TERMINAL_RECOVER" } | Select-Object -First 1
        if ($probeCim) {
            $terminalProbe = Get-Process -Id ([int]$probeCim.ProcessId) -ErrorAction SilentlyContinue
            $probeProcess = $terminalProbe
        }
    } while ((Get-Date) -lt $deadline -and (-not $probeProcess -or $probeProcess.MainWindowHandle -eq 0))

    if (-not $probeProcess -or $probeProcess.MainWindowHandle -eq 0) {
        throw "Stale terminal command probe did not create a visible window"
    }

    $recover = Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile", "-STA", "-ExecutionPolicy", "Bypass", "-File", $script, "-NoTray", "-NoServicingScan", "-Aggressive", "-RecoverStaleTerminalCommands", "-TerminalCommandStaleSeconds", "0", "-GenericStaleMinAgeSeconds", "0", "-SampleSeconds", "1", "-PostActionWaitSeconds", "1", "-MaxMonitorSeconds", "1", "-MaxGenericCandidates", "200", "-LogPath", $staleRecoverLog) -Wait -PassThru -NoNewWindow
    if ($recover.ExitCode -ne 0) {
        throw "Stale terminal command recovery run failed with exit code $($recover.ExitCode)"
    }
    $recoverText = Read-TextShared -Path $staleRecoverLog
    if ($recoverText -notmatch "STALE-CANDIDATE PID=\d+.*UNSTUCK_TEST_TERMINAL_RECOVER") {
        throw "Stale terminal recovery candidate proof missing from log: $staleRecoverLog"
    }
    if ($recoverText -notmatch "STALE-TERMINAL-RECOVERY PID=\d+.*UNSTUCK_TEST_TERMINAL_RECOVER") {
        throw "Marked stale terminal recovery proof missing from log: $staleRecoverLog"
    }
    if ($recoverText -notmatch "ACTION stop PID=\d+ name=powershell reason=stale terminal command") {
        throw "Stale terminal recovery action proof missing from log: $staleRecoverLog"
    }
    if ($recoverText -notmatch "NOTIFY-RECOVERY action=recovered process target=powershell PID") {
        throw "Stale terminal recovery notification proof missing from log: $staleRecoverLog"
    }
    if ($recoverText -notmatch "stopped with [1-9]\d* descendant process\(es\): stale terminal command") {
        throw "Stale terminal descendant cleanup proof missing from log: $staleRecoverLog"
    }
    if (Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match "UNSTUCK_TEST_TERMINAL_CHILD" }) {
        throw "Stale terminal recovery left a child command running"
    }
} finally {
    if ($terminalProbe) {
        Stop-Process -Id $terminalProbe.Id -Force -ErrorAction SilentlyContinue
    }
    Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match "UNSTUCK_TEST_TERMINAL_RECOVER|UNSTUCK_TEST_TERMINAL_CHILD" } | ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $fakeTerminalDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "Stale terminal command recovery PASS"

$genericLog = Join-Path $env:TEMP "unstuck-command-test-generic.log"
Remove-Item -LiteralPath $genericLog -ErrorAction SilentlyContinue
$sleeper = Start-Process -FilePath "cmd.exe" -ArgumentList @("/c", "ping -n 30 127.0.0.1 > nul & rem UNSTUCK_TEST_STALE") -PassThru
$benignSleeper = Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile", "-Command", "Start-Sleep -Seconds 30 # CodexConnectivityGuardian") -PassThru
try {
    Start-Sleep -Seconds 1
    $generic = Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile", "-STA", "-ExecutionPolicy", "Bypass", "-File", $script, "-DryRun", "-NoTray", "-IncludeGenericReport", "-SampleSeconds", "1", "-PostActionWaitSeconds", "1", "-MaxMonitorSeconds", "1", "-GenericStaleMinAgeSeconds", "0", "-MaxGenericCandidates", "100", "-LogPath", $genericLog) -Wait -PassThru -NoNewWindow
    if ($generic.ExitCode -ne 0) {
        throw "Generic stale report run failed with exit code $($generic.ExitCode)"
    }
    $genericText = Read-TextShared -Path $genericLog
    if ($genericText -notmatch "STALE-CANDIDATE PID=\d+.*UNSTUCK_TEST_STALE") {
        throw "Generic stale command candidate proof missing from log: $genericLog"
    }
    if ($genericText -notmatch "STALE-CANDIDATE-IGNORED PID=\d+.*CodexConnectivityGuardian") {
        throw "Generic benign candidate ignore proof missing from log: $genericLog"
    }
    if ($genericText -match "STALE-CANDIDATE PID=\d+.*CodexConnectivityGuardian") {
        throw "Generic benign candidate was reported as stale instead of ignored: $genericLog"
    }
} finally {
    Stop-Process -Id $sleeper.Id -Force -ErrorAction SilentlyContinue
    Stop-Process -Id $benignSleeper.Id -Force -ErrorAction SilentlyContinue
}

Write-Host "Generic stale command classification PASS"

$dupLog = Join-Path $env:TEMP "unstuck-command-test-duplicate.log"
Remove-Item -LiteralPath $dupLog -ErrorAction SilentlyContinue
$dupInstance = "Local\UnstuckCommandDuplicateTest_{0}_{1}" -f $PID, ([guid]::NewGuid().ToString("N"))
$first = Start-Process -FilePath $launcherExe -ArgumentList @("-DryRun", "-SelfExitAfterSeconds", "180", "-NoServicingScan", "-SampleSeconds", "1", "-PostActionWaitSeconds", "1", "-MaxMonitorSeconds", "10", "-MonitorIntervalSeconds", "1", "-IncludeAppReport", "-InstanceName", $dupInstance, "-LogPath", $dupLog) -PassThru
$deadline = (Get-Date).AddSeconds(30)
$dupText = ""
do {
    Start-Sleep -Milliseconds 500
    if (Test-Path -LiteralPath $dupLog) {
        $dupText = Read-TextShared -Path $dupLog
    }
} while ((Get-Date) -lt $deadline -and ($dupText -notmatch "single-instance guard acquired"))

if ($dupText -notmatch "single-instance guard acquired") {
    throw "First duplicate-guard monitor did not acquire guard: $dupLog"
}

$second = Start-Process -FilePath $launcherExe -ArgumentList @("-DryRun", "-SelfExitAfterSeconds", "2", "-NoServicingScan", "-SampleSeconds", "1", "-PostActionWaitSeconds", "1", "-MaxMonitorSeconds", "5", "-MonitorIntervalSeconds", "1", "-IncludeAppReport", "-InstanceName", $dupInstance, "-LogPath", $dupLog) -PassThru
$deadline = (Get-Date).AddSeconds(30)
do {
    Start-Sleep -Milliseconds 500
    if (Test-Path -LiteralPath $dupLog) {
        $dupText = Read-TextShared -Path $dupLog
    }
} while ((Get-Date) -lt $deadline -and ($dupText -notmatch "another unstuck-command tray monitor is already running"))

if ($dupText -notmatch "another unstuck-command tray monitor is already running") {
    throw "Duplicate launch guard proof missing from log: $dupLog"
}
Stop-Process -Id $first.Id,$second.Id -Force -ErrorAction SilentlyContinue

Write-Host "Duplicate launch guard PASS"
