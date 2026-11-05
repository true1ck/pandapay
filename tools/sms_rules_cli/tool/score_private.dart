// Local draft-label comparison. Pass private inputs and output under /tmp.
// The scoring rules live in lib/scoring.dart.
import 'dart:convert';
import 'dart:io';

import 'package:pandapay_domain/sms_v2.dart';
import 'package:sms_rules_cli/scoring.dart';

export 'package:sms_rules_cli/scoring.dart';

bool isTemporaryPath(String path) {
  final file = File(path);
  final parent = file.parent.resolveSymbolicLinksSync();
  final tmp = Directory('/tmp').resolveSymbolicLinksSync();
  if (parent != tmp && !parent.startsWith('$tmp/')) return false;
  return FileSystemEntity.typeSync(path, followLinks: false) !=
      FileSystemEntityType.link;
}

/// Writes a private file readable only by its owner.
void writePrivate(String path, String contents) {
  final file = File(path);
  if (!file.existsSync()) file.createSync(exclusive: true);
  if (Process.runSync('chmod', ['600', file.path]).exitCode != 0) {
    throw StateError('Could not restrict the private report permissions');
  }
  file.writeAsStringSync(contents);
}

void main(List<String> args) {
  if ((args.length != 3 && args.length != 4) ||
      args.skip(1).any((path) => !isTemporaryPath(path))) {
    stderr.writeln(
      'Usage: score_private.dart BUNDLE /tmp/LABELS /tmp/REPORT [/tmp/PHONE_OUTCOMES]',
    );
    exitCode = 64;
    return;
  }
  final bundle = RuleBundle.fromJson(
    (jsonDecode(File(args[0]).readAsStringSync()) as Map)
        .cast<String, Object?>(),
  );
  final families = {for (final rule in bundle.rules) rule.id: rule.family};
  final rows = [
    for (final line in File(args[1]).readAsLinesSync()) jsonDecode(line) as Map,
  ];
  final phone = args.length == 4
      ? (jsonDecode(File(args[3]).readAsStringSync()) as Map)['outcomes']
            as List
      : null;
  if (phone != null && phone.length != rows.length) {
    throw FormatException('Phone outcome count must equal the label count');
  }
  final engine = RuleEngine();
  final scored = <Map<String, Object?>>[];
  for (var index = 0; index < rows.length; index++) {
    final row = rows[index];
    final raw = row['message'] as Map;
    final expected = row['expected'] as Map;
    if (!const {'sure', 'unsure'}.contains(expected['confidence'])) {
      throw FormatException('Invalid label confidence at index $index');
    }
    final outcome = engine.interpretDetailed(
      SmsMessage(
        sender: raw['sender'] as String,
        body: raw['body'] as String,
        sourceKey: 'private-sample:$index',
        observedAt: DateTime.parse(raw['observedAt'] as String).toUtc(),
        iosFilter: raw['iosFilter'] as String?,
      ),
      bundle,
      appVersion: '2.0.0',
    );
    final phoneRow = phone?[index] as Map?;
    if (phoneRow != null && phoneRow['index'] != index) {
      throw FormatException(
        'Phone outcomes must follow zero-based sample order',
      );
    }
    scored.add(
      scoreRow(
        index: index,
        row: row,
        result: outcome.result,
        phoneRow: phoneRow,
        ruleFamilies: families,
      ),
    );
  }
  final summary = buildSummary(scored, phone: phone != null);
  final disagreements = disagreementExport(scored, [
    for (final row in rows) (row['message'] as Map),
  ]);
  writePrivate(
    args[2],
    jsonEncode({
      ...summary,
      'disagreements': scored.where((r) => r['ok'] != true).toList(),
    }),
  );
  // The review export carries message bodies: it stays beside the report.
  final base = args[2].endsWith('.json')
      ? args[2].substring(0, args[2].length - 5)
      : args[2];
  writePrivate(
    '$base.disagreements.jsonl',
    disagreements.map(jsonEncode).join('\n'),
  );
  writePrivate('$base.disagreements.txt', reviewSheet(disagreements));
  stdout.writeln(jsonEncode(summary));
}
