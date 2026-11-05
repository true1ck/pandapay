// Everything the learning loop does is visible and controllable here: one test
// for each console surface of Task B7 (Templates, Learning, Settings, Overview).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay_console/app/admin_identity.dart';
import 'package:pandapay_console/app/providers.dart';
import 'package:pandapay_console/data/sms_v2_admin_api.dart';
import 'package:pandapay_console/features/overview/overview_screen.dart';
import 'package:pandapay_console/features/sms_rules/ai_drafting_status.dart';
import 'package:pandapay_console/features/sms_rules/learning_tab.dart';
import 'package:pandapay_console/features/sms_rules/providers.dart';
import 'package:pandapay_console/features/sms_rules/settings_tab.dart';
import 'package:pandapay_console/features/sms_rules/templates_tab.dart';

import 'sms_rules/support.dart';

const profile = '00000000-0000-4000-8000-0000000000aa';

Map<String, dynamic> layout(String hash, String status, {Map<String, dynamic> extra = const {}}) => {
  'template_hash': hash * 64,
  'sender_brand': 'TESTBK',
  'redacted_body': '<AMT> layout $hash.',
  'seen_count': 2,
  'distinct_profiles': 1,
  'ai_status': status,
  'failure_code': null,
  ...extra,
};

Future<void> pump(WidgetTester tester, Widget child) async {
  await tester.binding.setSurfaceSize(const Size(1200, 2400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
  await tester.pumpAndSettle();
}

Future<void> typeReasonAndConfirm(WidgetTester tester, String reason) async {
  expect(tester.widget<FilledButton>(find.byKey(const Key('reason-confirm'))).onPressed, isNull, reason: 'a reason is required');
  await tester.enterText(find.byKey(const Key('reason-text')), reason);
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('reason-confirm')));
  await tester.pumpAndSettle();
}

void main() {
  group('Templates tab', () {
    testWidgets('offers all eight status filters', (tester) async {
      await pump(tester, SmsTemplatesTab(api: SmsV2AdminApi(FakeAdmin()..templates = [layout('a', 'held')]), onOpenRule: (_) {}));
      for (final status in ['held', 'queued', 'working', 'ready', 'failed', 'covered', 'rejected', 'blocked']) {
        expect(find.byKey(Key('filter-$status')), findsOneWidget, reason: status);
      }
    });

    testWidgets('Requeue is for failed and rejected layouts and asks why', (tester) async {
      final admin = FakeAdmin()
        ..templates = [
          layout('a', 'failed', extra: {'failure_code': 'draft_validation_failed'}),
          layout('b', 'failed', extra: {'admin_decision': 'rejected', 'admin_reason': 'overmatches'}),
          layout('c', 'ready'),
          layout('d', 'queued'),
        ];
      await pump(tester, SmsTemplatesTab(api: SmsV2AdminApi(admin), onOpenRule: (_) {}));
      expect(find.byKey(Key('requeue-${'a' * 64}')), findsOneWidget);
      expect(find.byKey(Key('requeue-${'b' * 64}')), findsOneWidget);
      expect(find.byKey(Key('requeue-${'c' * 64}')), findsNothing);
      expect(find.byKey(Key('requeue-${'d' * 64}')), findsNothing);
      await tester.tap(find.byKey(Key('requeue-${'a' * 64}')));
      await tester.pumpAndSettle();
      await typeReasonAndConfirm(tester, 'Prompt improved');
      final post = admin.requests.lastWhere((r) => r.$2.endsWith('/requeue'));
      expect(post.$2, '/admin/sms/v2/templates/${'a' * 64}/requeue');
      expect(post.$3, {'reason': 'Prompt improved'});
    });

    testWidgets('Block asks why, is offered until blocked, and shows the reason afterwards', (tester) async {
      final admin = FakeAdmin()
        ..templates = [
          layout('a', 'queued'),
          layout('b', 'blocked', extra: {'admin_reason': 'Looks like marketing'}),
        ];
      await pump(tester, SmsTemplatesTab(api: SmsV2AdminApi(admin), onOpenRule: (_) {}));
      expect(find.byKey(Key('block-${'b' * 64}')), findsNothing);
      expect(find.textContaining('Blocked: Looks like marketing'), findsOneWidget);
      await tester.tap(find.byKey(Key('block-${'a' * 64}')));
      await tester.pumpAndSettle();
      await typeReasonAndConfirm(tester, 'Marketing text');
      final post = admin.requests.lastWhere((r) => r.$2.endsWith('/block'));
      expect(post.$3, {'reason': 'Marketing text'});
    });

    testWidgets('Reject asks for a reason from the list', (tester) async {
      final admin = FakeAdmin()..templates = [layout('a', 'ready')];
      await pump(tester, SmsTemplatesTab(api: SmsV2AdminApi(admin), onOpenRule: (_) {}));
      await tester.tap(find.byKey(Key('reject-${'a' * 64}')));
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(find.byKey(const Key('reason-confirm'))).onPressed, isNull);
    });
  });

  group('Learning tab', () {
    FakeAdmin loaded() => FakeAdmin()
      ..learningCategories = [fixtureCategoryCandidate()]
      ..learningNames = [
        {'merchantKey': 'PAYU SWIGGY', 'name': 'SWIGGY', 'users': 5, 'keyUsers': 5, 'agreement': 1, 'split': {'SWIGGY': 5}, 'senders': ['HDFCBK'], 'status': 'new', 'decision': null},
      ]
      ..learningOther = [
        {
          'merchantKey': 'BLINKIT', 'users': 9, 'senders': ['ICICIB'], 'status': 'new', 'decision': null,
          'suggestion': {'category': 'groceries', 'confidence': 0.9, 'why': 'brand_known'},
        },
      ]
      ..reporters = [
        {
          'profileId': profile, 'signals': 5, 'layouts': 1, 'corrections': 0,
          'effectiveLimits': {'templates_per_user_per_day': 50, 'signals_per_user_per_day': 500}, 'override': null,
        },
        {
          'profileId': '00000000-0000-4000-8000-0000000000bb', 'signals': 2, 'layouts': 0, 'corrections': 1,
          'effectiveLimits': {'templates_per_user_per_day': 50, 'signals_per_user_per_day': 20},
          'override': {'key': 'signals_per_user_per_day', 'value': 20, 'expiresAt': '2026-11-09T00:00:00Z'},
        },
      ];

    testWidgets('renders every section with its rows', (tester) async {
      await pump(tester, SmsLearningTab(api: SmsV2AdminApi(loaded()), onCreateCategoryRule: (_, _) {}, onCreateName: (_, _) {}, onOpenCorrections: () {}));
      for (final section in ['Categories', 'Shop names', 'Shops in Other', 'Reporters', 'Fixes by layout']) {
        expect(find.byKey(Key('section-$section')), findsOneWidget, reason: section);
      }
      expect(find.byKey(const Key('category-SWIGGY')), findsOneWidget);
      expect(find.text('PAYU SWIGGY → SWIGGY'), findsOneWidget);
      expect(find.text('BLINKIT · 9 people'), findsOneWidget);
      expect(find.byKey(const Key('reporter-$profile')), findsOneWidget);
      expect(find.textContaining('Override: Shop signals per person per day 20 until'), findsOneWidget);
      expect(find.byKey(const Key('summary-cards')), findsOneWidget);
    });

    testWidgets('Set limit takes a value, an expiry up to 90 days and a reason', (tester) async {
      final admin = loaded();
      await pump(tester, SmsLearningTab(api: SmsV2AdminApi(admin), onCreateCategoryRule: (_, _) {}));
      await tester.tap(find.byKey(const Key('limit-$profile')));
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(find.byKey(const Key('limit-save'))).onPressed, isNull);
      await tester.enterText(find.byKey(const Key('limit-value')), '30');
      await tester.enterText(find.byKey(const Key('reason-text')), 'Bot-like volume');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('limit-days')));
      await tester.pumpAndSettle();
      expect(find.text('90 days'), findsWidgets);
      await tester.tap(find.text('30 days').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('limit-save')));
      await tester.pumpAndSettle();
      final put = admin.requests.lastWhere((r) => r.$1 == 'PUT' && r.$2.contains('/user-limits/'));
      expect(put.$2, '/admin/sms/v2/user-limits/$profile/signals_per_user_per_day');
      expect(put.$3?['value'], 30);
      expect(put.$3?['reason'], 'Bot-like volume');
      final expires = DateTime.parse(put.$3?['expiresAt'] as String);
      final days = expires.difference(DateTime.now().toUtc()).inDays;
      expect(days, inInclusiveRange(29, 30));
    });

    testWidgets('Ask again is offered for a shop with a suggestion and asks why', (tester) async {
      final admin = loaded();
      await pump(tester, SmsLearningTab(api: SmsV2AdminApi(admin), onCreateCategoryRule: (_, _) {}));
      await tester.tap(find.byKey(const Key('again-BLINKIT')));
      await tester.pumpAndSettle();
      await typeReasonAndConfirm(tester, 'Prompt improved');
      final post = admin.requests.lastWhere((r) => r.$2.contains('/merchant-suggestions/'));
      expect(post.$2, '/admin/sms/v2/merchant-suggestions/BLINKIT/ask-again');
      expect(post.$3, {'reason': 'Prompt improved'});
    });
  });

  group('Settings tab', () {
    testWidgets('one row per registry key and the recent changes list', (tester) async {
      final admin = FakeAdmin()
        ..auditEntries = [
          {'at': '2026-11-06T10:00:00Z', 'adminId': '11111111-2222-4333-8444-555555555555', 'action': 'sms_v2_setting', 'entity': 'sms_v2_setting', 'entityId': null, 'reason': 'Friends run'},
          {'at': '2026-11-06T09:00:00Z', 'adminId': '11111111-2222-4333-8444-555555555555', 'action': 'sms_v2_template_reject', 'entity': 'sms_v2_template', 'entityId': null, 'reason': 'It also read card bills'},
        ];
      await pump(tester, SmsSettingsTab(api: SmsV2AdminApi(admin)));
      for (final row in fixtureSettings()) {
        expect(find.byKey(Key('setting-${row['key']}')), findsOneWidget, reason: '${row['key']}');
      }
      expect(find.text('Recent changes'), findsOneWidget);
      expect(find.text('Setting changed'), findsOneWidget);
      expect(find.text('Draft rejected'), findsOneWidget);
      expect(find.textContaining('Friends run'), findsOneWidget);
      expect(find.textContaining('It also read card bills'), findsOneWidget);
      expect(admin.requests.any((r) => r.$2.startsWith('/admin/sms/v2/audit?limit=50')), isTrue);
    });

    testWidgets('an empty history says so', (tester) async {
      await pump(tester, SmsSettingsTab(api: SmsV2AdminApi(FakeAdmin())));
      expect(find.text('No changes recorded yet.'), findsOneWidget);
    });
  });

  group('Overview tiles', () {
    Future<void> overview(
      WidgetTester tester, {
      required Set<String>? permissions,
      Map<String, dynamic>? summary,
      List<Map<String, dynamic>> settings = const [],
      Map<String, dynamic>? metrics,
      List<Map<String, dynamic>> jobs = const [],
    }) async {
      await tester.binding.setSurfaceSize(const Size(1400, 2000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          key: UniqueKey(), // a fresh scope for each situation in one test
          overrides: [
            adminIdentityProvider.overrideWithValue(
              AdminIdentity(role: 'owner', environment: AdminEnvironment.local, permissions: permissions),
            ),
            dataQualityDashboardProvider.overrideWith((ref) async => <String, dynamic>{}),
            anonymizationAuditRunsProvider.overrideWith((ref) async => []),
            smsCategoryProposalsProvider.overrideWith((ref) async => []),
            smsParserProposalsProvider.overrideWith((ref) async => []),
            systemStatusProvider.overrideWith((ref) async => {'services': [], 'checks': [], 'database': {'ok': true}, 'jobs': jobs}),
            smsLearningSummaryProvider.overrideWith((ref) async => summary ?? {'candidates': {'total': 0}}),
            smsAiSettingsProvider.overrideWith((ref) async => {'settings': settings, 'metrics': metrics}),
          ],
          child: MaterialApp(home: Scaffold(body: OverviewScreen(onOpen: (_) {}))),
        ),
      );
      await tester.pumpAndSettle();
    }

    final owner = {'learning.read', 'learning.publish', 'operations.read', 'catalogue.read', 'admin.audit.read', 'support.evidence.read', 'referrals.read'};

    testWidgets('Learning candidates shows how many shops and names wait', (tester) async {
      await overview(tester, permissions: owner, summary: {'candidates': {'total': 4}});
      expect(find.text('Learning candidates'), findsOneWidget);
      expect(find.text('Shops and names people agree on'), findsOneWidget);
      expect(find.text('4'), findsWidgets);
    });

    testWidgets('AI drafting appears only when it is off, over budget, or its job is failing', (tester) async {
      await overview(tester, permissions: owner);
      expect(find.text('AI drafting'), findsNothing, reason: 'healthy: no tile');

      await overview(tester, permissions: owner, settings: fixtureSettings(values: {'ai_enabled': false}));
      expect(find.text('AI drafting'), findsOneWidget);
      expect(find.textContaining('AI drafting is switched off'), findsOneWidget);

      await overview(
        tester,
        permissions: owner,
        settings: fixtureSettings(values: {'ai_monthly_budget_usd': 1}),
        metrics: {'ai': [{'day': '${DateTime.now().toUtc().toIso8601String().substring(0, 7)}-01', 'cost_usd': '2.5'}]},
      );
      expect(find.text('AI drafting'), findsOneWidget);
      expect(find.textContaining('budget is used up'), findsOneWidget);

      await overview(tester, permissions: owner, jobs: [{'name': 'SMS AI drafts', 'state': 'overdue'}]);
      expect(find.text('AI drafting'), findsOneWidget);
      expect(find.textContaining('The AI drafts job is overdue'), findsOneWidget);
    });

    testWidgets('both tiles are hidden without the permission to read learning', (tester) async {
      await overview(
        tester,
        permissions: {'operations.read', 'catalogue.read'},
        summary: {'candidates': {'total': 9}},
        settings: fixtureSettings(values: {'ai_enabled': false}),
      );
      expect(find.text('Learning candidates'), findsNothing);
      expect(find.text('AI drafting'), findsNothing);
    });
  });

  test('what stops AI drafting is described in plain words', () {
    final now = DateTime.utc(2026, 11, 20);
    expect(aiDraftingProblems(settings: fixtureSettings(), metrics: null, jobs: null, now: now), isEmpty);
    expect(
      aiDraftingProblems(
        settings: fixtureSettings(values: {'ai_enabled': false, 'ai_monthly_budget_usd': 1}),
        metrics: {'ai': [{'day': '2026-11-02', 'cost_usd': '5'}]},
        jobs: [{'name': 'SMS AI drafts', 'state': 'failed'}],
        now: now,
      ),
      ['AI drafting is switched off', 'The AI drafts job is failed'],
      reason: 'a switched-off worker is not also reported as over budget',
    );
  });
}
