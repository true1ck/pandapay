// Prints, as JSON, what Dart's RegExp makes of every rule pattern and example.
// `regex_parity.mjs` runs the same checks in Node and compares the named groups.
//
//   dart run test/regex_parity_dump.dart <rules folder>
import 'dart:convert';
import 'dart:io';

import 'package:sms_rules_cli/rules_source.dart';

Map<String, Object?> _run(String kind, String id, String pattern, String flags, String input) {
  final re = RegExp(
    pattern,
    caseSensitive: !flags.contains('i'),
    multiLine: flags.contains('m'),
    dotAll: flags.contains('s'),
  );
  final m = re.firstMatch(input);
  Map<String, String?>? groups;
  if (m != null) {
    groups = {
      for (final g in m.groupNames) g: m.namedGroup(g),
    };
  }
  return {
    'kind': kind,
    'id': id,
    'pattern': pattern,
    'flags': flags,
    'input': input,
    'matched': m != null,
    'index': m?.start,
    'match': m?.group(0),
    'groups': groups,
  };
}

void main(List<String> args) {
  final dir = args.isNotEmpty ? args.first : 'rules/sms/v2';
  final src = readRulesFolder(dir);
  final bundle = parseUnsignedBundle(src.bundle);
  final allBodies = <String>[
    for (final r in bundle.rules)
      for (final e in r.examples) e.body,
  ];
  final out = <Map<String, Object?>>[];
  for (final r in bundle.rules) {
    for (final e in r.examples) {
      out.add(_run('rule', r.id, r.match.pattern, r.match.flags, e.body));
    }
  }
  for (final r in bundle.ignoreRules) {
    for (final b in allBodies) {
      out.add(_run('ignore', r.id, r.pattern, r.flags, b));
    }
  }
  stdout.writeln(jsonEncode(out));
}
