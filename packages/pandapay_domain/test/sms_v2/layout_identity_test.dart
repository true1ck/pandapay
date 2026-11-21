import 'dart:convert';
import 'dart:io';

import 'package:pandapay_domain/sms_v2.dart' show uploadSenderBrand;
import 'package:pandapay_domain/sms_v2_template.dart';
import 'package:test/test.dart';

/// Every message, name and number here is invented. These tests pin what makes two messages "the same layout":
/// how many layouts one bank template becomes, how many name slots a layout may hold, and the sender brand it is
/// filed under.
String layoutOf(String sender, String body, {String salt = 's'}) => smsSkeleton(
  redactSms(
    sender: sender,
    body: body,
    observedAt: DateTime.utc(2026, 11, 18),
    options: SmsRedactionOptions(salt: salt),
  ).body,
);

String hashOf(String sender, String body) => smsTemplateHash(smsTemplateBrand(sender), layoutOf(sender, body));

Directory _contracts() {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    final c = Directory('${dir.path}/contracts/sms/v2');
    if (c.existsSync()) return c;
    dir = dir.parent;
  }
  throw StateError('contracts/sms/v2 not found above ${Directory.current.path}');
}

void main() {
  group('S1-3: how many layouts one bank template becomes (the fan-out is KNOWN and deliberately NOT fixed here)', () {
    const merchants = [
      'AMAZON', 'ZOMATO', 'SWIGGY', 'FLIPKART', 'Joes Bakery', 'RAHUL SHARMA', 'Cafe Mocha', 'UBER', 'NETFLIX', 'Blue Tokai',
    ];

    // The catalogue merchants (AMAZON, ZOMATO, ...) stay literal in the layout on purpose (redact.dart: "a merchant
    // survives only when it is in the catalogue"; eight tests in template_test.dart and mask_test.dart pin that).
    // Turning them into <PARTY> makes ten shops one layout, but it also turns "American Express Card ending" and
    // "Paytm Wallet" into "<PARTY> Card ending" / "<PARTY> Wallet", moves the hash of every real layout that holds
    // a catalogue word and eats the 8-wildcard budget. Not shipped without the owner's sign-off: see
    // qa-bug-hunt/findings/fix-a4b.md. This test records today's numbers so a change of them is a decision.
    test('ten shops are seven layouts today: each catalogue merchant is its own layout, the rest share <PARTY>', () {
      final layouts = {
        for (final m in merchants)
          layoutOf('VM-HDFCBK-S', 'Rs.450.00 spent on card XX1234 at $m on 20-11-26. Avl limit Rs.45,000.00'),
      };
      expect(layouts, hasLength(7), reason: layouts.join('\n'));
      expect(layouts, contains('<AMT> spent on card <MASK> at <PARTY> on <DATE>. Avl limit <AMT>'));
    });

    test('layouts with no shop in them keep exactly the hashes they had', () {
      // Pinned from the build before this change: nothing may move for them (the origin links and the drafts the
      // server already holds are keyed by these).
      const pinned = {
        '925aec154c06d28ecdc0a0853ea5ba8f9ae6dadf3152d37df88a7e328b360fa0':
            ['VM-HDFCBK-S', 'Rs.450.00 debited from A/c XX1234 on 20-11-26 to RAHUL SHARMA. UPI Ref 123456789012. Avl Bal Rs.10,500.25.'],
        '08f5f7c8d0b47e1ddd1bedbf46054cdb12421eae9eb1a8e3d83b18f947b01de4':
            ['AD-ICICIB-T', 'Your account XX4321 was credited with Rs.5,000.00 on 20/11/2026. Avl Bal Rs.12,345.67.'],
        '5eeadc44d959843191dd524620ced784f36617dcbc4295875971268e8848b82a':
            ['ALPHAB', 'Rs.450 paid to Joes Bakery Pune via UPI on 20-11-26. Ref 123456789012.'],
        '83513012550928aeec1a9468d360d0c344ad2bccc03a912c201765841f3144bf':
            ['VM-HDFCBK-S', 'Rs.450.00 spent on card XX1234 at Joes Bakery on 20-11-26. Avl limit Rs.45,000.00'],
        '0c0707f084954db0c91e0e1dacc90da2392917c76578bcaae620db38dd238297':
            ['HDFCBK', 'Alert info Rs.500.00 debited from A/c XX6789'],
      };
      pinned.forEach((hash, message) {
        expect(hashOf(message[0], message[1]), hash, reason: message[1]);
      });
    });

    test('the wording sample still shows the shop (names stay in the sample; only the layout changes)', () {
      final sample = redactSms(
        sender: 'HDFCBK',
        body: 'Rs.450.00 spent on card XX1234 at AMAZON on 20-11-26.',
        observedAt: DateTime.utc(2026, 11, 18),
        options: SmsRedactionOptions(salt: 's', keepNames: true),
      ).body;
      expect(sample, contains('AMAZON'));
    });
  });

  group('S1-8: how many name slots a layout has', () {
    test('counts <PARTY>, <W> and any tag the matcher does not know, not the fixed value kinds', () {
      expect(smsLayoutWildcards('<AMT> to <PARTY> on <DATE>. Ref <REF> <MASK> <PHONE> <URL> <EMAIL> <VPA>'), 1);
      expect(smsLayoutWildcards('<W> <W> x <PARTY> <MERCHANT>'), 4);
      expect(smsLayoutWildcards('no slots at all'), 0);
    });

    test('a name slot with fixed text after it is anchored; one before a value slot, a digit mark or the end is not', () {
      expect(smsLayoutUnanchoredWildcards('Dear <PARTY>, paid <AMT> to <PARTY> on <DATE>. <PARTY> Team'), 0);
      expect(smsLayoutUnanchoredWildcards('<PARTY> <AMT> <W> #### <PARTY>'), 3);
      expect(smsLayoutUnanchoredWildcards('Paid <AMT> to <PARTY>'), 1);
      expect(smsLayoutUnanchoredWildcards('no slots at all'), 0);
    });

    test('loose slots in a row are counted as the server counts them (a literal, a digit or a fixed slot lifts the run)', () {
      expect(smsLayoutLooseRun('Call <PHONE> <PHONE> <PHONE> now'), 3);
      expect(smsLayoutLooseRun('<PARTY> <W> <PARTY> sent money'), 3);
      expect(smsLayoutLooseRun('Call <PHONE> <PHONE> now'), 2);
      expect(smsLayoutLooseRun('Call <PHONE> or <PHONE> or <PHONE> now'), 1);
      expect(smsLayoutLooseRun('<PARTY> <W> paid <AMT> to <PARTY> <W> today'), 2);
      expect(smsLayoutLooseRun('<PARTY> <AMT> <PARTY> <PARTY> x'), 2);
      expect(smsLayoutLooseRun('<PARTY> # <PARTY> <PARTY>'), 2);
      expect(smsLayoutLooseRun('no slots at all'), 0);
    });

    test('an ordinary 190-character notice can reach the server limit', () {
      final layout = layoutOf(
        'ALPHAB',
        'Dear Customer, Rs.450 debited from A/c XX1234 for Netflix Premium Subscription, Billing Cycle Monthly, Plan Ultra HD, '
        'Auto Renewal Enabled. Visit Alpha Bank Branch or Customer Care Centre for Queries Today Please.',
      );
      expect(smsLayoutWildcards(layout), greaterThan(0), reason: layout);
    });

    test('the limit is the one the server enforces (shared corpus), and every corpus layout counts as the server counts it', () {
      final corpus = jsonDecode(File('${_contracts().path}/fixtures/layout_corpus.json').readAsStringSync()) as Map;
      expect(smsMaxLayoutWildcards, corpus['wildcardLimit'], reason: 'api MAX_WILDCARDS and the phone constant must agree');
      expect(smsMaxAdjacentLooseSlots, corpus['adjacentLooseLimit'], reason: 'api MAX_ADJACENT_LOOSE and the phone constant must agree');
      expect(smsMaxAnchoredLayoutWildcards, corpus['anchoredWildcardLimit'], reason: 'api MAX_ANCHORED_WILDCARDS and the phone constant must agree');
      for (final c in (corpus['anchoredCases'] as List).cast<Map>()) {
        final layout = c['layout'] as String;
        expect(smsLayoutWildcards(layout), c['wildcards'], reason: layout);
        expect(smsLayoutUnanchoredWildcards(layout), c['unanchored'], reason: layout);
        final accepted = smsLayoutWildcards(layout) <= smsMaxAnchoredLayoutWildcards &&
            smsLayoutUnanchoredWildcards(layout) <= smsMaxLayoutWildcards;
        expect(accepted, c['accepted'], reason: layout);
      }
      for (final entry in (corpus['entries'] as List).cast<Map>()) {
        expect(smsLayoutWildcards(entry['layout'] as String), entry['wildcards'], reason: entry['layout'] as String);
        expect(smsLayoutLooseRun(entry['layout'] as String), lessThanOrEqualTo(smsMaxAdjacentLooseSlots), reason: entry['layout'] as String);
      }
    });
  });

  group('S1-9: the brand a layout is filed under is the one the server derives', () {
    // The server's cleanSenderBrand (api/src/sms_v2/upload_hygiene.js) gives these for these headers; the same table
    // is asserted against the JS function in app/test/.../template_upload_hardening_test.dart's notes and was checked by
    // running both over the whole list (see qa-bug-hunt/findings/fix-a4b.md).
    const server = {
      'SBI-UPI': 'SBIUPI',
      'Paytm Bank': 'PAYTMBANK',
      'JM-HDFC_BK': 'HDFCBK',
      'HDFC/BANK': 'HDFCBANK',
      'VM-HDFCBK-S': 'HDFCBK',
      'AD-ICICIB-T': 'ICICIB',
      'HDFCBK': 'HDFCBK',
      'ALPHAB (smsft_fi)': 'ALPHAB',
    };
    test('a header with punctuation is filed under its letters and digits only', () {
      server.forEach((header, brand) {
        expect(uploadSenderBrand(smsTemplateBrand(header)), brand, reason: header);
        expect(uploadSenderBrand(smsTemplateBrand(header)), matches(RegExp(r'^[A-Z0-9]{1,32}$')), reason: header);
      });
    });
    test('a brand that is already letters and digits is unchanged, so its hashes do not move', () {
      for (final header in ['HDFCBK', 'VM-HDFCBK-S', 'AD-ICICIB-T', 'ALPHAB', 'JM-SBIN56-P']) {
        final brand = smsTemplateBrand(header);
        expect(uploadSenderBrand(brand), brand, reason: header);
      }
    });
  });

  group('redactSmsPair shares one pass between the layout and the wording sample', () {
    test('gives exactly what two separate redactions give', () {
      const bodies = [
        'Rs.450.00 debited from A/c XX1234 on 20-11-26 to RAHUL SHARMA. UPI Ref 123456789012. Avl Bal Rs.10,500.25. Call 18001234567',
        'Dear Customer, Rs.99 spent on card XX1234 at Joes Bakery Pune on 20-Nov-26 14:05. Not you? mail me@x.com',
        'Your A/c XX4321 credited Rs.5,000.00 on 20/11/2026. Info: Sample Salary Ref 998877665544',
      ];
      for (final body in bodies) {
        final at = DateTime.utc(2026, 11, 18);
        final pair = redactSmsPair(sender: 'HDFCBK', body: body, observedAt: at, options: SmsRedactionOptions(salt: 'k'));
        final layout = redactSms(sender: 'HDFCBK', body: body, observedAt: at, options: SmsRedactionOptions(salt: 'k'));
        final sample = redactSms(sender: 'HDFCBK', body: body, observedAt: at, options: SmsRedactionOptions(salt: 'k', keepNames: true));
        expect(pair.layout.body, layout.body, reason: body);
        expect(pair.layout.observedAt, layout.observedAt);
        expect(pair.sample.body, sample.body, reason: body);
      }
    });
  });
}
