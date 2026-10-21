import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay/app/design/app_theme.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/referral_repository.dart';
import 'package:pandapay/features/referrals/invite_friends_screen.dart';

/// Launch this disposable, synthetic referral preview with:
/// `flutter run --flavor staging -t tool/referral_showcase.dart`
///
/// It mounts the production referral screen against an in-memory repository;
/// no account, API, database, or reward ledger is read or changed.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    ProviderScope(
      overrides: [
        referralRepositoryProvider.overrideWith(
          (ref) => _ShowcaseReferralRepository(),
        ),
        referralYearProvider.overrideWith((ref) => 2026),
      ],
      child: const _ReferralShowcaseApp(),
    ),
  );
}

class _ReferralShowcaseApp extends StatelessWidget {
  const _ReferralShowcaseApp();

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.light(),
    home: Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            const _SyntheticDataBanner(),
            const Expanded(child: InviteFriendsScreen()),
          ],
        ),
      ),
    ),
  );
}

class _SyntheticDataBanner extends StatelessWidget {
  const _SyntheticDataBanner();

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
    color: BambooInk.slate,
    child: Text(
      'PREVIEW ONLY · Synthetic referrals; no real credits are issued',
      textAlign: TextAlign.center,
      style: BambooFonts.ui(
        10.5,
        weight: FontWeight.w600,
        color: BambooInk.lime,
      ),
    ),
  );
}

class _ShowcaseReferralRepository implements ReferralRepository {
  bool _readyRewardSpun = false;

  static const _spin = SpinResult(
    entitlementId: 'demo-ready-entitlement',
    spinId: 'demo-spin-1',
    amount: PaiseAmount(2500),
    state: 'credited',
    outcomeId: 'twenty-five',
    ledgerEntryId: 'demo-ledger-entry',
  );

  @override
  Future<ReferralDashboard> loadDashboard({required int year}) async {
    return ReferralDashboard(
      code: 'DEMO26',
      page: ReferralPage(
        year: year,
        joinedCount: 6,
        awardedPaise: _readyRewardSpun ? 2500 : 1250,
        rewardsActive: true,
        asOf: DateTime.utc(2026, 10, 21, 6, 30),
        friends: [
          const ReferralFriend(
            id: 'sample-joined',
            label: 'Example friend 01 · joined',
            state: 'joined',
            completedDays: 0,
            requiredDays: 3,
          ),
          const ReferralFriend(
            id: 'sample-day-one',
            label: 'Example friend 02 · day 1',
            state: 'in_progress',
            completedDays: 1,
            requiredDays: 3,
          ),
          const ReferralFriend(
            id: 'sample-day-two',
            label: 'Example friend 03 · day 2',
            state: 'in_progress',
            completedDays: 2,
            requiredDays: 3,
          ),
          ReferralFriend(
            id: 'sample-complete',
            label: _readyRewardSpun
                ? 'Example friend 04 · credited'
                : 'Example friend 04 · milestone',
            state: _readyRewardSpun ? 'credited' : 'milestone_complete',
            completedDays: 3,
            requiredDays: 3,
          ),
          const ReferralFriend(
            id: 'sample-review',
            label: 'Example friend 05 · review',
            state: 'under_review',
            completedDays: 3,
            requiredDays: 3,
          ),
          const ReferralFriend(
            id: 'sample-credited',
            label: 'Example friend 06 · credited',
            state: 'credited',
            completedDays: 3,
            requiredDays: 3,
          ),
        ],
      ),
      mine: null,
      rewards: [
        const RewardEntitlement(
          id: 'demo-held-entitlement',
          state: 'under_review',
          role: 'referrer',
        ),
        RewardEntitlement(
          id: 'demo-ready-entitlement',
          state: _readyRewardSpun ? 'credited' : 'ready',
          role: 'referrer',
          result: _readyRewardSpun ? _spin : null,
        ),
        const RewardEntitlement(
          id: 'demo-credited-entitlement',
          state: 'credited',
          role: 'referrer',
          result: SpinResult(
            entitlementId: 'demo-credited-entitlement',
            spinId: 'demo-spin-saved',
            amount: PaiseAmount(1250),
            state: 'credited',
            outcomeId: 'demo-outcome-saved',
            ledgerEntryId: 'demo-ledger-saved',
          ),
        ),
      ],
    );
  }

  @override
  Future<ReferralPage> loadMore({
    required int year,
    required String cursor,
  }) async => ReferralPage(year: year, friends: const []);

  @override
  Future<SpinConfiguration> loadSpinConfiguration(String entitlementId) async =>
      const SpinConfiguration(
        role: 'inviter',
        campaignVersion: 'bamboo-spin-v1-2026-10',
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
          SpinPrize(
            id: 'three-hundred',
            amount: PaiseAmount(30000),
            weight: 30,
          ),
          SpinPrize(id: 'five-hundred', amount: PaiseAmount(50000), weight: 20),
        ],
      );

  @override
  Future<SpinResult> spin(String entitlementId) async {
    if (entitlementId != _spin.entitlementId) {
      throw StateError('Unknown synthetic showcase reward.');
    }
    _readyRewardSpun = true;
    return _spin;
  }
}
