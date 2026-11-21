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

/// The server cleans a layout before it drafts it (api/src/sms_v2/draft_layout.js). Both sides read the same fixture, so the
/// phone's idea of "how many blanks" and the layout it uploads agree with the server's.
void main() {
  final entries =
      (jsonDecode(File('${_contracts().path}/fixtures/draft_layout_corpus.json').readAsStringSync()) as Map)['entries']
          as List;

  for (final entry in entries.cast<Map>()) {
    test('draft layout: ${entry['name']}', () {
      expect(smsCleanLayout(entry['layout'] as String), entry['clean']);
    });
  }

  test('cleaning is idempotent', () {
    for (final entry in entries.cast<Map>()) {
      final once = smsCleanLayout(entry['layout'] as String);
      expect(smsCleanLayout(once), once, reason: entry['name'] as String);
    }
  });

  test('what goes up is cleaned of handles, odd tags and mixed IDs', () {
    expect(smsCleanLayout('Dear <PARTY> of <PARTY> shop @Flipkart txn mvtHfGfdjLvdwwKyVa#pF# <AMOUNT>'),
        'Dear <PARTY> of <PARTY> shop <W> txn <W> <AMT>');
    expect(smsCleanLayout('<AMT> paid to <PARTY>.'), '<AMT> paid to <PARTY>.');
  });

  test('a cleaned upload has no @ left, so the phone no longer drops such a format', () {
    final up = smsCleanLayout('<AMT> spent on YES BANK Card <MASK> @UPI_<PARTY> <DATE>');
    expect(smsSkeletonIsShareable(up), isTrue);
    expect(up.contains('@'), isFalse);
  });
}
