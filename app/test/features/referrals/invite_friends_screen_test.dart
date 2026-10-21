import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/api_exception.dart';
import 'package:pandapay/data/referral_repository.dart';
import 'package:pandapay/features/referrals/invite_friends_screen.dart';
import 'package:pandapay/features/referrals/reward_spin_dialog.dart';

void main() {
  test(
    'wheel slices are equal and the server-selected prize lands at pointer',
    () {
      final sectors = equalSpinWheelSectors(_spinConfiguration);
      expect(sectors, hasLength(_spinConfiguration.prizes.length));
      expect(
        sectors.map((sector) => sector.sweepAngle),
        everyElement(closeTo(2 * math.pi / sectors.length, 1e-12)),
      );
      expect(
        _spinConfiguration.prizes.map((prize) => prize.weight).toSet().length,
        greaterThan(1),
        reason:
            'The display slices are equal even though the server odds vary.',
      );

      const jackpot = SpinResult(
        entitlementId: 'own-entitlement',
        spinId: 'spin-jackpot',
        amount: PaiseAmount(50000),
        state: 'credited',
        outcomeId: 'five-hundred',
        ledgerEntryId: 'entry-jackpot',
      );
      final rotation = spinWheelRotationForResult(_spinConfiguration, jackpot);
      expect(rotation, isNotNull);
      final jackpotSector = sectors.singleWhere(
        (sector) => sector.prize.id == jackpot.outcomeId,
      );
      final pointerAngle =
          (jackpotSector.centerAngle + rotation!) % (2 * math.pi);
      expect(pointerAngle, closeTo(3 * math.pi / 2, 1e-12));
    },
  );

  testWidgets('shows distinct join and award totals, progress, and own spin', (
    tester,
  ) async {
    final repository = _FakeReferralRepository(_dashboard());
    await tester.pumpWidget(_app(repository));
    await tester.pumpAndSettle();

    expect(find.text('PANDA26'), findsOneWidget);
    expect(find.text('Joined in 2026'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('Credits awarded in 2026'), findsOneWidget);
    expect(find.text('₹32'), findsOneWidget);
    expect(find.text('Bamboo 2/3 days'), findsOneWidget);
    expect(find.text('Invited by Mira'), findsOneWidget);
    await tester.drag(find.byType(ListView).first, const Offset(0, -700));
    await tester.pumpAndSettle();
    expect(find.text('Spin your reward'), findsOneWidget);
    expect(find.text('Under review'), findsOneWidget);
    expect(find.textContaining('No one has joined'), findsNothing);
  });

  testWidgets(
    'shows a spin amount only after repository confirms its saved result',
    (tester) async {
      final repository = _FakeReferralRepository(_dashboard());
      await tester.pumpWidget(_app(repository));
      await tester.pumpAndSettle();

      await tester.drag(find.byType(ListView).first, const Offset(0, -700));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Spin your reward'));
      await tester.pumpAndSettle();

      expect(find.text('Your reward is ready'), findsOneWidget);
      expect(find.textContaining('%'), findsNothing);
      expect(find.textContaining('chance'), findsNothing);
      expect(find.text('See all prize odds'), findsNothing);
      expect(repository.spinCalls, 0);
      expect(repository.configCalls, 1);
      final action = find.byKey(const Key('referral-spin-action'));
      await tester.ensureVisible(action);
      await tester.pumpAndSettle();
      await tester.tap(action);
      await tester.pump(const Duration(milliseconds: 450));
      expect(find.text('SPINNING'), findsOneWidget);
      await tester.pumpAndSettle();

      expect(repository.spinCalls, 1);
      expect(find.text('Spin complete'), findsOneWidget);
      expect(find.text('₹12.50'), findsOneWidget);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.text('₹12.50 subscription credits added'), findsOneWidget);
      expect(find.textContaining('Saved reward: ₹12.50'), findsOneWidget);
    },
  );

  testWidgets(
    'keeps a lost spin response unknown until the server can confirm it',
    (tester) async {
      final repository = _FakeReferralRepository(
        _dashboard(),
        spinError: http.ClientException('response lost'),
      );
      await tester.pumpWidget(_app(repository));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView).first, const Offset(0, -700));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Spin your reward'));
      await tester.pumpAndSettle();
      final action = find.byKey(const Key('referral-spin-action'));
      await tester.ensureVisible(action);
      await tester.pumpAndSettle();
      await tester.tap(action);
      await tester.pumpAndSettle();

      expect(repository.spinCalls, 1);
      expect(
        find.textContaining('Your result may already be saved'),
        findsOneWidget,
      );
      expect(find.text('Check saved result'), findsNWidgets(2));
      expect(find.textContaining('Saved reward:'), findsNothing);
      expect(find.textContaining('subscription credits added'), findsNothing);
      await tester.ensureVisible(action);
      await tester.pumpAndSettle();
      await tester.tap(action);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('There’s no confirmed result yet.'),
        findsOneWidget,
      );
      expect(repository.spinCalls, 1);
    },
  );

  testWidgets('a zero-value result is a completed spin, not a wallet credit', (
    tester,
  ) async {
    final repository = _FakeReferralRepository(
      _dashboard(),
      spinResult: const SpinResult(
        entitlementId: 'own-entitlement',
        spinId: 'spin-zero',
        amount: PaiseAmount(0),
        state: 'completed',
        outcomeId: 'zero',
      ),
    );
    await tester.pumpWidget(_app(repository));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView).first, const Offset(0, -700));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Spin your reward'));
    await tester.pumpAndSettle();
    final action = find.byKey(const Key('referral-spin-action'));
    await tester.ensureVisible(action);
    await tester.pumpAndSettle();
    await tester.tap(action);
    await tester.pumpAndSettle();

    expect(find.text('No credits this time'), findsNWidgets(2));
    expect(find.textContaining('₹0 subscription credits added'), findsNothing);
    expect(repository.spinCalls, 1);
  });

  testWidgets('renders a structured denied state with a retry action', (
    tester,
  ) async {
    final repository = _FakeReferralRepository(
      _dashboard(),
      loadError: ApiException(
        'GET /referrals/v2 failed: 403 {"error":"invitation_required"}',
        userMessage: 'This account cannot access referral rewards.',
      ),
    );
    await tester.pumpWidget(_app(repository));
    await tester.pumpAndSettle();

    expect(
      find.text('This account cannot access referral rewards.'),
      findsOneWidget,
    );
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets(
    'renders offline state without claiming the user has no referrals',
    (tester) async {
      final repository = _FakeReferralRepository(
        _dashboard(),
        loadError: http.ClientException('offline'),
      );
      await tester.pumpWidget(_app(repository));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Something went wrong. Please check your connection and try again.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('No one has joined'), findsNothing);
    },
  );

  testWidgets('labels cached referral data and disables stale spin actions', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(_FakeReferralRepository(_dashboard(stale: true))),
    );
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Offline — showing saved information'),
      findsOneWidget,
    );
    await tester.drag(find.byType(ListView).first, const Offset(0, -700));
    await tester.pumpAndSettle();
    final spinButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Spin your reward'),
    );
    expect(spinButton.onPressed, isNull);
  });
}

Widget _app(_FakeReferralRepository repository) => ProviderScope(
  overrides: [
    referralRepositoryProvider.overrideWith((ref) => repository),
    referralYearProvider.overrideWith((ref) => 2026),
  ],
  child: const MaterialApp(home: InviteFriendsScreen()),
);

ReferralDashboard _dashboard({bool stale = false}) => ReferralDashboard(
  code: 'PANDA26',
  page: const ReferralPage(
    year: 2026,
    joinedCount: 3,
    awardedPaise: 3200,
    rewardsActive: true,
    friends: [
      ReferralFriend(
        id: 'friend-1',
        label: 'Kai',
        state: 'under_review',
        completedDays: 1,
        requiredDays: 3,
      ),
    ],
  ),
  mine: const ReferralMine(
    state: 'in_progress',
    rewardEligible: true,
    completedDays: 2,
    requiredDays: 3,
    inviterAlias: 'Mira',
  ),
  rewards: const [
    RewardEntitlement(id: 'own-entitlement', state: 'ready', role: 'referee'),
  ],
  isStale: stale,
  cachedAt: stale ? DateTime.utc(2026, 10, 21, 10) : null,
);

class _FakeReferralRepository implements ReferralRepository {
  _FakeReferralRepository(
    this.dashboard, {
    this.loadError,
    this.spinError,
    this.spinResult = const SpinResult(
      entitlementId: 'own-entitlement',
      spinId: 'spin-1',
      amount: PaiseAmount(1250),
      state: 'credited',
      outcomeId: 'bucket-1',
      ledgerEntryId: 'entry-1',
    ),
  });

  final ReferralDashboard dashboard;
  final Object? loadError;
  final Object? spinError;
  final SpinResult spinResult;
  int spinCalls = 0;
  int configCalls = 0;

  @override
  Future<ReferralDashboard> loadDashboard({required int year}) async {
    final error = loadError;
    if (error != null) throw error;
    return dashboard;
  }

  @override
  Future<ReferralPage> loadMore({
    required int year,
    required String cursor,
  }) async => const ReferralPage(year: 2026, friends: []);

  @override
  Future<SpinConfiguration> loadSpinConfiguration(String entitlementId) async {
    configCalls++;
    return _spinConfiguration;
  }

  @override
  Future<SpinResult> spin(String entitlementId) async {
    spinCalls++;
    final error = spinError;
    if (error != null) throw error;
    return spinResult;
  }
}

const _spinConfiguration = SpinConfiguration(
  role: 'referee',
  campaignVersion: 'test-v1',
  prizes: [
    SpinPrize(id: 'zero', amount: PaiseAmount(0), weight: 1000),
    SpinPrize(id: 'five', amount: PaiseAmount(500), weight: 2500),
    SpinPrize(id: 'ten', amount: PaiseAmount(1000), weight: 2500),
    SpinPrize(id: 'twenty-five', amount: PaiseAmount(2500), weight: 2000),
    SpinPrize(id: 'fifty', amount: PaiseAmount(5000), weight: 1000),
    SpinPrize(id: 'seventy-five', amount: PaiseAmount(7500), weight: 500),
    SpinPrize(id: 'one-hundred', amount: PaiseAmount(10000), weight: 300),
    SpinPrize(id: 'one-fifty', amount: PaiseAmount(15000), weight: 100),
    SpinPrize(id: 'two-hundred', amount: PaiseAmount(20000), weight: 50),
    SpinPrize(id: 'three-hundred', amount: PaiseAmount(30000), weight: 30),
    SpinPrize(id: 'five-hundred', amount: PaiseAmount(50000), weight: 20),
  ],
);
