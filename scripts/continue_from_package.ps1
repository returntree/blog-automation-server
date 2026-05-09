param(
    [Parameter(Mandatory = $true)]
    [string]$PackageDir
)

$ErrorActionPreference = "Stop"
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Add-Type @"
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Text;
using System.Runtime.InteropServices;
public static class WindowInteropContinue {
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool IsZoomed(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    public static string GetWindowTitle(IntPtr hWnd) {
        var builder = new StringBuilder(512);
        GetWindowText(hWnd, builder, builder.Capacity);
        return builder.ToString();
    }

    public static IntPtr[] GetVisibleTopLevelWindowsForProcessName(string processName) {
        var handles = new List<IntPtr>();
        EnumWindows(delegate (IntPtr hWnd, IntPtr lParam) {
            if (hWnd == IntPtr.Zero || !IsWindowVisible(hWnd)) {
                return true;
            }

            string title = GetWindowTitle(hWnd);
            if (string.IsNullOrWhiteSpace(title)) {
                return true;
            }

            uint processId;
            GetWindowThreadProcessId(hWnd, out processId);
            if (processId == 0) {
                return true;
            }

            try {
                using (var process = Process.GetProcessById((int)processId)) {
                    if (string.Equals(process.ProcessName, processName, StringComparison.OrdinalIgnoreCase)) {
                        handles.Add(hWnd);
                    }
                }
            } catch {
            }
            return true;
        }, IntPtr.Zero);
        return handles.ToArray();
    }
}
"@

$projectRoot = Split-Path -Parent $PSScriptRoot

function Test-PythonExecutable {
    param([string]$Candidate)
    if ([string]::IsNullOrWhiteSpace($Candidate)) { return $false }
    if ($Candidate -like "*\Microsoft\WindowsApps\python*.exe") { return $false }
    try {
        $output = & $Candidate --version 2>&1
        return ($LASTEXITCODE -eq 0 -and (($output -join " ") -match "Python\s+3\."))
    } catch {
        return $false
    }
}

function Resolve-PythonExe {
    $candidates = New-Object System.Collections.Generic.List[string]
    $settingsPath = Join-Path $projectRoot "installer\local_installer_settings.json"
    if (Test-Path -LiteralPath $settingsPath) {
        try {
            $settings = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($settings.python_path) { [void]$candidates.Add([string]$settings.python_path) }
        } catch {
        }
    }

    foreach ($name in @("py.exe", "python.exe", "py", "python")) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($command -and $command.Source) { [void]$candidates.Add($command.Source) }
        else { [void]$candidates.Add($name) }
    }

    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        if (Test-PythonExecutable $candidate) { return $candidate }
    }

    throw "Python 실행 파일을 찾지 못했습니다. 설치 마법사에서 'Python 설치/다운로드'를 눌러 Python 3을 설치한 뒤 '환경 확인'을 다시 눌러 주세요."
}
$logsDir = Join-Path $projectRoot "logs"
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$runLogPath = Join-Path $logsDir "continue_from_package_$timestamp.log"

$pythonExe = Resolve-PythonExe
$prepareScript = Join-Path $projectRoot "scripts\prepare_continue_from_package.py"
$reviewDraftScript = Join-Path $projectRoot "scripts\review_draft.ps1"
$packageScript = Join-Path $projectRoot "scripts\build_upload_package.py"
$imageScript = Join-Path $projectRoot "scripts\generate_package_images.py"
$reviewImagesScript = Join-Path $projectRoot "scripts\review_images.ps1"
$ahkScript = Join-Path $projectRoot "ahk\upload_from_package_v2.ahk"

$autoStartDelaySeconds = 2
$naverWriteOpenDelaySeconds = 3
$naverWriteUrl = "https://blog.naver.com/GoBlogWrite.naver"

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "== $Message ==" -ForegroundColor Cyan
}

function Invoke-StepCommand {
    param(
        [string]$Title,
        [scriptblock]$Action
    )

    Write-Step $Title
    & $Action
    if ($LASTEXITCODE -ne 0) {
        throw "$Title failed. Exit code: $LASTEXITCODE"
    }
}

function Test-PackageImagesReady {
    param([string]$TargetPackageDir)

    $promptsPath = Join-Path $TargetPackageDir "image_prompts.json"
    if (-not (Test-Path -LiteralPath $promptsPath)) {
        return $false
    }

    $promptData = Get-Content -LiteralPath $promptsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $items = @($promptData.items)
    if (-not $items -or $items.Count -eq 0) {
        return $false
    }

    foreach ($item in $items) {
        if ($null -eq $item) {
            continue
        }
        $relativeOutput = [string]$item.output_path
        if ([string]::IsNullOrWhiteSpace($relativeOutput)) {
            return $false
        }
        $imagePath = Join-Path $TargetPackageDir ($relativeOutput -replace "/", "\")
        if (-not (Test-Path -LiteralPath $imagePath)) {
            return $false
        }
    }

    return $true
}

function Update-AhkPackageDir {
    param(
        [string]$ScriptPath,
        [string]$NewPackageDir
    )

    $packageFolderName = Split-Path -Leaf $NewPackageDir
    $relativePackageDir = "..\jobs\$packageFolderName"
    $content = Get-Content -LiteralPath $ScriptPath -Raw -Encoding UTF8
    $updated = $content -replace 'global package_dir := ".*?"', ('global package_dir := "' + $relativePackageDir + '"')
    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($ScriptPath, $updated, $utf8Bom)
}

function Find-AutoHotkey {
    $commandCandidates = @("AutoHotkeyU64.exe", "AutoHotkey.exe", "AutoHotkey64.exe")
    foreach ($candidate in $commandCandidates) {
        $command = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($command) {
            return $command.Source
        }
    }

    $pathCandidates = @(
        "C:\Program Files\AutoHotkey\AutoHotkeyU64.exe",
        "C:\Program Files\AutoHotkey\AutoHotkey.exe",
        "C:\Program Files\AutoHotkey\v1.1.37.02\AutoHotkeyU64.exe",
        "C:\Program Files\AutoHotkey\v1.1.37.02\AutoHotkey.exe",
        "C:\Program Files (x86)\AutoHotkey\AutoHotkeyU64.exe",
        "C:\Program Files (x86)\AutoHotkey\AutoHotkey.exe"
    )

    foreach ($candidate in $pathCandidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    return $null
}

function Stop-ExistingAhkScript {
    param([string]$ScriptPath)

    $scriptName = [System.IO.Path]::GetFileName($ScriptPath)
    $normalizedScriptPath = $ScriptPath.ToLowerInvariant()
    $matchedProcesses = @()

    try {
        $processes = Get-CimInstance Win32_Process -Filter "Name = 'AutoHotkey.exe' OR Name = 'AutoHotkeyU64.exe' OR Name = 'AutoHotkey64.exe'"
        foreach ($process in $processes) {
            $commandLine = [string]$process.CommandLine
            if (-not [string]::IsNullOrWhiteSpace($commandLine)) {
                $normalizedCommandLine = $commandLine.ToLowerInvariant()
                if ($normalizedCommandLine.Contains($normalizedScriptPath) -or $normalizedCommandLine.Contains($scriptName.ToLowerInvariant())) {
                    $matchedProcesses += $process
                }
            }
        }
    } catch {
    }

    foreach ($process in $matchedProcesses) {
        try {
            Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
        } catch {
        }
    }

    Start-Sleep -Milliseconds 800
}

function Find-Chrome {
    $command = Get-Command "chrome.exe" -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $pathCandidates = @(
        "C:\Program Files\Google\Chrome\Application\chrome.exe",
        "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
    )

    foreach ($candidate in $pathCandidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    return $null
}

function Get-ChromeWindowHandles {
    $handles = @()
    foreach ($handle in [WindowInteropContinue]::GetVisibleTopLevelWindowsForProcessName("chrome")) {
        if ($null -ne $handle -and $handle -ne [IntPtr]::Zero) {
            $handles += $handle
        }
    }
    return $handles
}

function Find-NewChromeWindowHandle {
    param([System.Collections.Generic.HashSet[string]]$BeforeSet)

    foreach ($handle in (Get-ChromeWindowHandles)) {
        if ($null -eq $handle) {
            continue
        }

        $key = $handle.ToInt64().ToString()
        if (-not $BeforeSet.Contains($key)) {
            return $handle
        }
    }

    return [IntPtr]::Zero
}

function Force-MaximizeWindow {
    param([IntPtr]$WindowHandle)

    if ($WindowHandle -eq [IntPtr]::Zero) {
        return $false
    }

    for ($i = 0; $i -lt 12; $i++) {
        [void][WindowInteropContinue]::ShowWindowAsync($WindowHandle, 3)
        Start-Sleep -Milliseconds 250
        [void][WindowInteropContinue]::SetForegroundWindow($WindowHandle)
        Start-Sleep -Milliseconds 150
        if ([WindowInteropContinue]::IsZoomed($WindowHandle)) {
            return $true
        }
    }

    return $false
}

function Open-NaverWriteWindow {
    param(
        [string]$Url,
        [int]$DelaySeconds = 3
    )

    $chromeExe = Find-Chrome
    if (-not $chromeExe) {
        throw "Chrome executable was not found."
    }

    $beforeSet = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($handle in (Get-ChromeWindowHandles)) {
        if ($null -ne $handle) {
            [void]$beforeSet.Add($handle.ToInt64().ToString())
        }
    }

    Write-Host "Opening Naver write page in Chrome: $Url" -ForegroundColor Yellow
    Start-Process -FilePath $chromeExe -ArgumentList @("--new-window", "--start-maximized", $Url) | Out-Null

    $windowHandle = [IntPtr]::Zero
    for ($i = 0; $i -lt 80; $i++) {
        Start-Sleep -Milliseconds 200
        $candidate = Find-NewChromeWindowHandle -BeforeSet $beforeSet
        if ($candidate -ne [IntPtr]::Zero) {
            $windowHandle = $candidate
            break
        }
    }

    if ($windowHandle -ne [IntPtr]::Zero) {
        [void](Force-MaximizeWindow -WindowHandle $windowHandle)
    }

    Start-Sleep -Seconds $DelaySeconds
}

function Send-CtrlTToActiveWindow {
    param([int]$DelaySeconds = 2)

    Write-Host "Sending Ctrl+T to the active window after $DelaySeconds seconds." -ForegroundColor Yellow
    Start-Sleep -Seconds $DelaySeconds
    $shell = New-Object -ComObject WScript.Shell
    $shell.SendKeys("^t")
}

New-Item -ItemType Directory -Force -Path $logsDir | Out-Null
Start-Transcript -Path $runLogPath -Force | Out-Null

try {
    $resolvedPackageDir = [System.IO.Path]::GetFullPath($PackageDir)
    if (-not (Test-Path -LiteralPath $resolvedPackageDir)) {
        throw "Selected package folder was not found: $resolvedPackageDir"
    }

    Invoke-StepCommand "1. Restore latest result from selected package" { & $pythonExe -u $prepareScript $resolvedPackageDir }
    Invoke-StepCommand "2. Review draft" { powershell.exe -STA -ExecutionPolicy Bypass -File $reviewDraftScript }

    Write-Step "3. Rebuild selected package"
    $packageOutput = & $pythonExe -u $packageScript $resolvedPackageDir
    if ($LASTEXITCODE -ne 0) {
        throw "3. Rebuild selected package failed. Exit code: $LASTEXITCODE"
    }

    $packageOutput | ForEach-Object { Write-Host $_ }

    Write-Step "4. Update AHK package_dir"
    Update-AhkPackageDir -ScriptPath $ahkScript -NewPackageDir $resolvedPackageDir
    Write-Host "Package dir applied: $resolvedPackageDir"

    if (Test-PackageImagesReady -TargetPackageDir $resolvedPackageDir) {
        Write-Step "5. Skip image generation"
        Write-Host "Selected package already has image files, moving directly to image review." -ForegroundColor Yellow
    }
    else {
        Invoke-StepCommand "5. Generate missing images" { & $pythonExe -u $imageScript $resolvedPackageDir }
    }

    Invoke-StepCommand "6. Review images" { powershell.exe -STA -ExecutionPolicy Bypass -File $reviewImagesScript -PackageDir $resolvedPackageDir }

    Write-Step "7. Open Naver write page"
    Open-NaverWriteWindow -Url $naverWriteUrl -DelaySeconds $naverWriteOpenDelaySeconds

    Write-Step "8. Run AutoHotkey"
    Stop-ExistingAhkScript -ScriptPath $ahkScript
    $ahkExe = Find-AutoHotkey
    if ($ahkExe) {
        Start-Process -FilePath $ahkExe -ArgumentList @($ahkScript) | Out-Null
        Write-Host "AutoHotkey launched: $ahkExe"
    } else {
        Start-Process -FilePath $ahkScript | Out-Null
        Write-Host "AHK script launched via default app."
    }

    Write-Step "9. Start auto posting"
    Send-CtrlTToActiveWindow -DelaySeconds $autoStartDelaySeconds

    Write-Host ""
    Write-Host "Continue flow completed." -ForegroundColor Green
    Write-Host "Log: $runLogPath"
}
catch {
    Write-Host ""
    Write-Host "Failure: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Log: $runLogPath" -ForegroundColor Yellow
    if ($env:BLOG_AUTOMATION_GUI -ne "1") {
        cmd /c pause
    }
    exit 1
}
finally {
    Stop-Transcript | Out-Null
}

