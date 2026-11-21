import 'dart:convert';
import 'dart:io';

import 'package:pandapay_domain/sms_v2.dart';
import 'package:test/test.dart';

Directory _contracts() {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    final c = Directory('${dir.path}/contracts/sms/v2');
    if (c.existsSync()) return c;
    dir = dir.parent;
  }
  throw StateError('contracts/sms/v2 not found above ${Directory.current.path}');
}

/// The server builds the pattern of every drafted layout (api/src/sms_v2/layout_matcher.js) and the phone refuses a rule
/// whose pattern fails ITS regex lint (engine/lint.dart: the draft check and the provisional store drop it, and the phone
/// reports `unsafe_rule`). 22 Nov 2026: a layout over the old name-slot limit got a pattern the server accepted and this
/// lint refused, and nothing tested it. `layout_patterns.json` is written by the server's test from the real matcher.
void main() {
  final patterns = (jsonDecode(File('${_contracts().path}/fixtures/layout_patterns.json').readAsStringSync()) as List).cast<Map>();

  test('the fixture holds the layouts of the corpus and of the name-slot cases', () {
    expect(patterns.length, greaterThan(10));
  });

  for (final p in patterns) {
    final layout = p['layout'] as String;
    test('the phone lint accepts the server-built pattern of: $layout', () {
      final issues = lintRegexDialect(p['pattern'] as String, p['flags'] as String);
      expect(issues, isEmpty, reason: '${issues.join('; ')}\n${p['pattern']}');
    });

    test('and a hostile near-miss text is turned away fast: $layout', () {
      final regex = RegExp(p['pattern'] as String, caseSensitive: !(p['flags'] as String).contains('i'));
      for (final unit in const ['a ', 'x and ', ', ', 'note: note: ', 'on ', 'for ', 'to     ', 'to                    ', ',      ']) {
        final text = '${unit * 200} nope';
        final watch = Stopwatch()..start();
        regex.hasMatch(text);
        expect(watch.elapsedMilliseconds, lessThan(250), reason: 'unit "$unit"');
      }
    });
  }
}
