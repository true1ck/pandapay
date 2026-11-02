import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:args/command_runner.dart';
import 'package:pandapay_domain/sms_v2_template.dart';

import '../messages_io.dart';

/// `redact`: CSV or JSONL of `{sender, body, observedAt}` in, JSONL out with no
/// original name, number or amount left.
class RedactCommand extends Command<int> {
  RedactCommand() {
    argParser
      ..addOption('in', abbr: 'i', help: 'Input .csv or .jsonl (sender, body, observedAt).')
      ..addOption('out', abbr: 'o', help: 'Output JSONL path.')
      ..addOption('salt', help: 'Mixed into every synthetic value. Default: random per run (output cannot be mapped back).')
      ..addOption('shift-days', help: 'Days added to every date. Default: derived from the salt (7 to 89).')
      ..addOption('catalogue', help: 'Extra merchant names that may survive, one per line.');
  }

  @override
  String get name => 'redact';

  @override
  String get description =>
      'Redact SMS: names to <PARTY>, phones/URLs/emails to placeholders, '
      'digit runs and amounts to synthetic values (same format), dates shifted.';

  @override
  Future<int> run() async {
    final input = argResults!['in'] as String? ?? (argResults!.rest.isNotEmpty ? argResults!.rest.first : null);
    final output = argResults!['out'] as String?;
    if (input == null || output == null) {
      usageException('--in and --out are required.');
    }
    final salt = argResults!['salt'] as String? ?? _randomSalt();
    final shift = int.tryParse(argResults!['shift-days'] as String? ?? '');
    final catalogue = {...smsMerchantCatalogue};
    final extra = argResults!['catalogue'] as String?;
    if (extra != null) {
      for (final l in File(extra).readAsLinesSync()) {
        if (l.trim().isNotEmpty) catalogue.add(l.trim().toLowerCase());
      }
    }
    final options = SmsRedactionOptions(
      salt: salt,
      merchantCatalogue: catalogue,
      dateShiftDays: shift,
    );
    final messages = readMessages(input);
    final sink = File(output).openWrite();
    for (final m in messages) {
      final r = redactSms(
        sender: m.sender,
        body: m.body,
        observedAt: m.observedAt,
        options: options,
      );
      sink.writeln(jsonEncode({
        'sender': r.sender,
        'body': r.body,
        'observedAt': r.observedAt.toUtc().toIso8601String(),
      }));
    }
    await sink.close();
    stdout.writeln('redacted ${messages.length} messages -> $output');
    return 0;
  }

  String _randomSalt() {
    final r = Random.secure();
    return List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }
}
