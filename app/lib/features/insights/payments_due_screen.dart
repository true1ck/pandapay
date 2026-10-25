import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/card_bill_ledger.dart';
import '../../data/commitments_repository.dart';
import '../../data/past_bill_receipts.dart';
import '../../data/pending_bills.dart';
import '../../data/user_cards_repository.dart';
import 'bills_horizon.dart';
import 'central_bills_section.dart';
import 'insurance_premiums_section.dart';
import 'sms_bills_section.dart';
import 'past_bill_receipts_screen.dart';

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

  /// The issuer bill state the SMS engine derived for this card's newest
  /// statement cycle: bill amount, due date and how the user's card-bill
  /// payments cover it. Null when no bill SMS has been imported
  /// (or the card's last4 is unknown) — the UI must then fall back to
  /// [loggedThisCycle] with its honest "estimated" labelling.
  final CardBill? bill;

  const DuePayment({
    required this.card,
    required this.dueOn,
    required this.daysUntilDue,
    required this.loggedThisCycle,
    this.bill,
  });

  /// PandaPay cannot verify an issuer mandate, so every card needs the user
  /// to check the issuer account before relying on autopay.
  bool get needsAttention => true;
}

/// Per-card bill ledger from SMS (bill-generated messages + payment
/// receipts), used to show the issuer's actual bill instead of the logged
/// estimate. Empty when nothing has been imported.
final paymentsDueProvider = FutureProvider<List<DuePayment>>((ref) async {
  ref.watch(transactionsProvider);
  final repo = ref.watch(userCardsRepositoryProvider);
  final cards = await ref.watch(myCardsProvider.future);
  final now = ref.watch(clockProvider).now();
  final today = DateTime(now.year, now.month, now.day);
  final ledger = await ref.watch(cardBillLedgerProvider.future);

  final active = cards
      .where(
        (c) =>
            !c.isArchived &&
            (c.dueDay != null ||
                // A bill SMS may anchor the ledger even without a synced due
                // day, but only when its cycle anchor was explicitly stated;
                // a received-date anchor plus a due date from a mere reminder
                // is exactly the unverified claim the tests reject.
                (ledger[c.id]?.current != null &&
                    ledger[c.id]!.current!.statementDateVerified)),
      )
      .toList();
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
    final bill = ledger[card.id]?.current;
    final DateTime dueOn;
    if (bill?.dueDate != null &&
        (bill!.statementDateVerified || card.dueDay != null)) {
      dueOn = bill.dueDate!;
    } else if (card.dueDay != null) {
      dueOn = bill != null
          ? nextOccurrenceOf(card.dueDay!, bill.statementDate)
          : nextOccurrenceOf(card.dueDay!, today);
    } else if (bill != null) {
      // No stored due day and the bill SMS omitted the date; grace period
      // (standard 20 days) from the statement date is the best available estimate.
      final estimated = bill.statementDate.add(const Duration(days: 20));
      dueOn = estimated.isBefore(today)
          ? nextOccurrenceOf(estimated.day, today)
          : estimated;
    } else {
      continue;
    }
    final cycleStart = card.statementDay == null
        ? (bill?.statementDate)
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
        bill: bill,
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

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

List<DuePayment> _cardRowsForHorizon(
  List<DuePayment> rows,
  BillsHorizonFilter filter,
) {
  if (filter.isUpcoming) {
    return rows
        .where((row) => filter.matchesOpenDue(row.dueOn))
        .toList(growable: false);
  }
  final result = <DuePayment>[];
  for (final row in rows) {
    final day = row.card.dueDay;
    final billDate = row.bill?.dueDate;
    // A real issuer date outranks the saved-day projection whenever it falls
    // inside the window; otherwise the saved due day supplies the occurrence.
    DateTime? date;
    if (billDate != null && filter.matchesDue(billDate)) {
      date = billDate;
    } else if (day != null) {
      date = filter.scheduledOccurrence(day);
    }
    if (date == null || !filter.matchesDue(date)) continue;
    final billMatches =
        row.bill?.dueDate != null && _sameDay(row.bill!.dueDate!, date);
    result.add(
      DuePayment(
        card: row.card,
        dueOn: date,
        daysUntilDue: date.difference(filter.today).inDays,
        loggedThisCycle: row.loggedThisCycle,
        bill: billMatches ? row.bill : null,
      ),
    );
  }
  result.sort((a, b) => a.dueOn.compareTo(b.dueOn));
  return result;
}

bool _matchesCommitment(Commitment c, BillsHorizonFilter filter) {
  if (c.confidence < 0.85) return false;
  if (c.status == CommitmentStatus.needsConfirmation ||
      c.status == CommitmentStatus.dismissed) {
    return false;
  }
  if (filter.isUpcoming) {
    if (c.status == CommitmentStatus.paid) return false;
    return filter.matchesOpenDue(c.dueOn);
  }
  return filter.matchesDue(c.dueOn);
}

/// Body of the "Bills & commitments" tab inside the Payments group. Renders
/// only the list (or its loading/error state); the surrounding scaffold,
/// app bar and tab strip belong to the parent route.
class BillsAndCommitmentsTab extends ConsumerWidget {
  const BillsAndCommitmentsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final due = ref.watch(paymentsDueProvider);
    final now = ref.watch(clockProvider).now();
    final filter = BillsHorizonFilter(ref.watch(billsHorizonProvider), now);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpace.lg,
            AppSpace.sm,
            AppSpace.lg,
            AppSpace.xs,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Flexible(
                child: BillsHorizonFilterBar(),
              ),
              const SizedBox(width: AppSpace.sm),
              Tooltip(
                message: 'Add bill or policy',
                child: TextButton.icon(
                  onPressed: () => showAddCommitmentSheet(context, ref),
                  icon: const Icon(
                    Icons.add_rounded,
                    size: 16,
                    color: BambooInk.jade,
                  ),
                  label: Text(
                    'Add bill',
                    style: BambooFonts.ui(
                      12.5,
                      color: BambooInk.jade,
                      weight: FontWeight.w600,
                    ),
                  ),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpace.sm,
                      vertical: AppSpace.xs,
                    ),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ),
            ],
          ),
        ),
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
            data: (rows) => _DueList(rows: rows, filter: filter),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Bills Horizon Summary & Aggregate Decision Model
// ---------------------------------------------------------------------------

class BillsHorizonSummary {
  final Money totalDue;
  final Money totalPaid;
  final int actionableCount;
  final int autopayCount;
  final DateTime? earliestDue;
  final bool isUpcoming;
  final String horizonLabel;

  const BillsHorizonSummary({
    required this.totalDue,
    required this.totalPaid,
    required this.actionableCount,
    required this.autopayCount,
    this.earliestDue,
    required this.isUpcoming,
    required this.horizonLabel,
  });

  Money get totalBilled => totalDue + totalPaid;
  double get settledPct => totalBilled.paise == 0
      ? 0.0
      : (totalPaid.paise / totalBilled.paise).clamp(0.0, 1.0);
  bool get hasDues => totalDue.paise > 0;
  bool get hasPaid => totalPaid.paise > 0;
  bool get isEmpty =>
      totalBilled.paise == 0 && actionableCount == 0 && autopayCount == 0;
}

class _BillsSummaryHero extends StatelessWidget {
  final BillsHorizonSummary summary;

  const _BillsSummaryHero({required this.summary});

  @override
  Widget build(BuildContext context) {
    final isUpcoming = summary.isUpcoming;
    final total = isUpcoming ? summary.totalDue : summary.totalBilled;
    final headline = isUpcoming
        ? 'TOTAL DUE THIS CYCLE'
        : 'BILLED IN ${summary.horizonLabel.toUpperCase()}';

    final earliest = summary.earliestDue;
    final daysUntil = earliest == null
        ? null
        : DateTime(earliest.year, earliest.month, earliest.day)
            .difference(DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day))
            .inDays;

    final String statusPillText;
    if (isUpcoming) {
      if (summary.totalDue.paise == 0 && summary.actionableCount == 0) {
        statusPillText = 'All settled';
      } else if (daysUntil != null && daysUntil >= 0) {
        statusPillText = daysUntil == 0
            ? 'Due today'
            : 'Next due in ${daysUntil}d';
      } else if (daysUntil != null && daysUntil < 0) {
        statusPillText = 'Overdue items';
      } else {
        statusPillText = '${summary.actionableCount} due';
      }
    } else {
      statusPillText = '${(summary.settledPct * 100).round()}% settled';
    }

    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [BambooInk.slateRaised, BambooInk.slate, BambooInk.slateLow],
        ),
        borderRadius: BorderRadius.circular(24),
      ),
      padding: const EdgeInsets.all(AppSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  headline,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  style: BambooFonts.ui(
                    11,
                    weight: FontWeight.w700,
                    color: BambooInk.onSlateMuted,
                  ).copyWith(letterSpacing: 1.1),
                ),
              ),
              const SizedBox(width: AppSpace.xs),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: BambooInk.slateLow,
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                  border: Border.all(color: const Color(0x1FFFFFFF)),
                ),
                child: Text(
                  statusPillText,
                  style: BambooFonts.ui(
                    11,
                    weight: FontWeight.w600,
                    color: isUpcoming && daysUntil != null && daysUntil <= 2
                        ? BambooInk.clay
                        : BambooInk.lime,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.sm),
          Text(
            total.format(hidePaise: true),
            style: BambooFonts.money(
              30,
              color: isUpcoming ? BambooInk.lime : BambooInk.onSlate,
            ),
          ),
          const SizedBox(height: AppSpace.md),
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.pill),
            child: LinearProgressIndicator(
              value: summary.settledPct,
              minHeight: 6,
              backgroundColor: BambooInk.slateLow,
              valueColor: const AlwaysStoppedAnimation<Color>(BambooInk.lime),
            ),
          ),
          const SizedBox(height: AppSpace.md),
          Row(
            children: [
              _HeroStatChip(
                icon: Icons.check_circle_outline_rounded,
                iconColor: BambooInk.jade,
                label: summary.totalPaid.paise > 0
                    ? '${summary.totalPaid.format(hidePaise: true)} paid'
                    : '₹0 paid',
              ),
              const SizedBox(width: AppSpace.xs),
              _HeroStatChip(
                icon: Icons.pending_actions_rounded,
                iconColor: summary.actionableCount > 0
                    ? BambooInk.clay
                    : BambooInk.onSlateSubtle,
                label: '${summary.actionableCount} to pay',
              ),
              const SizedBox(width: AppSpace.xs),
              _HeroStatChip(
                icon: Icons.autorenew_rounded,
                iconColor: BambooInk.lime,
                label: '${summary.autopayCount} AutoPay',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _HeroStatChip extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String label;

  const _HeroStatChip({
    required this.icon,
    required this.iconColor,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        decoration: BoxDecoration(
          color: BambooInk.slateLow,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0x1FFFFFFF)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: iconColor),
            const SizedBox(width: 3),
            Flexible(
              child: Text(
                label,
                style: BambooFonts.ui(
                  10,
                  weight: FontWeight.w600,
                  color: BambooInk.onSlate,
                ),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DueList extends ConsumerWidget {
  final List<DuePayment> rows;
  final BillsHorizonFilter filter;

  const _DueList({required this.rows, required this.filter});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rawCardRows = _cardRowsForHorizon(rows, filter);
    final cardRows = filter.isUpcoming
        ? [
            ...rawCardRows.where((r) => r.bill?.isPaid != true),
            ...rawCardRows.where((r) => r.bill?.isPaid == true),
          ]
        : rawCardRows;

    final commitmentsAsync = ref.watch(commitmentsProvider);
    final smsAsync = ref.watch(smsBillRowsProvider);
    final receiptsAsync = ref.watch(pastBillReceiptsProvider);
    final centralAsync = ref.watch(centralBillsProjectionProvider);
    final commitments = commitmentsAsync.valueOrNull ?? const <Commitment>[];
    final localFailed = commitmentsAsync.hasError ||
        smsAsync.hasError ||
        receiptsAsync.hasError;
    final settled = !commitmentsAsync.isLoading &&
        !smsAsync.isLoading &&
        !receiptsAsync.isLoading &&
        !centralAsync.isLoading;
    final visibleCommitments = commitments
        .where((c) => _matchesCommitment(c, filter))
        .toList(growable: false);
    final hasSms =
        (smsAsync.valueOrNull ?? const []).any(filter.matchesSmsBill);
    final hasReceipts =
        (receiptsAsync.valueOrNull ?? const []).any(filter.matchesReceipt);
    final centralDedupKeys = cardRows
        .map((row) => CentralBillDedupKey(last4: row.card.last4,
            dueOn: row.dueOn, amountInr: row.bill?.amountDue?.rupees))
        .toList(growable: false);
    final hasCentral = hasVisibleCentralBills(centralAsync.valueOrNull, filter,
        cardRows: centralDedupKeys, localCommitments: commitments);
    final hasLocalMandates = filter.showsAutopay &&
        localAutopayMandates(ref.watch(responseCacheProvider).valueOrNull,
            ref.watch(cacheNamespaceProvider)).isNotEmpty;
    final visiblePremiums = ref
        .watch(premiumRemindersProvider)
        .where((reminder) {
          if (filter.isUpcoming) return true;
          if (filter.horizon != BillsHorizon.currentMonth) return false;
          return reminder.premiumMonth.year == filter.now.year &&
              reminder.premiumMonth.month == filter.now.month;
        })
        .toList(growable: false);
    final showEmptyState = settled &&
        !localFailed &&
        cardRows.isEmpty &&
        visibleCommitments.isEmpty &&
        !hasSms &&
        !hasReceipts &&
        !hasCentral &&
        !hasLocalMandates &&
        visiblePremiums.isEmpty;

    DateTime? nextDue;
    if (!filter.isUpcoming) {
      for (final row in rows) {
        if (row.dueOn.isBefore(filter.today)) continue;
        if (nextDue == null || row.dueOn.isBefore(nextDue)) nextDue = row.dueOn;
      }
    }

    BillsHorizonSummary calculateSummary() {
      var duePaise = 0;
      var paidPaise = 0;
      var actionable = 0;
      var autopay = 0;
      DateTime? earliest;

      for (final row in cardRows) {
        final card = row.card;
        final bill = row.bill;
        final isAutopay =
            card.autopayMode != AutopayMode.off || bill?.isAutopay == true;

        if (filter.isUpcoming) {
          if (bill?.isPaid == true) {
            paidPaise += bill?.amountDue?.paise ?? bill?.paidToward.paise ?? 0;
          } else {
            final due =
                bill?.outstanding ?? bill?.amountDue ?? row.loggedThisCycle;
            duePaise += due.paise;
            paidPaise += (bill?.paidToward.paise ?? 0);
            if (isAutopay) {
              autopay++;
            } else {
              actionable++;
            }
            if (earliest == null || row.dueOn.isBefore(earliest)) {
              earliest = row.dueOn;
            }
          }
        } else {
          if (bill?.isPaid == true) {
            paidPaise += bill?.amountDue?.paise ?? bill?.paidToward.paise ?? 0;
          } else {
            final due =
                bill?.outstanding ?? bill?.amountDue ?? row.loggedThisCycle;
            duePaise += due.paise;
            paidPaise += (bill?.paidToward.paise ?? 0);
            actionable++;
          }
        }
      }

      for (final c in visibleCommitments) {
        if (c.category == CommitmentCategory.subscription) {
          autopay++;
          if (c.amount != null) duePaise += c.amount!.paise;
        } else if (c.status == CommitmentStatus.paid) {
          if (c.amount != null) paidPaise += c.amount!.paise;
        } else {
          if (c.amount != null) duePaise += c.amount!.paise;
          actionable++;
          if (filter.isUpcoming &&
              (earliest == null || c.dueOn.isBefore(earliest))) {
            earliest = c.dueOn;
          }
        }
      }

      final visibleSms = (smsAsync.valueOrNull ?? const <SmsBillRow>[])
          .where(filter.matchesSmsBill);
      for (final b in visibleSms) {
        if (b.state == SmsBillState.linked) {
          paidPaise += b.amountDue.paise;
        } else {
          duePaise += b.amountDue.paise;
          if (b.isAutopay) {
            autopay++;
          } else {
            actionable++;
          }
          if (filter.isUpcoming &&
              b.dueDate != null &&
              (earliest == null || b.dueDate!.isBefore(earliest))) {
            earliest = b.dueDate;
          }
        }
      }

      return BillsHorizonSummary(
        totalDue: Money.fromPaise(duePaise),
        totalPaid: Money.fromPaise(paidPaise),
        actionableCount: actionable,
        autopayCount: autopay,
        earliestDue: earliest,
        isUpcoming: filter.isUpcoming,
        horizonLabel: filter.label,
      );
    }

    final summary = calculateSummary();

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.lg,
        AppSpace.md,
        AppSpace.lg,
        AppSpace.xxl,
      ),
      children: [
        if (localFailed) const _BillsLoadError(),
        if (showEmptyState)
          _EmptyHorizonState(filter: filter, nextDue: nextDue)
        else ...[
          _BillsSummaryHero(summary: summary),
          const SizedBox(height: AppSpace.lg),
          _CommitmentsSection(filter: filter),
          if (cardRows.isNotEmpty) ...[
            _SectionHeader(label: 'Credit cards', count: cardRows.length),
            const SizedBox(height: AppSpace.xs),
            Text(
              'Dates are based on your saved card settings. Check the issuer for the amount and payment status.',
              style: BambooFonts.ui(12, color: BambooInk.ink500),
            ),
            const SizedBox(height: AppSpace.md),
            for (final row in cardRows)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpace.sm),
                child: _ComingUpRow(row: row),
              ),
            const SizedBox(height: AppSpace.lg),
          ] else if (filter.isUpcoming && rows.isEmpty) ...[
            Text(
              'No due dates set for your cards. Add a due day in Cards to see reminders.',
              style: BambooFonts.ui(13, color: BambooInk.ink500),
            ),
            const SizedBox(height: AppSpace.lg),
          ],
          CentralBillsSection(cardRows: centralDedupKeys, filter: filter),
          SmsBillsSection(filter: filter),
          InsurancePremiumsSection(
            reminders: visiblePremiums,
            upcoming: filter.isUpcoming,
          ),
          const SizedBox(height: AppSpace.lg),
          _PastBillsPreview(filter: filter),
          const SizedBox(height: AppSpace.xl),
        ],
      ],
    );
  }
}

class _BillsLoadError extends ConsumerWidget {
  const _BillsLoadError();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpace.md),
      padding: const EdgeInsets.all(AppSpace.md),
      decoration: BoxDecoration(
        color: BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.error_outline_rounded,
            size: 20,
            color: BambooInk.clay,
          ),
          const SizedBox(width: AppSpace.sm),
          Expanded(
            child: Text(
              "Some bills couldn't load.",
              style: BambooFonts.ui(13, color: BambooInk.ink700),
            ),
          ),
          TextButton(
            onPressed: () {
              ref.invalidate(commitmentsProvider);
              ref.invalidate(smsBillRowsProvider);
              ref.invalidate(pastBillReceiptsProvider);
            },
            child: Text(
              'Retry',
              style: BambooFonts.ui(
                12,
                color: BambooInk.jade,
                weight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PastBillsPreview extends ConsumerWidget {
  final BillsHorizonFilter filter;

  const _PastBillsPreview({required this.filter});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(pastBillReceiptsProvider).valueOrNull ?? const [];
    final matching = filter.isUpcoming
        ? history
        : history.where(filter.matchesReceipt).toList(growable: false);
    final visible = matching
        .take(filter.isUpcoming ? 3 : 10)
        .toList(growable: false);
    if (visible.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: _SectionHeader(
                label: 'Past bills & receipts',
                count: null,
              ),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => PastBillReceiptsScreen(filter: filter),
                ),
              ),
              child: Text(
                'View all',
                style: BambooFonts.ui(
                  12,
                  color: BambooInk.jade,
                  weight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpace.xs),
        for (final item in visible)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.sm),
            child: _PastBillPreviewRow(item: item),
          ),
      ],
    );
  }
}

class _PastBillPreviewRow extends StatelessWidget {
  final PastBillReceipt item;
  const _PastBillPreviewRow({required this.item});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => PastBillReceiptDetailScreen(item: item),
        ),
      ),
      child: Container(
        padding: const EdgeInsets.all(AppSpace.md),
        decoration: BoxDecoration(
          color: BambooInk.glassFillOnPaper,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: BambooInk.hairlineOnPaper),
        ),
        child: Row(
          children: [
            const Icon(Icons.receipt_long_outlined, color: BambooInk.ink500),
            const SizedBox(width: AppSpace.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.merchant,
                    style: BambooFonts.ui(
                      14,
                      weight: FontWeight.w600,
                      color: BambooInk.ink900,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _pastBillStatusLabel(item),
                    style: BambooFonts.ui(
                      12,
                      color:
                          item.status ==
                                  PastBillReceiptStatus.historicalUnpaid ||
                              item.status ==
                                  PastBillReceiptStatus.needsConfirmation
                          ? BambooInk.clayInk
                          : BambooInk.jade,
                    ),
                  ),
                ],
              ),
            ),
            if (item.amount != null)
              Text(
                item.amount!.format(hidePaise: true),
                style: BambooFonts.money(14, color: BambooInk.ink900),
              ),
          ],
        ),
      ),
    );
  }
}

String _pastBillStatusLabel(PastBillReceipt item) => switch (item.status) {
  PastBillReceiptStatus.paidLinked => 'Paid · Linked',
  PastBillReceiptStatus.paidUnlinked => 'Paid · Unlinked',
  PastBillReceiptStatus.historicalUnpaid => 'Past bill · Payment not detected',
  PastBillReceiptStatus.needsConfirmation =>
    item.kind == PastBillReceiptKind.bill
        ? 'Past bill · Needs confirmation'
        : 'Receipt · Needs confirmation',
  PastBillReceiptStatus.userSavedPurchase => 'Saved purchase',
};

class _CalendarDateTile extends StatelessWidget {
  final DateTime dueOn;
  final bool isUrgent;
  final bool isPaid;

  const _CalendarDateTile({
    required this.dueOn,
    this.isUrgent = false,
    this.isPaid = false,
  });

  @override
  Widget build(BuildContext context) {
    final month = DateFormat('MMM').format(dueOn).toUpperCase();
    final day = DateFormat('dd').format(dueOn);

    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: isPaid
            ? BambooInk.paperMuted
            : isUrgent
                ? BambooInk.warningBg
                : BambooInk.paperMuted,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isUrgent && !isPaid
              ? BambooInk.warningBorder
              : BambooInk.hairlineOnPaper,
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            month,
            style: BambooFonts.ui(
              9.5,
              weight: FontWeight.w700,
              color: isUrgent && !isPaid ? BambooInk.clayInk : BambooInk.ink500,
            ),
          ),
          Text(
            day,
            style: BambooFonts.heading(
              16,
              weight: FontWeight.w800,
              color: isPaid
                  ? BambooInk.ink500
                  : isUrgent
                      ? BambooInk.clayInk
                      : BambooInk.ink900,
            ),
          ),
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
    final bill = row.bill;
    final isPaid = bill?.isPaid ?? false;
    final isAutopay =
        card.autopayMode != AutopayMode.off || bill?.isAutopay == true;
    final isUrgent = row.daysUntilDue <= 3 && !isPaid;
    final dueLabel = 'Due ${DateFormat('d MMM').format(row.dueOn)}';
    final dueDetail = row.daysUntilDue > 0
        ? '$dueLabel · in ${row.daysUntilDue}d'
        : row.daysUntilDue == 0
        ? '$dueLabel · today'
        : row.bill == null
        ? '$dueLabel · payment status unknown'
        : row.bill!.isPaid
        ? '$dueLabel · paid'
        : '$dueLabel · past due';

    return Container(
      decoration: BoxDecoration(
        color: isPaid
            ? BambooInk.paperMuted.withValues(alpha: 0.5)
            : BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      padding: const EdgeInsets.all(AppSpace.md),
      child: Row(
        children: [
          _CalendarDateTile(
            dueOn: row.dueOn,
            isUrgent: isUrgent,
            isPaid: isPaid,
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
                    color: isPaid ? BambooInk.ink500 : BambooInk.ink900,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  dueDetail,
                  style: BambooFonts.ui(12, color: BambooInk.ink500),
                ),
                if (isAutopay && !isPaid) ...[
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      const Icon(
                        Icons.autorenew_rounded,
                        size: 13,
                        color: BambooInk.jade,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'AutoPay scheduled',
                        style: BambooFonts.ui(
                          11,
                          color: BambooInk.jade,
                          weight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: AppSpace.sm),
          if (bill != null)
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  bill.amountDue == null
                      ? 'Amount not seen'
                      : (bill.amountDue!.format(hidePaise: true)),
                  style: BambooFonts.money(
                    15,
                    color: isPaid ? BambooInk.ink500 : BambooInk.ink900,
                  ),
                ),
                const SizedBox(height: 2),
                if (bill.isPaid)
                  Text(
                    'Paid ✓',
                    style: BambooFonts.ui(
                      12,
                      weight: FontWeight.w600,
                      color: BambooInk.rankBadgeInk,
                    ),
                  )
                else if (bill.hasPayments)
                  Text(
                    '${bill.paidToward.format(hidePaise: true)} paid',
                    style: BambooFonts.ui(12, color: BambooInk.ink500),
                  )
                else if (bill.minimumDue != null)
                  Text(
                    'Min ${bill.minimumDue!.format(hidePaise: true)}',
                    style: BambooFonts.ui(12, color: BambooInk.ink500),
                  ),
              ],
            )
          else
            const Icon(Icons.chevron_right_rounded, color: BambooInk.ink500),
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
  final BillsHorizonFilter filter;

  const _CommitmentRow({required this.commitment, required this.filter});

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
        'Paid · due ${DateFormat('d MMM').format(commitment.dueOn)}',
        style: BambooFonts.ui(
          12,
          color: BambooInk.jade,
          weight: FontWeight.w600,
        ),
      );
    }
    if (daysUntil < 0) {
      if (commitment.category == CommitmentCategory.subscription) {
        return Text(
          'Active mandate · Auto-debited',
          style: BambooFonts.ui(12, color: BambooInk.ink500),
        );
      }
      return Text(
        filter.isUpcoming
            ? 'Past due date · payment status unknown'
            : 'Due ${DateFormat('d MMM').format(commitment.dueOn)} · payment status unknown',
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
  final BillsHorizonFilter filter;

  const _CommitmentsSection({required this.filter});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final commitmentsAsync = ref.watch(commitmentsProvider);

    return commitmentsAsync.when(
      loading: () => const SkeletonList(count: 2),
      error: (_, _) => const SizedBox.shrink(),
      data: (commitments) {
        final active =
            commitments
                .where((c) => _matchesCommitment(c, filter))
                .toList()
              ..sort(
                (a, b) => filter.isUpcoming
                    ? a.dueOn.compareTo(b.dueOn)
                    : b.dueOn.compareTo(a.dueOn),
              );

        if (active.isEmpty) return const SizedBox.shrink();

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
        final subscriptions = active
            .where((c) => c.category == CommitmentCategory.subscription)
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

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Utilities & telecom group ─────────────────────────────
            if (utilities.isNotEmpty) ...[
              _SectionHeader(
                label: filter.isUpcoming ? 'Upcoming bills' : 'Bills',
                count: utilities.length,
              ),
              const SizedBox(height: AppSpace.md),
              for (final item in utilities)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpace.sm),
                  child: _CommitmentRow(commitment: item, filter: filter),
                ),
              if (renewals.isNotEmpty ||
                  scheduled.isNotEmpty ||
                  subscriptions.isNotEmpty)
                const SizedBox(height: AppSpace.xl),
            ],

            // ── Subscriptions ─────────────────────────────────────────
            if (subscriptions.isNotEmpty) ...[
              _SectionHeader(
                label: 'Subscriptions',
                count: subscriptions.length,
              ),
              const SizedBox(height: AppSpace.md),
              for (final item in subscriptions)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpace.sm),
                  child: _CommitmentRow(commitment: item, filter: filter),
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
                  child: _CommitmentRow(commitment: item, filter: filter),
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
                  child: _CommitmentRow(commitment: item, filter: filter),
                ),
            ],
          ],
        );
      },
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
                  ? 'Payment status unknown'
                  : inGrace
                  ? 'In grace window'
                  : 'Due date recorded · payment status unknown',
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
                          : 'Mark as paid only after checking your provider. A recurring bill then moves to its next cycle.',
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

void showAddCommitmentSheet(BuildContext context, WidgetRef ref) {
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
      labelStyle: BambooFonts.ui(
        13,
        weight: FontWeight.w600,
        color: selected ? BambooInk.onSlate : BambooInk.ink900,
      ),
      selected: selected,
      selectedColor: BambooInk.slate,
      backgroundColor: BambooInk.paperMuted,
      checkmarkColor: BambooInk.onSlate,
      side: BorderSide.none,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      onSelected: (_) => setState(() => _category = cat),
    );
  }

  Widget _buildCadenceChip(String label, CommitmentCadence cadence) {
    final selected = _cadence == cadence;
    return ChoiceChip(
      label: Text(label),
      labelStyle: BambooFonts.ui(
        13,
        weight: FontWeight.w600,
        color: selected ? BambooInk.onSlate : BambooInk.ink900,
      ),
      selected: selected,
      selectedColor: BambooInk.slate,
      backgroundColor: BambooInk.paperMuted,
      checkmarkColor: BambooInk.onSlate,
      side: BorderSide.none,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      onSelected: (_) => setState(() => _cadence = cadence),
    );
  }
}

class _EmptyHorizonState extends ConsumerWidget {
  final BillsHorizonFilter filter;
  final DateTime? nextDue;
  const _EmptyHorizonState({required this.filter, this.nextDue});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final title = switch (filter.horizon) {
      BillsHorizon.upcoming => 'No upcoming bills',
      BillsHorizon.allHistory => 'No bills recorded yet',
      _ => 'No bills in ${filter.label}',
    };
    final body = switch (filter.horizon) {
      BillsHorizon.upcoming =>
        'Add a bill with +, or add a due day in Cards to see reminders.',
      BillsHorizon.allHistory =>
        'Bills and receipts you record will be kept here.',
      _ =>
        'Nothing recorded for this period. Bills, card dues and receipts appear here after SMS import or a manual entry.',
    };
    return Container(
      padding: const EdgeInsets.all(AppSpace.lg),
      decoration: BoxDecoration(
        color: BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.event_available_rounded,
                color: BambooInk.jade,
                size: 20,
              ),
              const SizedBox(width: AppSpace.sm),
              Expanded(
                child: Text(
                  title,
                  style: BambooFonts.ui(
                    14,
                    weight: FontWeight.w600,
                    color: BambooInk.ink900,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.sm),
          Text(body, style: BambooFonts.ui(13, color: BambooInk.ink700)),
          if (!filter.isUpcoming) ...[
            if (nextDue != null) ...[
              const SizedBox(height: AppSpace.sm),
              Text(
                'Next card due ${DateFormat('d MMM').format(nextDue!)}',
                style: BambooFonts.ui(12, color: BambooInk.ink500),
              ),
            ],
            const SizedBox(height: AppSpace.sm),
            TextButton(
              onPressed: () => ref.read(billsHorizonProvider.notifier).state =
                  BillsHorizon.upcoming,
              child: const Text('View upcoming'),
            ),
          ],
        ],
      ),
    );
  }
}
