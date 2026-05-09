using System;
using System.Diagnostics;
using System.IO;

internal static class RunFullPipelineLauncher
{
    private static int Main()
    {
        try
        {
            var baseDir = AppDomain.CurrentDomain.BaseDirectory;
            var scriptPath = Path.Combine(baseDir, "scripts", "run_full_pipeline.ps1");

            if (!File.Exists(scriptPath))
            {
                return 1;
            }

            var startInfo = new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + scriptPath + "\"",
                WorkingDirectory = baseDir,
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden
            };

            using (var process = Process.Start(startInfo))
            {
                if (process == null)
                {
                    return 1;
                }

                process.WaitForExit();
                return process.ExitCode;
            }
        }
        catch
        {
            return 1;
        }
    }
}
