import 'dart:convert';
import 'dart:io';

import 'package:pandapay_domain/sms_v2.dart';

import 'adapters.dart';
import 'models.dart';

/// Stage 1 backed by the real [RuleEngine] and a bundle file.
class EngineInterpreterStage implements InterpreterStage {
  EngineInterpreterStage(this.bundle, {this.appVersion = 'golden'});

  factory EngineInterpreterStage.fromFile(String path) {
    final json = jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
    return EngineInterpreterStage(RuleBundle.fromJson(json));
  }

  final RuleBundle bundle;
  final String appVersion;
  final RuleEngine engine = RuleEngine();

  @override
  Future<InterpretedMessage> interpret(GoldenMessage message) async {
    final r = engine.interpret(
      SmsMessage(
        sender: message.sender,
        body: message.body,
        observedAt: message.observedAt,
        sourceKey: 'golden:${message.observedAt.millisecondsSinceEpoch}:${message.body.hashCode}',
      ),
      bundle,
      appVersion: appVersion,
    );
    return InterpretedMessage(
      facts: [for (final f in r.facts) f.toJson()],
      unknown: r.outcome == InterpretOutcome.unknown,
    );
  }
}
