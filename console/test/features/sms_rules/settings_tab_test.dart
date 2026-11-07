import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay_console/data/sms_v2_admin_api.dart';
import 'package:pandapay_console/features/sms_rules/providers.dart';
import 'package:pandapay_console/features/sms_rules/settings_tab.dart';
import 'package:pandapay_console/features/sms_rules/sms_rules_screen.dart';
import 'support.dart';

Future<FakeAdmin> pumpSettings(
  WidgetTester tester, {
  FakeAdmin? fake,
  DateTime? now,
}) async {
  final admin = fake ?? FakeAdmin();
  await tester.binding.setSurfaceSize(const Size(1000, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SmsSettingsTab(
          api: SmsV2AdminApi(admin),
          now: () => now ?? DateTime.utc(2026, 11, 20),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return admin;
}

void main() {
  testWidgets('shows one row per setting with default and allowed range', (
    tester,
  ) async {
    await pumpSettings(tester);
    for (final row in fixtureSettings()) {
      expect(find.byKey(Key('setting-${row['key']}')), findsOneWidget, reason: '${row['key']}');
    }
    expect(find.textContaining('Default 1 · From 1 to 20'), findsOneWidget);
    expect(find.text('Per-user limits'), findsOneWidget);
    expect(find.text('No per-user limits are set.'), findsOneWidget);
    expect(find.byKey(const Key('banner-ai-paused')), findsNothing);
  });

  testWidgets('the Settings tab is part of the SMS rules screen', (
    tester,
  ) async {
    final admin = FakeAdmin();
    await tester.binding.setSurfaceSize(const Size(1000, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [smsV2AdminApiProvider.overrideWithValue(SmsV2AdminApi(admin))],
        child: const MaterialApp(home: SmsRulesScreen()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Settings'));
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('setting-ai_enabled')), findsOneWidget);
  });

  testWidgets('a banner says when AI drafting is switched off', (tester) async {
    final admin = FakeAdmin()
      ..settings = fixtureSettings(values: {'ai_enabled': false});
    await pumpSettings(tester, fake: admin);
    expect(find.text('AI drafting is paused'), findsOneWidget);
  });

  testWidgets('a banner says when this month\'s budget is spent', (
    tester,
  ) async {
    final admin = FakeAdmin()
      ..metrics = {
        'ai': [
          {'day': '2026-11-03', 'model': 'm', 'calls': 5, 'cost_usd': '6.00'},
          {'day': '2026-11-04', 'model': 'm', 'calls': 5, 'cost_usd': '4.50'},
          {'day': '2026-10-31', 'model': 'm', 'calls': 5, 'cost_usd': '99'},
        ],
      };
    await pumpSettings(tester, fake: admin);
    expect(
      find.text('AI drafting is paused until next month: budget reached'),
      findsOneWidget,
    );
    expect(
      aiSpendThisMonth(admin.metrics, DateTime.utc(2026, 11, 20)),
      closeTo(10.5, 0.001),
    );
  });

  testWidgets('editing needs a written reason and sends the old updatedAt', (
    tester,
  ) async {
    final admin = FakeAdmin()
      ..settings = fixtureSettings(values: {'signals_min_distinct_users': 4});
    await pumpSettings(tester, fake: admin);
    await tester.tap(find.byKey(const Key('edit-signals_min_distinct_users')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<FilledButton>(find.byKey(const Key('setting-save'))).onPressed,
      isNull,
    );
    await tester.enterText(find.byKey(const Key('setting-number')), '0');
    await tester.enterText(find.byKey(const Key('reason-text')), 'friends run');
    await tester.pumpAndSettle();
    expect(find.text('At least 1.'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byKey(const Key('setting-save'))).onPressed,
      isNull,
    );
    await tester.enterText(find.byKey(const Key('setting-number')), '6');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('setting-save')));
    await tester.pumpAndSettle();
    final put = admin.requests.firstWhere((r) => r.$1 == 'PUT');
    expect(put.$2, '/admin/sms/v2/settings/signals_min_distinct_users');
    expect(put.$3, {
      'value': 6,
      'reason': 'friends run',
      'expectedUpdatedAt': '2026-11-06T09:00:00.000000Z',
    });
  });

  testWidgets('a switch setting is edited with a reason, too', (tester) async {
    final admin = await pumpSettings(tester);
    await tester.tap(find.byKey(const Key('edit-intake_enabled')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('setting-switch')));
    await tester.enterText(find.byKey(const Key('reason-text')), 'abuse suspected');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('setting-save')));
    await tester.pumpAndSettle();
    final put = admin.requests.firstWhere((r) => r.$1 == 'PUT');
    expect(put.$3?['value'], false);
    expect(put.$3?['expectedUpdatedAt'], isNull);
  });

  testWidgets('a stale save tells the admin and reloads', (tester) async {
    final admin = FakeAdmin()..failSettingSaveWith = 409;
    await pumpSettings(tester, fake: admin);
    final loads = admin.requests.where((r) => r.$2 == '/admin/sms/v2/settings').length;
    await tester.tap(find.byKey(const Key('edit-ai_rpm')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('setting-number')), '20');
    await tester.enterText(find.byKey(const Key('reason-text')), 'slow down');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('setting-save')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Someone else changed this first'), findsOneWidget);
    expect(
      admin.requests.where((r) => r.$2 == '/admin/sms/v2/settings').length,
      loads + 1,
    );
  });

  testWidgets('per-user limits are listed and removing one needs a reason', (
    tester,
  ) async {
    const profile = '00000000-0000-4000-8000-0000000000aa';
    final admin = FakeAdmin()
      ..userLimits = [
        {
          'profileId': profile,
          'key': 'signals_per_user_per_day',
          'value': 20,
          'expiresAt': '2026-11-09T00:00:00Z',
          'reason': 'bot-like volume',
          'active': true,
        },
      ];
    await pumpSettings(tester, fake: admin);
    expect(find.textContaining('bot-like volume'), findsOneWidget);
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<FilledButton>(find.byKey(const Key('reason-confirm'))).onPressed,
      isNull,
    );
    await tester.enterText(find.byKey(const Key('reason-text')), 'resolved');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('reason-confirm')));
    await tester.pumpAndSettle();
    final del = admin.requests.firstWhere((r) => r.$1 == 'DELETE');
    expect(del.$2, '/admin/sms/v2/user-limits/$profile/signals_per_user_per_day');
    expect(del.$3, {'reason': 'resolved'});
  });
}
