import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/sms_v2/pipeline/trace.dart';

void main() {
  const matched = DecisionTrace(
    appVersion: '1',
    engineVersion: '2',
    bundleVersion: 1,
    outcome: 'matched',
  );
  for (final row in {
    CorrectionKind.notFinancial: 'extraction',
    CorrectionKind.wrongKind: 'extraction',
    CorrectionKind.wrongAmount: 'extraction',
    CorrectionKind.wrongDate: 'extraction',
    CorrectionKind.wrongMerchant: 'extraction',
    CorrectionKind.wrongInstrument: 'instrument',
    CorrectionKind.wrongLink: 'linking',
    CorrectionKind.duplicate: 'linking',
    CorrectionKind.wrongCategory: 'category',
    CorrectionKind.missing: 'gate',
    CorrectionKind.preferenceOnly: null,
  }.entries) {
    test(
      'attributes ${row.key.wire}',
      () => expect(matched.stage(row.key), row.value),
    );
  }
  test(
    'mask extraction and ignored outcomes attribute to their originating stages',
    () {
      expect(
        matched.stage(
          CorrectionKind.wrongInstrument,
          extractedMaskCorrect: false,
        ),
        'extraction',
      );
      const ignored = DecisionTrace(
        appVersion: '1',
        engineVersion: '2',
        bundleVersion: 0,
        outcome: 'ignored',
      );
      expect(ignored.stage(CorrectionKind.notFinancial), 'gate');
      expect(jsonEncode(matched.toJson()), isNot(contains('body')));
    },
  );
}
