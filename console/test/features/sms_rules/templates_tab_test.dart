import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay_console/data/sms_v2_admin_api.dart';
import 'package:pandapay_console/features/sms_rules/templates_tab.dart';
import 'support.dart';

Map<String, dynamic> layout(
  String hash,
  String status, {
  Map<String, dynamic> extra = const {},
}) => {
  'template_hash': hash * 64,
  'sender_brand': 'TESTBK',
  'redacted_body': '<AMT> layout $hash.',
  'seen_count': 2,
  'distinct_profiles': 1,
  'ai_status': status,
  'failure_code': null,
  ...extra,
};

Future<FakeAdmin> pumpTemplates(
  WidgetTester tester,
  List<Map<String, dynamic>> rows, {
  void Function(String)? onOpen,
}) async {
  final admin = FakeAdmin()..templates = rows;
  await tester.binding.setSurfaceSize(const Size(1200, 1800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SmsTemplatesTab(
          api: SmsV2AdminApi(admin),
          onOpenRule: onOpen ?? (_) {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return admin;
}

void main() {
  test('rejected is a decision on a failed layout', () {
    expect(templateStatusOf(layout('a', 'failed')), 'failed');
    expect(
      templateStatusOf(
        layout('a', 'failed', extra: {'admin_decision': 'rejected'}),
      ),
      'rejected',
    );
    expect(
      templateStatusOf(
        layout('a', 'ready', extra: {'admin_decision': 'approved'}),
      ),
      'ready',
    );
    expect(smsTemplateStatuses, [
      'held',
      'queued',
      'working',
      'ready',
      'failed',
      'covered',
      'rejected',
      'blocked',
    ]);
  });

  testWidgets(
    'every status has a filter chip with its count, and a chip filters the list',
    (tester) async {
      await pumpTemplates(tester, [
        layout('a', 'held'),
        layout('b', 'ready'),
        layout('c', 'failed'),
        layout(
          'd',
          'failed',
          extra: {'admin_decision': 'rejected', 'admin_reason': 'overmatches'},
        ),
        layout('e', 'covered', extra: {'covered_by': 'HDFC-SPEND@3'}),
      ]);
      for (final status in smsTemplateStatuses) {
        expect(
          find.byKey(Key('filter-$status')),
          findsOneWidget,
          reason: status,
        );
      }
      expect(find.text('All (5)'), findsOneWidget);
      expect(
        find.text('failed (1)'),
        findsOneWidget,
        reason: 'a rejected layout is not counted as failed',
      );
      expect(find.text('rejected (1)'), findsOneWidget);
      expect(find.text('blocked (0)'), findsOneWidget);
      expect(find.byType(ExpansionTile), findsNWidgets(5));
      await tester.tap(find.byKey(const Key('filter-rejected')));
      await tester.pumpAndSettle();
      expect(find.byType(ExpansionTile), findsOneWidget);
      expect(
        find.textContaining('Rejected: It matches too much'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('filter-covered')));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Covered: already read by HDFC-SPEND@3'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('filter-all')));
      await tester.pumpAndSettle();
      expect(find.byType(ExpansionTile), findsNWidgets(5));
    },
  );

  testWidgets(
    'a draft that emits only info facts is badged as not a money message',
    (tester) async {
      await pumpTemplates(tester, [
        layout(
          'a',
          'ready',
          extra: {
            'ai_draft': {
              'emit': [
                {'factType': 'info'},
              ],
            },
          },
        ),
        layout(
          'b',
          'ready',
          extra: {
            'ai_draft': {
              'emit': [
                {'factType': 'movement'},
              ],
            },
          },
        ),
      ]);
      expect(find.textContaining('AI: not a money message'), findsOneWidget);
      expect(
        draftIsNotMoney({
          'ai_draft': {
            'emit': [
              {'factType': 'info'},
              {'factType': 'movement'},
            ],
          },
        }),
        isFalse,
      );
      expect(draftIsNotMoney({'ai_draft': null}), isFalse);
    },
  );

  testWidgets(
    'how the private rule fares on phones is shown once phones report',
    (tester) async {
      await pumpTemplates(tester, [
        layout(
          'a',
          'ready',
          extra: {'privatePhones': 3, 'privateHits': 12, 'privateCorrected': 1},
        ),
        layout('b', 'ready'),
      ]);
      expect(
        find.textContaining('Private rule on 3 phones: 12 hits, 1 corrected'),
        findsOneWidget,
      );
      expect(
        privateRuleLine({
          'privatePhones': 1,
          'privateHits': 0,
          'privateCorrected': 0,
        }),
        'Private rule on 1 phone: 0 hits, 0 corrected',
      );
      expect(privateRuleLine({}), isNull);
    },
  );

  testWidgets('Reject offers only for a finished draft and needs a reason', (
    tester,
  ) async {
    final admin = await pumpTemplates(tester, [
      layout('a', 'ready'),
      layout('b', 'queued'),
    ]);
    expect(find.byKey(Key('reject-${'a' * 64}')), findsOneWidget);
    expect(find.byKey(Key('reject-${'b' * 64}')), findsNothing);
    await tester.tap(find.byKey(Key('reject-${'a' * 64}')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('reason-confirm')))
          .onPressed,
      isNull,
    );
    await tester.tap(find.byKey(const Key('reason-choice')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('It matches too much').last);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('reason-confirm')))
          .onPressed,
      isNotNull,
      reason: 'a note is optional for a listed reason',
    );
    await tester.tap(find.byKey(const Key('reason-confirm')));
    await tester.pumpAndSettle();
    final post = admin.requests.lastWhere((r) => r.$2.endsWith('/reject'));
    expect(post.$2, '/admin/sms/v2/templates/${'a' * 64}/reject');
    expect(post.$3, {'reason': 'overmatches'});
  });

  testWidgets('"Something else" needs a written note', (tester) async {
    final admin = await pumpTemplates(tester, [layout('a', 'ready')]);
    await tester.tap(find.byKey(Key('reject-${'a' * 64}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('reason-choice')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Something else (write a note)').last);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('reason-confirm')))
          .onPressed,
      isNull,
    );
    await tester.enterText(
      find.byKey(const Key('reason-text')),
      'Reads an offer message',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('reason-confirm')));
    await tester.pumpAndSettle();
    final post = admin.requests.lastWhere((r) => r.$2.endsWith('/reject'));
    expect(post.$3, {'reason': 'other', 'note': 'Reads an offer message'});
  });

  testWidgets('Create draft opens the rule for a ready layout only', (
    tester,
  ) async {
    final opened = <String>[];
    final admin = FakeAdmin();
    final layouts = [layout('a', 'ready')];
    admin.templates = layouts;
    await tester.binding.setSurfaceSize(const Size(1200, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SmsTemplatesTab(
            api: SmsV2AdminApi(_Drafts(admin)),
            onOpenRule: opened.add,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create draft'));
    await tester.pumpAndSettle();
    expect(opened, ['AI-${'a' * 64}']);
  });
  testWidgets(
    'an approved layout offers no Reject, because the server refuses it',
    (tester) async {
      await pumpTemplates(tester, [
        layout('a', 'ready'),
        layout('b', 'ready', extra: {'admin_decision': 'approved'}),
      ]);
      expect(find.byKey(Key('reject-${'a' * 64}')), findsOneWidget);
      expect(find.byKey(Key('reject-${'b' * 64}')), findsNothing);
    },
  );
}

class _Drafts extends FakeAdmin {
  _Drafts(FakeAdmin base) {
    templates = base.templates;
  }
  @override
  Future<Map<String, dynamic>> smsV2Request(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    if (path.endsWith('/draft') &&
        path.startsWith('/admin/sms/v2/templates/')) {
      return {'ruleId': 'AI-${'a' * 64}', 'version': 1, 'status': 'draft'};
    }
    return super.smsV2Request(method, path, body: body);
  }
}
