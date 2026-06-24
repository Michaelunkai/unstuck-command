# unstuck-command

Windows PowerShell 5 compatible launcher for unsticking stalled Windows servicing commands.

## Use

Run the executable or command launcher as Administrator:

```cmd
UnstuckCommandLauncher.exe
unstuck-command.cmd
```

With no arguments, the launcher runs:

```powershell
Unstuck-Command.ps1 -Aggressive -RerunDism -IncludeAppReport -IncludeGenericReport -RecoverHungExplorer
```

Normal launches create a system tray icon. The monitor keeps running while that icon is present. Choosing `Exit and stop` from the tray icon stops the monitor and cleans up any DISM process started by this script. Every actual recovery action sends a tray balloon notification immediately and writes a `NOTIFY-RECOVERY` marker to the log.

Only one normal tray monitor can run at a time. If `ssstuck`, the executable, or the command launcher is triggered again while the tray monitor is already active, the duplicate launch exits instead of creating a second competing monitor.

For a safe inspection-only pass:

```cmd
unstuck-command.cmd -DryRun -NoTray -Aggressive -RerunDism -MaxMonitorSeconds 20
```

For a harmless tray-notification plumbing test:

```cmd
UnstuckCommandLauncher.exe -ForceTestNotification -SelfExitAfterSeconds 2
```

## What It Targets

- Stale `sfc.exe` processes blocking CBS.
- Active `Dism.exe` with no DISM/CBS log movement.
- Wedged `TiWorker.exe` when `-Aggressive` is used.
- Confirmed non-responding GUI application reporting, with safe Explorer restart when `-RecoverHungExplorer` is enabled.
- Bounded stale terminal/command candidate reporting for common shells and command-line tools, with known benign background helpers ignored by default and tray warning cooldown to avoid repeated noise.
- Optional DISM RestoreHealth relaunch with `C:\Temp\codex-repair-source\sources\install.esd`.
- Continuous tray monitoring so the tool does not exit while its tray icon is present.

The script avoids generic broad process killing by default.
