// Regenerate the backend contract fixture using the actual Dart classifier/segmenter.
import 'dart:convert';
import 'dart:io';
import 'package:sync_life/mocap/posture_classifier.dart';
import 'package:sync_life/mocap/posture_recording.dart';
import '../test/support/posture_samples.dart';

void main() {
  final events = <Map<String, dynamic>>[];
  final session = newMotionId(), device = newMotionId();
  for (final state in BodyPosture.values) {
    final recorder = PostureSegmenter(
        userId: 1,
        deviceId: device,
        sessionId: session,
        onSegment: (entry) =>
            events.add(entry['event'] as Map<String, dynamic>));
    for (final estimate in syntheticPosture(state,
        start: DateTime.utc(2020, 1, 2, 2, state.index))) {
      recorder.add(estimate);
    }
    recorder.interrupt();
  }
  final file =
      File('../server/Sync/posture/fixtures/phone_motion_synthetic.json');
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert({
    'fixture': 'SYNTHETIC_SOFTWARE_TEST_ONLY',
    'protocol': 1,
    'events': events,
  }));
  stdout.writeln(
      'Generated ${events.length} synthetic segments for contract tests.');
}
