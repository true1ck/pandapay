import 'dart:convert';
import 'dart:io';
import 'package:pandapay_domain/sms_v2.dart' as v2;
import 'package:pandapay_domain/src/sms_v2/evaluation/adapters.dart' as shared;
import 'models.dart';
export 'package:pandapay_domain/src/sms_v2/evaluation/adapters.dart'
    show
        InterpretedMessage,
        InterpreterStage,
        InstrumentResolution,
        InstrumentStage,
        LinkerStage,
        LedgerTotals,
        ProjectorStage,
        CategoryStage,
        GoldenAdapters;

shared.GoldenAdapters loadDefaultAdapters({String? bundlePath}) {
  if (bundlePath == null)
    return const shared.GoldenAdapters(label: 'unwired (no --bundle given)');
  final bundle = v2.RuleBundle.fromJson(
    (jsonDecode(File(bundlePath).readAsStringSync()) as Map)
        .cast<String, Object?>(),
  );
  return shared.adaptersForBundle(
    bundle,
    label: 'rule engine ${v2.smsEngineVersion} + $bundlePath',
  );
}

class PrecomputedInterpreter extends shared.PrecomputedInterpreter {
  PrecomputedInterpreter(super.label, super.results, super.keyOf);
  factory PrecomputedInterpreter.fromFile(String path, GoldenBundle bundle) {
    final j = jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
    final results = (j['results'] as Map).cast<String, dynamic>();
    final keys = <GoldenMessage, String>{};
    for (final c in bundle.cases) {
      for (var i = 0; i < c.messages.length; i++) {
        keys[c.messages[i]] = '${c.id}#$i';
      }
    }
    return PrecomputedInterpreter(
      j['engine'] as String? ?? path,
      results,
      keys,
    );
  }
}
