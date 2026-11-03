import 'dart:convert';
import 'dart:io';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_console/features/sms_rules/rule_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay_console/data/sms_v2_admin_api.dart';
import 'package:pandapay_console/features/sms_rules/golden_runner.dart';
import 'package:pandapay_console/features/sms_rules/providers.dart';
import 'package:pandapay_console/features/sms_rules/sms_rules_screen.dart';
import 'support.dart';

void main() {
  test('editor validates JSON, missing fields and regex dialect', () {
    expect(validateEditor(jsonEncode(rule()), senders: catalog), isEmpty);
    expect(validateEditor('{'), isNotEmpty);
    expect(validateEditor('{}'), isNotEmpty);
    final invalid = rule();
    invalid['match'] = {'pattern': r'(a+)+\1', 'flags': 'i'};
    expect(validateEditor(jsonEncode(invalid)), isNotEmpty);
  });
  test(
    'browser golden runner uses every real stage and binds candidate content',
    () async {
      final bundle = editorBundle({...rule(), 'status': 'active'});
      final result = await tinyRunner().run(bundle);
      expect(result.passed, isTrue);
      expect(result.report['counts']['casesPassed'], 1);
      expect(
        result.report['stages'].values.every((value) => value == 'available'),
        isTrue,
      );
    },
  );
  test('local tester retains candidate issuer and alias context', () {
    final context =
        (jsonDecode(
                  File(
                    '../contracts/sms/v2/fixtures/valid/bundle/full.json',
                  ).readAsStringSync(),
                )
                as Map)
            .cast<String, dynamic>();
    final draft = (context['rules'] as List).first as Map<String, dynamic>;
    final bundle = RuleBundle.fromJson(localTestBundle(context, draft));
    final body = (draft['examples'] as List).first['body'] as String;
    final result = RuleEngine().interpret(
      SmsMessage(
        sender: 'AD-HDFCCC',
        body: body,
        observedAt: DateTime.utc(2026, 11, 1),
        sourceKey: 'alias-test',
      ),
      bundle,
      appVersion: 'console',
    );
    expect(result.facts, isNotEmpty);
    expect(result.facts.first.envelope.instrument?.issuerSlug, 'hdfc');
    expect(
      bundle.counterpartyPurposes,
      hasLength((context['counterpartyPurposes'] as List).length),
    );
  });
  testWidgets(
    'an existing active version can run golden for promotion without saving',
    (tester) async {
      final admin = FakeAdmin()
        ..latestVersion = 2
        ..latestStatus = 'active';
      await tester.pumpWidget(
        MaterialApp(
          home: SmsRuleEditor(
            api: SmsV2AdminApi(admin),
            ruleId: 'CONSOLE-SPEND',
            runner: () async => tinyRunner(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final scroll = tester
          .state<ScrollableState>(
            find
                .descendant(
                  of: find.byKey(const Key('rule-editor-scroll')),
                  matching: find.byType(Scrollable),
                )
                .first,
          )
          .position;
      final run = find.byKey(const Key('run-golden'));
      for (var i = 0; run.evaluate().isEmpty && i < 30; i++) {
        scroll.jumpTo((scroll.pixels + 300).clamp(0, scroll.maxScrollExtent));
        await tester.pump();
      }
      expect(tester.widget<OutlinedButton>(run).onPressed, isNotNull);
      await tester.ensureVisible(run);
      await tester.tap(run);
      await tester.pumpAndSettle();
      expect(find.text('Golden set passed'), findsOneWidget);
      expect(admin.requests.any((r) => r.$1 == 'PUT'), isFalse);
      expect(
        admin.requests
            .where((r) => r.$2.contains('/candidate?'))
            .every((r) => r.$2.contains('version=2')),
        isTrue,
      );
    },
  );
  testWidgets(
    'rules virtualize 2000 rows and filters and sorts remain responsive',
    (tester) async {
      final rows = [
        for (var i = 0; i < 2000; i++)
          {
            'ruleId': 'RULE-${i.toString().padLeft(4, '0')}',
            'latestVersion': 1,
            'status': i.isEven ? 'active' : 'paused',
            'family': i.isEven ? 'card_spend' : 'bank_debit',
            'senders': [i.isEven ? 'BANKA' : 'BANKB'],
            'metrics7d': {'hits': 2000 - i, 'toReview': 0, 'corrected': i},
          },
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SmsRulesTable(rows: rows, onOpen: (_) {}),
          ),
        ),
      );
      expect(find.text('2000 rules'), findsOneWidget);
      expect(find.byType(ListTile).evaluate().length, lessThan(15));
      await tester.enterText(
        find.byKey(const Key('rules-search')),
        'RULE-1999',
      );
      await tester.pumpAndSettle();
      expect(find.text('1 rules'), findsOneWidget);
      expect(find.text('RULE-1999 · v1'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('rules-search')), '');
      await tester.tap(find.byKey(const Key('filter-status')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('paused').last);
      await tester.pumpAndSettle();
      expect(find.text('1000 rules'), findsOneWidget);
      await tester.tap(find.byKey(const Key('rules-sort')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Highest correction rate').last);
      await tester.pumpAndSettle();
      expect(find.text('RULE-1999 · v1'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  Future<FakeAdmin> screen(
    WidgetTester tester, {
    void Function(String, String)? download,
  }) async {
    final admin = FakeAdmin();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          smsV2AdminApiProvider.overrideWithValue(SmsV2AdminApi(admin)),
        ],
        child: MaterialApp(
          home: SmsRulesScreen(
            runner: () async => tinyRunner(),
            onDownload: download,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return admin;
  }

  Future<void> correction(WidgetTester tester, String label) async {
    await tester.tap(find.text('Corrections'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('template-a · 1 cases'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('correction-reason')),
      'Reviewed synthetic example',
    );
    await tester.pump();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'a correction becomes a draft and publishes only after passing golden',
    (tester) async {
      final admin = await screen(tester);
      await correction(tester, 'Data fix');
      expect(find.text('CONSOLE-SPEND'), findsOneWidget);
      final publish = find.byKey(const Key('publish-rule'));
      Future<void> reveal(Finder target, double step) async {
        final scroll = find
            .descendant(
              of: find.byKey(const Key('rule-editor-scroll')),
              matching: find.byType(Scrollable),
            )
            .first;
        final position = tester.state<ScrollableState>(scroll).position;
        for (var i = 0; target.evaluate().isEmpty && i < 40; i++) {
          position.jumpTo(
            (position.pixels + step).clamp(0, position.maxScrollExtent),
          );
          await tester.pump();
        }
        await tester.ensureVisible(target);
      }

      await reveal(publish, 300);
      expect(tester.widget<FilledButton>(publish).onPressed, isNull);
      await reveal(find.byKey(const Key('save-draft')), -300);
      await tester.tap(find.byKey(const Key('save-draft')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('run-golden')));
      await tester.tap(find.byKey(const Key('run-golden')));
      await tester.pumpAndSettle();
      expect(find.text('Golden set passed'), findsOneWidget);
      await reveal(find.byKey(const Key('publish-reason')), 300);
      await tester.enterText(
        find.byKey(const Key('publish-reason')),
        'Fix reviewed amount capture',
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(publish);
      await tester.tap(publish);
      await tester.pumpAndSettle();
      final sent = admin.requests.singleWhere(
        (request) => request.$2.endsWith('/publish'),
      );
      expect(sent.$3!['cohort'], 'testers');
      expect(sent.$3!['goldenReport']['bundleSha256'], isNotEmpty);
      expect(sent.$3!['version'], 2);
      final pause = find.byKey(const Key('pause-rule'));
      await reveal(pause, 300);
      await tester.tap(pause);
      await tester.pumpAndSettle();
      expect(find.text('Pause CONSOLE-SPEND version 2?'), findsOneWidget);
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
      expect(
        admin.requests.singleWhere((r) => r.$2.contains('/pause?')).$2,
        endsWith('version=2'),
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'not a bug requires a reason and calls only the decision endpoint',
    (tester) async {
      final admin = await screen(tester);
      await correction(tester, 'Not a bug');
      expect(
        admin.requests.where((r) => r.$2.endsWith('/decision')).single.$3,
        {'decision': 'not_a_bug', 'reason': 'Reviewed synthetic example'},
      );
      expect(admin.requests.any((r) => r.$2.endsWith('/publish')), isFalse);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('code fix saves a reviewed synthetic example before exporting', (
    tester,
  ) async {
    String? downloaded;
    final admin = await screen(
      tester,
      download: (name, body) => downloaded = body,
    );
    await correction(tester, 'Code fix');
    await tester.enterText(
      find.byKey(const Key('synthetic-example')),
      jsonEncode({
        'source': 'synthetic',
        'body': 'Rs. 125 spent at SHOP.',
        'observedAt': '2026-11-01T12:00:00Z',
        'expect': {
          'facts': [
            {'factType': 'movement'},
          ],
        },
      }),
    );
    await tester.pump();
    await tester.tap(find.text('Save example'));
    await tester.pumpAndSettle();
    final mutations = admin.requests.where((r) => r.$1 != 'GET').toList();
    expect(mutations.map((r) => r.$1), ['PUT', 'POST']);
    expect(mutations.last.$3!['decision'], 'code_fix');
    expect(downloaded, isNotNull);
    expect(tester.takeException(), isNull);
  });
}
