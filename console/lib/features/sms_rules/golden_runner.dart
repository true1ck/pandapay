import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_evaluation.dart';

class BrowserGoldenResult {
  const BrowserGoldenResult(this.report, this.passed);
  final Map<String, dynamic> report;
  final bool passed;
}

class BrowserGoldenRunner {
  BrowserGoldenRunner({
    required this.cases,
    required this.gates,
    this.baseline = const {},
    this.contextBundle = const {},
  });
  final GoldenBundle cases;
  final Map<String, Gate> gates;
  final Map<String, dynamic> baseline;
  final Map<String, dynamic> contextBundle;

  static Future<BrowserGoldenRunner> load() async {
    final json =
        (jsonDecode(
                  await rootBundle.loadString('assets/sms_golden/bundle.json'),
                )
                as Map)
            .cast<String, dynamic>();
    final items = (json['items'] as List).cast<Map>();
    return BrowserGoldenRunner(
      cases: GoldenBundle(
        [
          for (final item in items.where((item) => item['kind'] == 'cases'))
            GoldenCase.fromJson((item['body'] as Map).cast<String, dynamic>()),
        ],
        [
          for (final item in items.where((item) => item['kind'] == 'scenarios'))
            GoldenScenario.fromJson(
              (item['body'] as Map).cast<String, dynamic>(),
            ),
        ],
      ),
      gates: parseGates((json['gates'] as Map).cast<String, dynamic>(), 'm1'),
      baseline: (json['baseline'] as Map).cast<String, dynamic>(),
      contextBundle: (json['contextBundle'] as Map).cast<String, dynamic>(),
    );
  }

  Future<BrowserGoldenResult> run(Map<String, dynamic> candidate) async {
    final bundle = RuleBundle.fromJson(candidate.cast<String, Object?>());
    final run = await runGolden(cases, adaptersForBundle(bundle));
    final checks = checkGates(run.metrics, gates);
    final regressions = compareToBaseline(run.metrics, baseline);
    final passed =
        run.cases > 0 &&
        run.casesPassed == run.cases &&
        run.scenariosEvaluated &&
        run.scenariosPassed == run.scenarios &&
        !checks.any((check) => check.status == 'fail') &&
        regressions.isEmpty;
    final report = reportJson(
      run,
      profile: 'm1',
      gateResults: checks,
    ).cast<String, dynamic>();
    report['bundleSha256'] = evaluationContentHash(candidate);
    report['regressions'] = [for (final value in regressions) value.toJson()];
    return BrowserGoldenResult(report, passed);
  }
}

Map<String, dynamic> editorBundle(Map<String, dynamic> rule) => {
  'schema': 'pandapay.sms.rules/2',
  'bundleVersion': 0,
  'createdAt': '2026-11-01T00:00:00Z',
  'expiresAt': '2026-11-08T00:00:00Z',
  'minEngineVersion': '2.0.0',
  'taxonomyVersion': 1,
  'senders': <Object?>[],
  'ignoreRules': <Object?>[],
  'rules': [rule],
  'counterpartyPurposes': <Object?>[],
  'linkRules': <Object?>[],
  'categoryRules': <Object?>[],
  'merchantAliases': <Object?>[],
  'signature': null,
};

List<String> validateEditor(String source, {List<dynamic> senders = const []}) {
  try {
    final rule = (jsonDecode(source) as Map).cast<String, dynamic>();
    final validation = validateBundleJson({
      ...editorBundle(rule),
      'senders': senders,
    });
    if (!validation.ok) {
      return validation.errors.map((error) => error.toString()).toList();
    }
    final bundle = RuleBundle.fromJson({
      ...editorBundle(rule),
      'senders': senders,
    });
    return lintBundle(bundle).map((issue) => issue.toString()).toList();
  } catch (_) {
    return ['Enter a valid JSON Rule object.'];
  }
}
