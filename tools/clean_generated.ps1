param([switch]$Apply)
$ErrorActionPreference = 'Stop'
$taskRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$taskPrefix = $taskRoot + [IO.Path]::DirectorySeparatorChar

function Assert-WorkspacePath([string]$Path) {
    $taskFull = [IO.Path]::GetFullPath($Path)
    if (-not $taskFull.StartsWith($taskPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is outside this workspace: $taskFull"
    }
    $taskParent = Get-Item -LiteralPath $taskFull -Force
    while ($taskParent.FullName -ne $taskRoot) {
        if ($taskParent.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Refusing to clean through a link: $($taskParent.FullName)"
        }
        $taskParent = if ($taskParent -is [IO.DirectoryInfo]) { $taskParent.Parent } else { $taskParent.Directory }
        if (-not $taskParent) { throw 'Cannot establish workspace boundary.' }
    }
    return $taskFull
}

$taskRelative = @(
    'sync_life/build', 'sync_life/.dart_tool', 'sync_life/.idea',
    'sync_life/android/.gradle', 'sync_life/android/.kotlin',
    'sync_life/android/build', 'sync_life/android/app/build',
    'sync_life/android/app/.cxx',
    'sync_life/android/unityLibrary/build', 'sync_life/android/unityLibrary/symbols',
    'sync_life/unity/HumanPlus_MoCap_Unity-main/Library',
    'sync_life/unity/HumanPlus_MoCap_Unity-main/Temp',
    'sync_life/unity/HumanPlus_MoCap_Unity-main/Logs',
    'sync_life/unity/HumanPlus_MoCap_Unity-main/Builds',
    'sync_life/unity/HumanPlus_MoCap_Unity-main/UserSettings',
    'plugins/flutter_unity_widget/android/build',
    'plugins/flutter_unity_widget/example/unity/DemoApp/obj', 'server/.idea'
)
# Scan source roots only; do not touch installed dependencies or private records.
foreach ($taskScanRoot in @('server/Sync', 'sync_life/unity/HumanPlus_MoCap_Unity-main')) {
    $taskScan = Join-Path $taskRoot $taskScanRoot
    foreach ($taskItem in Get-ChildItem -LiteralPath $taskScan -Recurse -Force -ErrorAction Stop) {
        if ($taskItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        if (($taskItem.PSIsContainer -and $taskItem.Name -eq '__pycache__') -or
            (-not $taskItem.PSIsContainer -and $taskItem.Extension -in @('.sln', '.csproj', '.log'))) {
            $taskRelative += $taskItem.FullName.Substring($taskPrefix.Length)
        }
    }
}
foreach ($taskFile in @('sync_life/flutter_01.log', 'sync_life/sync_life.iml',
    'sync_life/android/sync_life_android.iml', 'server/debug.log')) {
    $taskRelative += $taskFile
}

$taskTargets = @()
foreach ($taskName in ($taskRelative | Sort-Object -Unique)) {
    $taskPath = Join-Path $taskRoot $taskName
    if (-not (Test-Path -LiteralPath $taskPath)) { continue }
    $taskFull = Assert-WorkspacePath $taskPath
    # Validate children before a recursive deletion. Never traverse junction targets.
    if (Test-Path -LiteralPath $taskFull -PathType Container) {
        $taskLink = Get-ChildItem -LiteralPath $taskFull -Recurse -Force |
            Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint } |
            Select-Object -First 1
        if ($taskLink) { throw "Remove or relocate the generated link before cleaning: $($taskLink.FullName)" }
    }
    if (-not ($taskTargets | Where-Object { $taskFull.StartsWith($_ + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) })) {
        $taskTargets += $taskFull
    }
}
$taskTotal = 0L
foreach ($taskPath in $taskTargets) {
    $taskFiles = @(Get-ChildItem -LiteralPath $taskPath -Recurse -File -Force)
    $taskSize = ($taskFiles | Measure-Object -Property Length -Sum).Sum
    $taskTotal += $taskSize
    Write-Output ('{0,10:N1} MB  {1}' -f ($taskSize / 1MB), $taskPath.Substring($taskPrefix.Length))
}
Write-Output ('Total: {0:N2} GB; Apply={1}' -f ($taskTotal / 1GB), $Apply)
if ($Apply) {
    foreach ($taskPath in $taskTargets) {
        $taskChecked = Assert-WorkspacePath $taskPath
        Remove-Item -LiteralPath $taskChecked -Recurse -Force
    }
}
