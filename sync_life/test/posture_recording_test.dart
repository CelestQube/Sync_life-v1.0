import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_life/mocap/posture_classifier.dart';
import 'package:sync_life/mocap/posture_recording.dart';
import 'support/posture_samples.dart';

void main() {
  test(
      'changing the backend never uploads records solely because numeric user IDs match',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('sync-life-server-scope-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/outbox.json');
    final development =
        MotionOutbox(file, namespace: 'http://localhost:8000/api');
    await development.append({
      'user_id': 1,
      'event': {'segment_id': 'same-id'}
    });
    final production =
        MotionOutbox(file, namespace: 'https://example.test/api');
    await production.load();
    expect(production.countForUser(1), 0);
    await production.acknowledge(1, {'same-id'});
    final original = MotionOutbox(file, namespace: development.namespace);
    await original.load();
    expect(original.countForUser(1), 1);
  });
  test(
      'segmentation records observed intervals without crediting disconnect gaps',
      () {
    final entries = <Map<String, dynamic>>[];
    final segmenter = PostureSegmenter(
        userId: 7,
        deviceId: newMotionId(),
        sessionId: newMotionId(),
        onSegment: entries.add);
    final estimates = syntheticPosture(BodyPosture.stand);
    for (final estimate in estimates) {
      segmenter.add(estimate);
    }
    segmenter.interrupt();
    final last = estimates.last;
    segmenter.add(PostureEstimate(last.time.add(const Duration(seconds: 10)),
        last.state, last.confidence, last.features));
    segmenter.add(PostureEstimate(last.time.add(const Duration(seconds: 11)),
        last.state, last.confidence, last.features));
    segmenter.interrupt();
    expect(entries.every((entry) => entry['user_id'] == 7), isTrue);
    final duration = entries.fold<double>(0, (sum, entry) {
      final event = entry['event'] as Map;
      final interval = DateTime.parse(event['end_time'])
              .difference(DateTime.parse(event['start_time']))
              .inMicroseconds /
          1e6;
      expect(interval, inExclusiveRange(0, 5.05));
      return sum + interval;
    });
    expect(duration, lessThan(6));
    expect(
        entries.map((entry) => (entry['event'] as Map)['segment_id']).toSet(),
        hasLength(entries.length));
  });

  test(
      'durable outbox survives reload, concurrent append and partial receipt with user isolation',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('sync-life-outbox-test-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/outbox.json');
    final outbox = MotionOutbox(file);
    await Future.wait([
      outbox.append({
        'user_id': 1,
        'event': {'segment_id': 'a'}
      }),
      outbox.append({
        'user_id': 2,
        'event': {'segment_id': 'a'}
      }),
      outbox.append({
        'user_id': 1,
        'event': {'segment_id': 'b'}
      }),
    ]);
    final restored = MotionOutbox(file);
    await restored.load();
    expect(restored.countForUser(1), 2);
    expect(restored.countForUser(2), 1);
    await restored.acknowledge(1, {'a', 'foreign'});
    final reloaded = MotionOutbox(file);
    await reloaded.load();
    expect(reloaded.forUser(1).single['event']['segment_id'], 'b');
    expect(reloaded.countForUser(2), 1);
  });

  test(
      'incomplete rename recovers a temporary file; corrupt records are preserved',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('sync-life-outbox-recovery-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/outbox.json');
    await File('${file.path}.tmp').writeAsString('{"protocol":1,"pending":[]}');
    await MotionOutbox(file).load();
    expect(await file.exists(), isTrue);
    await file.writeAsString('broken');
    await expectLater(MotionOutbox(file).load(), throwsFormatException);
    expect(await file.readAsString(), 'broken');
  });
}
