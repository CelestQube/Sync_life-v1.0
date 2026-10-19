param(
    [Parameter(Mandatory=$true)][string]$ExportRoot,
    [string]$NdkVersion = '27.0.12077973',
    [string]$NdkPath
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath $ExportRoot).Path
$library = Join-Path $root 'unityLibrary'
if (-not (Test-Path -LiteralPath $library)) { $library = Join-Path $root 'tuanjieLibrary' }
if (-not (Test-Path -LiteralPath (Join-Path $library 'build.gradle'))) { throw 'Unity Android library not found' }
$assembly = Join-Path $library 'src/main/Il2CppOutputProject/Source/il2cppOutput/Assembly-CSharp.cpp'
if (-not (Select-String -LiteralPath $assembly -Pattern 'SyncLifeMoCapBridge' -SimpleMatch -Quiet)) {
    throw 'Export does not include SyncLifeMoCapBridge. Re-export the updated Unity project.'
}

# Flutter imports the library under :unityLibrary, including exports produced by Tuanjie.
$gradlePath = Join-Path $library 'build.gradle'
$gradle = [IO.File]::ReadAllText($gradlePath)
$gradle = $gradle.Replace("project(':tuanjieLibrary')", "project(':unityLibrary')")
if ($NdkPath) {
    $resolvedNdk = (Resolve-Path -LiteralPath $NdkPath).Path.Replace('\', '/')
    $ndkProperties = Join-Path $resolvedNdk 'source.properties'
    if (-not (Test-Path -LiteralPath $ndkProperties)) { throw 'NDK source.properties not found' }
    $revision = [regex]::Match([IO.File]::ReadAllText($ndkProperties), '(?m)^Pkg\.Revision\s*=\s*(\S+)').Groups[1].Value
    if (-not $revision) { throw 'NDK version missing from source.properties' }
    $selector = "    ndkPath `"$resolvedNdk`"`n    ndkVersion `"$revision`""
} else {
    $selector = "    ndkVersion `"$NdkVersion`""
}
# The standard plugin comments out Unity's NDK path. Allow its bundled NDK per library,
# without pinning ndk.dir globally and conflicting with Flutter/JNI dependencies.
$ndkPattern = '(?m)^\s*ndk(?:Path|Version)\s+["''][^"'']*["''].*$'
$gradle = [regex]::Replace($gradle, $ndkPattern, '')
$gradle = [regex]::new('android \{').Replace($gradle, "android {`n$selector", 1)
[IO.File]::WriteAllText($gradlePath, $gradle, [Text.UTF8Encoding]::new($false))

# Flutter owns activities and APK packaging; avoid a second launcher and conflicting themes.
$manifestPath = Join-Path $library 'src/main/AndroidManifest.xml'
[xml]$manifest = Get-Content -LiteralPath $manifestPath -Raw
$application = $manifest.manifest.application
@($application.SelectNodes('activity')) | ForEach-Object { $application.RemoveChild($_) | Out-Null }
$application.RemoveAttribute('extractNativeLibs', 'http://schemas.android.com/apk/res/android')
$manifest.Save($manifestPath)

$resources = Join-Path $library 'src/main/res/values'
if ((Get-ChildItem -LiteralPath $resources -Filter '*.xml' | Select-String -Pattern 'name="TuanjieThemeSelector"' -SimpleMatch).Count -gt 0) {
    $alias = '<resources><style name="UnityThemeSelector" parent="TuanjieThemeSelector" /></resources>'
    [IO.File]::WriteAllText((Join-Path $resources 'phone_unity_compat.xml'), $alias, [Text.UTF8Encoding]::new($false))
}
Write-Output "Prepared library: $library"
Write-Output "Build with Gradle property: -PphoneUnityLibrary=$library"
