"""Check staged/tracked content before uploading; never print credential values."""
import json
import re
import subprocess
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parents[1]
GENERATED = {
    '.git', '.venv', 'venv', '__pycache__', '.dart_tool', '.gradle', '.kotlin',
    'build', 'Library', 'Temp', 'Logs', 'obj', 'Builds', 'UserSettings',
    '.idea', '.local', 'node_modules', 'ephemeral',
}
PRIVATE = {'local.properties', 'key.properties', 'local-account.json'}
PRIVATE_SUFFIXES = {'.apk', '.aab', '.aar', '.jks', '.keystore', '.p12', '.pyc', '.log', '.sqlite3'}
REQUIRED = [
    'server/.env.example', 'server/requirements-api.txt', 'server/Sync/manage.py',
    'sync_life/pubspec.lock', 'plugins/flutter_unity_widget/LICENSE',
    'plugins/flutter_unity_widget/pubspec.yaml', 'plugins/flutter_unity_widget/lib/flutter_unity_widget.dart',
    'sync_life/android/gradlew', 'sync_life/android/gradlew.bat',
    'sync_life/android/gradle/wrapper/gradle-wrapper.jar',
    'sync_life/android/app/src/main/assets/mocap/LFP_dense_taichi_ft.onnx',
    'sync_life/android/app/src/main/assets/mocap/TIC4Clothes_dense.onnx',
    'sync_life/unity/HumanPlus_MoCap_Unity-main/ProjectSettings/ProjectVersion.txt',
    'sync_life/unity/HumanPlus_MoCap_Unity-main/Packages/manifest.json',
    'sync_life/unity/HumanPlus_MoCap_Unity-main/Assets/HumanPlusMoCap/Scripts/SyncLifeMoCapBridge.cs',
    'sync_life/unity/HumanPlus_MoCap_Unity-main/Assets/HumanPlusMoCap/Scripts/SyncLifeMoCapBridge.cs.meta',
]


def git(*arguments, **kwargs):
    return subprocess.check_output(['git', '-C', str(ROOT), *arguments], **kwargs)


def local_secrets():
    values = []
    environment = ROOT / 'server/.env'
    if environment.is_file():
        for line in environment.read_text(encoding='utf-8-sig').splitlines():
            if '=' not in line or line.lstrip().startswith('#'):
                continue
            key, value = line.split('=', 1)
            value = value.strip().strip('\"\'')
            if any(word in key for word in ('KEY', 'PASSWORD', 'SECRET')) and len(value) >= 8:
                values.append(value.encode())
    account = ROOT / 'server/local-account.json'
    if account.is_file():
        value = json.loads(account.read_text(encoding='utf-8-sig')).get('password', '')
        if len(value) >= 8:
            values.append(value.encode())
    return values


def main():
    records = []
    failures = []
    for entry in git('ls-files', '--stage', '-z').split(b'\0'):
        if not entry:
            continue
        header, filename = entry.split(b'\t', 1)
        mode, object_id, stage = header.split()
        name = filename.decode('utf-8')
        records.append((name, object_id))
        path = PurePosixPath(name)
        is_environment = path.name == '.env' or (path.name.startswith('.env.') and not path.name.endswith('.example'))
        if (set(path.parts) & GENERATED or path.name in PRIVATE or
                path.suffix.lower() in PRIVATE_SUFFIXES or is_environment or
                name.startswith('sync_life/android/unityLibrary/') or
                name.startswith('sync_life/android/src/')):
            failures.append(f'Private/generated path is tracked: {name}')
        if mode == b'160000' or stage != b'0':
            failures.append(f'Unexpected submodule or unresolved index entry: {name}')
    names = {name for name, _ in records}
    for name in REQUIRED:
        if name not in names:
            failures.append(f'Required source/resource missing from index: {name}')

    secrets = local_secrets()
    patterns = [
        re.compile(rb'-----BEGIN (?:RSA |OPENSSH |EC )?PRIVATE KEY-----'),
        re.compile(rb'sk-[A-Za-z0-9]{20,}'),
        re.compile(rb'(?:gh[pousr]_[A-Za-z0-9]{25,}|github_pat_[A-Za-z0-9_]{30,})'),
    ]
    payload = b''.join(object_id + b'\n' for _, object_id in records)
    content = git('cat-file', '--batch', input=payload)
    offset = total = largest = 0
    for name, _ in records:
        end = content.index(b'\n', offset)
        header = content[offset:end].split()
        size = int(header[2])
        blob = content[end + 1:end + 1 + size]
        offset = end + size + 2
        total += size
        largest = max(largest, size)
        if size > 95 * 1024**2:
            failures.append(f'File exceeds repository size budget: {name}')
        if any(value in blob for value in secrets) or any(pattern.search(blob) for pattern in patterns):
            failures.append(f'Possible credential in indexed file: {name}')
    for failure in failures:
        print(f'ERROR: {failure}')
    print(json.dumps({'files': len(records), 'total_mib': round(total / 1024**2, 2),
                      'largest_mib': round(largest / 1024**2, 2), 'errors': len(failures)}))
    return bool(failures)


if __name__ == '__main__':
    raise SystemExit(main())
