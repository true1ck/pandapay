import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/sms_import/ios_sms_intake_controller.dart';

Map<String, Object?> window(int ordinal, String start, String end, String state,
        {int? found, int? limitOff, int enumerated = 0}) =>
    {'id': 'w$ordinal', 'job_id': 'job', 'ordinal': ordinal, 'start': start,
     'end': end, 'state': state, 'found': found, 'limit_off': limitOff,
     'enumerated': enumerated, 'logical_id': start.substring(0, 7)};

IosSmsIntakeState stateWith(List<Map<String, Object?>> windows) =>
    IosSmsIntakeState(snapshot: {
      'jobs': [
        {'id': 'job', 'kind': 'history', 'state': 'active',
         'start': '2026-08-01T00:00:00Z', 'end': '2026-10-01T00:00:00Z'},
      ],
      'windows': windows,
    });

void main() {
  test('progress follows dates, including a continued 500-message range', () {
    final state = stateWith([
      // Listed out of order on purpose: progress uses date order.
      window(2, '2026-09-01T00:00:00Z', '2026-10-01T00:00:00Z', 'queued'),
      window(0, '2026-08-01T00:00:00Z', '2026-08-18T00:00:00Z', 'complete',
          found: 500, limitOff: 1, enumerated: 500),
      window(1, '2026-08-18T00:00:00Z', '2026-09-01T00:00:00Z', 'running'),
    ]);
    expect(state.importedThrough, DateTime.utc(2026, 8, 18));
    expect(state.currentWindow?['id'], 'w1');
    expect(state.coverage, closeTo(17 / 61, 0.001));
    expect(state.stopReason, isNull);
  });

  test('a field-mapping problem is explained', () {
    final state = stateWith([
      {
        ...window(0, '2026-08-01T00:00:00Z', '2026-09-01T00:00:00Z', 'partial',
            found: 40, limitOff: 0, enumerated: 40),
        'incomplete': 30,
      },
    ]);
    expect(state.importedThrough, isNull);
    expect(state.stopReason, contains('Body and Date fields'));
    expect(state.currentStopIsRetryable, isFalse);
  });
}
