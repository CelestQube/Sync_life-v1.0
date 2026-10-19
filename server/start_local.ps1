param([switch]$NoReload, [switch]$SkipDatabase)
$ErrorActionPreference = 'Stop'
$taskPython = Join-Path $PSScriptRoot '.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $taskPython)) { throw 'Create .venv and install requirements-api.txt first.' }
if (-not $SkipDatabase) {
    & docker compose --env-file (Join-Path $PSScriptRoot '.env') -f (Join-Path $PSScriptRoot 'compose.local.yml') up -d --wait --wait-timeout 30
    if ($LASTEXITCODE -ne 0) { throw 'Start Docker Desktop first; or use -SkipDatabase for an external PostgreSQL server.' }
}
Push-Location (Join-Path $PSScriptRoot 'Sync')
try {
    & $taskPython manage.py migrate --noinput
    if ($LASTEXITCODE -ne 0) { throw 'Database migration failed.' }
    & $taskPython manage.py motion_maintenance
    if ($LASTEXITCODE -ne 0) { throw 'Motion retention maintenance failed.' }
    $taskMaintenanceJob = Start-Job -ArgumentList $taskPython, (Get-Location).Path -ScriptBlock {
        param($taskWorkerPython, $taskWorkerDirectory)
        Set-Location -LiteralPath $taskWorkerDirectory
        while ($true) {
            Start-Sleep -Seconds 21600
            & $taskWorkerPython manage.py motion_maintenance
        }
    }
    $taskArguments = @('manage.py', 'runserver', '127.0.0.1:8000')
    if ($NoReload) { $taskArguments += '--noreload' }
    & $taskPython @taskArguments
} finally {
    if ($taskMaintenanceJob) {
        Stop-Job -Job $taskMaintenanceJob
        Remove-Job -Job $taskMaintenanceJob -Force
    }
    Pop-Location
}
