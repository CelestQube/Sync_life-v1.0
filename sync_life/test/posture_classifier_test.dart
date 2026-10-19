import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_life/mocap/posture_classifier.dart';
import 'support/posture_samples.dart';

void main() {
  test('light nonperiodic body sway can remain standing without inventing gait',
      () {
    final classifier = PostureClassifier();
    PostureEstimate? result;
    for (var i = 0; i < 180; i++) {
      final input = Float32List(120)..[28] = .64 / 30;
      result = classifier.add(Float32List(72), input,
          DateTime.utc(2026).add(Duration(milliseconds: i * 33)));
    }
    expect(result!.state, BodyPosture.stand);
    expect(BodyPosture.slowWalk.summaryState, BodyPosture.walk);
    expect(BodyPosture.jog.summaryState, BodyPosture.run);
  });
  test(
      'deep squat and forward leaning while seated are unknown; side lying is supported',
      () {
    for (var scenario = 0; scenario < 3; scenario++) {
      final classifier = PostureClassifier();
      PostureEstimate? result;
      for (var i = 0; i < 180; i++) {
        final pose = Float32List(72);
        if (scenario == 2) {
          pose[2] = math.pi / 2;
        } else {
          pose[3] = pose[6] = -math.pi / 2;
          pose[12] = pose[15] = scenario == 0 ? 2.6 : math.pi / 2;
          if (scenario == 1) pose[9] = 1.3;
        }
        result = classifier.add(pose, Float32List(120),
            DateTime.utc(2020).add(Duration(milliseconds: i * 33)));
      }
      expect(
          result!.state, scenario == 2 ? BodyPosture.lie : BodyPosture.unknown);
    }
  });
  test('slow walking is detected after enough complete stride cycles', () {
    for (final cadence in [1.0, 1.2, 1.5]) {
      final result =
          syntheticPosture(BodyPosture.walk, cadence: cadence, frames: 240)
              .last;
      expect(result.state, BodyPosture.walk);
      expect(result.features['cadence_hz'], closeTo(cadence, .1));
    }
  });
  for (final state in BodyPosture.values) {
    test('synthetic ${state.name}: warm-up is unknown, stable output matches',
        () {
      final results = syntheticPosture(state);
      expect(results.first.state, BodyPosture.unknown);
      expect(
          results.skip(130).map((value) => value.state), everyElement(state));
      expect(results.last.features.values.every((value) => value.isFinite),
          isTrue);
    });
  }
  test('walking/running tolerate BLE timing jitter and different body headings',
      () {
    for (final state in [BodyPosture.walk, BodyPosture.run]) {
      for (final heading in [0.0, math.pi / 2, math.pi]) {
        final result = syntheticPosture(state, yaw: heading, jitter: true).last;
        expect(result.state, state);
        expect(result.features['cadence_hz'],
            closeTo(state == BodyPosture.walk ? 2 : 3, .15));
      }
    }
  });
  test('moving arms without gait does not create walking or running', () {
    final classifier = PostureClassifier();
    PostureEstimate? result;
    for (var i = 0; i < 150; i++) {
      final pose = Float32List(72)..[48] = math.sin(i / 5) * 1.2;
      final input = Float32List(120)..[0] = 1.0;
      result = classifier.add(
          pose, input, DateTime.utc(2020).add(Duration(milliseconds: i * 33)));
    }
    expect(result!.state, BodyPosture.stand);
  });
  test('deep squat and movement without a periodic leg signal remain unknown',
      () {
    for (final squat in [true, false]) {
      final classifier = PostureClassifier();
      PostureEstimate? result;
      for (var i = 0; i < 150; i++) {
        final pose = Float32List(72);
        if (squat) {
          pose[3] = pose[6] = -.9;
          pose[12] = pose[15] = 1.8;
        }
        final input = Float32List(120)..[28] = squat ? 0 : .2;
        result = classifier.add(pose, input,
            DateTime.utc(2020).add(Duration(milliseconds: i * 33)));
      }
      expect(result!.state, BodyPosture.unknown);
    }
  });
  test('disconnect or reversed timestamp restarts recognition warm-up', () {
    final classifier = PostureClassifier();
    final pose = Float32List(72), input = Float32List(120);
    final start = DateTime.utc(2020);
    for (var i = 0; i < 100; i++) {
      classifier.add(pose, input, start.add(Duration(milliseconds: i * 33)));
    }
    expect(
        classifier
            .add(pose, input, start.add(const Duration(seconds: 7)))
            .state,
        BodyPosture.unknown);
    expect(classifier.add(pose, input, start).state, BodyPosture.unknown);
  });
  test('invalid input is rejected instead of inventing a posture', () {
    final classifier = PostureClassifier();
    expect(
        () => classifier.add(Float32List(71), Float32List(120), DateTime.now()),
        throwsArgumentError);
    expect(
        () => classifier.add(Float32List(72)..[0] = double.nan,
            Float32List(120), DateTime.now()),
        throwsArgumentError);
  });
}
