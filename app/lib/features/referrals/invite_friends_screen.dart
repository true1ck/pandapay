import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/referral_repository.dart';
import 'reward_spin_dialog.dart';
import '../subscription_credits/subscription_credits_screen.dart';

TextStyle get _eyebrow => BambooFonts.ui(
  11.5,
  weight: FontWeight.w700,
  color: BambooInk.ink500,
).copyWith(letterSpacing: 1.2);

class InviteFriendsScreen extends ConsumerStatefulWidget {
  const InviteFriendsScreen({super.key});

  @override
  ConsumerState<InviteFriendsScreen> createState() =>
      _InviteFriendsScreenState();
}

class _InviteFriendsScreenState extends ConsumerState<InviteFriendsScreen>
    with WidgetsBindingObserver {
  String? _spinningEntitlementId;
  String? _checkingEntitlementId;
  String? _spinError;
  SpinResult? _lastSpin;
  bool _loadingMore = false;
  String? _loadMoreError;
  final List<ReferralFriend> _additionalFriends = [];
  String? _nextReferralCursor;
  int? _cursorYear;
  bool _cursorInitialized = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      _refresh(ref.read(referralYearProvider));
    }
  }

  Future<void> _refresh(int year) async {
    ref.invalidate(referralDashboardProvider(year));
    try {
      await ref.read(referralDashboardProvider(year).future);
    } catch (_) {
      // The AsyncValue below owns the visible error state.
    }
  }

  Future<void> _openSpinGame(RewardEntitlement entitlement, int year) async {
    final repository = ref.read(referralRepositoryProvider);
    if (repository == null || _spinningEntitlementId != null) return;
    await showDialog<SpinResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) => RewardSpinDialog(
        loadConfiguration: () =>
            repository.loadSpinConfiguration(entitlement.id),
        onSpin: () => _spin(entitlement, year),
        onCheckResult: () => _checkSpin(entitlement, year),
      ),
    );
  }

  Future<SpinResult?> _spin(RewardEntitlement entitlement, int year) async {
    final repository = ref.read(referralRepositoryProvider);
    if (repository == null || _spinningEntitlementId != null) return null;
    final namespace = ref.read(cacheNamespaceProvider);
    setState(() {
      _spinningEntitlementId = entitlement.id;
      _checkingEntitlementId = null;
      _spinError = null;
    });

    try {
      final result = await repository.spin(entitlement.id);
      if (!mounted || ref.read(cacheNamespaceProvider) != namespace) return null;
      setState(() => _lastSpin = result);
      ref.invalidate(referralDashboardProvider(year));
      ref.invalidate(subscriptionCreditDataProvider);
      return result;
    } catch (error) {
      // A lost response may follow a committed spin. Read canonical server
      // state before presenting a retry path; never animate or invent a value.
      RewardEntitlement? committed;
      try {
        final refreshed = await repository.loadDashboard(year: year);
        for (final candidate in refreshed.rewards) {
          if (candidate.id == entitlement.id && candidate.result != null) {
            committed = candidate;
            break;
          }
        }
        ref.invalidate(referralDashboardProvider(year));
        if (committed != null) ref.invalidate(subscriptionCreditDataProvider);
      } catch (_) {
        // Keep the outcome explicitly unknown until the user can check again.
      }
      if (!mounted || ref.read(cacheNamespaceProvider) != namespace) return null;
      setState(() {
        if (committed?.result != null) {
          _lastSpin = committed!.result;
          _checkingEntitlementId = null;
          _spinError = null;
        } else if (isTransientNetworkFailure(error)) {
          _checkingEntitlementId = entitlement.id;
          _spinError =
              'We could not confirm the result. Check the saved reward '
              'before trying again.';
        } else {
          _spinError = userFacingErrorMessage(error);
        }
      });
      if (committed?.result != null) return committed!.result;
      return null;
    } finally {
      if (mounted) setState(() => _spinningEntitlementId = null);
    }
  }

  Future<SpinResult?> _checkSpin(
    RewardEntitlement entitlement,
    int year,
  ) async {
    setState(() {
      _checkingEntitlementId = entitlement.id;
      _spinError = null;
    });
    await _refresh(year);
    final dashboard = ref.read(referralDashboardProvider(year)).valueOrNull;
    final saved = dashboard?.rewards
        .where((item) => item.id == entitlement.id)
        .firstOrNull
        ?.result;
    if (!mounted) return null;
    if (saved != null) {
      setState(() {
        _lastSpin = saved;
        _checkingEntitlementId = null;
        _spinError = null;
      });
      ref.invalidate(subscriptionCreditDataProvider);
      return saved;
    }
    setState(() {
      if (dashboard?.isStale ?? false) {
        _checkingEntitlementId = null;
        _spinError =
            'Still offline. Reconnect before checking or spinning this reward.';
      } else {
        _spinError =
            'There is no confirmed result yet. You can check again later.';
      }
    });
    return null;
  }

  Future<void> _loadMore(
    int year,
    String cursor, {
    required Set<String> existingIds,
  }) async {
    final repository = ref.read(referralRepositoryProvider);
    if (repository == null || _loadingMore) return;
    final namespace = ref.read(cacheNamespaceProvider);
    setState(() {
      _loadingMore = true;
      _loadMoreError = null;
    });
    try {
      final page = await repository.loadMore(year: year, cursor: cursor);
      if (!mounted || ref.read(cacheNamespaceProvider) != namespace) return;
      final seen = {
        ...existingIds,
        ..._additionalFriends.map((item) => item.id),
      };
      setState(() {
        _nextReferralCursor = page.nextCursor;
        _additionalFriends.addAll(
          page.friends.where((friend) => seen.add(friend.id)),
        );
      });
    } catch (error) {
      if (mounted) {
        setState(() => _loadMoreError = userFacingErrorMessage(error));
      }
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<String>(cacheNamespaceProvider, (previous, next) {
      if (previous == null || previous == next || !mounted) return;
      setState(() {
        _lastSpin = null;
        _spinningEntitlementId = null;
        _checkingEntitlementId = null;
        _spinError = null;
        _additionalFriends.clear();
        _nextReferralCursor = null;
        _cursorYear = null;
        _cursorInitialized = false;
      });
      ref.invalidate(referralDashboardProvider(ref.read(referralYearProvider)));
      ref.invalidate(subscriptionCreditDataProvider);
    });
    final repository = ref.watch(referralRepositoryProvider);
    final year = ref.watch(referralYearProvider);

    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text(
          'Invite friends',
          style: BambooFonts.heading(19, color: BambooInk.ink900),
        ),
        actions: [
          IconButton(
            tooltip: 'Subscription credits',
            icon: const Icon(Icons.account_balance_wallet_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const SubscriptionCreditsScreen(),
              ),
            ),
          ),
        ],
      ),
      body: AppBackground(
        child: repository == null
            ? const EmptyState(
                icon: Icons.card_giftcard_rounded,
                title: 'Sign in to view invites',
                message:
                    'Your invite code and reward progress are tied to your account.',
              )
            : ref
                  .watch(referralDashboardProvider(year))
                  .when(
                    loading: () =>
                        const Center(child: CircularProgressIndicator()),
                    error: (error, _) => ErrorState(
                      message: userFacingErrorMessage(error),
                      onRetry: () =>
                          ref.invalidate(referralDashboardProvider(year)),
                    ),
                    data: (dashboard) => dashboard == null
                        ? const EmptyState(
                            icon: Icons.card_giftcard_rounded,
                            title: 'Sign in to view invites',
                            message:
                                'Your invite code and reward progress are tied to your account.',
                          )
                        : _buildDashboard(context, dashboard, year),
                  ),
      ),
    );
  }

  Widget _buildDashboard(
    BuildContext context,
    ReferralDashboard dashboard,
    int year,
  ) {
    if (!_cursorInitialized || _cursorYear != year) {
      _cursorInitialized = true;
      _cursorYear = year;
      _nextReferralCursor = dashboard.page.nextCursor;
    }
    final friends = [...dashboard.page.friends, ..._additionalFriends];
    final readyRewards = dashboard.rewards
        .where((item) => item.isReady)
        .toList();
    final visibleRewards = dashboard.rewards
        .where((item) => item.isReady || item.isHeld || item.result != null)
        .toList();
    final shareLink = dashboard.code == null
        ? null
        : 'https://pandapay.app/i/${dashboard.code}';

    return RefreshIndicator(
      onRefresh: () => _refresh(year),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 32),
        children: [
          if (dashboard.isStale) ...[
            _StaleDataNotice(cachedAt: dashboard.cachedAt),
            const SizedBox(height: 12),
          ],
          _InviteCodeCard(
            code: dashboard.code,
            link: shareLink,
            rewardsActive: dashboard.page.rewardsActive,
          ),
          const SizedBox(height: 18),
          _YearTotals(
            year: year,
            joinedCount: dashboard.page.joinedCount,
            awardedPaise: dashboard.page.awardedPaise,
            onYearChanged: (nextYear) {
              setState(() {
                _additionalFriends.clear();
                _loadMoreError = null;
                _nextReferralCursor = null;
                _cursorInitialized = false;
              });
              ref.read(referralYearProvider.notifier).state = nextYear;
            },
          ),
          if (dashboard.mine != null) ...[
            const SizedBox(height: 18),
            _MyProgressCard(mine: dashboard.mine!),
          ],
          if (visibleRewards.isNotEmpty) ...[
            const SizedBox(height: 18),
            Text('YOUR REWARDS', style: _eyebrow),
            const SizedBox(height: 9),
            for (final reward in visibleRewards)
              _RewardCard(
                entitlement: reward,
                confirmedResult: _lastSpin?.entitlementId == reward.id
                    ? _lastSpin
                    : null,
                spinning: _spinningEntitlementId == reward.id,
                checking: _checkingEntitlementId == reward.id,
                onSpin: reward.isReady && !dashboard.isStale
                    ? () => _openSpinGame(reward, year)
                    : null,
                onCheck: _checkingEntitlementId == reward.id
                    ? () => _checkSpin(reward, year)
                    : null,
              ),
            if (_lastSpin != null) ...[
              const SizedBox(height: 6),
              _ConfirmedSpinBanner(result: _lastSpin!),
            ],
            if (_spinError != null) ...[
              const SizedBox(height: 8),
              Text(
                _spinError!,
                style: BambooFonts.ui(13, color: BambooInk.clay),
              ),
            ],
          ],
          const SizedBox(height: 22),
          Row(
            children: [
              Expanded(child: Text('FRIENDS', style: _eyebrow)),
              Text(
                '${friends.length} shown',
                style: BambooFonts.ui(12, color: BambooInk.ink500),
              ),
            ],
          ),
          const SizedBox(height: 9),
          if (friends.isEmpty)
            _InfoCard(
              child: Text(
                'No one has joined through your code for $year yet. A shared link alone does not '
                'count as a join; PandaPay lists someone after their account is confirmed.',
                style: BambooFonts.ui(
                  13,
                  color: BambooInk.ink500,
                  height: 1.45,
                ),
              ),
            )
          else
            for (final friend in friends) _FriendRow(friend: friend),
          if (_nextReferralCursor != null) ...[
            if (_loadMoreError != null) ...[
              const SizedBox(height: 6),
              Text(
                _loadMoreError!,
                style: BambooFonts.ui(12.5, color: BambooInk.clay),
              ),
            ],
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: _loadingMore
                  ? null
                  : () => _loadMore(
                      year,
                      _nextReferralCursor!,
                      existingIds: friends.map((friend) => friend.id).toSet(),
                    ),
              child: Text(_loadingMore ? 'Loading…' : 'Load more friends'),
            ),
          ],
          if (dashboard.page.asOf != null) ...[
            const SizedBox(height: 12),
            Text(
              'Progress confirmed ${_dateLabel(dashboard.page.asOf!)}',
              textAlign: TextAlign.center,
              style: BambooFonts.ui(11.5, color: BambooInk.ink500),
            ),
          ],
          if (readyRewards.isNotEmpty) ...[
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const SubscriptionCreditsScreen(),
                ),
              ),
              icon: const Icon(Icons.account_balance_wallet_outlined),
              label: const Text('View subscription credits'),
            ),
          ],
        ],
      ),
    );
  }
}

class _InviteCodeCard extends StatelessWidget {
  const _InviteCodeCard({
    required this.code,
    required this.link,
    required this.rewardsActive,
  });

  final String? code;
  final String? link;
  final bool? rewardsActive;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: BambooInk.slate,
        borderRadius: BorderRadius.circular(26),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Icon(
            Icons.diversity_3_rounded,
            size: 32,
            color: BambooInk.lime,
          ),
          const SizedBox(height: 10),
          Text(
            'Invite friends to PandaPay',
            textAlign: TextAlign.center,
            style: BambooFonts.heading(20, color: BambooInk.paper),
          ),
          const SizedBox(height: 7),
          Text(
            switch (rewardsActive) {
              false =>
                'Your invite code is available. Referral rewards are currently paused.',
              true =>
                'Eligible invites can unlock a separate reward spin for each person after '
                    'the Bamboo milestone.',
              _ =>
                'Share your code. PandaPay confirms each join, progress step and reward here.',
            },
            textAlign: TextAlign.center,
            style: BambooFonts.ui(
              13,
              color: BambooInk.onSlateSubtle,
              height: 1.45,
            ),
          ),
          if (code != null) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.fromLTRB(15, 9, 8, 9),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(15),
                border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: SelectableText(
                      code!,
                      style: BambooFonts.heading(
                        17,
                        color: BambooInk.lime,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Copy invite code',
                    color: BambooInk.paper,
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: code!));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Invite code copied.')),
                        );
                      }
                    },
                    icon: const Icon(Icons.copy_rounded),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: link == null
                  ? null
                  : () => SharePlus.instance.share(
                      ShareParams(
                        subject: 'Try PandaPay',
                        text: 'Try PandaPay with my invite code $code: $link',
                      ),
                    ),
              style: FilledButton.styleFrom(
                backgroundColor: BambooInk.lime,
                foregroundColor: BambooInk.slate,
                minimumSize: const Size.fromHeight(48),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(15),
                ),
              ),
              icon: const Icon(Icons.ios_share_rounded),
              label: const Text('Share invite link'),
            ),
          ] else ...[
            const SizedBox(height: 12),
            Text(
              'Invite code unavailable. Refresh to try again.',
              textAlign: TextAlign.center,
              style: BambooFonts.ui(12.5, color: BambooInk.onSlateSubtle),
            ),
          ],
        ],
      ),
    );
  }
}

class _YearTotals extends StatelessWidget {
  const _YearTotals({
    required this.year,
    required this.joinedCount,
    required this.awardedPaise,
    required this.onYearChanged,
  });

  final int year;
  final int? joinedCount;
  final int? awardedPaise;
  final ValueChanged<int> onYearChanged;

  @override
  Widget build(BuildContext context) {
    final currentYear = _currentCampaignYear;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text('YEARLY ACTIVITY', style: _eyebrow)),
            DropdownButton<int>(
              value: year,
              underline: const SizedBox.shrink(),
              items: [
                for (var value = currentYear;
                    value >= (currentYear - 4).clamp(2026, currentYear);
                    value--)
                  DropdownMenuItem(value: value, child: Text('$value')),
              ],
              onChanged: (value) {
                if (value != null) onYearChanged(value);
              },
            ),
          ],
        ),
        Row(
          children: [
            Expanded(
              child: _MetricCard(
                title: 'Joined in $year',
                value: joinedCount?.toString() ?? '—',
                icon: Icons.person_add_alt_1_rounded,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _MetricCard(
                title: 'Credits awarded in $year',
                value: awardedPaise == null
                    ? '—'
                    : PaiseAmount(awardedPaise!).inr,
                icon: Icons.card_giftcard_rounded,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.title,
    required this.value,
    required this.icon,
  });

  final String title;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) => _InfoCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: BambooInk.jade, size: 19),
        const SizedBox(height: 8),
        Text(value, style: BambooFonts.heading(18, color: BambooInk.ink900)),
        const SizedBox(height: 2),
        Text(title, style: BambooFonts.ui(11.5, color: BambooInk.ink500)),
      ],
    ),
  );
}

class _MyProgressCard extends StatelessWidget {
  const _MyProgressCard({required this.mine});

  final ReferralMine mine;

  @override
  Widget build(BuildContext context) {
    final showProgress =
        mine.rewardEligible &&
        (mine.state == 'joined' ||
            mine.state == 'signed_up' ||
            mine.state == 'pending' ||
            mine.state == 'in_progress' ||
            mine.state == 'bamboo' ||
            mine.state == 'progress');
    return _InfoCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('YOUR INVITE PROGRESS', style: _eyebrow),
          const SizedBox(height: 8),
          Text(
            mine.displayState,
            style: BambooFonts.heading(17, color: BambooInk.ink900),
          ),
          if (mine.inviterAlias != null) ...[
            const SizedBox(height: 3),
            Text(
              'Invited by ${mine.inviterAlias}',
              style: BambooFonts.ui(12.5, color: BambooInk.ink500),
            ),
          ],
          if (showProgress) ...[
            const SizedBox(height: 12),
            Text(
              'Bamboo ${mine.completedDays}/${mine.requiredDays} days',
              style: BambooFonts.ui(
                14,
                weight: FontWeight.w700,
                color: BambooInk.ink900,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 7,
              children: [
                for (var day = 0; day < mine.requiredDays; day++)
                  Container(
                    key: ValueKey('milestone-day-${day + 1}'),
                    width: 23,
                    height: 8,
                    decoration: BoxDecoration(
                      color: day < mine.completedDays
                          ? BambooInk.lime
                          : BambooInk.paperMuted,
                      borderRadius: BorderRadius.circular(5),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'PandaPay confirms eligible app-use days. Opening the app or importing old '
              'transactions does not add a day.',
              style: BambooFonts.ui(12, color: BambooInk.ink500, height: 1.4),
            ),
          ] else if (mine.state == 'access_only') ...[
            const SizedBox(height: 5),
            Text(
              'This invitation grants account access only; it has no reward milestone.',
              style: BambooFonts.ui(12.5, color: BambooInk.ink500),
            ),
          ],
          if (mine.deadlineAt != null) ...[
            const SizedBox(height: 8),
            Text(
              'Complete by ${_campaignDateLabel(mine.deadlineAt!)} IST',
              style: BambooFonts.ui(11.5, color: BambooInk.ink500),
            ),
          ],
        ],
      ),
    );
  }
}

class _RewardCard extends StatelessWidget {
  const _RewardCard({
    required this.entitlement,
    required this.confirmedResult,
    required this.spinning,
    required this.checking,
    required this.onSpin,
    required this.onCheck,
  });

  final RewardEntitlement entitlement;
  final SpinResult? confirmedResult;
  final bool spinning;
  final bool checking;
  final VoidCallback? onSpin;
  final VoidCallback? onCheck;

  @override
  Widget build(BuildContext context) {
    final result = entitlement.result ?? confirmedResult;
    return _InfoCard(
      margin: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.card_giftcard_rounded, color: BambooInk.jade),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  entitlement.role == 'referee'
                      ? 'Your invite reward'
                      : 'Your referral reward',
                  style: BambooFonts.heading(15, color: BambooInk.ink900),
                ),
              ),
              Text(
                entitlement.state.replaceAll('_', ' '),
                style: BambooFonts.ui(11.5, color: BambooInk.ink500),
              ),
            ],
          ),
          if (result != null) ...[
            const SizedBox(height: 8),
            Text(
              result.amount.value == 0
                  ? 'No credits this time'
                  : '${result.amount.inr} subscription credits added',
              style: BambooFonts.ui(
                14,
                weight: FontWeight.w700,
                color: BambooInk.jade,
              ),
              semanticsLabel: result.amount.value == 0
                  ? 'No subscription credits were awarded this time'
                  : '${result.amount.inr} subscription credits added',
            ),
          ] else if (entitlement.isHeld) ...[
            const SizedBox(height: 7),
            Text(
              'This reward is under review. The amount will appear only after PandaPay confirms it.',
              style: BambooFonts.ui(12.5, color: BambooInk.ink500, height: 1.4),
            ),
          ] else if (entitlement.isReady) ...[
            const SizedBox(height: 9),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: BambooInk.slate,
                foregroundColor: BambooInk.lime,
                padding: const EdgeInsets.symmetric(
                  horizontal: 17,
                  vertical: 13,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(15),
                ),
              ),
              onPressed: spinning || checking ? null : onSpin,
              icon: spinning
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.casino_outlined),
              label: Text(
                spinning
                    ? 'Saving your spin…'
                    : checking
                    ? 'Checking your reward…'
                    : 'Spin your reward',
              ),
            ),
            if (checking) ...[
              const SizedBox(height: 6),
              TextButton(
                onPressed: onCheck,
                child: const Text('Check saved result'),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class _ConfirmedSpinBanner extends StatelessWidget {
  const _ConfirmedSpinBanner({required this.result});

  final SpinResult result;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: BambooInk.wash,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        'Saved reward: ${result.amount.inr} subscription credits. Your result is stored with your account.',
        style: BambooFonts.ui(
          13,
          weight: FontWeight.w600,
          color: BambooInk.ink900,
        ),
      ),
    ),
  );
}

class _FriendRow extends StatelessWidget {
  const _FriendRow({required this.friend});

  final ReferralFriend friend;

  @override
  Widget build(BuildContext context) => _InfoCard(
    margin: const EdgeInsets.only(bottom: 8),
    child: Row(
      children: [
        Container(
          width: 34,
          height: 34,
          alignment: Alignment.center,
          decoration: const BoxDecoration(
            color: BambooInk.paperMuted,
            shape: BoxShape.circle,
          ),
          child: Text(
            (friend.label?.characters.firstOrNull ?? '•').toUpperCase(),
            style: BambooFonts.heading(14, color: BambooInk.ink700),
          ),
        ),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                friend.label?.isNotEmpty == true
                    ? friend.label!
                    : 'Invited friend',
                style: BambooFonts.ui(
                  14,
                  weight: FontWeight.w600,
                  color: BambooInk.ink900,
                ),
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              if (friend.completedDays != null && friend.requiredDays != null)
                Text(
                  'Bamboo ${friend.completedDays}/${friend.requiredDays} days',
                  style: BambooFonts.ui(11.5, color: BambooInk.ink500),
                )
              else
                Text(
                  friend.displayState,
                  style: BambooFonts.ui(11.5, color: BambooInk.ink500),
                ),
            ],
          ),
        ),
        if (friend.completedDays != null && friend.requiredDays != null)
          Text(
            friend.displayState,
            style: BambooFonts.ui(11, color: BambooInk.ink500),
          ),
      ],
    ),
  );
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.child, this.margin});

  final Widget child;
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) => Container(
    margin: margin,
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: BambooInk.glassFillOnPaper,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: BambooInk.hairlineOnPaper),
    ),
    child: child,
  );
}

class _StaleDataNotice extends StatelessWidget {
  const _StaleDataNotice({required this.cachedAt});

  final DateTime? cachedAt;

  @override
  Widget build(BuildContext context) => _InfoCard(
    child: Text(
      cachedAt == null
          ? 'Offline — showing saved referral information. Reconnect to confirm current progress and reward status.'
          : 'Offline — showing saved information from ${_dateLabel(cachedAt!)}. Reconnect to confirm current progress and reward status.',
      style: BambooFonts.ui(12.5, color: BambooInk.ink700, height: 1.4),
    ),
  );
}

String _dateLabel(DateTime date) =>
    '${date.toLocal().day}/${date.toLocal().month}/${date.toLocal().year}';

int get _currentCampaignYear =>
    DateTime.now().toUtc().add(const Duration(hours: 5, minutes: 30)).year;

String _campaignDateLabel(DateTime date) {
  final india = date.toUtc().add(const Duration(hours: 5, minutes: 30));
  return '${india.day}/${india.month}/${india.year}';
}
