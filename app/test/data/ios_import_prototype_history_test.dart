import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/ios_import_prototype.dart';
import 'package:pandapay/data/ios_import_prototype_fixtures.dart';
import 'package:pandapay/data/local_sms_parser.dart';
import 'package:pandapay/features/sms_import/sms_text_hint.dart';

void main() {
  final fixtures = iosPrototypeHistoryFixtures();

  test('100 historical fixtures use original dates before the test day', () {
    expect(fixtures, hasLength(100));
    expect(fixtures.map((m) => m['id']).toSet(), hasLength(100));
    for (final row in fixtures) {
      final capture = IosPrototypeCapture.fromMap(row);
      expect(capture.receivedAt!.isBefore(DateTime.utc(2026, 10, 26)), isTrue);
      expect(capture.receivedAt!.isBefore(capture.capturedAt), isTrue);
    }
  });

  test('canonical Android triage and parser classify the mixed corpus', () {
    final observations = <String, int>{};
    var sensitive = 0;
    var ignored = 0;
    for (final row in fixtures) {
      final capture = IosPrototypeCapture.fromMap(row);
      final triage = classifySmsTriage(capture.sender, capture.body);
      final parsed = capture.parse();
      switch (row['expected']) {
        case 'sensitive':
          expect(triage.kind, SmsTriageKind.sensitive, reason: '${row['id']}');
          expect(parsed, isNull);
          sensitive++;
        case 'ignored':
          expect(triage.kind, isNot(SmsTriageKind.financialCandidate));
          expect(parsed, isNull, reason: '${row['id']}');
          ignored++;
        default:
          expect(triage.kind, SmsTriageKind.financialCandidate);
          expect(parsed, isNotNull, reason: '${row['id']}');
          final kind = parsed!.eventType.wireValue;
          expect(kind, row['expected'], reason: '${row['id']}');
          observations.update(kind, (n) => n + 1, ifAbsent: () => 1);
      }
    }
    expect(observations, {'transaction': 60, 'bill': 15});
    expect(sensitive, 10);
    expect(ignored, 15);
  });

  test('identical payment text on different dates remains two events', () {
    final first = IosPrototypeCapture.fromMap(fixtures[0]);
    final second = IosPrototypeCapture.fromMap(fixtures[20]);
    expect(first.body, second.body);
    expect(first.receivedAt, isNot(second.receivedAt));
    expect(first.parse(), isNotNull);
    expect(second.parse(), isNotNull);
  });
}
