# unstuck-command

Windows PowerShell 5 compatible launcher for unsticking stalled Windows servicing commands.

## Use

Run the launcher as Administrator:

```cmd
unstuck-command.cmd
```

With no arguments, the launcher runs:

```powershell
Unstuck-Command.ps1 -Aggressive -RerunDism
```

For a safe inspection-only pass:

```cmd
unstuck-command.cmd -DryRun -Aggressive -RerunDism
```

## What It Targets

- Stale `sfc.exe` processes blocking CBS.
- Active `Dism.exe` with no DISM/CBS log movement.
- Wedged `TiWorker.exe` when `-Aggressive` is used.
- Optional DISM RestoreHealth relaunch with `C:\Temp\codex-repair-source\sources\install.esd`.

The script avoids generic broad process killing by default.
