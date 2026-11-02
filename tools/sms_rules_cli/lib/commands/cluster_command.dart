import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';

import '../cluster.dart';
import '../messages_io.dart';

/// `cluster`: redacted JSONL in, `templates.json` out.
class ClusterCommand extends Command<int> {
  ClusterCommand() {
    argParser
      ..addOption('in', abbr: 'i', help: 'Redacted .jsonl (output of `redact`).')
      ..addOption('out', abbr: 'o', help: 'templates.json path.')
      ..addOption('min-messages', defaultsTo: '5', help: 'A word seen in fewer messages becomes <W>.')
      ..addOption('samples', defaultsTo: '3', help: 'Sample bodies kept per template.');
  }

  @override
  String get name => 'cluster';

  @override
  String get description =>
      'Group redacted SMS into templates (brand + skeleton -> templateHash); '
      'writes templates.json sorted by count.';

  @override
  Future<int> run() async {
    final input = argResults!['in'] as String? ?? (argResults!.rest.isNotEmpty ? argResults!.rest.first : null);
    final output = argResults!['out'] as String?;
    if (input == null || output == null) {
      usageException('--in and --out are required.');
    }
    final messages = readMessages(input);
    final templates = clusterMessages(
      messages,
      minMessages: int.parse(argResults!['min-messages'] as String),
      sampleCount: int.parse(argResults!['samples'] as String),
    );
    File(output).writeAsStringSync(
      '${const JsonEncoder.withIndent(' ').convert([for (final t in templates) t.toJson()])}\n',
    );
    var covered = 0;
    var top90 = templates.length;
    for (var i = 0; i < templates.length; i++) {
      covered += templates[i].count;
      if (covered >= 0.9 * messages.length) {
        top90 = i + 1;
        break;
      }
    }
    final brands = templates.map((t) => t.brand).toSet().length;
    stdout.writeln(
      '${messages.length} messages -> ${templates.length} templates '
      '($brands brands); top $top90 cover 90% -> $output',
    );
    return 0;
  }
}
