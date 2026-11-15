// Before changing rules: run every message we hold through the OLD and the NEW
// rule folder and print each message whose reading changed. A rule change is
// safe when the only differences are the ones you meant.
//
//   git archive <base> rules/sms/v2 | tar -x -C /some/dir      # the old folder
//   dart run tool/rules_diff.dart /some/dir/rules/sms/v2 ../../rules/sms/v2
//   dart run tool/rules_diff.dart <old> <new> extra.json        # only the messages in extra.json
//
// The corpus is every golden case, scenario, heldout variant, lookalike and
// negative under tools/sms_golden, plus every rule example of both folders.
// Compare committed rules to committed rules: an untracked rule file in the
// working tree changes the reading of hundreds of messages.
import 'dart:convert';
import 'dart:io';

import 'package:pandapay_domain/sms_v2.dart';
import 'package:sms_rules_cli/rules_source.dart';

class Msg {
  Msg(this.origin, this.sender, this.body);
  final String origin, sender, body;
}

void collect(Object? o, String origin, List<Msg> out) {
  if (o is Map) {
    final s = o['sender'];
    final b = o['body'];
    if (s is String && b is String) out.add(Msg(origin, s, b));
    for (final v in o.values) {
      collect(v, origin, out);
    }
  } else if (o is List) {
    for (final v in o) {
      collect(v, origin, out);
    }
  }
}

Object? norm(Object? v) {
  if (v is Map) {
    return {
      for (final e in v.entries)
        if (!{'factId', 'provenance', 'evidence', 'sourceKey', 'observedAt'}
            .contains(e.key))
          e.key: norm(e.value),
    };
  }
  if (v is List) return [for (final x in v) norm(x)];
  return v;
}

String read(RuleEngine e, RuleBundle b, Msg m) {
  try {
    final o = e.interpretDetailed(
      SmsMessage(
        sender: m.sender,
        body: m.body,
        observedAt: DateTime.utc(2026, 11, 3, 6),
        sourceKey: 'k',
      ),
      b,
      appVersion: 'test',
    );
    final facts = [for (final f in o.result.facts) norm(f.toJson())];
    return jsonEncode({
      'outcome': o.result.outcome.name,
      'winner': o.winnerId,
      'facts': facts,
    });
  } on Object catch (e) {
    return 'ERROR $e';
  }
}

Future<void> main(List<String> args) async {
  final oldSrc = readRulesFolder(args[0]);
  final newSrc = readRulesFolder(args[1]);
  final oldB = parseUnsignedBundle(oldSrc.bundle);
  final newB = parseUnsignedBundle(newSrc.bundle);

  final msgs = <Msg>[];
  // golden cases, scenarios
  for (final f in Directory('../sms_golden')
      .listSync(recursive: true)
      .whereType<File>()) {
    if (args.length > 2) continue; // extra file only
    if (f.path.contains('reports')) continue;
    if (f.path.endsWith('.json')) {
      try {
        collect(jsonDecode(f.readAsStringSync()), f.path.split('sms_golden').last, msgs);
      } on Object {
        continue;
      }
    } else if (f.path.endsWith('.jsonl')) {
      for (final line in f.readAsLinesSync()) {
        if (line.trim().isEmpty) continue;
        try {
          collect(jsonDecode(line), f.path.split('sms_golden').last, msgs);
        } on Object {
          continue;
        }
      }
    }
  }
  if (args.length > 2) {
    collect(jsonDecode(File(args[2]).readAsStringSync()), 'extra', msgs);
  }
  // every rule example of both folders
  for (final b in args.length > 2 ? <Map<String, Object?>>[] : [oldSrc.bundle, newSrc.bundle]) {
    for (final r in b['rules'] as List) {
      collect((r as Map)['examples'], 'rule-example:${r['id']}', msgs);
    }
  }
  final seen = <String>{};
  final unique = [
    for (final m in msgs)
      if (seen.add('${m.sender}|${m.body}')) m,
  ];

  final engine = RuleEngine();
  var changed = 0;
  final byKind = <String, int>{};
  for (final m in unique) {
    final a = read(engine, oldB, m);
    final b = read(engine, newB, m);
    if (a == b) continue;
    changed++;
    final ja = a.startsWith('ERROR') ? null : jsonDecode(a) as Map;
    final jb = b.startsWith('ERROR') ? null : jsonDecode(b) as Map;
    final kind = '${ja?['winner']} -> ${jb?['winner']}';
    byKind[kind] = (byKind[kind] ?? 0) + 1;
    stdout.writeln('--- ${m.origin}');
    stdout.writeln('  ${m.sender}: ${m.body}');
    stdout.writeln('  old: ${a.length > 360 ? a.substring(0, 360) : a}');
    stdout.writeln('  new: ${b.length > 360 ? b.substring(0, 360) : b}');
  }
  stdout.writeln('\nmessages: ${unique.length}, changed: $changed');
  byKind.forEach((k, v) => stdout.writeln('  $v x $k'));
}
