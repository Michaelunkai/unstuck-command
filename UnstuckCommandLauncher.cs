using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;

internal static class UnstuckCommandLauncher
{
    private static int Main(string[] args)
    {
        string root = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.Combine(root, "Unstuck-Command.ps1");
        if (!File.Exists(script))
        {
            return 2;
        }

        var psArgs = new List<string>
        {
            "-NoProfile",
            "-STA",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            Quote(script)
        };

        if (args.Length == 0)
        {
            psArgs.Add("-Aggressive");
            psArgs.Add("-RerunDism");
            psArgs.Add("-IncludeAppReport");
            psArgs.Add("-IncludeGenericReport");
            psArgs.Add("-RecoverHungExplorer");
            psArgs.Add("-RecoverHungTerminalWindows");
            psArgs.Add("-RecoverHungGenericApps");
            psArgs.Add("-RecoverStaleTerminalCommands");
            psArgs.Add("-MaxMonitorSeconds");
            psArgs.Add("0");
        }
        else
        {
            foreach (string arg in args)
            {
                psArgs.Add(Quote(arg));
            }
        }

        var startInfo = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            Arguments = string.Join(" ", psArgs),
            UseShellExecute = false,
            CreateNoWindow = true,
            WindowStyle = ProcessWindowStyle.Hidden
        };

        Process.Start(startInfo);
        return 0;
    }

    private static string Quote(string value)
    {
        if (value.IndexOfAny(new[] { ' ', '\t', '"', '\'' }) < 0)
        {
            return value;
        }

        return "\"" + value.Replace("\"", "\\\"") + "\"";
    }
}
