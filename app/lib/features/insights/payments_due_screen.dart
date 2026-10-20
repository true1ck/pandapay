import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../app/router.dart' show AppRoute;
import '../../data/api_exception.dart';
import '../../data/commitments_repository.dart';
import '../../data/user_cards_repository.dart';
import '../../main.dart' show MoneyText;
import 'billing_float_screen.dart' show assumedGracePeriodDays;

// ---------------------------------------------------------------------------
// Backward-compatible type aliases for existing test harnesses
// ---------------------------------------------------------------------------
typedef BillReminder = Commitment;
typedef BillType = CommitmentCategory;
typedef BillCadence = CommitmentCadence;
typedef BillPaymentStatus = CommitmentStatus;
typedef BillSource = CommitmentSource;

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

  /// PandaPay cannot verify an issuer mandate, so every card needs the user
  /// to check the issuer account before relying on autopay.
  bool get needsAttention => true;
}

/// Design 13's list, soonest first.
final paymentsDueProvider = FutureProvider<List<DuePayment>>((ref) async {
  ref.watch(transactionsProvider);
  final repo = ref.watch(userCardsRepositoryProvider);
  final cards = await ref.watch(myCardsProvider.future);
  final now = ref.watch(clockProvider).now();
  final today = DateTime(now.year, now.month, now.day);

  final active = cards.where((c) => !c.isArchived && c.dueDay != null).toList();
  if (active.isEmpty) return const [];

  final earliestCycleStart = DateTime(now.year, now.month - 2, 1);
  final transactions = repo == null
      ? const <TransactionEntry>[]
      : await loadTransactionsWithOfflineCache(
          ref,
          repo: repo,
          cacheKey: 'transactions:payments_due',
          from: earliestCycleStart,
        );

  final rows = <DuePayment>[];
  for (final card in active) {
    final dueOn = nextOccurrenceOf(card.dueDay!, today);
    final cycleStart = card.statementDay == null
        ? null
        : previousOccurrenceOf(card.statementDay!, today);

    var logged = const Money.zero();
    if (cycleStart != null) {
      for (final txn in transactions) {
        if (txn.status != 'active') continue;
        if (txn.entryKind != TxnEntryKind.spend ||
            txn.instrument != TxnInstrument.creditCard) {
          continue;
        }
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

DateTime nextOccurrenceOf(int day, DateTime from) {
  final thisMonth = _clampToMonth(from.year, from.month, day);
  if (!thisMonth.isBefore(from)) return thisMonth;
  return _clampToMonth(from.year, from.month + 1, day);
}

DateTime previousOccurrenceOf(int day, DateTime from) {
  final thisMonth = _clampToMonth(from.year, from.month, day);
  if (!thisMonth.isAfter(from)) return thisMonth;
  return _clampToMonth(from.year, from.month - 1, day);
}

DateTime _clampToMonth(int year, int month, int day) {
  final lastDayOfMonth = DateTime(year, month + 1, 0).day;
  return DateTime(year, month, day > lastDayOfMonth ? lastDayOfMonth : day);
}

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
        title: Text(
          'Bills & commitments',
          style: BambooFonts.heading(18, color: BambooInk.ink900),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_rounded, color: BambooInk.ink900),
            tooltip: 'Add bill or policy',
            onPressed: () => _showAddCommitmentSheet(context, ref),
          ),
        ],
      ),
      body: AppBackground(
        child: Column(
          children: [
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
                data: (rows) => _DueList(rows: rows),
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
    final soonest = rows.isNotEmpty ? rows.first : null;
    final rest = rows.length > 1 ? rows.skip(1).toList() : const <DuePayment>[];

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.lg,
        AppSpace.lg,
        AppSpace.lg,
        AppSpace.xxl,
      ),
      children: [
        // ── Section A: Credit card dues (if any) ──────────────────────
        if (rows.isNotEmpty) ...[
          _SectionHeader(label: 'Credit card dues', count: rows.length),
          const SizedBox(height: AppSpace.md),
          if (soonest != null) _SoonestCard(row: soonest),
          if (rest.isNotEmpty) ...[
            const SizedBox(height: AppSpace.sm),
            for (final row in rest)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpace.sm),
                child: _ComingUpRow(row: row),
              ),
          ],
          const SizedBox(height: AppSpace.xl),
        ],

        // ── Section B: Upcoming bills & insurance commitments ─────────
        const _CommitmentsSection(),
        const SizedBox(height: AppSpace.xl),

        // ── Section C: Subscriptions nudge ────────────────────────────
        const _SubscriptionsNudge(),
        const SizedBox(height: AppSpace.xl),

        // ── Section D: Free money float tip (if cards exist) ──────────
        if (rows.isNotEmpty) _FreeMoneyCard(rows: rows),
      ],
    );
  }
}

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
          Text(
            'Logged on this card this cycle',
            style: BambooFonts.ui(12, color: BambooInk.onSlateMuted),
          ),
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
          const _AutopayLine(onSlate: true),
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
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: BambooInk.paperMuted,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Center(
              child: Text(
                '${row.dueOn.day}',
                style: BambooFonts.heading(18, color: BambooInk.ink900),
              ),
            ),
          ),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  card.nickname?.isNotEmpty == true
                      ? card.nickname!
                      : card.cardName,
                  style: BambooFonts.ui(
                    14,
                    weight: FontWeight.w600,
                    color: BambooInk.ink900,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  'Due ${DateFormat('d MMM').format(row.dueOn)} · in ${row.daysUntilDue}d',
                  style: BambooFonts.ui(12, color: BambooInk.ink500),
                ),
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

class _AutopayLine extends StatelessWidget {
  final bool onSlate;
  const _AutopayLine({required this.onSlate});

  @override
  Widget build(BuildContext context) {
    final text = 'Autopay status not verified — check your issuer app';
    final color = onSlate ? BambooInk.onSlateSubtle : BambooInk.ink500;
    return Text(text, style: BambooFonts.ui(12.5, color: color));
  }
}

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
            style: BambooFonts.ui(
              12,
              weight: FontWeight.w700,
              color: BambooInk.rankBadgeInk,
            ),
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

class _SectionHeader extends StatelessWidget {
  final String label;
  final int? count;

  const _SectionHeader({required this.label, this.count});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(label, style: BambooFonts.heading(17, color: BambooInk.ink900)),
        if (count != null) ...[
          const SizedBox(width: AppSpace.sm),
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpace.sm,
              vertical: 2,
            ),
            decoration: BoxDecoration(
              color: BambooInk.rankBadgeBg,
              borderRadius: BorderRadius.circular(AppRadius.pill),
              border: Border.all(color: BambooInk.rankBadgeBorder),
            ),
            child: Text(
              '$count',
              style: BambooFonts.ui(
                11,
                weight: FontWeight.w600,
                color: BambooInk.rankBadgeInk,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Commitment Row — renders with Money and category-specific styling
// ---------------------------------------------------------------------------

class _CommitmentRow extends ConsumerWidget {
  final Commitment commitment;

  const _CommitmentRow({required this.commitment});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.watch(clockProvider).now();
    final daysUntil = commitment.daysUntilDue(now);
    final inGrace = commitment.isWithinGracePeriod(now);
    final graceDaysLeft = commitment.daysRemainingInGrace(now);
    final isPaid = commitment.status == CommitmentStatus.paid;

    final List<String> metaParts = [];
    if (commitment.identifier != null && commitment.identifier!.isNotEmpty) {
      final prefix = commitment.category == CommitmentCategory.insurance
          ? 'Policy'
          : 'A/C';
      metaParts.add('$prefix ${commitment.identifier}');
    }
    if (commitment.cadence != CommitmentCadence.monthly) {
      metaParts.add(commitment.cadence.label);
    }

    return GestureDetector(
      onTap: () => _showCommitmentDetailSheet(context, ref, commitment),
      behavior: HitTestBehavior.opaque,
      child: Container(
        decoration: BoxDecoration(
          color: BambooInk.paper,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: commitment.status == CommitmentStatus.paymentNotDetected
                ? BambooInk.warningBorder
                : BambooInk.hairlineOnPaper,
          ),
        ),
        padding: const EdgeInsets.all(AppSpace.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: commitment.category.iconBg,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    commitment.category.icon,
                    color: commitment.category.iconColor,
                    size: 20,
                  ),
                ),
                const SizedBox(width: AppSpace.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        commitment.title,
                        style: BambooFonts.ui(
                          14,
                          weight: FontWeight.w600,
                          color: BambooInk.ink900,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (metaParts.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          metaParts.join(' · '),
                          style: BambooFonts.ui(11.5, color: BambooInk.ink700),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                      const SizedBox(height: 2),
                      _buildDueText(commitment, now, daysUntil, isPaid),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpace.sm),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (commitment.amount != null)
                      Text(
                        commitment.amount!.format(hidePaise: true),
                        style: BambooFonts.money(15, color: BambooInk.ink900),
                      )
                    else
                      Text(
                        'Amount unstated',
                        style: BambooFonts.ui(12, color: BambooInk.ink500),
                      ),
                    const SizedBox(height: 4),
                    const Icon(
                      Icons.chevron_right_rounded,
                      size: 18,
                      color: BambooInk.ink500,
                    ),
                  ],
                ),
              ],
            ),
            // Evidence-based policy grace window pill (only when specified)
            if (inGrace && !isPaid && graceDaysLeft != null) ...[
              const SizedBox(height: AppSpace.sm),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: BambooInk.rankBadgeBg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: BambooInk.rankBadgeBorder),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.shield_outlined,
                      color: BambooInk.rankBadgeInk,
                      size: 14,
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        'Policy grace window · $graceDaysLeft days left to pay',
                        style: BambooFonts.ui(
                          11.5,
                          weight: FontWeight.w600,
                          color: BambooInk.rankBadgeInk,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildDueText(
    Commitment commitment,
    DateTime now,
    int daysUntil,
    bool isPaid,
  ) {
    if (isPaid) {
      return Text(
        'Paid',
        style: BambooFonts.ui(
          12,
          color: BambooInk.jade,
          weight: FontWeight.w600,
        ),
      );
    }
    if (commitment.status == CommitmentStatus.paymentNotDetected ||
        commitment.isPastGrace(now)) {
      return Text(
        'Payment not detected · due ${DateFormat('d MMM').format(commitment.dueOn)}',
        style: BambooFonts.ui(12, color: BambooInk.clayInk),
      );
    }
    if (commitment.isWithinGracePeriod(now)) {
      return Text(
        'Grace window · was due ${DateFormat('d MMM').format(commitment.dueOn)}',
        style: BambooFonts.ui(12, color: BambooInk.amber),
      );
    }
    if (daysUntil == 0) {
      return Text(
        'Due today',
        style: BambooFonts.ui(
          12,
          color: BambooInk.clayInk,
          weight: FontWeight.w600,
        ),
      );
    }
    return Text(
      'Due ${DateFormat('d MMM').format(commitment.dueOn)} · in ${daysUntil}d',
      style: BambooFonts.ui(12, color: BambooInk.ink500),
    );
  }
}

// ---------------------------------------------------------------------------
// Commitments section — backed by durable CommitmentsRepository
// ---------------------------------------------------------------------------

class _CommitmentsSection extends ConsumerWidget {
  const _CommitmentsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final commitmentsAsync = ref.watch(commitmentsProvider);

    return commitmentsAsync.when(
      loading: () => const SkeletonList(count: 2),
      error: (_, __) => const SizedBox.shrink(),
      data: (commitments) {
        // Progressive disclosure:
        // 1. Unreviewed items route to Needs Review banner.
        final unreviewed = commitments
            .where(
              (c) =>
                  c.status != CommitmentStatus.dismissed &&
                  (c.confidence < 0.85 ||
                      c.status == CommitmentStatus.needsConfirmation),
            )
            .toList();
        final active = commitments
            .where(
              (c) =>
                  c.confidence >= 0.85 &&
                  c.status != CommitmentStatus.needsConfirmation &&
                  c.status != CommitmentStatus.dismissed &&
                  !(c.status == CommitmentStatus.paid &&
                      c.cadence == CommitmentCadence.oneTime),
            )
            .toList();

        // 2. Hide empty categories (no placeholder zeroes).
        final utilities = active
            .where(
              (c) =>
                  c.category == CommitmentCategory.utility ||
                  c.category == CommitmentCategory.telecom,
            )
            .toList();
        final renewals = active
            .where((c) => c.category == CommitmentCategory.insurance)
            .toList();
        final scheduled = active
            .where(
              (c) =>
                  c.category == CommitmentCategory.loanOrEmi ||
                  c.category == CommitmentCategory.rent ||
                  c.category == CommitmentCategory.education ||
                  c.category == CommitmentCategory.tax ||
                  c.category == CommitmentCategory.other,
            )
            .toList();

        // This banner is specifically for commitment evidence. The existing
        // transaction review queue has a different item type and must not
        // inflate this count or promise that a bill can be reviewed there.
        final totalUnreviewed = unreviewed.length;

        if (active.isEmpty && totalUnreviewed == 0) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _SectionHeader(label: 'Upcoming bills', count: null),
              const SizedBox(height: AppSpace.md),
              Container(
                padding: const EdgeInsets.all(AppSpace.lg),
                decoration: BoxDecoration(
                  color: BambooInk.glassFillOnPaper,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: BambooInk.hairlineOnPaper),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.check_circle_outline_rounded,
                      color: BambooInk.jade,
                      size: 20,
                    ),
                    const SizedBox(width: AppSpace.sm),
                    Expanded(
                      child: Text(
                        'No upcoming bills detected yet. Tap + to add one.',
                        style: BambooFonts.ui(13, color: BambooInk.ink700),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Real Needs Review banner connected to queue ───────────
            if (totalUnreviewed > 0) ...[
              _NeedsReviewCommitmentsBanner(count: totalUnreviewed),
              const SizedBox(height: AppSpace.lg),
            ],

            // ── Utilities & telecom group ─────────────────────────────
            if (utilities.isNotEmpty) ...[
              _SectionHeader(label: 'Upcoming bills', count: utilities.length),
              const SizedBox(height: AppSpace.md),
              for (final item in utilities)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpace.sm),
                  child: _CommitmentRow(commitment: item),
                ),
              if (renewals.isNotEmpty || scheduled.isNotEmpty)
                const SizedBox(height: AppSpace.xl),
            ],

            // ── Renewals & Insurance policies group ───────────────────
            if (renewals.isNotEmpty) ...[
              _SectionHeader(
                label: 'Insurance & renewals',
                count: renewals.length,
              ),
              const SizedBox(height: AppSpace.md),
              for (final item in renewals)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpace.sm),
                  child: _CommitmentRow(commitment: item),
                ),
              if (scheduled.isNotEmpty) const SizedBox(height: AppSpace.xl),
            ],

            // ── Scheduled payments (Loans, EMIs, Rent) ────────────────
            if (scheduled.isNotEmpty) ...[
              _SectionHeader(
                label: 'Scheduled payments',
                count: scheduled.length,
              ),
              const SizedBox(height: AppSpace.md),
              for (final item in scheduled)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpace.sm),
                  child: _CommitmentRow(commitment: item),
                ),
            ],
          ],
        );
      },
    );
  }
}

class _NeedsReviewCommitmentsBanner extends StatelessWidget {
  final int count;
  const _NeedsReviewCommitmentsBanner({required this.count});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => context.push(AppRoute.needsReview),
      child: Container(
        decoration: BoxDecoration(
          color: BambooInk.warningBg,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: BambooInk.warningBorder),
        ),
        padding: const EdgeInsets.all(AppSpace.md),
        child: Row(
          children: [
            const Icon(
              Icons.help_outline_rounded,
              color: BambooInk.clayInk,
              size: 20,
            ),
            const SizedBox(width: AppSpace.md),
            Expanded(
              child: Text(
                '$count ${count == 1 ? 'item needs' : 'items need'} review in queue · tap to review',
                style: BambooFonts.ui(
                  13,
                  weight: FontWeight.w600,
                  color: BambooInk.clayInk,
                ),
              ),
            ),
            const Icon(
              Icons.chevron_right_rounded,
              color: BambooInk.clayInk,
              size: 20,
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Interactive Commitment Detail Sheet — durable actions & payment rollover
// ---------------------------------------------------------------------------

void _showCommitmentDetailSheet(
  BuildContext context,
  WidgetRef ref,
  Commitment commitment,
) {
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: BambooInk.paper,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (ctx) => _CommitmentDetailSheet(commitment: commitment),
  );
}

class _CommitmentDetailSheet extends ConsumerWidget {
  final Commitment commitment;
  const _CommitmentDetailSheet({required this.commitment});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.watch(clockProvider).now();
    final inGrace = commitment.isWithinGracePeriod(now);
    final graceDaysLeft = commitment.daysRemainingInGrace(now);
    final isPaid = commitment.status == CommitmentStatus.paid;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpace.lg,
          AppSpace.md,
          AppSpace.lg,
          AppSpace.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: BambooInk.hairlineOnPaper,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: AppSpace.md),

            Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: commitment.category.iconBg,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(
                    commitment.category.icon,
                    color: commitment.category.iconColor,
                    size: 24,
                  ),
                ),
                const SizedBox(width: AppSpace.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        commitment.title,
                        style: BambooFonts.heading(18, color: BambooInk.ink900),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        commitment.category.label,
                        style: BambooFonts.ui(12, color: BambooInk.ink500),
                      ),
                    ],
                  ),
                ),
                if (commitment.amount != null)
                  Text(
                    commitment.amount!.format(hidePaise: true),
                    style: BambooFonts.money(22, color: BambooInk.ink900),
                  ),
              ],
            ),
            const SizedBox(height: AppSpace.lg),
            const Divider(height: 1, color: BambooInk.hairlineOnPaper),
            const SizedBox(height: AppSpace.md),

            _DetailItem(
              label: 'Due date',
              value: DateFormat('EEEE, d MMMM yyyy').format(commitment.dueOn),
            ),
            if (commitment.identifier != null)
              _DetailItem(
                label: commitment.category == CommitmentCategory.insurance
                    ? 'Policy number'
                    : 'Account identifier',
                value: commitment.identifier!,
              ),
            _DetailItem(label: 'Cadence', value: commitment.cadence.label),
            if (commitment.gracePeriodDays != null)
              _DetailItem(
                label: 'Policy grace window',
                value: inGrace
                    ? 'Active · $graceDaysLeft days remaining'
                    : '~${commitment.gracePeriodDays} days (verify with policy)',
                isHighlighted: inGrace,
              ),
            _DetailItem(
              label: 'Status',
              value: isPaid
                  ? 'Paid on ${commitment.paidOn != null ? DateFormat('d MMM').format(commitment.paidOn!) : 'record'}'
                  : commitment.status == CommitmentStatus.paymentNotDetected
                  ? 'Payment not detected'
                  : inGrace
                  ? 'In grace window'
                  : 'Upcoming due',
            ),
            const SizedBox(height: AppSpace.md),

            Container(
              padding: const EdgeInsets.all(AppSpace.md),
              decoration: BoxDecoration(
                color: BambooInk.paperMuted,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.info_outline,
                    size: 16,
                    color: BambooInk.ink700,
                  ),
                  const SizedBox(width: AppSpace.sm),
                  Expanded(
                    child: Text(
                      isPaid
                          ? 'This commitment has been marked as paid.'
                          : 'Marking as paid records the payment date and automatically schedules the next recurring due date.',
                      style: BambooFonts.ui(12, color: BambooInk.ink700),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpace.lg),

            if (!isPaid) ...[
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () async {
                    await ref
                        .read(commitmentsRepositoryProvider)
                        .markAsPaid(
                          commitment.id,
                          paidOn: DateTime.now(),
                          detectedCommitment: commitment,
                        );
                    ref.invalidate(commitmentsProvider);
                    if (context.mounted) {
                      Navigator.of(context).pop();
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Marked ${commitment.title} as paid'),
                        ),
                      );
                    }
                  },
                  icon: const Icon(Icons.check_circle_outline, size: 18),
                  label: const Text('Mark as paid'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: BambooInk.slate,
                    foregroundColor: BambooInk.lime,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: AppSpace.sm),
            ],

            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: () async {
                  final repository = ref.read(commitmentsRepositoryProvider);
                  if (commitment.source == CommitmentSource.sms) {
                    // Detected SMS commitments are derived from observations,
                    // so they are not in the durable manual list yet. Save a
                    // tombstone with the full identity or the next refresh
                    // would recreate the dismissed item.
                    await repository.save(
                      commitment.copyWith(status: CommitmentStatus.dismissed),
                    );
                  } else {
                    await repository.delete(commitment.id);
                  }
                  ref.invalidate(commitmentsProvider);
                  if (context.mounted) Navigator.of(context).pop();
                },
                style: TextButton.styleFrom(
                  foregroundColor: BambooInk.ink700,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                child: Text(
                  commitment.source == CommitmentSource.sms
                      ? 'Dismiss detected commitment'
                      : 'Delete commitment',
                ),
              ),
            ),

            const SizedBox(height: AppSpace.xs),
            Row(
              children: [
                const Icon(Icons.security, size: 12, color: BambooInk.ink500),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'PandaPay never opens unverified SMS links. Always pay via your official provider app or website.',
                    style: BambooFonts.ui(10.5, color: BambooInk.ink500),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _DetailItem extends StatelessWidget {
  final String label;
  final String value;
  final bool isHighlighted;

  const _DetailItem({
    required this.label,
    required this.value,
    this.isHighlighted = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: BambooFonts.ui(12.5, color: BambooInk.ink500)),
          const SizedBox(width: AppSpace.md),
          Flexible(
            child: Text(
              value,
              style: BambooFonts.ui(
                12.5,
                weight: FontWeight.w600,
                color: isHighlighted
                    ? BambooInk.rankBadgeInk
                    : BambooInk.ink900,
              ),
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Add commitment sheet — manual durable registration with real DatePicker
// ---------------------------------------------------------------------------

void _showAddCommitmentSheet(BuildContext context, WidgetRef ref) {
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: BambooInk.paper,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (ctx) => const _AddCommitmentSheet(),
  );
}

class _AddCommitmentSheet extends ConsumerStatefulWidget {
  const _AddCommitmentSheet();

  @override
  ConsumerState<_AddCommitmentSheet> createState() =>
      _AddCommitmentSheetState();
}

class _AddCommitmentSheetState extends ConsumerState<_AddCommitmentSheet> {
  final _nameCtrl = TextEditingController();
  final _amountCtrl = TextEditingController();
  final _accountCtrl = TextEditingController();
  final _graceDaysCtrl = TextEditingController();

  CommitmentCategory _category = CommitmentCategory.utility;
  CommitmentCadence _cadence = CommitmentCadence.monthly;
  DateTime _selectedDate = DateTime.now().add(const Duration(days: 7));

  @override
  void dispose() {
    _nameCtrl.dispose();
    _amountCtrl.dispose();
    _accountCtrl.dispose();
    _graceDaysCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: now.subtract(const Duration(days: 365)),
      lastDate: now.add(const Duration(days: 365 * 10)),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.light(
              primary: BambooInk.slate,
              onPrimary: BambooInk.lime,
              onSurface: BambooInk.ink900,
            ),
          ),
          child: child!,
        );
      },
    );
    if (picked != null) {
      setState(() => _selectedDate = picked);
    }
  }

  Future<void> _submit() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) return;

    final parsedRupees = double.tryParse(_amountCtrl.text.trim());
    final moneyAmount = parsedRupees != null
        ? Money.fromRupees(parsedRupees)
        : null;
    final rawAccount = _accountCtrl.text.trim();
    final account = rawAccount.isEmpty
        ? null
        : '••••${rawAccount.length <= 4 ? rawAccount : rawAccount.substring(rawAccount.length - 4)}';
    final graceDays = int.tryParse(_graceDaysCtrl.text.trim());

    final newCommitment = Commitment(
      id: 'manual-${DateTime.now().millisecondsSinceEpoch}',
      title: name,
      category: _category,
      amount: moneyAmount,
      dueOn: _selectedDate,
      identifier: account,
      cadence: _cadence,
      gracePeriodDays: _category == CommitmentCategory.insurance
          ? graceDays
          : null,
      source: CommitmentSource.manual,
      isUserConfirmed: true,
      status: CommitmentStatus.due,
      confidence: 1.0,
    );

    // Durable on-device write
    await ref.read(commitmentsRepositoryProvider).save(newCommitment);
    ref.invalidate(commitmentsProvider);

    if (mounted) {
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved $name to durable commitments')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: AppSpace.lg,
        right: AppSpace.lg,
        top: AppSpace.md,
        bottom: MediaQuery.of(context).viewInsets.bottom + AppSpace.lg,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: BambooInk.hairlineOnPaper,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: AppSpace.md),
            Text(
              'Add a bill or commitment',
              style: BambooFonts.heading(18, color: BambooInk.ink900),
            ),
            const SizedBox(height: AppSpace.md),

            // Category selector
            Wrap(
              spacing: AppSpace.sm,
              runSpacing: AppSpace.xs,
              children: [
                _buildCategoryChip('Utility', CommitmentCategory.utility),
                _buildCategoryChip('Telecom', CommitmentCategory.telecom),
                _buildCategoryChip(
                  'Insurance / LIC',
                  CommitmentCategory.insurance,
                ),
                _buildCategoryChip('EMI / Loan', CommitmentCategory.loanOrEmi),
                _buildCategoryChip('Rent', CommitmentCategory.rent),
                _buildCategoryChip('Education', CommitmentCategory.education),
                _buildCategoryChip('Other', CommitmentCategory.other),
              ],
            ),
            const SizedBox(height: AppSpace.md),

            // Name
            TextField(
              controller: _nameCtrl,
              decoration: InputDecoration(
                labelText: _category == CommitmentCategory.insurance
                    ? 'Insurer or Policy Name (e.g. LIC Jeevan Labh)'
                    : 'Biller or Entity (e.g. Bescom, Airtel, HDFC Loan)',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            const SizedBox(height: AppSpace.sm),

            // Real Date Picker Button
            GestureDetector(
              onTap: _pickDate,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpace.md,
                  vertical: 14,
                ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: BambooInk.hairlineOnPaper),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.calendar_today_outlined,
                      size: 18,
                      color: BambooInk.ink700,
                    ),
                    const SizedBox(width: AppSpace.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Due Date',
                            style: BambooFonts.ui(11, color: BambooInk.ink500),
                          ),
                          Text(
                            DateFormat(
                              'EEEE, d MMMM yyyy',
                            ).format(_selectedDate),
                            style: BambooFonts.ui(
                              14,
                              color: BambooInk.ink900,
                              weight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Icon(Icons.arrow_drop_down, color: BambooInk.ink500),
                  ],
                ),
              ),
            ),
            const SizedBox(height: AppSpace.sm),

            // Canonical Money Amount
            TextField(
              controller: _amountCtrl,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText: 'Amount (optional)',
                prefixText: '₹ ',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            const SizedBox(height: AppSpace.sm),

            // Identifier
            TextField(
              controller: _accountCtrl,
              decoration: InputDecoration(
                labelText: _category == CommitmentCategory.insurance
                    ? 'Policy Number (optional)'
                    : 'Consumer / Account Number (optional)',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            const SizedBox(height: AppSpace.md),

            // Cadence
            Text('Cadence', style: BambooFonts.ui(13, color: BambooInk.ink700)),
            const SizedBox(height: 6),
            Wrap(
              spacing: AppSpace.sm,
              children: [
                _buildCadenceChip('Monthly', CommitmentCadence.monthly),
                _buildCadenceChip('Quarterly', CommitmentCadence.quarterly),
                _buildCadenceChip('Half-yearly', CommitmentCadence.halfYearly),
                _buildCadenceChip('Annual', CommitmentCadence.annual),
                _buildCadenceChip('One-time', CommitmentCadence.oneTime),
              ],
            ),
            const SizedBox(height: AppSpace.md),

            if (_category == CommitmentCategory.insurance) ...[
              TextField(
                controller: _graceDaysCtrl,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText:
                      'Policy grace period in days (optional, verify with policy)',
                  hintText: 'e.g. 15 or 30',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
              const SizedBox(height: AppSpace.md),
            ],

            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _submit,
                style: ElevatedButton.styleFrom(
                  backgroundColor: BambooInk.slate,
                  foregroundColor: BambooInk.lime,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: const Text('Save Commitment'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCategoryChip(String label, CommitmentCategory cat) {
    final selected = _category == cat;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => setState(() => _category = cat),
    );
  }

  Widget _buildCadenceChip(String label, CommitmentCadence cadence) {
    final selected = _cadence == cadence;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => setState(() => _cadence = cadence),
    );
  }
}

// ---------------------------------------------------------------------------
// Subscriptions nudge — compact tap-through to SubscriptionsScreen
// ---------------------------------------------------------------------------

class _SubscriptionsNudge extends ConsumerWidget {
  const _SubscriptionsNudge();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final report = ref.watch(recurringReportProvider);
    final count = report.valueOrNull?.series
        .where((s) => s.nextExpectedOn != null)
        .length;

    if (count == null || count == 0) return const SizedBox.shrink();

    return GestureDetector(
      onTap: () => context.push(AppRoute.subscriptions),
      child: Container(
        decoration: BoxDecoration(
          color: BambooInk.rankBadgeBg,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: BambooInk.rankBadgeBorder),
        ),
        padding: const EdgeInsets.all(AppSpace.md),
        child: Row(
          children: [
            const Icon(
              Icons.autorenew_rounded,
              color: BambooInk.jade,
              size: 20,
            ),
            const SizedBox(width: AppSpace.md),
            Expanded(
              child: Text(
                '$count recurring '
                '${count == 1 ? 'subscription' : 'subscriptions'} · tap to review',
                style: BambooFonts.ui(13, color: BambooInk.rankBadgeInk),
              ),
            ),
            const Icon(
              Icons.chevron_right_rounded,
              color: BambooInk.rankBadgeInk,
              size: 20,
            ),
          ],
        ),
      ),
    );
  }
}
