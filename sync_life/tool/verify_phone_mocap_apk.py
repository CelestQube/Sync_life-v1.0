"""Verify packaged phone mocap dependencies; this does not test device rendering."""
import argparse
import hashlib
import json
import zipfile
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("apk", type=Path)
    args = parser.parse_args()
    expected_model = "652f9601f33102fa3794e472e9264ad4e6d5f8149ddd1d44891faceada08adc3"
    expected_drift_model = "93efa5e8622fa5e9b1c8aca4d94d6445d0391db7e04688c1b402f12bdb932c19"
    required_libraries = {
        "libflutter.so", "libunity.so", "libmain.so", "libil2cpp.so",
        "libonnxruntime.so", "libonnxruntime4j_jni.so",
    }
    with zipfile.ZipFile(args.apk) as package:
        names = set(package.namelist())
        abis = {name.split("/")[1] for name in names if name.startswith("lib/") and name.endswith(".so")}
        if abis != {"arm64-v8a"}:
            raise ValueError(f"APK must declare only the exported Unity ABI; got {sorted(abis)}")
        missing = required_libraries - {name.rsplit("/", 1)[-1] for name in names if name.startswith("lib/arm64-v8a/")}
        if missing:
            raise ValueError(f"Missing native libraries: {sorted(missing)}")
        if any(name.endswith("/libtuanjie.so") for name in names):
            raise ValueError("APK contains a Tuanjie engine library")
        managers = package.read("assets/bin/Data/globalgamemanagers")
        if b"2022.3.22f1" not in managers:
            raise ValueError("Packaged scene data is not from Unity 2022.3.22f1")
        model_hash = hashlib.sha256(package.read("assets/mocap/LFP_dense_taichi_ft.onnx")).hexdigest()
        if model_hash != expected_model:
            raise ValueError(f"Unexpected model hash: {model_hash}")
        drift_hash = hashlib.sha256(package.read("assets/mocap/TIC4Clothes_dense.onnx")).hexdigest()
        if drift_hash != expected_drift_model:
            raise ValueError(f"Unexpected drift model hash: {drift_hash}")
        dex_files = [package.read(name) for name in names if name.endswith('.dex')]
        for symbol in (b'Lcom/example/sync_life/MocapDriftModel;',
                       b'Lcom/example/sync_life/MocapPhysics;', b'calibrateDrift'):
            if not any(symbol in dex for dex in dex_files):
                raise ValueError(f"Missing Android enhancement code: {symbol.decode()}; clean :app build outputs")
        if 'assets/flutter_assets/kernel_blob.bin' in names:
            kernel = package.read('assets/flutter_assets/kernel_blob.bin')
            for symbol in (b'DailyActivityPage', b'activity_slots', b'smpl-imu-temporal-v2',
                           b'location_required', b'restaurant_recommend'):
                if symbol not in kernel:
                    raise ValueError(f"Missing Flutter activity enhancement: {symbol.decode()}")
        metadata = package.read("assets/bin/Data/Managed/Metadata/global-metadata.dat")
        for symbol in (b"SyncLifeMoCapBridge", b"ReceivePose", b"ApplyPhonePose"):
            if symbol not in metadata:
                raise ValueError(f"Missing C# interface: {symbol.decode()}")
        initializers = json.loads(package.read("assets/bin/Data/RuntimeInitializeOnLoads.json"))
        if not any(entry.get("className") == "SyncLifeMoCapBridge" and entry.get("methodName") == "Install"
                   for entry in initializers["root"]):
            raise ValueError("Bridge scene-load initializer is missing")
    print(json.dumps({
        "apk": str(args.apk.absolute()), "bytes": args.apk.stat().st_size,
        "sha256": hashlib.sha256(args.apk.read_bytes()).hexdigest(),
        "unity": "2022.3.22f1", "abis": sorted(abis), "model_sha256": model_hash,
        "drift_model_sha256": drift_hash,
        "package_checks": "passed", "device_rendering": "not_tested",
    }, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
