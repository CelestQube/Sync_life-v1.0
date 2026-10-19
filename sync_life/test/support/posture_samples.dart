// Synthetic SMPL/IMU inputs. These are software fixtures, never real observations.
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:sync_life/mocap/posture_classifier.dart';

List<PostureEstimate> syntheticPosture(BodyPosture state,
    {double yaw = 0,
    bool jitter = false,
    double? cadence,
    DateTime? start,
    int frames = 180}) {
  final classifier = PostureClassifier();
  final result = <PostureEstimate>[];
  var micros = 0;
  for (var i = 0; i < frames; i++) {
    final t = micros / 1e6;
    final pose = Float32List(72), input = Float32List(120);
    pose[1] = yaw;
    if (state == BodyPosture.sit) {
      pose[3] = pose[6] = -math.pi / 2;
      pose[12] = pose[15] = math.pi / 2;
    } else if (state == BodyPosture.lie) {
      pose[0] = math.pi / 2;
      // Use a single root axis for the lying fixture; heading variants are tested on gait.
      pose[1] = 0;
    } else if ([
      BodyPosture.walk,
      BodyPosture.run,
      BodyPosture.slowWalk,
      BodyPosture.jog
    ].contains(state)) {
      final steps = cadence ??
          (state == BodyPosture.walk
              ? 2.0
              : state == BodyPosture.run
                  ? 3.0
                  : state == BodyPosture.jog
                      ? 2.4
                      : 1.2);
      final phase = math.pi * steps * t;
      pose[3] = (state == BodyPosture.slowWalk ? .08 : .35) * math.sin(phase);
      pose[6] = -pose[3];
      input[28] = ((state == BodyPosture.run
                  ? 4.8
                  : state == BodyPosture.jog
                      ? 2.6
                      : state == BodyPosture.slowWalk
                          ? .5
                          : 1.4) *
              math.sin(phase * 2)) /
          30;
    } else if (state == BodyPosture.unknown) {
      // Deep unsupported bend, not default standing or lying.
      pose[9] = 1.05;
    }
    result.add(classifier.add(
        pose,
        input,
        (start ?? DateTime.utc(2020, 1, 2, 2))
            .add(Duration(microseconds: micros))));
    micros += jitter ? [27000, 40000, 33000][i % 3] : 33333;
  }
  return result;
}
