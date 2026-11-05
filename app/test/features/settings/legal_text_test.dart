import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/consent_policy.dart';
import 'package:pandapay/features/settings/legal_screen.dart';
import 'package:pandapay/features/settings/legal_text.dart';

/// The hosted pages (`deploy/legal/*.html`) and the in-app text are the same
/// document. These tests read the hosted files and fail if they drift.
String _hosted(String name) {
  // `flutter test` runs from app/.
  final file = File('../deploy/legal/$name');
  expect(file.existsSync(), isTrue, reason: '${file.path} exists');
  return file.readAsStringSync();
}

String _plain(String htmlFragment) => htmlFragment
    .replaceAll(RegExp(r'<[^>]+>'), '')
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .trim();

List<String> _expectedParts(List<LegalSection> sections) => [
  for (final section in sections) ...[
    section.title,
    for (final block in section.blocks)
      if (block.text != null) block.text! else ...block.items,
  ],
];

List<String> _hostedParts(String page) {
  final body = page.substring(page.indexOf('</p>') + 4);
  final parts = <String>[];
  for (final m in RegExp(
    r'<(h2|p|li)[^>]*>(.*?)</\1>',
    dotAll: true,
  ).allMatches(body)) {
    final text = _plain(m.group(2)!);
    // The closing "other page" link paragraph is navigation, not content.
    if (m.group(1) == 'p' && text.contains('Terms of Service →') ||
        text.contains('← Privacy Policy')) {
      continue;
    }
    parts.add(text);
  }
  return parts;
}

void main() {
  group('hosted pages match the in-app text', () {
    test('privacy policy', () {
      expect(
        _hostedParts(_hosted('privacy.html')),
        _expectedParts(privacyPolicySections),
      );
    });

    test('terms of service', () {
      expect(
        _hostedParts(_hosted('terms.html')),
        _expectedParts(termsOfServiceSections),
      );
    });

    test('both carry the one policy version and its date', () {
      for (final name in ['privacy.html', 'terms.html']) {
        final page = _hosted(name);
        expect(page, contains('Last updated: $legalLastUpdated'));
        expect(page, contains('version $consentPolicyVersion'));
      }
      expect(legalLastUpdated, '15 November 2026');
    });
  });

  group('privacy policy covers every required section', () {
    final titles = [for (final s in privacyPolicySections) s.title];

    test('in order, including 5a for email import', () {
      expect(titles, [
        '1. Who we are',
        '2. Data we collect',
        '3. What stays on your phone',
        '4. Why we use your data',
        '5. Optional: sharing redacted message templates',
        '5a. Optional: email import',
        '6. Service providers',
        '7. Security',
        '8. How long we keep data',
        '9. Your rights and how to use them',
        '10. If something goes wrong',
        '11. Age',
        '12. Changes to this policy',
      ]);
    });

    String section(String prefix) => _expectedParts([
      privacyPolicySections.firstWhere((s) => s.title.startsWith(prefix)),
    ]).join('\n');

    test('who we are names a grievance officer with a 30 day reply', () {
      final text = section('1.');
      expect(text, contains('grievance officer'));
      expect(text, contains('within 30 days'));
    });

    test('says SMS text stays on the phone, and what is collected instead', () {
      expect(section('2.'), contains('We do not collect the message itself.'));
      expect(section('3.'), contains('never sent to us'));
    });

    test('names Google Gemini and says the sharing is off by default', () {
      final text = section('5.');
      expect(text, contains('Google Gemini'));
      expect(text, contains('off unless you turn it on'));
    });

    test('email import: bank senders only, deleted once read, 30 days', () {
      final text = section('5a.');
      expect(text, contains('Only emails from bank and card senders are read'));
      expect(text, contains('deleted once it has been read'));
      expect(text, contains('up to 30 days'));
      expect(text, contains('app password is stored encrypted'));
      expect(text, contains('Disconnecting deletes it'));
    });

    test('security describes what the phone actually does', () {
      final text = '${section('3.')}\n${section('7.')}';
      expect(text, contains('database is encrypted'));
      expect(text, contains('Receipt files are encrypted'));
      expect(text, contains('through the Shortcut are encrypted'));
      expect(text, contains('left out of phone backups'));
      expect(text, contains('HTTPS/TLS'));
    });

    test('retention, rights, breach and age', () {
      expect(section('8.'), contains('within 30 days'));
      expect(section('9.'), contains('Withdrawing consent'));
      expect(section('10.'), contains('personal data breach'));
      expect(section('11.'), contains('18 or over'));
    });

    test('drops claims that are no longer true', () {
      final all = _expectedParts(privacyPolicySections).join('\n');
      expect(all, isNot(contains('account recovery')));
      expect(all, isNot(contains('recovery copies')));
      expect(all, isNot(contains('financial message content')));
      expect(all, isNot(contains('read existing and incoming messages')));
    });
  });

  test('terms say PandaPay is 18+ only', () {
    final all = _expectedParts(termsOfServiceSections).join('\n');
    expect(all, contains('only for people aged 18 or over'));
    expect(all, isNot(contains('guest mode')));
  });

  test('owner placeholders are present and unmistakable', () {
    final all = [
      ..._expectedParts(privacyPolicySections),
      ..._expectedParts(termsOfServiceSections),
    ].join('\n');
    for (final needed in [
      '[OWNER TO FILL: legal entity name and registered address]',
      '[OWNER TO FILL: grievance officer name]',
      '[OWNER TO FILL: grievance officer email]',
    ]) {
      expect(all, contains(needed));
    }
    expect(legalOwnerPlaceholder, '[OWNER TO FILL');
  });

  testWidgets('the Legal screen shows the policy sections and the 18+ line', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 40000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(home: LegalScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Privacy Policy'), findsOneWidget);
    expect(find.text('5a. Optional: email import'), findsOneWidget);
    expect(
      find.textContaining('PandaPay is only for people aged 18 or over'),
      findsNWidgets(2),
    );
    expect(find.textContaining('Last updated: $legalLastUpdated'), findsNWidgets(2));
  });
}
