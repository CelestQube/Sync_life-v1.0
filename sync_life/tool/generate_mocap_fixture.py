"""Read the supplied Python implementation without importing its sockets/UI/SMPL assets.

Run with the hardware project's Python (numpy, torch, onnxruntime installed).
Only writes --output, never the hardware project.
"""
import argparse
import ast
import base64
import json
import math
from pathlib import Path
import struct
from types import SimpleNamespace

import numpy as np
import onnxruntime as ort
import torch


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--hardware-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    tree = ast.parse((args.hardware_root / "Socket/UDP.py").read_text(encoding="utf-8-sig"))
    original = next(node for node in tree.body if isinstance(node, ast.ClassDef) and node.name == "DataProcessServer_FullBody")
    methods = [node for node in original.body if isinstance(node, ast.FunctionDef) and node.name in
               {"set_calibrate_data", "calibrate", "normalize_and_concat"}]
    # Execute exactly the original calibration methods; omit its desktop imports/constructor.
    for node in methods:
        node.decorator_list = []
    klass = ast.ClassDef(name="Reference", bases=[], keywords=[], body=methods, decorator_list=[])
    module = ast.fix_missing_locations(ast.Module(body=[klass], type_ignores=[]))
    scope = {"torch": torch, "np": np, "normalize_tensor": lambda v: torch.nn.functional.normalize(v, dim=-1)}
    exec(compile(module, "hardware-calibration", "exec"), scope)
    reference = scope["Reference"]()
    reference.imu_num = 10
    reference.root_2_smpl = torch.diag(torch.tensor([-1., 1., -1.]))
    reference.config_clothes = {"root_2_back": torch.eye(3).unsqueeze(0)}
    reference.cali_pose = torch.eye(3).repeat(24, 1, 1)
    reference.device2bone = None
    reference.global_shift = reference.local_shift = torch.eye(3).repeat(10, 1, 1)

    angular = ast.parse((args.hardware_root / "Math/angular.py").read_text(encoding="utf-8-sig"))
    quaternion_method = next(node for node in angular.body if isinstance(node, ast.FunctionDef) and node.name == "quaternion_to_rotation_matrix")
    exec(compile(ast.fix_missing_locations(ast.Module(body=[quaternion_method], type_ignores=[])), "hardware-quaternion", "exec"), scope)
    q_to_matrix = scope["quaternion_to_rotation_matrix"]

    def samples(count, moving=False):
        result = []
        for i in range(count):
            # Stable, distinct sensor orientations; vertical gravity convention matches the script.
            ax = math.pi / 2 + i * .08 + (.04 * i if moving else 0)
            az = i * .12 + (.11 if moving else 0)
            xq = np.array([math.sin(ax/2), 0, 0, math.cos(ax/2)])
            zq = np.array([0, 0, math.sin(az/2), math.cos(az/2)])
            x, y, z, w = xq
            X, Y, Z, W = zq
            q = np.array([w*X+x*W+y*Z-z*Y, w*Y-x*Z+y*W+z*X,
                          w*Z+x*Y-y*X+z*W, w*W-x*X-y*Y-z*Z], dtype=np.float32)
            result.append(([float(i + .2), float(-i - .5), 9.8 + (.7 if moving else 0)], q.tolist()))
        return result

    def packet(data, lower=False, timestamp=1234):
        buf = bytearray(217)
        struct.pack_into("<BBHI", buf, 0, 255, 254, 217, timestamp)
        offsets = [8, 42, 76, 148, 182] if lower else [8, 42, 76, 110, 148, 182]
        # Lower left sensor 3 exists on the wire but is excluded by the reference receiver.
        if lower:
            struct.pack_into("<HI7f", buf, 110, 0, timestamp, 0, 0, 0, 0, 0, 0, 1)
        struct.pack_into("<I", buf, 144, timestamp)
        for i, (acc, quat) in enumerate(data):
            struct.pack_into("<HI7f", buf, offsets[i], i, timestamp, *acc, *quat)
        return base64.b64encode(buf).decode("ascii")

    def flatten(data):
        acc = torch.tensor([v[0] for v in data], dtype=torch.float32).flatten()
        quat = torch.tensor([[v[1][3], *v[1][:3]] for v in data], dtype=torch.float32)
        return torch.cat((acc, q_to_matrix(quat).flatten())).tolist()

    up_ref, low_ref = samples(6), samples(5)
    up_current, low_current = samples(6, True), samples(5, True)
    def select(up, low):
        return [up[i] for i in [5, 1, 4, 0, 3]] + [low[i] for i in [4, 1, 3, 0, 2]]
    reference.set_calibrate_data(flatten(select(up_ref, low_ref)))
    input_data = reference.calibrate(flatten(select(up_current, low_current))).astype(np.float32)
    session = ort.InferenceSession(str(args.hardware_root / "onnx_models/LFP_dense_taichi_ft.onnx"), providers=["CPUExecutionProvider"])
    states = {name: np.zeros((2, 1, 256), dtype=np.float32) for name in ["h_1", "c_1", "h_2", "c_2", "h_3", "c_3"]}
    poses = []
    for _ in range(3):
        output = dict(zip([value.name for value in session.get_outputs()], session.run(None, {"imu_data": input_data.reshape(1, 120), **states})))
        states = {name: output[name + "_n"] for name in states}
        pose = output["pose"].reshape(72)
        pose[21:27] = 0  # Same ankle suppression as the original postprocessor.
        assert np.isfinite(pose).all()
        poses.append(pose.tolist())
    fixture = {
        "origin": "Original FullBody calibration methods + LFP_dense_taichi_ft.onnx, CPU ORT " + ort.__version__,
        "upperReference": packet(up_ref), "lowerReference": packet(low_ref, True),
        "upperCurrent": packet(up_current, timestamp=1240), "lowerCurrent": packet(low_current, True, 1240),
        "expectedInput": input_data.tolist(), "expectedPoses": poses,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(fixture, indent=2) + "\n", encoding="utf-8")
    print("Wrote", args.output, "with 120 calibrated input values and 3 recurrent poses")


if __name__ == "__main__":
    main()
