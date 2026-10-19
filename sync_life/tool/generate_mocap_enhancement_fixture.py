"""Read-only extraction of desktop numerical methods; no sockets/GUI imports.

The desktop MotionOptimizer's QP has no inequality constraints. NumPy's dense
linear solve provides its exact minimizer for the reference fixture.
"""
import argparse
import ast
import json
from pathlib import Path
from types import SimpleNamespace
import warnings

import numpy as np
import onnxruntime as ort
import torch
from scipy.spatial.transform import Rotation


def array(value):
    return value.detach().cpu().numpy() if isinstance(value, torch.Tensor) else np.asarray(value)


def euler_to_matrix(q, seq='XYZ'):
    return torch.tensor(Rotation.from_euler(seq, array(q).reshape(-1, 3)).as_matrix(), dtype=torch.float32)


def matrix_to_euler(r, seq='XYZ'):
    with warnings.catch_warnings():
        warnings.simplefilter('ignore')
        result = Rotation.from_matrix(array(r).reshape(-1, 3, 3)).as_euler(seq)
    return torch.tensor(result, dtype=torch.float32)


def extract(path, names, scope):
    tree = ast.parse(path.read_text(encoding='utf-8-sig'))
    nodes = [node for node in tree.body if isinstance(node, (ast.FunctionDef, ast.ClassDef)) and node.name in names]
    # Named constants of SMPLight are safe numeric expressions, not imports.
    if 'SMPLight' in names:
        nodes = [node for node in tree.body if isinstance(node, ast.Assign) and
                 any(isinstance(t, ast.Name) and t.id in {'EDGES', 'JOINT_LOCAL', 'Z_90_p', 'Z_90_n'} for t in node.targets)] + nodes
    exec(compile(ast.fix_missing_locations(ast.Module(body=nodes, type_ignores=[])), str(path), 'exec'), scope)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--hardware-root', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    root = args.hardware_root
    scope = {'np': np, 'torch': torch, 'math': __import__('math'),
             'normalize_tensor': lambda x: torch.nn.functional.normalize(x, dim=-1),
             'euler_angle_to_rotation_matrix': euler_to_matrix,
             'euler_angle_to_rotation_matrix_np': lambda q, seq='XYZ': Rotation.from_euler(seq, array(q).reshape(-1,3)).as_matrix(),
             'rotation_matrix_to_euler_angle': matrix_to_euler,
             'rotation_matrix_to_euler_angle_np': lambda r, seq='XYZ': array(matrix_to_euler(r,seq)),
             'axis_angle_to_rotation_matrix': lambda a: torch.tensor(Rotation.from_rotvec(array(a).reshape(-1,3)).as_matrix(), dtype=torch.float32),
             'rotation_matrix_to_axis_angle': lambda r: torch.tensor(Rotation.from_matrix(array(r).reshape(-1,3,3)).as_rotvec(), dtype=torch.float32)}
    extract(root / 'articulate/math/angular.py', {'r6d_to_rotation_matrix', 'rotation_matrix_to_r6d'}, scope)
    extract(root / 'Socket/UDP.py', {'rotation_diversity', 'ego_drift_regularization'}, scope)
    extract(root / 'mos/smpl_light.py', {'SMPLight', 'SAMPLight'}, scope)
    extract(root / 'mos/tools.py', {'constrain_joint_dofs', 'pose_to_q', 'q_to_pose', 'mask_jacobian'}, scope)
    scope['solve_qp'] = lambda p, q, **kwargs: np.linalg.solve(p, -q)
    scope['constrain_channels_q'] = [3 + j * 3 + 2 for j in (18, 19, 4, 5)]
    scope['KalmanFilterVelocity'] = lambda **kwargs: None
    scope['art'] = SimpleNamespace(math=SimpleNamespace(block_diagonal_matrix_np=lambda blocks: blocks[0]))
    extract(root / 'mos/motion_optimizer.py', {'normalize_angle', 'MotionOptimizer'}, scope)
    optimizer = scope['MotionOptimizer'](fps=30)
    frames = []
    for i in range(12):
        pose = np.zeros((24,3),dtype=np.float32)
        pose[0,1] = .2 + i*.01
        for j in (1,2,4,5,16,17,18,19):
            pose[j] = [.12*np.sin(i*.2+j), .03*np.cos(i*.1+j), .025*np.sin(j)]
        velocity = np.sin(np.arange(72).reshape(24,3)*.11+i*.1).astype(np.float32)*.04
        rotation = torch.tensor(Rotation.from_rotvec(pose).as_matrix(),dtype=torch.float32)
        result, _ = optimizer.optimize_frame(rotation, torch.from_numpy(velocity), torch.zeros(3))
        # Desktop first frame returns SAMPL axes before its inverse map; fix the
        # fixture boundary to SMPL just as the mobile output contract requires.
        if i == 0:
            result = optimizer.body_model.to_smpl(result)
        expected = Rotation.from_matrix(array(result)).as_rotvec().reshape(72)
        expected[21:27] = 0
        frames.append({'pose': pose.reshape(72).tolist(), 'velocity': velocity.reshape(72).tolist(),
                       'expected': expected.tolist()})
    history = np.zeros((256,120),dtype=np.float32)
    for i in range(256):
        angles = np.array([[.9*np.sin(i*.13+j),.7*np.cos(i*.09+j),1.3*np.sin(i*.07+j)] for j in range(10)])
        history[i,30:] = Rotation.from_euler('XYZ',angles).as_matrix().reshape(-1)
    session = ort.InferenceSession(str(root / 'onnx_models/TIC4Clothes_dense.onnx'),providers=['CPUExecutionProvider'])
    global_r6, local_r6 = session.run(None, {'imu_rot': history.reshape(1,256,120)})
    global_r = scope['r6d_to_rotation_matrix'](torch.tensor(global_r6).reshape(-1,6))
    global_r = scope['ego_drift_regularization'](global_r,imu_num=10).squeeze(0).transpose(-2,-1)
    local_r = scope['r6d_to_rotation_matrix'](torch.tensor(local_r6).reshape(-1,6)).transpose(-2,-1)
    diversity = scope['rotation_diversity'](torch.tensor(history[:,30:].reshape(1,256,10,3,3)))
    fixture = {'source': 'Original desktop MotionOptimizer + TIC4Clothes_dense; synthetic input only',
               'physics': frames, 'drift': {'history': history.reshape(-1).tolist(),
                   'prediction': np.concatenate([global_r6.reshape(-1),local_r6.reshape(-1)]).tolist(),
                   'global': global_r.reshape(-1).tolist(), 'local': local_r.reshape(-1).tolist(),
                   'diversity': diversity.reshape(-1).tolist()}}
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(fixture,separators=(',',':'))+'\n',encoding='utf-8')
    print('Wrote',len(frames),'physics frames, 256 drift frames, diversity',diversity.tolist())


if __name__ == '__main__':
    main()
