import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:pandapay_domain/sms_v2.dart';

import '../rules_source.dart';
import 'build_command.dart';

/// `lint`: regex dialect, unique ids, positive and negative examples, known
/// senders and shadowing. The lint core lives in the domain package
/// (`engine/lint.dart`, `engine/bundle_lint.dart`); this only wraps it.
class LintCommand extends Command<int> {
  LintCommand() {
    addRulesFolderOptions(argParser);
    argParser.addFlag('json', negatable: false, help: 'Print findings as JSON.');
  }

  @override
  String get name => 'lint';

  @override
  String get description =>
      'Check the rules folder: regex dialect, unique ids, examples, senders and shadowing.';

  @override
  Future<int> run() async {
    final r = argResults!;
    final src = loadRules(r);
    final issues = <LintIssue>[
      for (final p in src.problems) LintIssue('lint.file.unreadable', p),
    ];
    if (src.problems.isEmpty) {
      // Duplicate ids are caught by the contract validator on a typed bundle,
      // so report them from the raw lists first.
      for (final key in const ['rules', 'ignoreRules', 'counterpartyPurposes', 'linkRules']) {
        final seen = <String>{};
        for (final o in src.bundle[key] as List) {
          final id = o is Map ? '${o['id']}' : '';
          if (!seen.add(id)) issues.add(LintIssue('lint.id.duplicate', 'duplicate id in $key', ruleId: id));
        }
      }
      try {
        // A bundle with duplicate ids fails typed parsing; lint the rest from
        // a copy with duplicates removed.
        final copy = Map<String, Object?>.of(src.bundle);
        for (final key in const ['rules', 'ignoreRules', 'counterpartyPurposes', 'linkRules']) {
          final seen = <String>{};
          copy[key] = [
            for (final o in copy[key] as List)
              if (seen.add(o is Map ? '${o['id']}' : '')) o,
          ];
        }
        final bundle = parseUnsignedBundle(copy);
        issues.addAll(lintBundle(bundle));
      } on ContractException catch (e) {
        for (final err in e.errors.take(50)) {
          issues.add(LintIssue('lint.contract', err.toString()));
        }
      }
    }
    // Same id twice would be reported by both passes; keep one of each.
    final seenKey = <String>{};
    final unique = [
      for (final i in issues)
        if (seenKey.add('${i.code}|${i.ruleId}|${i.message}')) i,
    ];

    if (r['json'] as bool) {
      stdout.writeln(const JsonEncoder.withIndent('  ').convert([for (final i in unique) i.toJson()]));
    } else {
      for (final i in unique) {
        stdout.writeln(i);
      }
      stdout.writeln(unique.isEmpty ? 'lint: clean' : 'lint: ${unique.length} problem(s)');
    }
    return unique.isEmpty ? 0 : 1;
  }
}
