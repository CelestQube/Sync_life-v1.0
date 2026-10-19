param(
    [string]$UnityLibrary,
    [string]$ApiBaseUrl = 'http://127.0.0.1:8000/api',
    [string]$JavaHome = $env:JAVA_HOME
)
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
if (-not $UnityLibrary) { $UnityLibrary = Join-Path $taskRoot 'android/unityLibrary' }
$taskExport = (Resolve-Path -LiteralPath $UnityLibrary).Path
$taskAssembly = Join-Path $taskExport 'src\main\Il2CppOutputProject\Source\il2cppOutput\Assembly-CSharp.cpp'
$taskManagers = Join-Path $taskExport 'src\main\assets\bin\Data\globalgamemanagers'
if (-not (Test-Path -LiteralPath $taskAssembly) -or -not (Test-Path -LiteralPath $taskManagers)) {
    throw 'Use the official Unity Android library exported through FlutterUnityIntegration.'
}
if (-not ([IO.File]::ReadAllText($taskAssembly).Contains('SyncLifeMoCapBridge')) -or
    -not ([Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($taskManagers)).Contains('2022.3.22f1'))) {
    throw 'The library must contain the phone bridge and official Unity 2022.3.22f1 scene data.'
}
# IL2CPP on Windows needs a short ASCII path; keep the actual export in the workspace.
if ($taskExport -match '[^\x00-\x7F]') {
    $taskHasher = [Security.Cryptography.SHA256]::Create()
    try {
        $taskHash = [BitConverter]::ToString($taskHasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($taskExport))).Replace('-', '').Substring(0, 12)
    } finally { $taskHasher.Dispose() }
    $taskAlias = Join-Path ([IO.Path]::GetTempPath()) "SyncLife-UnityLibrary-$taskHash"
    if (Test-Path -LiteralPath $taskAlias) {
        $taskTarget = @((Get-Item -LiteralPath $taskAlias).Target)[0]
        if (-not $taskTarget -or [IO.Path]::GetFullPath($taskTarget) -ne $taskExport) {
            throw "Existing export link points elsewhere: $taskAlias"
        }
    } else {
        New-Item -ItemType Junction -Path $taskAlias -Target $taskExport | Out-Null
    }
    $taskExport = $taskAlias
}
$taskApi = [Uri]$ApiBaseUrl
if (-not $taskApi.IsAbsoluteUri -or $taskApi.Scheme -notin @('http', 'https') -or
    $taskApi.UserInfo -or $taskApi.Query -or $taskApi.Fragment) {
    throw 'ApiBaseUrl must be an HTTP(S) base address without credentials, query, or fragment.'
}
$taskPython = Join-Path $taskRoot '..\server\.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $taskPython)) { $taskPython = (Get-Command python -ErrorAction Stop).Source }
$taskPreviousJavaHome = $env:JAVA_HOME
$taskPreviousPythonUtf8 = $env:PYTHONUTF8
if ($JavaHome -and -not (Test-Path -LiteralPath (Join-Path $JavaHome 'bin\java.exe'))) {
    throw 'JavaHome must point to an installed JDK (17 or later).'
}
if (-not $JavaHome -and -not (Get-Command java -ErrorAction SilentlyContinue)) {
    throw 'Set JAVA_HOME or supply -JavaHome with an installed JDK (17 or later).'
}
$taskOutput = Join-Path $taskRoot 'build'
New-Item -ItemType Directory -Path $taskOutput -Force | Out-Null
Push-Location (Join-Path $taskRoot 'android')
try {
    if ($JavaHome) { $env:JAVA_HOME = $JavaHome }
    $taskDefine = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("SYNC_LIFE_API_BASE_URL=$ApiBaseUrl"))
    # Flutter's Gradle plugin compiles Dart; pass the library property explicitly to settings.gradle.kts.
    & .\gradlew.bat assembleDebug '--no-watch-fs' '-Ptarget-platform=android-arm64' "-PphoneUnityLibrary=$($taskExport.Replace('\', '/'))" '-Pkotlin.incremental=false' "-Pdart-defines=$taskDefine" |
        Tee-Object -FilePath (Join-Path $taskOutput 'agent-apk-build.log')
    if ($LASTEXITCODE -ne 0) { throw 'Android build failed; no acceptance APK was copied.' }
    $taskApk = Join-Path $taskOutput 'app\outputs\flutter-apk\app-debug.apk'
    $env:PYTHONUTF8 = '1'
    $taskValidation = & $taskPython (Join-Path $PSScriptRoot 'verify_phone_mocap_apk.py') $taskApk
    if ($LASTEXITCODE -ne 0) { throw 'APK content checks failed; no acceptance APK was copied.' }
    $taskValidation | Set-Content -LiteralPath (Join-Path $taskOutput 'agent-apk-validation.json') -Encoding UTF8
    $taskValidation | Write-Output
    Copy-Item -LiteralPath $taskApk -Destination (Join-Path $taskOutput 'app\outputs\flutter-apk\Sync-Life-agent-local-debug.apk')
} finally {
    $env:JAVA_HOME = $taskPreviousJavaHome
    $env:PYTHONUTF8 = $taskPreviousPythonUtf8
    Pop-Location
}
