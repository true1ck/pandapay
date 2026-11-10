// The intake gate runs before any rule. A message it rejects is dropped and its
// text is not kept, so nothing downstream can recover it. This reads the
// held-out alerts in `tools/sms_golden/heldout/` (layouts no rule was written
// for) and requires the gate to let every one of them through.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/sms_import/sms_text_hint.dart';
import 'package:pandapay/features/sms_v2/pipeline/intake_gate.dart';

List<Map<String, dynamic>> _rows(String name) => [
  for (final l in File('../tools/sms_golden/heldout/$name').readAsLinesSync())
    if (l.trim().isNotEmpty) jsonDecode(l) as Map<String, dynamic>,
];

void main() {
  for (final file in ['variants_a.jsonl', 'variants_b.jsonl', 'variants_c.jsonl']) {
    test('the gate passes every alert in $file', () {
      final dropped = <String>[];
      for (final m in _rows(file)) {
        final r = classifySmsV2Intake(m['sender'] as String, m['body'] as String);
        if (r.kind != SmsTriageKind.financialCandidate) {
          dropped.add('${r.kind.name}/${r.reasonCode} :: ${m['sender']} :: ${m['body']}');
        }
      }
      expect(dropped, isEmpty, reason: dropped.join('\n'));
    });
  }

  test('an OTP that quotes an amount never reaches the reader', () {
    for (final m in _rows('lookalikes.jsonl').where((m) => m['kind'] == 'otp')) {
      final r = classifySmsV2Intake(m['sender'] as String, m['body'] as String);
      expect(r.kind, isNot(SmsTriageKind.financialCandidate), reason: m['body'] as String);
    }
  });
}
