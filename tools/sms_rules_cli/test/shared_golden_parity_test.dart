import 'dart:convert';
import 'dart:io';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_evaluation.dart' as shared;
import 'package:sms_rules_cli/golden/adapters.dart';
import 'package:sms_rules_cli/golden/models.dart';
import 'package:sms_rules_cli/golden/report.dart';
import 'package:sms_rules_cli/golden/scorer.dart';
import 'package:sms_rules_cli/rules_source.dart';
import 'package:test/test.dart';

void main() {
  test(
    'shared browser evaluator preserves CLI full golden counts and metrics',
    () async {
      final source = readRulesFolder(
        '../../rules/sms/v2',
        bundleVersion: 0,
        createdAt: '2026-11-01T00:00:00Z',
      );
      final bundle = parseUnsignedBundle(source.bundle);
      final golden = loadGoldenBundle('../sms_golden');
      final directory = Directory.systemTemp.createTempSync('sms-v2-parity-');
      try {
        final path = '${directory.path}/bundle.json';
        File(path).writeAsStringSync(jsonEncode(bundle.toJson()));
        final cli = await runGolden(
          golden,
          loadDefaultAdapters(bundlePath: path),
        );
        final browser = await shared.runGolden(
          golden,
          shared.adaptersForBundle(bundle),
        );
        final cliReport = reportJson(cli),
            browserReport = shared.reportJson(browser);
        for (final field in ['stages', 'counts', 'metrics', 'failures'])
          expect(browserReport[field], cliReport[field]);
        expect(browser.casesPassed, 115);
        expect(browser.scenariosPassed, 15);
      } finally {
        directory.deleteSync(recursive: true);
      }
    },
  );
}
