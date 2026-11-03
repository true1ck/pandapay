import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:pandapay_domain/sms_v2.dart';

import '../rules_source.dart';

/// Adds the folder/meta options shared by `build` and `lint`.
void addRulesFolderOptions(ArgParser p) {
  p
    ..addOption('rules', abbr: 'r', defaultsTo: 'rules/sms/v2', help: 'Rules folder.')
    ..addOption('bundle-version', help: 'Overrides meta.json bundleVersion.')
    ..addOption('created-at', help: 'Overrides meta.json createdAt (ISO-8601 UTC).');
}

RulesSource loadRules(ArgResults r) => readRulesFolder(
      r['rules'] as String,
      bundleVersion: int.tryParse(r['bundle-version'] as String? ?? '') ?? 1,
      createdAt: (r['created-at'] as String?) ?? '2026-01-01T00:00:00Z',
    );

/// `build`: merge `rules/sms/v2/**` into one canonical bundle, validate it and
/// run every rule's examples. Any mismatch fails the build.
class BuildCommand extends Command<int> {
  BuildCommand() {
    addRulesFolderOptions(argParser);
    argParser.addOption('out', abbr: 'o', defaultsTo: 'build/sms_rules_bundle.json', help: 'Bundle path.');
  }

  @override
  String get name => 'build';

  @override
  String get description =>
      'Merge the rules folder into one canonical bundle JSON, validate it and run every rule example.';

  @override
  Future<int> run() async {
    final r = argResults!;
    final src = loadRules(r);
    var failed = false;
    for (final p in src.problems) {
      stderr.writeln('error: $p');
      failed = true;
    }
    if (failed) return 1;

    final RuleBundle bundle;
    try {
      bundle = parseUnsignedBundle(src.bundle);
    } on ContractException catch (e) {
      stderr.writeln('error: the merged bundle breaks the contract:');
      for (final err in e.errors.take(50)) {
        stderr.writeln('  $err');
      }
      return 1;
    }

    final failures = runRuleExamples(bundle);
    for (final f in failures) {
      stderr.writeln('example failed: $f');
    }
    if (failures.isNotEmpty) {
      stderr.writeln('build failed: ${failures.length} example(s) disagree with the engine.');
      return 1;
    }

    final out = File(r['out'] as String);
    out.parent.createSync(recursive: true);
    out.writeAsStringSync('${canonicalJson(unsignedJson(bundle))}\n');
    final examples = bundle.rules.fold<int>(0, (n, x) => n + x.examples.length);
    stdout.writeln(
      'built ${out.path}: ${bundle.rules.length} rules, ${bundle.ignoreRules.length} ignore rules, '
      '${bundle.senders.length} senders, $examples examples OK.',
    );
    return 0;
  }
}
