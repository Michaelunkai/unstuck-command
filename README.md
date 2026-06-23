# unstuck-command

Windows PowerShell 5 compatible launcher for unsticking stalled Windows servicing commands.

## Use

Run the launcher as Administrator:

```cmd
unstuck-command.cmd
```

With no arguments, the launcher runs:

```powershell
Unstuck-Command.ps1 -Aggressive -RerunDism -MaxMonitorSeconds 300
```

For a safe inspection-only pass:

```cmd
unstuck-command.cmd -DryRun -Aggressive -RerunDism -MaxMonitorSeconds 20
```

## What It Targets

- Stale `sfc.exe` processes blocking CBS.
- Active `Dism.exe` with no DISM/CBS log movement.
- Wedged `TiWorker.exe` when `-Aggressive` is used.
- Optional DISM RestoreHealth relaunch with `C:\Temp\codex-repair-source\sources\install.esd`.
- Repeated bounded monitoring so the tool does not exit after a single stale check.

The script avoids generic broad process killing by default.
