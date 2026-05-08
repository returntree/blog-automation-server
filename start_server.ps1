$ErrorActionPreference = "Stop"

Set-Location -LiteralPath $PSScriptRoot

if (-not (Test-Path "$PSScriptRoot\.venv\Scripts\python.exe")) {
    throw "가상환경이 없습니다. 먼저 .\bootstrap_server.ps1 을 실행해 주세요."
}

if (-not (Test-Path "$PSScriptRoot\.env")) {
    Copy-Item -LiteralPath "$PSScriptRoot\.env.example" -Destination "$PSScriptRoot\.env"
}

Get-Content -LiteralPath "$PSScriptRoot\.env" | ForEach-Object {
    if ($_ -match '^\s*#' -or $_ -match '^\s*$') { return }
    $pair = $_ -split '=', 2
    if ($pair.Count -eq 2) {
        [Environment]::SetEnvironmentVariable($pair[0], $pair[1])
    }
}

$hostValue = [Environment]::GetEnvironmentVariable('SERVER_HOST')
if ([string]::IsNullOrWhiteSpace($hostValue)) { $hostValue = '0.0.0.0' }
$portValue = [Environment]::GetEnvironmentVariable('PORT')
if ([string]::IsNullOrWhiteSpace($portValue)) { $portValue = [Environment]::GetEnvironmentVariable('SERVER_PORT') }
if ([string]::IsNullOrWhiteSpace($portValue)) { $portValue = '8000' }
$appEnv = [Environment]::GetEnvironmentVariable('APP_ENV')
if ([string]::IsNullOrWhiteSpace($appEnv)) { $appEnv = 'development' }

if ($appEnv -eq 'production') {
    & "$PSScriptRoot\.venv\Scripts\python.exe" -m uvicorn app.main:app --host $hostValue --port $portValue
}
else {
    & "$PSScriptRoot\.venv\Scripts\python.exe" -m uvicorn app.main:app --host $hostValue --port $portValue --reload
}
