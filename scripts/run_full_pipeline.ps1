param(
    [switch]$SkipRequestInput,
    [switch]$NoPause,
    [string]$ExternalRunLogPath
)

$ErrorActionPreference = "Stop"
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$progressWindowTitle = "blog_automation 진행 화면"
try {
    $Host.UI.RawUI.WindowTitle = $progressWindowTitle
} catch {
}

Add-Type @"
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Text;
using System.Runtime.InteropServices;
public static class WindowInterop {
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

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowTextLength(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    public static string GetWindowTitle(IntPtr hWnd) {
        int length = GetWindowTextLength(hWnd);
        var builder = new StringBuilder(length + 1);
        GetWindowText(hWnd, builder, builder.Capacity);
        return builder.ToString();
    }

    public static string GetWindowClass(IntPtr hWnd) {
        var builder = new StringBuilder(256);
        GetClassName(hWnd, builder, builder.Capacity);
        return builder.ToString();
    }

    public static IntPtr[] GetVisibleTopLevelWindowsForProcessName(string processName) {
        var handles = new List<IntPtr>();
        EnumWindows(delegate (IntPtr hWnd, IntPtr lParam) {
            if (!IsWindowVisible(hWnd)) {
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
$runLogPath = if (-not [string]::IsNullOrWhiteSpace($ExternalRunLogPath)) { $ExternalRunLogPath } else { Join-Path $logsDir "run_full_pipeline_$timestamp.log" }
$pythonExe = Resolve-PythonExe
$launchOverlayScript = Join-Path $projectRoot "scripts\show_launch_overlay.ps1"
$requestFormScript = Join-Path $projectRoot "scripts\collect_user_request.ps1"
$licenseCheckScript = Join-Path $projectRoot "scripts\check_client_license.py"
$researchScript = Join-Path $projectRoot "scripts\collect_blog_research.py"
$titleOptionsScript = Join-Path $projectRoot "scripts\generate_title_options.py"
$titleSelectScript = Join-Path $projectRoot "scripts\select_title_option.ps1"
$draftScript = Join-Path $projectRoot "scripts\generate_blog_draft.py"
$manualDraftScript = Join-Path $projectRoot "scripts\generate_draft_from_manual.py"
$imageDraftScript = Join-Path $projectRoot "scripts\generate_draft_from_images.py"
$packageScript = Join-Path $projectRoot "scripts\build_upload_package.py"
$imageScript = Join-Path $projectRoot "scripts\generate_package_images.py"
$usageEventScript = Join-Path $projectRoot "scripts\report_usage_event.py"
$reviewDraftScript = Join-Path $projectRoot "scripts\review_draft.ps1"
$reviewImagesScript = Join-Path $projectRoot "scripts\review_images.ps1"
$continueFromPackageScript = Join-Path $projectRoot "scripts\continue_from_package.ps1"
$ahkScript = Join-Path $projectRoot "ahk\upload_from_package_v2.ahk"
$requestPath = Join-Path $projectRoot "inputs\request.json"
$continueRequestPath = Join-Path $projectRoot "inputs\continue_from_history.json"
$researchOutputPath = Join-Path $projectRoot "research\latest_research.json"
$titleOptionsPath = Join-Path $projectRoot "research\title_options.json"
$latestResultPath = Join-Path $projectRoot "jobs\latest_result.json"
$autoStartDelaySeconds = 2
$naverWriteUrl = "https://blog.naver.com/GoBlogWrite.naver"
$naverWriteOpenDelaySeconds = 3

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "== $Message ==" -ForegroundColor Cyan
}

function Show-ProgressWindow {
    try {
        $Host.UI.RawUI.WindowTitle = $progressWindowTitle
    } catch {
    }

    Start-Sleep -Milliseconds 250

    try {
        $shell = New-Object -ComObject WScript.Shell
        [void]$shell.AppActivate($progressWindowTitle)
    } catch {
    }

    try {
        $process = Get-Process -Id $PID -ErrorAction Stop
        if ($process.MainWindowHandle -ne 0) {
            [void][WindowInterop]::ShowWindowAsync($process.MainWindowHandle, 5)
            Start-Sleep -Milliseconds 100
            [void][WindowInterop]::SetForegroundWindow($process.MainWindowHandle)
        }
    } catch {
    }
}

function Show-LaunchOverlay {
    param([string]$ScriptPath)

    if (-not (Test-Path $ScriptPath)) {
        return
    }

    try {
        powershell.exe -STA -ExecutionPolicy Bypass -File $ScriptPath | Out-Null
    }
    catch {
        Write-Host "시작 오버레이 표시는 건너뜁니다: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Invoke-StepCommand {
    param(
        [string]$Title,
        [scriptblock]$Action
    )

    Write-Step $Title
    & $Action
    if ($LASTEXITCODE -ne 0) {
        throw "$Title 단계가 실패했습니다. 종료 코드: $LASTEXITCODE"
    }
}

function Write-ResumeSkip {
    param(
        [string]$Title,
        [string]$Reason
    )

    Write-Step $Title
    Write-Host $Reason -ForegroundColor Yellow
}

function Get-ClientSettingsPath {
    $primary = Join-Path $projectRoot "config\client_settings.json"
    if (Test-Path -LiteralPath $primary) {
        return $primary
    }

    $example = Join-Path $projectRoot "config\client_settings.example.json"
    if (Test-Path -LiteralPath $example) {
        return $example
    }

    return $null
}

function Get-ClientSettings {
    $settingsPath = Get-ClientSettingsPath
    if (-not $settingsPath) {
        return @{
            mode = "local"
            server_base_url = ""
            auth_token = ""
            license_check_on_start = $false
        }
    }

    try {
        return Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-Host "클라이언트 설정 파일을 읽는 중 경고가 발생했습니다. 기본 로컬 모드로 진행합니다: $($_.Exception.Message)" -ForegroundColor Yellow
        return @{
            mode = "local"
            server_base_url = ""
            auth_token = ""
            license_check_on_start = $false
        }
    }
}

function Test-ServerMode {
    param($Settings)

    if ($null -eq $Settings) {
        return $false
    }

    return ([string]$Settings.mode).Trim().ToLowerInvariant() -eq "server"
}

function Run-PythonStep {
    param(
        [string]$Title,
        [string]$ScriptPath,
        [string[]]$Arguments = @()
    )

    if (-not (Test-Path -LiteralPath $ScriptPath)) {
        throw "$Title 스크립트를 찾지 못했습니다: $ScriptPath"
    }

    & $pythonExe -u $ScriptPath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Title 단계가 실패했습니다. 종료 코드: $LASTEXITCODE"
    }
}

function Report-UsageEvent {
    param(
        [string]$EventType,
        [string]$Stage = "",
        [string]$Status = "",
        [string]$Message = "",
        [string]$PackageDir = ""
    )

    if (-not $script:IsServerMode) {
        return
    }

    if (-not (Test-Path -LiteralPath $usageEventScript)) {
        return
    }

    $arguments = @(
        $usageEventScript,
        "--event-type", $EventType
    )

    if (-not [string]::IsNullOrWhiteSpace($Stage)) {
        $arguments += @("--stage", $Stage)
    }
    if (-not [string]::IsNullOrWhiteSpace($Status)) {
        $arguments += @("--status", $Status)
    }
    if (-not [string]::IsNullOrWhiteSpace($Message)) {
        $arguments += @("--message", $Message)
    }
    if (-not [string]::IsNullOrWhiteSpace($PackageDir)) {
        $arguments += @("--package-dir", $PackageDir)
    }

    try {
        & $pythonExe -u @arguments | Out-Null
    } catch {
        Write-Host "사용 이벤트 기록은 건너뜁니다: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Test-IsFreshForRequest {
    param(
        [string]$ArtifactPath,
        [string[]]$ReferencePaths
    )

    if (-not (Test-Path $ArtifactPath)) {
        return $false
    }

    $artifactTime = (Get-Item -LiteralPath $ArtifactPath).LastWriteTime
    foreach ($referencePath in $ReferencePaths) {
        if ([string]::IsNullOrWhiteSpace($referencePath)) {
            continue
        }
        if (-not (Test-Path $referencePath)) {
            return $false
        }
        if ((Get-Item -LiteralPath $referencePath).LastWriteTime -gt $artifactTime) {
            return $false
        }
    }
    return $true
}

function Test-ShouldReuseArtifact {
    param(
        [bool]$ResumeRequested,
        [string]$ArtifactPath,
        [string[]]$ReferencePaths
    )

    if ($ResumeRequested) {
        return (Test-Path $ArtifactPath)
    }

    return (Test-IsFreshForRequest -ArtifactPath $ArtifactPath -ReferencePaths $ReferencePaths)
}

function Invoke-TitleSelectionFlow {
    param(
        [int]$TitleOptionCount,
        [string]$PythonExe,
        [string]$TitleOptionsScript,
        [string]$TitleSelectScript
    )

    while ($true) {
        Invoke-StepCommand "2. 제목 후보 생성" { & $PythonExe -u $TitleOptionsScript }

        if ($TitleOptionCount -gt 1) {
            Write-Step "3. 제목 후보 선택"
        } else {
            Write-Step "3. 제목 자동 선택"
        }

        powershell.exe -STA -ExecutionPolicy Bypass -File $TitleSelectScript
        $selectionExitCode = $LASTEXITCODE

        if ($selectionExitCode -eq 10) {
            Write-Host "추가요청을 반영해 제목 후보를 다시 생성합니다." -ForegroundColor Yellow
            continue
        }

        if ($selectionExitCode -ne 0) {
            throw "3. 제목 후보 선택 단계가 실패했습니다. 종료 코드: $selectionExitCode"
        }

        break
    }
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
        if (Test-Path $candidate) {
            return $candidate
        }
    }

    return $null
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
        if (Test-Path $candidate) {
            return $candidate
        }
    }

    return $null
}

function Get-ChromeWindowHandles {
    $handles = @()
    foreach ($handle in [WindowInterop]::GetVisibleTopLevelWindowsForProcessName("chrome")) {
        if ($handle -ne [IntPtr]::Zero) {
            $handles += $handle
        }
    }
    return $handles
}

function Find-NewChromeWindowHandle {
    param(
        [System.Collections.Generic.HashSet[string]]$BeforeSet
    )

    $currentHandles = Get-ChromeWindowHandles
    foreach ($handle in $currentHandles) {
        $key = $handle.ToInt64().ToString()
        if (-not $BeforeSet.Contains($key)) {
            return $handle
        }
    }

    if ($currentHandles.Count -gt 0) {
        return $currentHandles[-1]
    }

    return [IntPtr]::Zero
}

function Force-MaximizeWindow {
    param(
        [IntPtr]$WindowHandle
    )

    if ($WindowHandle -eq [IntPtr]::Zero) {
        return $false
    }

    $maximized = $false
    for ($i = 0; $i -lt 12; $i++) {
        [void][WindowInterop]::ShowWindowAsync($WindowHandle, 3)
        Start-Sleep -Milliseconds 250
        [void][WindowInterop]::SetForegroundWindow($WindowHandle)
        Start-Sleep -Milliseconds 150
        if ([WindowInterop]::IsZoomed($WindowHandle)) {
            $maximized = $true
            break
        }
    }

    if (-not $maximized) {
        $shell = New-Object -ComObject WScript.Shell
        [void][WindowInterop]::SetForegroundWindow($WindowHandle)
        Start-Sleep -Milliseconds 250
        $shell.SendKeys("% ")
        Start-Sleep -Milliseconds 150
        $shell.SendKeys("x")
        Start-Sleep -Milliseconds 500
        $maximized = [WindowInterop]::IsZoomed($WindowHandle)
    }

    return $maximized
}

function Update-AhkPackageDir {
    param(
        [string]$ScriptPath,
        [string]$PackageDir
    )

    $packageFolderName = Split-Path -Leaf $PackageDir
    $relativePackageDir = "..\jobs\$packageFolderName"

    $content = Get-Content -LiteralPath $ScriptPath -Raw -Encoding UTF8
    $updated = $content -replace 'global package_dir := ".*?"', ('global package_dir := "' + $relativePackageDir + '"')

    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($ScriptPath, $updated, $utf8Bom)
}

function Find-LatestPackageDir {
    param([string]$JobsDir)

    $latestPackage = Get-ChildItem -LiteralPath $JobsDir -Directory -Filter "upload_package_*" |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if (-not $latestPackage) {
        throw "최신 업로드 패키지 폴더를 찾지 못했습니다."
    }
    return $latestPackage.FullName
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
        Write-Host "기존 AutoHotkey 프로세스 확인 중 경고: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    if ($matchedProcesses.Count -eq 0) {
        Write-Host "기존 upload AHK 프로세스가 없어 바로 최신 스크립트를 실행합니다."
        return
    }

    foreach ($process in $matchedProcesses) {
        try {
            Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
            Write-Host "기존 AHK 종료 완료: PID $($process.ProcessId)"
        } catch {
            Write-Host "기존 AHK 종료 실패: PID $($process.ProcessId) - $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    Start-Sleep -Milliseconds 800
}

function Send-CtrlTToActiveWindow {
    param([int]$DelaySeconds = 4)

    Write-Host "현재 활성 창에 $DelaySeconds초 후 Ctrl+T를 전송합니다." -ForegroundColor Yellow
    Start-Sleep -Seconds $DelaySeconds
    $shell = New-Object -ComObject WScript.Shell
    $shell.SendKeys("^t")
}

function Open-NaverWriteWindow {
    param(
        [string]$Url,
        [int]$DelaySeconds = 5
    )

    $chromeExe = Find-Chrome
    if (-not $chromeExe) {
        throw "크롬 실행 파일을 찾지 못했습니다. 크롬이 설치되어 있는지 확인해 주세요."
    }

    $beforeSet = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($handle in (Get-ChromeWindowHandles)) {
        [void]$beforeSet.Add($handle.ToInt64().ToString())
    }

    Write-Host "크롬 최대화 새창으로 네이버 글쓰기 창을 여는 중입니다: $Url" -ForegroundColor Yellow
    Start-Process -FilePath $chromeExe -ArgumentList @("--new-window", "--start-maximized", $Url) | Out-Null

    $windowHandle = [IntPtr]::Zero
    for ($i = 0; $i -lt 80; $i++) {
        Start-Sleep -Milliseconds 200
        $latestChromeHandle = Find-NewChromeWindowHandle -BeforeSet $beforeSet
        if ($latestChromeHandle -ne [IntPtr]::Zero) {
            $windowHandle = $latestChromeHandle
            break
        }
    }

    if ($windowHandle -ne [IntPtr]::Zero) {
        $maximized = Force-MaximizeWindow -WindowHandle $windowHandle
        if ($maximized) {
            Write-Host "크롬 창을 최대화하고 전면으로 가져왔습니다." -ForegroundColor Yellow
        }
        else {
            Write-Host "크롬 창은 열렸지만 최대화 확인은 실패했습니다." -ForegroundColor Yellow
        }
    }
    else {
        Write-Host "새 크롬 창 핸들을 찾지 못해 최대화 확인은 건너뜁니다." -ForegroundColor Yellow
    }

    Write-Host "$DelaySeconds초 동안 브라우저 로딩을 기다립니다." -ForegroundColor Yellow
    Start-Sleep -Seconds $DelaySeconds
}

if (-not $SkipRequestInput) {
    Show-LaunchOverlay -ScriptPath $launchOverlayScript
}

New-Item -ItemType Directory -Force -Path $logsDir | Out-Null
Start-Transcript -Path $runLogPath -Force | Out-Null

try {
    $script:IsServerMode = $false
    $script:UsageStage = "request_input"
    Write-Step "0. 포스팅 요청 입력"
    if ($SkipRequestInput) {
        $resumeRequested = $false
        Write-Host "입력창에서 저장한 request.json 기준으로 진행합니다." -ForegroundColor Yellow
    }
    else {
        powershell.exe -STA -ExecutionPolicy Bypass -File $requestFormScript
        $requestExitCode = $LASTEXITCODE
        if ($requestExitCode -eq 30) {
            if (-not (Test-Path -LiteralPath $continueRequestPath)) {
                throw "이어서 작업 요청 파일을 찾지 못했습니다."
            }

            $continueRequest = Get-Content -LiteralPath $continueRequestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $continuePackageDir = [string]$continueRequest.package_dir
            Remove-Item -LiteralPath $continueRequestPath -Force -ErrorAction SilentlyContinue

            if ([string]::IsNullOrWhiteSpace($continuePackageDir)) {
                throw "이어서 작업할 패키지 경로가 비어 있습니다."
            }

            Write-Host "생성 이력에서 선택한 패키지 기준 이어서 작업을 시작했습니다." -ForegroundColor Yellow
            powershell.exe -STA -ExecutionPolicy Bypass -File $continueFromPackageScript -PackageDir $continuePackageDir
            $continueExitCode = $LASTEXITCODE
            if ($continueExitCode -ne 0) {
                throw "이어서 작업 단계가 실패했습니다. 종료 코드: $continueExitCode"
            }

            Write-Host "실행 로그: $runLogPath"
            exit 0
        }
        $resumeRequested = ($requestExitCode -eq 20)
        if ($requestExitCode -eq 20) {
            Write-Host "기존 요청 기준으로 이어서 실행합니다." -ForegroundColor Yellow
        }
        elseif ($requestExitCode -eq 40) {
            Write-Host "입력창 안에서 전체 진행을 완료했습니다." -ForegroundColor Green
            Write-Host "실행 로그: $runLogPath"
            exit 0
        }
        elseif ($requestExitCode -eq 41) {
            throw "입력창 안에서 진행한 작업이 실패했습니다."
        }
        elseif ($requestExitCode -ne 0) {
            throw "0. 포스팅 요청 입력 단계가 실패했습니다. 종료 코드: $requestExitCode"
        }
    }

    if (-not (Test-Path $requestPath)) {
        throw "이어받을 request.json 이 없습니다. 먼저 한 번 저장 후 진행으로 요청을 만들어 주세요."
    }

    $clientSettings = Get-ClientSettings
    $isServerMode = Test-ServerMode -Settings $clientSettings
    $script:IsServerMode = $isServerMode

    if ($isServerMode) {
        $script:UsageStage = "license_check"
        Write-Step "0-1. 이용 권한 확인"
        if (-not [string]::IsNullOrWhiteSpace([string]$clientSettings.server_base_url)) {
            Write-Host "서버 모드로 실행합니다. 연결 서버: $($clientSettings.server_base_url)" -ForegroundColor Yellow
        } else {
            Write-Host "서버 모드로 실행합니다." -ForegroundColor Yellow
        }
        Run-PythonStep -Title "이용 권한 확인" -ScriptPath $licenseCheckScript
    } else {
        Write-ResumeSkip "0-1. 이용 권한 확인" "현재는 로컬 모드이므로 서버 구독 확인을 건너뜁니다."
    }

    $requestData = Get-Content -LiteralPath $requestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $inputMode = [string]$requestData.input_mode
    $reviewDraftEnabled = [bool]$requestData.review_draft_enabled
    $reviewImagesEnabled = [bool]$requestData.review_images_enabled
    $autoPostingEnabled = [bool]$requestData.auto_posting_enabled
    $titleOptionCount = [int]$requestData.title_option_count
    $jobsDir = Join-Path $projectRoot "jobs"
    $latestPackageDir = $null

    Report-UsageEvent -EventType "pipeline_started" -Stage "pipeline" -Status "started" -Message "전체 파이프라인 실행 시작"

    if ($inputMode -eq "autopost_only") {
        $script:UsageStage = "autopost_prepare"
        Write-Step "1. 최신 생성 자료 확인"
        $latestPackageDir = Find-LatestPackageDir -JobsDir $jobsDir
        Write-Host "자동포스팅에 사용할 최신 패키지: $latestPackageDir"
        Report-UsageEvent -EventType "stage_completed" -Stage "autopost_prepare" -Status "completed" -PackageDir $latestPackageDir -Message "최신 패키지 확인 완료"
    }
    elseif ($inputMode -eq "draft") {
        $script:UsageStage = "manual_draft_prepare"
        if (Test-ShouldReuseArtifact -ResumeRequested $resumeRequested -ArtifactPath $latestResultPath -ReferencePaths @($requestPath)) {
            Write-ResumeSkip "1. 보유 원고 기반 초안 정리" "기존 latest_result.json 이 있어 초안 정리 단계를 건너뜁니다."
            Report-UsageEvent -EventType "stage_completed" -Stage "manual_draft_prepare" -Status "reused" -Message "기존 latest_result.json 재사용"
        } else {
            Invoke-StepCommand "1. 보유 원고 기반 초안 정리" { & $pythonExe -u $manualDraftScript }
            Report-UsageEvent -EventType "stage_completed" -Stage "manual_draft_prepare" -Status "completed" -Message "보유 원고 기반 초안 정리 완료"
        }
    }
    elseif ($inputMode -eq "image") {
        $script:UsageStage = "image_research"
        if (Test-ShouldReuseArtifact -ResumeRequested $resumeRequested -ArtifactPath $researchOutputPath -ReferencePaths @($requestPath)) {
            Write-ResumeSkip "1. 보유 이미지용 리서치 수집" "기존 latest_research.json 이 있어 리서치 수집 단계를 건너뜁니다."
            Report-UsageEvent -EventType "stage_completed" -Stage "image_research" -Status "reused" -Message "이미지 입력용 리서치 재사용"
        } else {
            Invoke-StepCommand "1. 보유 이미지용 리서치 수집" { & $pythonExe -u $researchScript }
            Report-UsageEvent -EventType "stage_completed" -Stage "image_research" -Status "completed" -Message "이미지 입력용 리서치 완료"
        }

        $script:UsageStage = "image_draft"
        if (Test-ShouldReuseArtifact -ResumeRequested $resumeRequested -ArtifactPath $latestResultPath -ReferencePaths @($requestPath, $researchOutputPath)) {
            Write-ResumeSkip "2. 보유 이미지 기반 초안 생성" "기존 latest_result.json 이 있어 이미지 기반 초안 생성 단계를 건너뜁니다."
            Report-UsageEvent -EventType "stage_completed" -Stage "image_draft" -Status "reused" -Message "이미지 기반 초안 재사용"
        } else {
            Invoke-StepCommand "2. 보유 이미지 기반 초안 생성" { & $pythonExe -u $imageDraftScript }
            Report-UsageEvent -EventType "stage_completed" -Stage "image_draft" -Status "completed" -Message "이미지 기반 초안 생성 완료"
        }
    }
    else {
        $script:UsageStage = "research"
        if (Test-ShouldReuseArtifact -ResumeRequested $resumeRequested -ArtifactPath $researchOutputPath -ReferencePaths @($requestPath)) {
            Write-ResumeSkip "1. 온라인 리서치 수집" "기존 latest_research.json 이 있어 리서치 수집 단계를 건너뜁니다."
            Report-UsageEvent -EventType "stage_completed" -Stage "research" -Status "reused" -Message "리서치 재사용"
        } else {
            Invoke-StepCommand "1. 온라인 리서치 수집" { & $pythonExe -u $researchScript }
            Report-UsageEvent -EventType "stage_completed" -Stage "research" -Status "completed" -Message "온라인 리서치 완료"
        }

        $script:UsageStage = "title_selection"
        if ((Test-ShouldReuseArtifact -ResumeRequested $resumeRequested -ArtifactPath $titleOptionsPath -ReferencePaths @($requestPath, $researchOutputPath)) -and $requestData.selected_title) {
            Write-ResumeSkip "2~3. 제목 후보 생성/선택" "기존 제목 후보와 선택된 제목이 있어 제목 단계를 건너뜁니다."
            Report-UsageEvent -EventType "stage_completed" -Stage "title_selection" -Status "reused" -Message "기존 제목 후보/선택값 재사용"
        }
        elseif (Test-ShouldReuseArtifact -ResumeRequested $resumeRequested -ArtifactPath $titleOptionsPath -ReferencePaths @($requestPath, $researchOutputPath)) {
            Write-Step "2. 제목 후보 재사용"
            Write-Host "기존 title_options.json 을 재사용하고 제목 선택만 다시 진행합니다." -ForegroundColor Yellow
            if ($titleOptionCount -gt 1) {
                Write-Step "3. 제목 후보 선택"
            } else {
                Write-Step "3. 제목 자동 선택"
            }
            powershell.exe -STA -ExecutionPolicy Bypass -File $titleSelectScript
            $selectionExitCode = $LASTEXITCODE
            if ($selectionExitCode -eq 10) {
                Remove-Item -LiteralPath $titleOptionsPath -Force -ErrorAction SilentlyContinue
                Invoke-TitleSelectionFlow -TitleOptionCount $titleOptionCount -PythonExe $pythonExe -TitleOptionsScript $titleOptionsScript -TitleSelectScript $titleSelectScript
            }
            elseif ($selectionExitCode -ne 0) {
                throw "3. 제목 후보 선택 단계가 실패했습니다. 종료 코드: $selectionExitCode"
            }
            Report-UsageEvent -EventType "stage_completed" -Stage "title_selection" -Status "completed" -Message "제목 선택 완료"
        }
        else {
            Invoke-TitleSelectionFlow -TitleOptionCount $titleOptionCount -PythonExe $pythonExe -TitleOptionsScript $titleOptionsScript -TitleSelectScript $titleSelectScript
            Report-UsageEvent -EventType "stage_completed" -Stage "title_selection" -Status "completed" -Message "제목 후보 생성/선택 완료"
        }

        $script:UsageStage = "draft_generation"
        if (Test-ShouldReuseArtifact -ResumeRequested $resumeRequested -ArtifactPath $latestResultPath -ReferencePaths @($requestPath, $researchOutputPath, $titleOptionsPath)) {
            Write-ResumeSkip "4. 블로그 초안 생성" "기존 latest_result.json 이 있어 초안 생성 단계를 건너뜁니다."
            Report-UsageEvent -EventType "stage_completed" -Stage "draft_generation" -Status "reused" -Message "초안 재사용"
        } else {
            Invoke-StepCommand "4. 블로그 초안 생성" { & $pythonExe -u $draftScript }
            Report-UsageEvent -EventType "stage_completed" -Stage "draft_generation" -Status "completed" -Message "블로그 초안 생성 완료"
        }
    }

    if ($reviewDraftEnabled -and $inputMode -ne "autopost_only") {
        $script:UsageStage = "draft_review"
        Invoke-StepCommand "5. 원고 확인 및 수정" { powershell.exe -STA -ExecutionPolicy Bypass -File $reviewDraftScript }
        Report-UsageEvent -EventType "stage_completed" -Stage "draft_review" -Status "completed" -Message "원고 검토/수정 완료"
    }

    if ($inputMode -eq "autopost_only") {
        $script:UsageStage = "package_prepare"
        Write-Step "6. 기존 패키지 재사용"
        if (-not $latestPackageDir) {
            $latestPackageDir = Find-LatestPackageDir -JobsDir $jobsDir
        }
        Write-Host "패키지 생성 없이 기존 자료를 그대로 사용합니다."
        Write-Host "사용 패키지: $latestPackageDir"
        Report-UsageEvent -EventType "stage_completed" -Stage "package_prepare" -Status "reused" -PackageDir $latestPackageDir -Message "기존 패키지 재사용"
    } else {
        $script:UsageStage = "package_build"
        $latestPackage = Get-ChildItem -LiteralPath $jobsDir -Directory -Filter "upload_package_*" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        $resultLastWrite = if (Test-Path $latestResultPath) { (Get-Item $latestResultPath).LastWriteTime } else { $null }
        if ($latestPackage -and $resultLastWrite -and $latestPackage.LastWriteTime -ge $resultLastWrite -and $latestPackage.LastWriteTime -ge (Get-Item $requestPath).LastWriteTime) {
            Write-ResumeSkip "6. 업로드 패키지 생성" "기존 최신 패키지를 재사용합니다."
            $latestPackageDir = $latestPackage.FullName
            Report-UsageEvent -EventType "stage_completed" -Stage "package_build" -Status "reused" -PackageDir $latestPackageDir -Message "최신 업로드 패키지 재사용"
        } else {
            Write-Step "6. 업로드 패키지 생성"
            $packageOutput = & $pythonExe -u $packageScript
            if ($LASTEXITCODE -ne 0) {
                throw "6. 업로드 패키지 생성 단계가 실패했습니다. 종료 코드: $LASTEXITCODE"
            }
            $packageOutput | ForEach-Object { Write-Host $_ }
            $latestPackageDir = ($packageOutput | Select-Object -Last 1).Trim()
            if (-not $latestPackageDir) {
                throw "업로드 패키지 폴더 경로를 찾지 못했습니다."
            }
            Report-UsageEvent -EventType "stage_completed" -Stage "package_build" -Status "completed" -PackageDir $latestPackageDir -Message "업로드 패키지 생성 완료"
        }
    }

    $script:UsageStage = "package_apply"
    Write-Step "7. AHK package_dir 갱신"
    Update-AhkPackageDir -ScriptPath $ahkScript -PackageDir $latestPackageDir
    Write-Host "반영된 패키지 폴더: $latestPackageDir"
    Report-UsageEvent -EventType "stage_completed" -Stage "package_apply" -Status "completed" -PackageDir $latestPackageDir -Message "AHK package_dir 반영 완료"

    if ($inputMode -eq "autopost_only") {
        $script:UsageStage = "image_generation"
        Write-Step "8. 이미지 생성 건너뛰기"
        Write-Host "이미 생성된 최신 패키지 이미지를 그대로 사용합니다."
        Report-UsageEvent -EventType "stage_completed" -Stage "image_generation" -Status "reused" -PackageDir $latestPackageDir -Message "기존 이미지 재사용"
    } else {
        $script:UsageStage = "image_generation"
        $imagePromptsPath = Join-Path $latestPackageDir "image_prompts.json"
        $imagesDir = Join-Path $latestPackageDir "images"
        $hasGeneratedImages = $false
        if ((Test-Path $imagePromptsPath) -and (Test-Path $imagesDir)) {
            $promptData = Get-Content -LiteralPath $imagePromptsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $items = @($promptData.items)
            if ($items.Count -gt 0) {
                $hasGeneratedImages = $true
                foreach ($item in $items) {
                    $outputPath = Join-Path $latestPackageDir ([string]$item.output_path -replace '/', '\')
                    if (-not (Test-Path $outputPath)) {
                        $hasGeneratedImages = $false
                        break
                    }
                }
            }
        }
        if ($hasGeneratedImages) {
            Write-ResumeSkip "8. 이미지 생성" "기존 패키지 이미지가 모두 있어 이미지 생성 단계를 건너뜁니다."
            Report-UsageEvent -EventType "stage_completed" -Stage "image_generation" -Status "reused" -PackageDir $latestPackageDir -Message "기존 패키지 이미지 재사용"
        } else {
            Invoke-StepCommand "8. 이미지 생성" { & $pythonExe -u $imageScript }
            Report-UsageEvent -EventType "stage_completed" -Stage "image_generation" -Status "completed" -PackageDir $latestPackageDir -Message "패키지 이미지 생성 완료"
        }
    }

    if ($reviewImagesEnabled -and $inputMode -ne "autopost_only") {
        $script:UsageStage = "image_review"
        Invoke-StepCommand "9. 이미지 확인 및 재생성" { powershell.exe -STA -ExecutionPolicy Bypass -File $reviewImagesScript }
        Report-UsageEvent -EventType "stage_completed" -Stage "image_review" -Status "completed" -PackageDir $latestPackageDir -Message "이미지 검토/재생성 완료"
    }

    if (-not $autoPostingEnabled) {
        $script:UsageStage = "pipeline"
        Report-UsageEvent -EventType "pipeline_completed" -Stage "pipeline" -Status "completed" -PackageDir $latestPackageDir -Message "자동포스팅 없이 생성 작업 완료"
        Write-Host ""
        Write-Host "자동포스팅 옵션이 꺼져 있어 원고와 이미지 생성 후 종료합니다." -ForegroundColor Yellow
        Write-Host "실행 로그: $runLogPath"
        exit 0
    }

    $script:UsageStage = "naver_window"
    Write-Step "10. 네이버 글쓰기 창 열기"
    Open-NaverWriteWindow -Url $naverWriteUrl -DelaySeconds $naverWriteOpenDelaySeconds
    Report-UsageEvent -EventType "stage_completed" -Stage "naver_window" -Status "completed" -PackageDir $latestPackageDir -Message "네이버 글쓰기 창 열기 완료"

    $script:UsageStage = "ahk_launch"
    Write-Step "11. AutoHotkey 실행"
    Stop-ExistingAhkScript -ScriptPath $ahkScript
    $ahkExe = Find-AutoHotkey
    if ($ahkExe) {
        Start-Process -FilePath $ahkExe -ArgumentList @($ahkScript) | Out-Null
        Write-Host "AutoHotkey를 실행했습니다: $ahkExe"
    } else {
        Start-Process -FilePath $ahkScript | Out-Null
        Write-Host "연결된 기본 앱으로 AHK 스크립트를 실행했습니다."
    }
    Report-UsageEvent -EventType "stage_completed" -Stage "ahk_launch" -Status "completed" -PackageDir $latestPackageDir -Message "AutoHotkey 실행 완료"

    $script:UsageStage = "autopost_start"
    Write-Step "12. 자동 포스팅 시작"
    Send-CtrlTToActiveWindow -DelaySeconds $autoStartDelaySeconds
    Report-UsageEvent -EventType "pipeline_completed" -Stage "pipeline" -Status "completed" -PackageDir $latestPackageDir -Message "자동 포스팅 시작 신호 전송 완료"

    Write-Host ""
    Write-Host "v4 전체 파이프라인 실행이 끝났습니다." -ForegroundColor Green
    Write-Host "실행 로그: $runLogPath"
}
catch {
    Report-UsageEvent -EventType "pipeline_failed" -Stage $script:UsageStage -Status "failed" -PackageDir $latestPackageDir -Message $_.Exception.Message
    Write-Host ""
    if ($_.Exception.Message -match "insufficient_quota") {
        Write-Host "OpenAI API 크레딧 또는 결제 한도가 부족해서 작업이 중단되었습니다." -ForegroundColor Red
        Write-Host "크레딧을 충전하거나 결제 한도를 복구한 뒤, 같은 요청으로 다시 실행하면 이미 완료된 단계는 가능한 범위에서 이어서 진행합니다." -ForegroundColor Yellow
    }
    Write-Host "실패 원인: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "실행 로그: $runLogPath" -ForegroundColor Yellow
    if (-not $NoPause) {
        cmd /c pause
    }
    exit 1
}
finally {
    Stop-Transcript | Out-Null
}





