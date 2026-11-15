import 'dart:convert';
import 'dart:io';

import 'package:pandapay_domain/sms_v2_template.dart';
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

/// The server reads a layout with a pattern built from the layout
/// (api/src/sms_v2/layout_matcher.js). Both sides read the same corpus:
/// the server's matcher must read every message, and where the entry says
/// `skeleton`, the phone's own skeleton of each message must BE the layout.
/// If the two drift apart (a new amount form, a new date form), this fails.
void main() {
  final corpus = (jsonDecode(File('${_contracts().path}/fixtures/layout_corpus.json').readAsStringSync()) as Map)['entries'] as List;

  for (final entry in corpus.cast<Map>()) {
    if (entry['skeleton'] != true) continue;
    final layout = entry['layout'] as String;
    test('the skeleton of every message is the layout: $layout', () {
      for (final message in (entry['messages'] as List).cast<String>()) {
        expect(smsSkeleton(message), layout, reason: message);
      }
    });
  }
}
