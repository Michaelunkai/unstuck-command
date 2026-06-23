[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$script = Join-Path $root "Unstuck-Command.ps1"
$launcher = Join-Path $root "unstuck-command.cmd"

if (-not (Test-Path -LiteralPath $script)) {
    throw "Missing script: $script"
}

if (-not (Test-Path -LiteralPath $launcher)) {
    throw "Missing launcher: $launcher"
}

$tokens = $null
$errors = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$tokens, [ref]$errors)
if ($errors -and $errors.Count -gt 0) {
    $errors | Format-List | Out-String | Write-Error
    throw "Parser failed"
}

Write-Host "Parser PASS"

$proc = Start-Process -FilePath "cmd.exe" -ArgumentList @("/c", "`"$launcher`" -DryRun -SampleSeconds 1 -PostActionWaitSeconds 1") -Wait -PassThru -NoNewWindow
if ($proc.ExitCode -ne 0) {
    throw "Launcher dry-run failed with exit code $($proc.ExitCode)"
}

Write-Host "Launcher dry-run PASS"
