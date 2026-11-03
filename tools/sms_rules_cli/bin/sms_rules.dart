import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:sms_rules_cli/commands/cluster_command.dart';
import 'package:sms_rules_cli/commands/golden_command.dart';
import 'package:sms_rules_cli/commands/redact_command.dart';

/// The command registry: `name -> Command`. Later work packages add one line
/// each (`build`, `lint`, `sign-dev`, `fetch-baseline`, ...).
final Map<String, Command<int> Function()> commandRegistry = {
  'redact': RedactCommand.new,
  'cluster': ClusterCommand.new,
  'golden': GoldenCommand.new,
};

Future<void> main(List<String> args) async {
  final runner = CommandRunner<int>(
    'sms_rules',
    'PandaPay SMS pipeline v2 rules tool.',
  );
  for (final make in commandRegistry.values) {
    runner.addCommand(make());
  }
  try {
    exitCode = await runner.run(args) ?? 0;
  } on UsageException catch (e) {
    stderr.writeln(e);
    exitCode = 64;
  }
}
