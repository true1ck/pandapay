import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/offline_banner.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/user_cards_repository.dart';
import '../../main.dart' show MoneyText;
import 'billing_float_screen.dart' show assumedGracePeriodDays;

/// One card's upcoming statement, as design 13 "Payments due" lists it.
class DuePayment {
  final UserCard card;
  final DateTime dueOn;
  final int daysUntilDue;

  /// Spend **logged in PandaPay** since this card's last statement date —
  /// NOT the issuer's statement balance.
  ///
  /// The distinction matters enough to be in the type's name-adjacent
  /// docs: PandaPay never sees a real statement. This sums the
  /// transactions the user logged or imported, so it misses anything they
  /// paid on the card without telling the app, and it includes nothing
  /// carried over from a previous cycle. The screen must always label it
  /// as logged spend and mark it [Confidence.estimated] — presenting it as
  /// "amount due" would be a lie that costs the user a late fee when the
  /// real balance is higher.
  final Money loggedThisCycle;

  const DuePayment({
    required this.card,
    required this.dueOn,
    required this.daysUntilDue,
    required this.loggedThisCycle,
  });

  /// Whether this card is at real risk of a late fee: the user hasn't told
  /// us autopay covers the full statement. [AutopayMode.minimum] still
  /// counts as at-risk for interest, but not for a late mark — the screen
  /// words those two differently.
  bool get needsAttention => !card.autopayMode.coversFullStatement;
}

/// Design 13's list, soonest first.
///
/// Cards with no `due_day` set are omitted entirely rather than shown with
/// a guessed date — the same rule E8's calendar already follows. That is a
/// real gap the user can close from Edit Card, not something to paper over.
final paymentsDueProvider = FutureProvider<List<DuePayment>>((ref) async {
  final repo = ref.watch(userCardsRepositoryProvider);
  final cards = ref.watch(myCardsProvider).valueOrNull ?? const <UserCard>[];
  final now = ref.watch(clockProvider).now();
  final today = DateTime(now.year, now.month, now.day);

  final active = cards.where((c) => !c.isArchived && c.dueDay != null).toList();
  if (active.isEmpty) return const [];

  // One fetch for the widest cycle any card could need, then bucketed
  // per-card below — rather than one request per card.
  final earliestCycleStart = DateTime(now.year, now.month - 2, 1);
  final transactions = repo == null
      ? const <TransactionEntry>[]
      : await repo.fetchTransactions(from: earliestCycleStart);

  final rows = <DuePayment>[];
  for (final card in active) {
    final dueOn = nextOccurrenceOf(card.dueDay!, today);
    final cycleStart = card.statementDay == null ? null : previousOccurrenceOf(card.statementDay!, today);

    var logged = const Money.zero();
    if (cycleStart != null) {
      for (final txn in transactions) {
        if (txn.status != 'active') continue;
        if (txn.userCardId != card.id) continue;
        if (txn.occurredAt.isBefore(cycleStart)) continue;
        logged += txn.amount;
      }
    }

    rows.add(
      DuePayment(
        card: card,
        dueOn: dueOn,
        daysUntilDue: dueOn.difference(today).inDays,
        loggedThisCycle: logged,
      ),
    );
  }

  rows.sort((a, b) => a.dueOn.compareTo(b.dueOn));
  return rows;
});

/// The next date on or after [from] falling on day-of-month [day], clamped
/// into short months (a due day of 31 lands on the 30th in April, and on
/// the 28th/29th in February — issuers roll the same way).
DateTime nextOccurrenceOf(int day, DateTime from) {
  final thisMonth = _clampToMonth(from.year, from.month, day);
  if (!thisMonth.isBefore(from)) return thisMonth;
  return _clampToMonth(from.year, from.month + 1, day);
}

/// The most recent date on or before [from] falling on day-of-month [day].
DateTime previousOccurrenceOf(int day, DateTime from) {
  final thisMonth = _clampToMonth(from.year, from.month, day);
  if (!thisMonth.isAfter(from)) return thisMonth;
  return _clampToMonth(from.year, from.month - 1, day);
}

DateTime _clampToMonth(int year, int month, int day) {
  final lastDayOfMonth = DateTime(year, month + 1, 0).day;
  return DateTime(year, month, day > lastDayOfMonth ? lastDayOfMonth : day);
}

/// Design 13 "Payments due · pay on time, buy on time".
///
/// Replaces the split the app had before, where the same question was
/// answered across two screens: E8's Due Date Calendar (when things are
/// due) and E7's Billing Cycle Float (when it's cheapest to buy). The deck
/// puts both on one screen because they are one decision — this is the
/// screen you open before a big purchase.
///
/// **What this screen cannot say.** Design 13 shows a statement amount
/// ("₹18,420"), a minimum due ("₹920") and a late fee ("₹500 + interest at
/// 42% p.a."). None of the three exist anywhere in this system: PandaPay is
/// read-only by design, never sees a statement, and no schema column holds
/// a minimum-due or late-fee term. Rather than invent them, this shows what
/// is real — the due date, the spend the user has logged this cycle
/// (explicitly labelled as that, see [DuePayment.loggedThisCycle]), and the
/// autopay answer the user gave us — and says plainly that the issuer's
/// balance may be higher. A screen that displayed a fabricated "₹18,420
/// due" would be worse than no screen at a moment when the cost of being
/// wrong is a late fee.
class PaymentsDueScreen extends ConsumerWidget {
  const PaymentsDueScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final due = ref.watch(paymentsDueProvider);

    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text('Payments due', style: BambooFonts.heading(18, color: BambooInk.ink900)),
      ),
      body: AppBackground(
        child: Column(
          children: [
            OfflineBanner(gutter: AppSpace.lg, onRetry: () => ref.invalidate(paymentsDueProvider)),
            Expanded(
              child: due.when(
                loading: () => const Padding(
                  padding: EdgeInsets.symmetric(horizontal: AppSpace.lg),
                  child: SkeletonList(count: 3),
                ),
                error: (err, _) => ErrorState(
                  message: userFacingErrorMessage(err),
                  onRetry: () => ref.invalidate(paymentsDueProvider),
                ),
                data: (rows) => rows.isEmpty
                    ? const EmptyState(
                        icon: Icons.event_available_outlined,
                        title: 'No due dates set',
                        message:
                            'Add a due day to a card from Edit Card and its statement '
                            'shows up here.',
                      )
                    : _DueList(rows: rows),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DueList extends StatelessWidget {
  final List<DuePayment> rows;
  const _DueList({required this.rows});

  @override
  Widget build(BuildContext context) {
    final soonest = rows.first;
    final rest = rows.skip(1).toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(AppSpace.lg, AppSpace.lg, AppSpace.lg, AppSpace.xxl),
      children: [
        _SoonestCard(row: soonest),
        if (rest.isNotEmpty) ...[
          const SizedBox(height: AppSpace.xl),
          Text('Coming up', style: BambooFonts.heading(17, color: BambooInk.ink900)),
          const SizedBox(height: AppSpace.sm),
          for (final row in rest)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.sm),
              child: _ComingUpRow(row: row),
            ),
        ],
        const SizedBox(height: AppSpace.xl),
        _FreeMoneyCard(rows: rows),
      ],
    );
  }
}

/// Design 13's hero — the statement closest to its due date.
class _SoonestCard extends StatelessWidget {
  final DuePayment row;
  const _SoonestCard({required this.row});

  @override
  Widget build(BuildContext context) {
    final card = row.card;
    final urgent = row.daysUntilDue <= 5 && row.needsAttention;

    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [BambooInk.slateRaised, BambooInk.slate, BambooInk.slateLow],
        ),
        borderRadius: BorderRadius.circular(28),
      ),
      padding: const EdgeInsets.all(AppSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            row.daysUntilDue == 0
                ? 'DUE TODAY'
                : 'DUE IN ${row.daysUntilDue} ${row.daysUntilDue == 1 ? 'DAY' : 'DAYS'}',
            style: BambooFonts.ui(
              11,
              weight: FontWeight.w700,
              color: urgent ? BambooInk.lime : BambooInk.onSlateMuted,
            ).copyWith(letterSpacing: 1.2),
          ),
          const SizedBox(height: AppSpace.sm),
          Text(
            card.nickname?.isNotEmpty == true ? card.nickname! : card.cardName,
            style: BambooFonts.heading(20, color: BambooInk.onSlate),
          ),
          const SizedBox(height: AppSpace.md),
          // Labelled as logged spend every single time it renders — see
          // DuePayment.loggedThisCycle for why this is not "amount due".
          Text('Logged on this card this cycle', style: BambooFonts.ui(12, color: BambooInk.onSlateMuted)),
          const SizedBox(height: 2),
          MoneyText(
            row.loggedThisCycle,
            confidence: Confidence.estimated,
            style: BambooFonts.money(28, color: BambooInk.onSlate),
            hidePaise: true,
          ),
          const SizedBox(height: AppSpace.sm),
          Text(
            "Your issuer's statement may be higher — PandaPay only counts what it has seen.",
            style: BambooFonts.ui(12, color: BambooInk.onSlateSubtle),
          ),
          const SizedBox(height: AppSpace.md),
          const Divider(height: 1, color: BambooInk.slateHairline),
          const SizedBox(height: AppSpace.md),
          _AutopayLine(mode: card.autopayMode, onSlate: true),
        ],
      ),
    );
  }
}

class _ComingUpRow extends StatelessWidget {
  final DuePayment row;
  const _ComingUpRow({required this.row});

  @override
  Widget build(BuildContext context) {
    final card = row.card;
    return Container(
      decoration: BoxDecoration(
        color: BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      padding: const EdgeInsets.all(AppSpace.md),
      child: Row(
        children: [
          // The deck's date chip: day over month.
          Container(
            width: 44,
            padding: const EdgeInsets.symmetric(vertical: 6),
            decoration: BoxDecoration(color: BambooInk.paperMuted, borderRadius: BorderRadius.circular(12)),
            child: Column(
              children: [
                Text(DateFormat.d().format(row.dueOn), style: BambooFonts.money(16, color: BambooInk.ink900)),
                Text(
                  DateFormat.MMM().format(row.dueOn),
                  style: BambooFonts.ui(10.5, weight: FontWeight.w600, color: BambooInk.ink500),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  card.nickname?.isNotEmpty == true ? card.nickname! : card.cardName,
                  style: BambooFonts.ui(14, weight: FontWeight.w600, color: BambooInk.ink900),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                _AutopayLine(mode: card.autopayMode, onSlate: false),
              ],
            ),
          ),
          const SizedBox(width: AppSpace.sm),
          MoneyText(
            row.loggedThisCycle,
            confidence: Confidence.estimated,
            style: BambooFonts.money(15, color: BambooInk.ink900),
            hidePaise: true,
          ),
        ],
      ),
    );
  }
}

/// The one line that turns the autopay answer into advice. Three states,
/// worded differently on purpose — see [AutopayMode].
class _AutopayLine extends StatelessWidget {
  final AutopayMode mode;
  final bool onSlate;
  const _AutopayLine({required this.mode, required this.onSlate});

  @override
  Widget build(BuildContext context) {
    final (text, color) = switch (mode) {
      AutopayMode.full => (
        'Autopay covers the full amount',
        onSlate ? BambooInk.lime : BambooInk.rankBadgeInk,
      ),
      AutopayMode.minimum => (
        'Autopay pays the minimum — the rest carries interest',
        onSlate ? BambooInk.onSlateSubtle : BambooInk.clayInk,
      ),
      AutopayMode.off => (
        "Autopay not set — you'll need to pay this yourself",
        onSlate ? BambooInk.onSlateSubtle : BambooInk.ink500,
      ),
    };
    return Text(text, style: BambooFonts.ui(12.5, color: color));
  }
}

/// Design 13's "Free money, briefly" — which card buys you the longest
/// interest-free stretch if you put a big purchase on it today.
///
/// Reuses [billingCycleFloat] and E7's own documented 20-day grace-period
/// assumption rather than restating either; the copy says "up to" for the
/// same reason E7's does.
class _FreeMoneyCard extends ConsumerWidget {
  final List<DuePayment> rows;
  const _FreeMoneyCard({required this.rows});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final clock = ref.watch(clockProvider);

    (UserCard, int)? best;
    for (final row in rows) {
      final statementDay = row.card.statementDay;
      if (statementDay == null) continue;
      final float = billingCycleFloat(
        statementDay: statementDay,
        gracePeriodDays: assumedGracePeriodDays,
        clock: clock,
      );
      if (best == null || float.totalInterestFreeDays > best.$2) {
        best = (row.card, float.totalInterestFreeDays);
      }
    }
    if (best == null) return const SizedBox.shrink();

    final (card, days) = best;
    return Container(
      decoration: BoxDecoration(
        color: BambooInk.rankBadgeBg,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: BambooInk.rankBadgeBorder),
      ),
      padding: const EdgeInsets.all(AppSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Free money, briefly',
            style: BambooFonts.ui(12, weight: FontWeight.w700, color: BambooInk.rankBadgeInk),
          ),
          const SizedBox(height: AppSpace.sm),
          Text(
            'A big purchase on ${card.nickname?.isNotEmpty == true ? card.nickname! : card.cardName} '
            'today holds the cash for up to $days interest-free days.',
            style: BambooFonts.ui(13, color: BambooInk.ink900),
          ),
          const SizedBox(height: AppSpace.xs),
          Text(
            'Assumes a $assumedGracePeriodDays-day grace period — issuers vary.',
            style: BambooFonts.ui(11.5, color: BambooInk.ink500),
          ),
        ],
      ),
    );
  }
}
