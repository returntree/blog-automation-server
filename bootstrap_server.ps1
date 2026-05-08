$ErrorActionPreference = "Stop"

Set-Location -LiteralPath $PSScriptRoot

if (-not (Test-Path '.venv')) {
    python -m venv .venv
}

& "$PSScriptRoot\.venv\Scripts\python.exe" -m pip install --upgrade pip
& "$PSScriptRoot\.venv\Scripts\python.exe" -m pip install -r "$PSScriptRoot\requirements.txt"

if (-not (Test-Path "$PSScriptRoot\.env")) {
    Copy-Item -LiteralPath "$PSScriptRoot\.env.example" -Destination "$PSScriptRoot\.env"
}

Write-Host "서버 초기화 완료" -ForegroundColor Green
Write-Host "다음 단계: server 폴더에서 .\start_server.ps1 실행" -ForegroundColor Cyan
