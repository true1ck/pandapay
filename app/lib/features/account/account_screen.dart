import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../main.dart' show MoneyText;
import '../auth/login_screen.dart';
import '../insights/payments_due_screen.dart';
import '../notifications/notifications_screen.dart';
import '../referrals/invite_friends_screen.dart';
import '../tools/split_planner_screen.dart';
import '../geofence/nearby_merchants_screen.dart';
import '../settings/feedback_support_screen.dart';
import '../settings/settings_hub_screen.dart';
import '../settings/whats_new_providers.dart';
import '../settings/whats_new_screen.dart';
import '../tools/tools_hub_screen.dart';

/// Design 05 "You · tools & control", over ui-spec.md's H1 Settings Hub.
///
/// Signed out this shows the guest banner rather than a login wall (ui-spec
/// A3); signed in it shows the profile row `GET /profile` returns, the
/// streak card, and then the short list of things design 05 actually puts
/// on this tab.
///
/// **Ten settings rows moved off this screen** into [SettingsHubScreen]
/// (design 20), reached from a single "Settings & security" row. This tab
/// used to carry nineteen rows including two both labelled "Notifications"
/// — one the inbox, one the notification preferences — which is exactly the
/// kind of list the deck's short You is a reaction to. Nothing became
/// unreachable; see that screen for the grouping.
///
/// Per the plan: H2 (Account) owns sign-out and account actions, not this
/// screen — see AccountSettingsScreen.
class AccountScreen extends ConsumerWidget {
  const AccountScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessionInit = ref.watch(sessionInitProvider);
    if (sessionInit.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    final token = ref.watch(accessTokenProvider);

    // Guest/no-account mode (ui-spec.md A3): Tools and Settings below are
    // all local-device features (or, like Import & Sync, self-gate their
    // own remote-only actions) — only the profile header actually needs
    // a signed-in session, so that's the only part that branches here
    // instead of blocking the whole screen behind LoginScreen.
    final profile = token == null
        ? const AsyncValue<Map<String, dynamic>?>.data(null)
        : ref.watch(profileProvider);
    return profile.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) =>
          ErrorState(message: userFacingErrorMessage(err), onRetry: () => ref.invalidate(profileProvider)),
      data: (profileData) => AppBackground(
        child: ListView(
          // Status bar above, nav-pill clearance below — see AppShell.
          padding: EdgeInsets.fromLTRB(
            AppSpace.lg,
            MediaQuery.paddingOf(context).top + AppSpace.lg,
            AppSpace.lg,
            AppShell.navClearance,
          ),
          children: [
            if (token != null) ...[
              _ProfileHero(profile: profileData),
              const SizedBox(height: AppSpace.lg),
              const _StreakCard(),
              const SizedBox(height: AppSpace.xxl),
            ],
            if (token == null)
              Container(
                padding: const EdgeInsets.all(AppSpace.lg),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [BambooInk.slateRaised, BambooInk.slate, BambooInk.slateLow],
                  ),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: token == null
                    ? Row(
                        children: [
                          Container(
                            width: 48,
                            height: 48,
                            decoration: BoxDecoration(
                              color: BambooInk.lime.withValues(alpha: 0.16),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.person_outline_rounded, color: BambooInk.lime, size: 24),
                          ),
                          const SizedBox(width: AppSpace.md),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  "You're browsing as a guest",
                                  style: BambooFonts.heading(15, color: BambooInk.onSlate),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'Sign in to sync across devices',
                                  style: BambooFonts.ui(12.5, color: BambooInk.onSlateMuted),
                                ),
                              ],
                            ),
                          ),
                          FilledButton(
                            style: FilledButton.styleFrom(
                              backgroundColor: BambooInk.lime,
                              foregroundColor: BambooInk.slate,
                              minimumSize: const Size(0, 36),
                              padding: const EdgeInsets.symmetric(horizontal: AppSpace.md),
                              textStyle: BambooFonts.ui(13, weight: FontWeight.w700),
                            ),
                            onPressed: () => Navigator.of(
                              context,
                            ).push(MaterialPageRoute(builder: (_) => const Scaffold(body: LoginScreen()))),
                            child: const Text('Sign in'),
                          ),
                        ],
                      )
                    // Signed in is handled above by _ProfileHero (design 05).
                    : const SizedBox.shrink(),
              ),
            if (token == null) const SizedBox(height: AppSpace.xxl),
            Text(
              'TOOLS',
              style: BambooFonts.ui(
                12,
                weight: FontWeight.w700,
                color: BambooInk.ink500,
              ).copyWith(letterSpacing: 1.1),
            ),
            const SizedBox(height: AppSpace.sm),
            // UA-8 (Chunk 32): foreground-triggered geofencing + home-screen
            // widget entry points — both scoped-down per PROGRESS.md.
            AccountTile(
              icon: Icons.near_me_rounded,
              label: 'Nearby merchants',
              onTap: () => Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const NearbyMerchantsScreen())),
            ),
            const SizedBox(height: AppSpace.sm),
            // UA-5.3 (Chunk 31): built but never wired into any navigation
            // entry point at the time — the building agent's own report
            // flagged this gap explicitly. Fixed here, same pattern as the
            // two UA-8 entries above.
            // Design 05 gives You direct rows for the things a user actually
            // reaches for, not only settings sub-hubs. Notifications (19),
            // Payments due (13), Split planner (11), Invite friends (25) and
            // Report an issue (26) are all screens the deck draws — they
            // were reachable only two or three taps deep, or not at all.
            AccountTile(
              icon: Icons.notifications_none_rounded,
              label: 'Notifications',
              badgeCount: ref.watch(unreadNotificationCountProvider),
              onTap: () =>
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const NotificationsScreen())),
            ),
            const SizedBox(height: AppSpace.sm),
            // Design 05 lists "Payments due" pointing at design 13, which is
            // PaymentsDueScreen — not E8's calendar. The calendar keeps its
            // own entry point on the Insights grid ("Due Dates"): it owns the
            // month view and the per-card reminder toggles, which design 13
            // has no room for.
            AccountTile(
              icon: Icons.event_available_outlined,
              label: 'Payments due',
              onTap: () =>
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PaymentsDueScreen())),
            ),
            const SizedBox(height: AppSpace.sm),
            AccountTile(
              icon: Icons.call_split_rounded,
              label: 'Split planner',
              onTap: () =>
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SplitPlannerScreen())),
            ),
            const SizedBox(height: AppSpace.sm),
            AccountTile(
              icon: Icons.card_giftcard_rounded,
              label: 'Invite friends',
              onTap: () =>
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const InviteFriendsScreen())),
            ),
            const SizedBox(height: AppSpace.sm),
            AccountTile(
              icon: Icons.flag_outlined,
              label: 'Report an issue',
              onTap: () => Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const FeedbackSupportScreen())),
            ),
            const SizedBox(height: AppSpace.sm),
            // Group G (Tools & Modes) — implementation-plan-group-e-f-g.md §4.
            // G4 Emergency Card Info is ALSO reachable without ever landing on
            // this screen (LoginScreen has its own direct link) — see
            // AppRoute.emergencyCardInfo's doc-comment for why.
            AccountTile(
              icon: Icons.travel_explore_outlined,
              label: 'Travel & tools',
              onTap: () =>
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ToolsHubScreen())),
            ),
            const SizedBox(height: AppSpace.xxl),
            Text(
              'SETTINGS',
              style: BambooFonts.ui(
                12,
                weight: FontWeight.w700,
                color: BambooInk.ink500,
              ).copyWith(letterSpacing: 1.1),
            ),
            const SizedBox(height: AppSpace.sm),
            // One row where there used to be ten. Design 05's You is a short
            // list of things you do; everything you configure moved behind
            // design 20's grouped Settings screen — including the second row
            // that used to be called "Notifications" here, which went to
            // notification *settings* rather than the inbox above and was the
            // most confusing thing on this screen.
            AccountTile(
              icon: Icons.settings_outlined,
              label: 'Settings & security',
              onTap: () =>
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsHubScreen())),
            ),
            const SizedBox(height: AppSpace.sm),
            _WhatsNewTile(ref: ref),
          ],
        ),
      ),
    );
  }
}

/// H10's "manual re-read" entry point — the unread-dot lights up using the
/// exact same version comparison `maybeShowWhatsNewSheet` uses, so H1 and
/// the auto-shown sheet never disagree about what counts as "new."
class _WhatsNewTile extends StatelessWidget {
  final WidgetRef ref;
  const _WhatsNewTile({required this.ref});

  @override
  Widget build(BuildContext context) {
    final entries = ref.watch(changelogProvider).valueOrNull ?? const [];
    final lastSeen = ref.watch(lastSeenAppVersionProvider).valueOrNull;
    final hasUnseen = entries.isNotEmpty && (lastSeen == null || entries.first.appVersion != lastSeen);
    return AccountTile(
      icon: Icons.new_releases_outlined,
      label: "What's New",
      trailing: hasUnseen
          ? const StatusPill(label: 'New', foreground: BambooInk.slate, background: BambooInk.lime)
          : null,
      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const WhatsNewScreen())),
    );
  }
}

class AccountTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Widget? trailing;

  /// Unread count for a slate pill on the right — 0 renders nothing rather
  /// than an empty badge.
  final int badgeCount;

  const AccountTile({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.trailing,
    this.badgeCount = 0,
  });

  @override
  Widget build(BuildContext context) {
    // Pressable rather than Material+InkWell: the deck's press state is a
    // 0.98 scale, not a ripple spreading across a tinted-glass row. See
    // app/design/widgets.dart.
    return Pressable(
      onTap: onTap,
      semanticLabel: label,
      child: Container(
        decoration: BoxDecoration(
          color: BambooInk.glassFillOnPaper,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: BambooInk.hairlineOnPaper),
        ),
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg, vertical: AppSpace.md),
        child: Row(
          children: [
            Icon(icon, size: 20, color: BambooInk.ink900),
            const SizedBox(width: AppSpace.md),
            Expanded(
              child: Text(
                label,
                style: BambooFonts.ui(14.5, weight: FontWeight.w500, color: BambooInk.ink900),
              ),
            ),
            if (badgeCount > 0) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: BambooInk.slate,
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                ),
                child: Text(
                  badgeCount > 99 ? '99+' : '$badgeCount',
                  style: BambooFonts.ui(11.5, weight: FontWeight.w700, color: BambooInk.lime),
                ),
              ),
              const SizedBox(width: AppSpace.sm),
            ],
            if (trailing != null) ...[trailing!, const SizedBox(width: AppSpace.sm)],
            const Icon(Icons.chevron_right_rounded, size: 20, color: BambooInk.ink300),
          ],
        ),
      ),
    );
  }
}

/// Design 05's profile card: a slate block with a lime initial tile, the
/// account name, a "N cards · member since YYYY" line, and two stat tiles.
///
/// Every value is real. `display_name`/`email`/`created_at` come off the
/// profiles row; the card count off the wallet; "Lifetime earned" off
/// `GET /home-summary`. "Panda rank" is the one figure the mockup invents —
/// it's derived here from the user's actual logging streak (see
/// [pandaRankFor]), so it's a real measurement rendered with the design's
/// naming rather than a decorative badge.
class _ProfileHero extends ConsumerWidget {
  final Map<String, dynamic>? profile;
  const _ProfileHero({required this.profile});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summary = ref.watch(homeSummaryProvider).valueOrNull;
    final cards = ref.watch(userCardsProvider).valueOrNull ?? const [];

    final displayName = (profile?['display_name'] as String?)?.trim();
    final email = (profile?['email'] as String?)?.trim();
    final name = displayName?.isNotEmpty == true
        ? displayName!
        : (email?.isNotEmpty == true ? email!.split('@').first : 'Your account');

    final createdRaw = profile?['created_at'] as String?;
    final memberSince = createdRaw == null ? null : DateTime.tryParse(createdRaw)?.year;
    final subtitleParts = [
      '${cards.length} card${cards.length == 1 ? '' : 's'}',
      if (memberSince != null) 'member since $memberSince',
    ];

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(color: BambooInk.slate, borderRadius: BorderRadius.circular(30)),
      child: Stack(
        children: [
          Positioned(
            top: -60,
            right: -50,
            child: Container(
              width: 170,
              height: 170,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: BambooInk.lime.withValues(alpha: 0.09),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(AppSpace.xl),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 56,
                      height: 56,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: BambooInk.lime,
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Text(
                        name.characters.first.toUpperCase(),
                        style: BambooFonts.heading(22, weight: FontWeight.w800, color: BambooInk.slate),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name,
                            style: BambooFonts.heading(20, color: BambooInk.onSlate),
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 3),
                          Text(
                            subtitleParts.join(' · '),
                            style: BambooFonts.ui(12.5, color: BambooInk.onSlateMuted),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: _StatTile(
                        label: 'Lifetime earned',
                        // Hidden rather than shown as ₹0 when there's
                        // nothing logged yet — same rule the rest of the app
                        // follows for figures it can't back with a row.
                        value: summary == null || summary.transactionCount == 0
                            ? null
                            : MoneyText(
                                summary.rewardsAllTime,
                                confidence: Confidence.estimated,
                                style: BambooFonts.heading(18, color: BambooInk.lime),
                                hidePaise: true,
                                showConfidenceIcon: false,
                              ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _StatTile(
                        label: 'Panda rank',
                        value: summary == null
                            ? null
                            : Text(
                                pandaRankFor(summary.streakDays),
                                style: BambooFonts.heading(18, color: BambooInk.onSlate),
                              ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One of design 05's two slate-raised stat tiles. [value] is null while
/// there's nothing real to put in it, in which case the tile says so rather
/// than showing a zero.
class _StatTile extends StatelessWidget {
  final String label;
  final Widget? value;
  const _StatTile({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      decoration: BoxDecoration(color: BambooInk.slateRaised, borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: BambooFonts.ui(11.5, color: BambooInk.onSlateMuted)),
          const SizedBox(height: 3),
          value ?? Text('Not yet', style: BambooFonts.heading(18, color: BambooInk.onSlateMuted)),
        ],
      ),
    );
  }
}

/// Design 05 names the rank tiers "Bamboo I..IV" without saying what earns
/// them. They're defined here off the one behaviour the app can actually
/// measure — consecutive days with a logged transaction, the same streak
/// `GET /home-summary` computes — so the badge is a readout, not decoration.
/// The thresholds are the design's own: its mockup pairs a 14-day streak
/// with "Bamboo III" and "7 more days unlocks Bamboo IV".
String pandaRankFor(int streakDays) {
  if (streakDays >= 21) return 'Bamboo IV';
  if (streakDays >= 14) return 'Bamboo III';
  if (streakDays >= 7) return 'Bamboo II';
  return 'Bamboo I';
}

/// The next rank up and the streak it needs, or null at the top tier.
({String rank, int atDays})? nextPandaRank(int streakDays) {
  if (streakDays < 7) return (rank: 'Bamboo II', atDays: 7);
  if (streakDays < 14) return (rank: 'Bamboo III', atDays: 14);
  if (streakDays < 21) return (rank: 'Bamboo IV', atDays: 21);
  return null;
}

/// Design 05's streak card — current streak, current rank badge, what the
/// next rank needs, and a progress bar between the two thresholds.
/// Hidden entirely when there's no streak to report, rather than showing an
/// empty "0-day streak" bar that reads as a broken widget.
class _StreakCard extends ConsumerWidget {
  const _StreakCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summary = ref.watch(homeSummaryProvider).valueOrNull;
    if (summary == null || summary.streakDays == 0) return const SizedBox.shrink();

    final days = summary.streakDays;
    final rank = pandaRankFor(days);
    final next = nextPandaRank(days);
    final floor = next == null ? days : (next.atDays == 7 ? 0 : next.atDays - 7);
    final ceiling = next?.atDays ?? days;
    final progress = ceiling == floor ? 1.0 : ((days - floor) / (ceiling - floor)).clamp(0.0, 1.0);
    final cards = ref.watch(userCardsProvider).valueOrNull ?? const [];

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('$days-day streak', style: BambooFonts.heading(16, color: BambooInk.ink900)),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
                decoration: BoxDecoration(
                  color: BambooInk.rankBadgeBg,
                  border: Border.all(color: BambooInk.rankBadgeBorder),
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                ),
                child: Text(
                  rank.toUpperCase(),
                  style: BambooFonts.ui(
                    11.5,
                    weight: FontWeight.w700,
                    color: BambooInk.rankBadgeInk,
                  ).copyWith(letterSpacing: 0.9),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.sm),
          Text(
            next == null
                ? "You're at the top rank — ${cards.length} card${cards.length == 1 ? '' : 's'} tracked and every day logged."
                : '${next.atDays - days} more day${next.atDays - days == 1 ? '' : 's'} of logging your spends '
                      'unlocks ${next.rank}.',
            style: BambooFonts.ui(13, color: BambooInk.ink300, height: 1.5),
          ),
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.pill),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 9,
              backgroundColor: BambooInk.hairlineOnPaper,
              color: BambooInk.slate,
            ),
          ),
          const SizedBox(height: 7),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('$days days', style: BambooFonts.ui(11.5, color: BambooInk.ink500)),
              Text('$ceiling days', style: BambooFonts.ui(11.5, color: BambooInk.ink500)),
            ],
          ),
        ],
      ),
    );
  }
}
