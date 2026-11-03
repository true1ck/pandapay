/// Reproducible CI gate over rule sources and every implemented pipeline stage.
/// The signing key is ephemeral and never written or printed.
import 'dart:convert';
import 'dart:io';
import 'package:args/command_runner.dart';
import 'package:cryptography/cryptography.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sms_rules_cli/commands/golden_command.dart';
import 'package:sms_rules_cli/rules_source.dart';

Future<void> main(List<String> args) async {
  final source = readRulesFolder('../../rules/sms/v2');
  if (source.problems.isNotEmpty) throw StateError(source.problems.join('\n'));
  final bundle = parseUnsignedBundle(source.bundle);
  final lint = lintBundle(bundle);
  if (lint.isNotEmpty) throw StateError(lint.join('\n'));
  final examples = runRuleExamples(bundle);
  if (examples.isNotEmpty) throw StateError(examples.join('\n'));
  final key = await Ed25519().newKeyPair();
  final signature = await Ed25519().sign(
    utf8.encode(bundle.signedPayload),
    keyPair: key,
  );
  final scratch = Directory.systemTemp.createTempSync('pandapay-sms-v2-gate-');
  try {
    final file = File('${scratch.path}/bundle.json');
    file.writeAsStringSync(
      jsonEncode({
        ...bundle.toJson(),
        'signature': {
          'alg': 'Ed25519',
          'keyId': 'ephemeral-ci',
          'value': base64Encode(signature.bytes),
        },
      }),
    );
    final runner = CommandRunner<int>(
      'check_pipeline',
      'Validate the complete SMS v2 pipeline.',
    )..addCommand(GoldenCommand());
    exitCode =
        await runner.run([
          'golden',
          '--bundle',
          file.path,
          '--require-stages',
          ...args,
        ]) ??
        0;
  } finally {
    scratch.deleteSync(recursive: true);
  }
}
