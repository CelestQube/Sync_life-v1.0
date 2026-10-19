param(
    [Parameter(Mandatory=$true)][string]$UnityEditor
)
$ErrorActionPreference = 'Stop'
$editor = (Resolve-Path -LiteralPath $UnityEditor).Path
$repo = Split-Path -Parent $PSScriptRoot
$source = Join-Path $repo 'unity/HumanPlus_MoCap_Unity-main'
$stage = Join-Path $repo 'build/official-unity-workspace'
$project = Join-Path $stage 'unity/HumanPlus_MoCap_Unity-main'
$android = Join-Path $stage 'android'
$ndk = Join-Path (Split-Path -Parent $editor) 'Data/PlaybackEngines/AndroidPlayer/NDK'
if (-not (Test-Path -LiteralPath (Join-Path $ndk 'source.properties'))) {
    throw 'Install Android Build Support, SDK & NDK Tools and OpenJDK for Unity 2022.3.22f1.'
}

# Export scripts delete their previous output. Keep every output in this generated workspace.
$resolvedStage = [IO.Path]::GetFullPath($stage)
$buildRoot = [IO.Path]::GetFullPath((Join-Path $repo 'build')) + [IO.Path]::DirectorySeparatorChar
if (-not $resolvedStage.StartsWith($buildRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Staging directory must remain inside the repository build directory.'
}
New-Item -ItemType Directory -Force -Path $project,(Join-Path $android 'app') | Out-Null
foreach ($part in @('Assets', 'Packages', 'ProjectSettings')) {
    Copy-Item -LiteralPath (Join-Path $source $part) -Destination $project -Recurse -Force
}
foreach ($file in @('build.gradle.kts', 'settings.gradle.kts', 'gradle.properties', 'local.properties')) {
    Copy-Item -LiteralPath (Join-Path $repo "android/$file") -Destination $android -Force
}
Copy-Item -LiteralPath (Join-Path $repo 'android/app/build.gradle.kts') -Destination (Join-Path $android 'app') -Force

# A short ASCII junction avoids Android tooling errors with the original Chinese path.
$ascii = Join-Path ([IO.Path]::GetTempPath()) 'SyncLife-Unity2022-01a10'
if (Test-Path -LiteralPath $ascii) {
    $target = @((Get-Item -LiteralPath $ascii).Target)[0]
    if (-not $target -or [IO.Path]::GetFullPath($target) -ne $resolvedStage) {
        throw "Existing staging link points elsewhere: $ascii"
    }
} else {
    New-Item -ItemType Junction -Path $ascii -Target $stage | Out-Null
}
$asciiProject = Join-Path $ascii 'unity/HumanPlus_MoCap_Unity-main'
$log = Join-Path $ascii 'official-unity-export.log'
$arguments = @('-batchmode', '-quit', '-buildTarget', 'Android', '-projectPath', "`"$asciiProject`"",
    '-executeMethod', 'ExportPhoneMocap.ExportWithFlutterPlugin', '-logFile', "`"$log`"")
$process = Start-Process -FilePath $editor -ArgumentList $arguments -WindowStyle Hidden -Wait -PassThru
if ($process.ExitCode -ne 0 -or -not (Select-String -LiteralPath $log -SimpleMatch -Quiet -Pattern '-- Android Debug Build: SUCCESSFUL --')) {
    throw "Unity export failed (exit $($process.ExitCode)); inspect $log"
}
& (Join-Path $PSScriptRoot 'prepare_phone_unity_export.ps1') -ExportRoot (Join-Path $ascii 'android') -NdkPath $ndk
Write-Output "Export log: $log"
