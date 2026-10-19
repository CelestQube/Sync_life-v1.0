param(
    [string]$JavaHome = $env:JAVA_HOME,
    [string]$UnityLibrary
)
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
if (-not $JavaHome -or -not (Test-Path -LiteralPath (Join-Path $JavaHome 'bin/java.exe'))) {
    throw 'Set JAVA_HOME or supply -JavaHome with an installed JDK (17 or later).'
}
if (-not $UnityLibrary) { $UnityLibrary = Join-Path $taskRoot 'android/unityLibrary' }
$UnityLibrary = (Resolve-Path -LiteralPath $UnityLibrary).Path
$env:JAVA_HOME = $JavaHome
Push-Location (Join-Path $taskRoot 'android')
try {
    & .\gradlew.bat :app:compileDebugUnitTestKotlin "-PphoneUnityLibrary=$UnityLibrary" '-Pkotlin.incremental=false'
    if ($LASTEXITCODE -ne 0) { throw 'Native test compilation failed.' }
} finally { Pop-Location }
# Gradle's test worker misloads classes on this Windows checkout's Unicode path.
# Pass the same compiled classes directly to JUnit, preserving Unicode arguments.
$taskCache = Join-Path $env:USERPROFILE '.gradle/caches/modules-2/files-2.1'
$taskJars = foreach ($taskName in @('junit-4.13.2.jar', 'hamcrest-core-1.3.jar', 'json-20240303.jar', 'onnxruntime-1.19.2.jar', 'kotlin-stdlib-2.2.0.jar')) {
    $taskFound = @(rg --files $taskCache -g $taskName)
    if ($taskFound.Count -ne 1) { throw "Expected one test runtime jar: $taskName" }
    $taskFound[0]
}
$taskClassPath = @(
    (Join-Path $taskRoot 'android/app/build/tmp/kotlin-classes/debug'),
    (Join-Path $taskRoot 'android/app/build/tmp/kotlin-classes/debugUnitTest')
) + $taskJars
Push-Location (Join-Path $taskRoot 'android/app')
try {
    & (Join-Path $JavaHome 'bin/java.exe') '-Dfile.encoding=UTF-8' '-cp' ($taskClassPath -join ';') org.junit.runner.JUnitCore com.example.sync_life.MocapInferenceTest com.example.sync_life.MocapEnhancementTest
    if ($LASTEXITCODE -ne 0) { throw 'Native numerical reference tests failed.' }
} finally { Pop-Location }
