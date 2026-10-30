import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../data/local/financial_store.dart';
import '../activity/sms_learning_capture.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/card_bill_ledger.dart';
import '../../data/bills_projection_api.dart';
import '../../data/commitments_repository.dart';
import '../../data/past_bill_receipts.dart';
import '../../data/user_cards_repository.dart';
import 'bills_horizon.dart';
import 'central_bills_section.dart';
import 'card_bill_review_section.dart';
import 'insurance_premiums_section.dart';
import 'sms_bills_section.dart';
import 'past_bill_receipts_screen.dart';
import '../cards/card_visual.dart';

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

/// Finds an owned card that matches a credit card central projection obligation.
UserCard? findMatchingCardForCentralBill(
  BillProjection projection,
  List<UserCard> cards,
) {
  final activeCards = cards.where((c) => !c.isArchived).toList();
  if (activeCards.isEmpty) return null;

  // 1. Match by last4 if available
  final last4 = projection.last4;
  if (last4 != null && last4.isNotEmpty) {
    final matches = activeCards.where((c) => c.last4 == last4).toList();
    return matches.length == 1 ? matches.single : null;
  }

  // 2. Match by card name / nickname
  final title =
      (projection.billerName ?? projection.serviceName ?? '').toLowerCase();
  // A bank-only label identifies the issuer, not one of several cards from
  // that issuer. Tata Neu delivery does not identify a Tata Neu card either.
  if (activeCards.length > 1 && _genericCardBillTitle(title)) return null;
  final namedMatches = <UserCard>[];
  if (title.isNotEmpty) {
    for (final card in activeCards) {
      final cName = card.cardName.toLowerCase();
      final nick = (card.nickname ?? '').toLowerCase();
      if (cName.isNotEmpty && (title.contains(cName) || cName.contains(title))) {
        namedMatches.add(card);
        continue;
      }
      if (nick.isNotEmpty && (title.contains(nick) || nick.contains(title))) {
        namedMatches.add(card);
      }
    }
  }
  if (namedMatches.length == 1) return namedMatches.single;
  if (namedMatches.length > 1) return null;

  // 3. Match by bank/issuer tokens
  const issuers = [
    'hdfc', 'sbi', 'icici', 'axis', 'kotak', 'amex',
    'citi', 'rbl', 'indusind', 'bob', 'pnb', 'idfc', 'onecard'
  ];
  for (final issuer in issuers) {
    if (title.contains(issuer)) {
      final matches = activeCards.where((c) {
        final cName = c.cardName.toLowerCase();
        final nick = (c.nickname ?? '').toLowerCase();
        return cName.contains(issuer) || nick.contains(issuer);
      }).toList();
      return matches.length == 1 ? matches.single : null;
    }
  }

  // 4. If user only has one active card, map to it
  if (activeCards.length == 1) {
    return activeCards.first;
  }

  return null;
}

bool _genericCardBillTitle(String title) {
  final productWords = title
      .replaceAll(RegExp(r'\btata\s*neu\b'), '')
      .replaceAll(
        RegExp(r'\b(?:hdfc|sbi|icici|axis|kotak|amex|citi|rbl|indusind|bob|pnb|idfc|onecard|bank|credit|card|bill|payment)\b'),
        '',
      )
      .replaceAll(RegExp(r'[^a-z0-9]+'), '');
  return productWords.isEmpty;
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

  final rows = <DuePayment>[];
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
  if (active.isNotEmpty) {

  final earliestCycleStart = DateTime(now.year, now.month - 2, 1);
  final transactions = repo == null
      ? const <TransactionEntry>[]
      : await loadTransactionsWithOfflineCache(
          ref,
          repo: repo,
          cacheKey: 'transactions:payments_due',
          from: earliestCycleStart,
        );

  // active rows loop
  for (final card in active) {
    final bill = ledger[card.id]?.current;
    final DateTime dueOn;
    final billIsCurrent = bill != null && bill.isCurrentAsOf(now);
    if (bill?.dueDate != null &&
        (bill!.statementDateVerified || card.dueDay != null) &&
        (billIsCurrent || card.dueDay == null)) {
      dueOn = bill.dueDate!;
    } else if (card.dueDay != null) {
      dueOn = bill != null && billIsCurrent
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
        bill: billIsCurrent ? bill : null,
      ),
    );
  }

  }

  // Central credit card bill projection mapping:
  final centralSnapshot = ref.watch(centralBillsProjectionProvider).valueOrNull;
  if (centralSnapshot != null && centralSnapshot.available) {
    for (final projection in centralSnapshot.projections) {
      if (!isCreditCardBill(projection)) continue;
      final dueDate = projection.dueDate;
      if (dueDate == null) continue;
      final amountInr = projection.amountInr;
      if (amountInr == null || amountInr <= 0) continue;
      final amount = Money.fromRupees(amountInr);

      final ownedMatch = findMatchingCardForCentralBill(projection, cards);
      // A suffix-less central projection may be another view of an SMS bill
      // already attached to a card. Do not show the same obligation twice as
      // an unmatched card when its due date and amount agree exactly.
      if (ownedMatch == null && projection.last4 == null &&
          rows.any((r) => _sameDay(r.dueOn, dueDate) &&
              r.bill?.amountDue?.paise == amount.paise)) {
        continue;
      }
      final matchedCard = ownedMatch ??
          UserCard(
            id: 'central-${projection.id}',
            cardProductId: 'central-${projection.id}',
            cardName: projection.billerName ??
                projection.serviceName ??
                'Credit card',
            isDefault: false,
          );

      final cardBill = CardBill(
        statementDate: dueDate.subtract(const Duration(days: 20)),
        dueDate: dueDate,
        amountDue: amount,
        minimumDue: null,
        paidToward: Money.zero(),
        lastPaymentAt: null,
        confidence: 0.95,
        statementDateVerified: true,
        statementDateExplicit: false,
      );

      int existingIndex =
          rows.indexWhere((r) => r.card.id == matchedCard.id);
      if (existingIndex < 0 && ownedMatch == null) {
        existingIndex = rows.indexWhere((r) {
          final rName = r.card.cardName.toLowerCase();
          final bName = (projection.billerName ??
                  projection.serviceName ??
                  '')
              .toLowerCase();
          return _sameDay(r.dueOn, dueDate) &&
              (rName == bName ||
                  (bName.isNotEmpty &&
                      (rName.contains(bName) || bName.contains(rName))));
        });
      }
      if (existingIndex >= 0) {
        final existing = rows[existingIndex];
        if (existing.bill == null || !existing.bill!.statementDateVerified) {
          rows[existingIndex] = DuePayment(
            card: existing.card,
            dueOn: dueDate,
            daysUntilDue: dueDate.difference(today).inDays,
            loggedThisCycle: existing.loggedThisCycle,
            bill: cardBill,
          );
        }
      } else {
        rows.add(
          DuePayment(
            card: matchedCard,
            dueOn: dueDate,
            daysUntilDue: dueDate.difference(today).inDays,
            loggedThisCycle: Money.zero(),
            bill: cardBill,
          ),
        );
      }
    }
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
  // Subscriptions have their own dedicated screen (AppRoute.subscriptions).
  // Exclude them from Payments Due to avoid cluttering actionable bills.
  if (c.category == CommitmentCategory.subscription) return false;
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
          child: Builder(
            builder: (context) {
              final rows = due.valueOrNull;
              if (rows != null) {
                return _DueList(rows: rows, filter: filter);
              }
              if (due.isLoading) {
                return const Padding(
                  padding: EdgeInsets.symmetric(horizontal: AppSpace.lg),
                  child: SkeletonList(count: 3),
                );
              }
              if (due.hasError) {
                return ErrorState(
                  message: userFacingErrorMessage(due.error!),
                  onRetry: () => ref.invalidate(paymentsDueProvider),
                );
              }
              return const SizedBox.shrink();
            },
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

// ---------------------------------------------------------------------------
// Section Visibility Flags
// ---------------------------------------------------------------------------
// Hidden for now per user request; preserved to easily re-enable later.
const bool _showSmsBills = false;
const bool _showScheduledPayments = false;
const bool _showCardBillReview = false;

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
    final reviewAsync = ref.watch(cardBillReviewItemsProvider);
    bool showsReview(CardBillReviewItem item) {
      final date = item.dueDate ?? item.receivedAt;
      return filter.isUpcoming
          ? (item.dueDate == null || filter.matchesOpenDue(date))
          : filter.matchesDue(date);
    }
    final hasReview = _showCardBillReview &&
        (reviewAsync.valueOrNull ?? const <CardBillReviewItem>[])
            .any(showsReview);
    final commitments = commitmentsAsync.valueOrNull ?? const <Commitment>[];
    final localFailed = commitmentsAsync.hasError ||
        (_showSmsBills && smsAsync.hasError) ||
        receiptsAsync.hasError ||
        (_showCardBillReview && reviewAsync.hasError);
    final settled = !commitmentsAsync.isLoading &&
        (!_showSmsBills || !smsAsync.isLoading) &&
        !receiptsAsync.isLoading &&
        !centralAsync.isLoading &&
        (!_showCardBillReview || !reviewAsync.isLoading);
    final visibleCommitments = commitments
        .where((c) => _matchesCommitment(c, filter))
        .toList()
      ..sort(
        (a, b) => filter.isUpcoming
            ? a.dueOn.compareTo(b.dueOn)
            : b.dueOn.compareTo(a.dueOn),
      );

    final utilities = visibleCommitments
        .where(
          (c) =>
              c.category == CommitmentCategory.utility ||
              c.category == CommitmentCategory.telecom,
        )
        .toList(growable: false);
    final renewals = visibleCommitments
        .where((c) => c.category == CommitmentCategory.insurance)
        .toList(growable: false);
    final scheduled = visibleCommitments
        .where(
          (c) =>
              c.category == CommitmentCategory.loanOrEmi ||
              c.category == CommitmentCategory.rent ||
              c.category == CommitmentCategory.education ||
              c.category == CommitmentCategory.tax ||
              c.category == CommitmentCategory.other,
        )
        .toList(growable: false);

    final hasSms =
        _showSmsBills &&
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
        !(utilities.isNotEmpty ||
            renewals.isNotEmpty ||
            (_showScheduledPayments && scheduled.isNotEmpty)) &&
        !hasSms &&
        !hasReceipts &&
        !hasCentral &&
        !hasReview &&
        !hasLocalMandates &&
        visiblePremiums.isEmpty;

    DateTime? nextDue;
    if (!filter.isUpcoming) {
      for (final row in rows) {
        if (row.dueOn.isBefore(filter.today)) continue;
        if (nextDue == null || row.dueOn.isBefore(nextDue)) nextDue = row.dueOn;
      }
    }

    // Preserved for when hero card is re-enabled:
    // ignore: unused_element
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
          // Hero card is hidden for now as requested; can be re-enabled later.
          if (commitmentsAsync.isLoading && !commitmentsAsync.hasValue)
            const Padding(
              padding: EdgeInsets.only(bottom: AppSpace.lg),
              child: SkeletonList(count: 2),
            ),

          // 1. Upcoming bills (utilities & telecom)
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
            const SizedBox(height: AppSpace.lg),
          ],

          // 2. Credit cards (immediately following Upcoming bills)
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

          if (_showCardBillReview) CardBillReviewSection(includes: showsReview),

          // 3. Central bills / AutoPay authorizations
          CentralBillsSection(cardRows: centralDedupKeys, filter: filter),

          // 4. Insurance & renewals (CommitmentCategory.insurance + InsurancePremiumsSection)
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
            if (visiblePremiums.isEmpty) const SizedBox(height: AppSpace.lg),
          ],
          InsurancePremiumsSection(
            reminders: visiblePremiums,
            upcoming: filter.isUpcoming,
          ),

          // 5. Scheduled payments (loans, EMIs, rent, education, tax, other)
          if (_showScheduledPayments && scheduled.isNotEmpty) ...[
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
            const SizedBox(height: AppSpace.lg),
          ],

          // 6. SMS bills
          if (_showSmsBills) SmsBillsSection(filter: filter),
          // 7. Past bills preview
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
              if (_showSmsBills) ref.invalidate(smsBillRowsProvider);
              ref.invalidate(pastBillReceiptsProvider);
              if (_showCardBillReview) {
                ref.invalidate(cardBillReviewItemsProvider);
              }
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
                    maxLines: 1,
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
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
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

void _showCardBillDetailSheet(
  BuildContext context,
  WidgetRef ref,
  DuePayment row,
) {
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: BambooInk.paper,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (ctx) => _CardBillDetailSheet(row: row),
  );
}

Map<String, dynamic>? _findBestCandidateObs(
  FinancialStore store,
  String namespace,
  UserCard card,
  DateTime dueOn, {
  String? issuerName,
}) {
  final allObs = store.entities(namespace, 'sms_observations');
  final assignments = store.cardBillAssignments(namespace);
  final cardBank = (issuerName ?? '').toLowerCase();
  final cardName = card.cardName.toLowerCase();
  final last4 = card.last4;

  Map<String, dynamic>? best;
  int bestScore = 0;

  for (final obs in allObs) {
    if (obs['event_type'] != 'bill') continue;
    final id = obs['id'] as String?;
    if (id == null) continue;

    final assignedTo = assignments[id]?['user_card_id'] as String?;
    if (assignedTo != null && assignedTo != card.id) continue;

    final obsLast4 = obs['card_last4'] as String?;
    final senderBank = (obs['sender_bank'] as String? ?? '').toLowerCase();
    final biller = (obs['biller_name'] as String? ?? '').toLowerCase();
    final body = (obs['sample_body'] as String? ?? '').toLowerCase();
    final obsDue = DateTime.tryParse(obs['due_date'] as String? ?? '');

    int score = 0;
    if (last4 != null && last4.isNotEmpty && obsLast4 == last4) {
      score += 100;
    }
    if (assignedTo == card.id) {
      score += 80;
    }
    final isHdfc = cardBank.contains('hdfc') || cardName.contains('hdfc');
    final isSbi = cardBank.contains('sbi') || cardName.contains('sbi');
    final isIcici = cardBank.contains('icici') || cardName.contains('icici');
    final isAxis = cardBank.contains('axis') || cardName.contains('axis');
    final isKotak = cardBank.contains('kotak') || cardName.contains('kotak');

    if (isHdfc &&
        (senderBank.contains('hdfc') ||
            senderBank.contains('mytneu') ||
            senderBank.contains('tata') ||
            body.contains('hdfc'))) {
      score += 40;
    } else if (isSbi &&
        (senderBank.contains('sbi') || body.contains('sbi'))) {
      score += 40;
    } else if (isIcici &&
        (senderBank.contains('icici') || body.contains('icici'))) {
      score += 40;
    } else if (isAxis &&
        (senderBank.contains('axis') || body.contains('axis'))) {
      score += 40;
    } else if (isKotak &&
        (senderBank.contains('kotak') || body.contains('kotak'))) {
      score += 40;
    } else if (cardBank.isNotEmpty &&
        senderBank.isNotEmpty &&
        (cardBank.contains(senderBank) || senderBank.contains(cardBank))) {
      score += 30;
    }

    if (biller.isNotEmpty && cardName.contains(biller)) {
      score += 20;
    }

    if (obsDue != null && _sameDay(obsDue, dueOn)) {
      score += 30;
    } else if (obsDue != null && (obsDue.difference(dueOn).inDays).abs() <= 5) {
      score += 15;
    }

    if (obs['amount_due_paise'] != null) {
      score += 10;
    }

    if (score > bestScore && score >= 30) {
      bestScore = score;
      best = obs;
    }
  }

  return best;
}

class _ComingUpRow extends ConsumerWidget {
  final DuePayment row;
  const _ComingUpRow({required this.row});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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

    final pairs = ref.watch(myCardsWithProductProvider).valueOrNull ?? const [];
    final product = pairs
        .where((p) => p.$1.id == card.id)
        .map((p) => p.$2)
        .firstOrNull ??
        ref.watch(catalogueProvider).valueOrNull?.where((p) => p.id == card.cardProductId).firstOrNull;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _showCardBillDetailSheet(context, ref, row),
        borderRadius: BorderRadius.circular(18),
        child: Container(
          decoration: BoxDecoration(
            color: isPaid
                ? BambooInk.paperMuted.withValues(alpha: 0.5)
                : BambooInk.glassFillOnPaper,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: isUrgent && !isPaid
                  ? BambooInk.warningBorder
                  : BambooInk.hairlineOnPaper,
            ),
          ),
          padding: const EdgeInsets.all(AppSpace.md),
          child: Row(
            children: [
              MiniCardVisual(
                product: product,
                userCard: card,
                width: 50,
                height: 32,
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
                      maxLines: 1,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      dueDetail,
                      style: BambooFonts.ui(
                        12,
                        color: isUrgent ? BambooInk.clayInk : BambooInk.ink500,
                        weight: isUrgent ? FontWeight.w600 : FontWeight.w400,
                      ),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                    if (isAutopay && !isPaid) ...[
                      const SizedBox(height: 3),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.autorenew_rounded,
                            size: 13,
                            color: BambooInk.jade,
                          ),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              'AutoPay scheduled',
                              style: BambooFonts.ui(
                                11,
                                color: BambooInk.jade,
                                weight: FontWeight.w600,
                              ),
                              overflow: TextOverflow.ellipsis,
                              maxLines: 1,
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
                ),
              const SizedBox(width: 4),
              const Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: BambooInk.ink500,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CardBillDetailSheet extends ConsumerStatefulWidget {
  final DuePayment row;
  const _CardBillDetailSheet({required this.row});

  @override
  ConsumerState<_CardBillDetailSheet> createState() =>
      _CardBillDetailSheetState();
}

class _CardBillDetailSheetState extends ConsumerState<_CardBillDetailSheet> {
  late TextEditingController _amountCtrl;
  late TextEditingController _minDueCtrl;
  late DateTime _selectedDate;
  late bool _isPaid;
  late bool _initialIsPaid;
  bool _saving = false;
  String? _error;
  String? _selectedObservationId;
  Map<String, dynamic>? _detectedSmsObs;
  bool _prefilledFromSms = false;

  @override
  void initState() {
    super.initState();
    _selectedDate = widget.row.dueOn;
    _isPaid = widget.row.bill?.isPaid ?? false;
    _initialIsPaid = _isPaid;

    if (widget.row.bill?.amountDue != null) {
      _amountCtrl = TextEditingController(
        text: widget.row.bill!.amountDue!.rupees.toStringAsFixed(0),
      );
    } else {
      _amountCtrl = TextEditingController();
    }

    if (widget.row.bill?.minimumDue != null) {
      _minDueCtrl = TextEditingController(
        text: widget.row.bill!.minimumDue!.rupees.toStringAsFixed(0),
      );
    } else {
      _minDueCtrl = TextEditingController();
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _lookForCandidateObs();
    });
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _minDueCtrl.dispose();
    super.dispose();
  }

  Future<void> _lookForCandidateObs() async {
    try {
      final cache = await ref.read(responseCacheProvider.future);
      final namespace = ref.read(cacheNamespaceProvider);
      final pairs = ref.read(myCardsWithProductProvider).valueOrNull ?? const [];
      final prod = pairs
              .where((p) => p.$1.id == widget.row.card.id)
              .map((p) => p.$2)
              .firstOrNull ??
          ref
              .read(catalogueProvider)
              .valueOrNull
              ?.where((p) => p.id == widget.row.card.cardProductId)
              .firstOrNull;

      final candidate = _findBestCandidateObs(
        cache.financialStore,
        namespace,
        widget.row.card,
        widget.row.dueOn,
        issuerName: prod?.issuerName,
      );
      if (candidate != null && mounted) {
        setState(() {
          _detectedSmsObs = candidate;
          if (_amountCtrl.text.isEmpty &&
              candidate['amount_due_paise'] != null) {
            final paise = (candidate['amount_due_paise'] as num).toInt();
            _amountCtrl.text = (paise / 100).toStringAsFixed(0);
            _selectedObservationId = candidate['id'] as String?;
            _prefilledFromSms = true;
            final candDue =
                DateTime.tryParse(candidate['due_date'] as String? ?? '');
            if (candDue != null) {
              _selectedDate = candDue;
            }
          }
        });
      }
    } catch (_) {}
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: now.subtract(const Duration(days: 365)),
      lastDate: now.add(const Duration(days: 365 * 2)),
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

  Future<void> _save() async {
    final rawText = _amountCtrl.text.trim().replaceAll(',', '');
    final amount = double.tryParse(rawText);
    if (amount == null || amount <= 0) {
      setState(() => _error = 'Please enter a valid statement amount.');
      return;
    }
    final minRaw = _minDueCtrl.text.trim().replaceAll(',', '');
    final minDue = double.tryParse(minRaw);

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      final cache = await ref.read(responseCacheProvider.future);
      final namespace = ref.read(cacheNamespaceProvider);
      final store = cache.financialStore;
      final card = widget.row.card;
      final amountPaise = Money.fromRupees(amount).paise;
      final minPaise =
          minDue != null && minDue > 0 ? Money.fromRupees(minDue).paise : null;

      final obsId = _selectedObservationId ??
          (_detectedSmsObs != null
              ? _detectedSmsObs!['id'] as String?
              : null) ??
          (widget.row.bill?.sourceIds.isNotEmpty == true
              ? widget.row.bill!.sourceIds.first
              : null);

      if (obsId != null && obsId.isNotEmpty) {
        store.saveCardBillAssignment(
          namespace,
          obsId,
          userCardId: card.id,
          amountDuePaise: amountPaise,
          dueDate: _selectedDate,
          statementDate: _selectedDate.subtract(const Duration(days: 20)),
        );
      }

      final pairs = ref.read(myCardsWithProductProvider).valueOrNull ?? const [];
      final prod = pairs
              .where((p) => p.$1.id == card.id)
              .map((p) => p.$2)
              .firstOrNull ??
          ref
              .read(catalogueProvider)
              .valueOrNull
              ?.where((p) => p.id == card.cardProductId)
              .firstOrNull;

      final senderBankName = prod?.issuerName ??
          (card.cardName.toLowerCase().contains('hdfc')
              ? 'HDFCBK'
              : card.cardName);

      final manualId =
          'manual-bill-${card.id}-${_selectedDate.year}-${_selectedDate.month.toString().padLeft(2, '0')}';
      store.saveObservation(namespace, manualId, {
        'id': manualId,
        'event_type': 'bill',
        'card_last4': card.last4,
        'biller_name': card.cardName,
        'sender_bank': senderBankName,
        'amount_due_paise': amountPaise,
        'minimum_due_paise': ?minPaise,
        'due_date': _selectedDate.toIso8601String(),
        'statement_date':
            _selectedDate.subtract(const Duration(days: 20)).toIso8601String(),
        'statement_date_explicit': true,
        'received_at': DateTime.now().toIso8601String(),
        'confidence': 1.0,
        'reason_codes': ['credit_card_bill'],
      });
      store.saveCardBillAssignment(
        namespace,
        manualId,
        userCardId: card.id,
        amountDuePaise: amountPaise,
        dueDate: _selectedDate,
        statementDate: _selectedDate.subtract(const Duration(days: 20)),
      );

      final txnId =
          'payment-${card.id}-${_selectedDate.year}-${_selectedDate.month.toString().padLeft(2, '0')}';
      if (_isPaid && !_initialIsPaid) {
        final paymentTxn = TransactionEntry(
          id: txnId,
          amount: Money.fromPaise(amountPaise),
          occurredAt: DateTime.now(),
          merchantName: 'Credit Card Bill Payment',
          note:
              'Card payment for ${card.cardName} •••• ${card.last4 ?? ""}',
          entryKind: TxnEntryKind.transfer,
          rail: TxnRail.unknown,
          instrument: TxnInstrument.creditCard,
          instrumentKnown: true,
          source: 'manual',
          status: 'active',
          userCardId: card.id,
          cardLast4: card.last4,
        );
        store.saveTransactions(namespace, [paymentTxn]);
      } else if (!_isPaid && _initialIsPaid) {
        store.deleteTransaction(namespace, txnId);
      }

      ref.invalidate(cardBillLedgerProvider);
      ref.invalidate(paymentsDueProvider);
      ref.invalidate(cardBillReviewItemsProvider);

      unawaited(_recordSmsBillEditFeedback(amountPaise, minPaise));

      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Updated bill for ${card.cardName}')),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Failed to save bill details: $e';
        });
      }
    }
  }

  /// Queues one consented correction against the detected statement SMS after
  /// the local bill save committed. Only a real change against the detected
  /// observation produces evidence; a purely manual bill stays local.
  Future<void> _recordSmsBillEditFeedback(
    int amountPaise,
    int? minPaise,
  ) async {
    final obs = _detectedSmsObs;
    if (obs == null) return;
    final sourceKey = obs['id'] as String? ?? '';
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(sourceKey)) return;
    final originalAmountPaise = obs['amount_due_paise'] as num?;
    final originalMinPaise = obs['minimum_due_paise'] as num?;
    final originalDue =
        DateTime.tryParse(obs['due_date'] as String? ?? '');
    final amountChanged =
        originalAmountPaise == null || originalAmountPaise != amountPaise;
    final minChanged = (originalMinPaise ?? 0) != (minPaise ?? 0);
    final dueChanged =
        originalDue == null ||
        !DateTime(_selectedDate.year, _selectedDate.month, _selectedDate.day)
            .isAtSameMomentAs(
              DateTime(originalDue.year, originalDue.month, originalDue.day),
            );
    if (!amountChanged && !minChanged && !dueChanged) return;
    await queueSmsLearningEvent(
      ref: ref,
      sourceKey: sourceKey,
      action: 'edited',
      resolvedKind: 'bill',
      occurredAtIso:
          (obs['received_at'] as String? ?? DateTime.now().toIso8601String()),
      originalDecision: {
        'kind': 'bill_obligation',
        'origin': 'parser',
        'fields': {
          if (originalAmountPaise != null)
            'amountDueInr': originalAmountPaise / 100,
          if (originalMinPaise != null) 'minimumDueInr': originalMinPaise / 100,
          if (originalDue != null) 'dueDate': originalDue.toUtc().toIso8601String(),
        },
      },
      correctedFields: {
        'amountDueInr': amountPaise / 100,
        if (minPaise != null) 'minimumDueInr': minPaise / 100,
        'dueDate': _selectedDate.toUtc().toIso8601String(),
      },
      correctionKind: amountChanged
          ? 'wrong_amount'
          : dueChanged
              ? 'wrong_date'
              : 'wrong_bill_fields',
    );
  }

  Future<void> _resetBill() async {
    setState(() => _saving = true);
    try {
      final cache = await ref.read(responseCacheProvider.future);
      final namespace = ref.read(cacheNamespaceProvider);
      final store = cache.financialStore;
      final card = widget.row.card;
      final manualId =
          'manual-bill-${card.id}-${_selectedDate.year}-${_selectedDate.month.toString().padLeft(2, '0')}';
      final txnId =
          'payment-${card.id}-${_selectedDate.year}-${_selectedDate.month.toString().padLeft(2, '0')}';

      store.removeCardBillAssignment(namespace, manualId);
      store.deleteObservation(namespace, manualId);
      store.deleteTransaction(namespace, txnId);
      if (_selectedObservationId != null) {
        store.removeCardBillAssignment(namespace, _selectedObservationId!);
      }

      ref.invalidate(cardBillLedgerProvider);
      ref.invalidate(paymentsDueProvider);
      ref.invalidate(cardBillReviewItemsProvider);

      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Reset bill override for ${card.cardName}')),
        );
      }
    } catch (_) {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final card = widget.row.card;
    final isAutopay = card.autopayMode != AutopayMode.off ||
        widget.row.bill?.isAutopay == true;

    final pairs =
        ref.watch(myCardsWithProductProvider).valueOrNull ?? const [];
    final product = pairs
            .where((p) => p.$1.id == card.id)
            .map((p) => p.$2)
            .firstOrNull ??
        ref
            .watch(catalogueProvider)
            .valueOrNull
            ?.where((p) => p.id == card.cardProductId)
            .firstOrNull;

    final candPaise = _detectedSmsObs?['amount_due_paise'] as num?;
    final candAmount = candPaise != null
        ? (candPaise / 100).toStringAsFixed(0)
        : null;
    final candDue = _detectedSmsObs?['due_date'] != null
        ? DateFormat('d MMM').format(
            DateTime.tryParse(_detectedSmsObs!['due_date'] as String) ??
                DateTime.now())
        : null;

    final daysDiff = _selectedDate.difference(DateTime.now()).inDays;
    final dueSubtitle = daysDiff > 0
        ? 'in $daysDiff days'
        : daysDiff == 0
            ? 'due today'
            : '$daysDiff days ago';

    return SafeArea(
      child: Padding(
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

              Row(
                children: [
                  MiniCardVisual(
                    product: product,
                    userCard: card,
                    width: 52,
                    height: 34,
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
                          style:
                              BambooFonts.heading(17, color: BambooInk.ink900),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${product?.issuerName != null ? "${product!.issuerName} · " : ""}${card.last4 != null ? "•••• ${card.last4}" : card.cardName}',
                          style: BambooFonts.ui(12, color: BambooInk.ink500),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded,
                        color: BambooInk.ink500),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: AppSpace.md),
              const Divider(height: 1, color: BambooInk.hairlineOnPaper),
              const SizedBox(height: AppSpace.md),

              if (_detectedSmsObs != null) ...[
                Container(
                  padding: const EdgeInsets.all(AppSpace.md),
                  decoration: BoxDecoration(
                    color: BambooInk.jade.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(14),
                    border:
                        Border.all(color: BambooInk.jade.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.auto_awesome_rounded,
                          color: BambooInk.jade, size: 20),
                      const SizedBox(width: AppSpace.sm),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _prefilledFromSms
                                  ? 'Bill detected from SMS'
                                  : 'Detected statement SMS',
                              style: BambooFonts.ui(
                                13,
                                weight: FontWeight.w600,
                                color: BambooInk.ink900,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _prefilledFromSms
                                  ? 'Pre-filled ₹${_amountCtrl.text} due ${DateFormat('d MMM').format(_selectedDate)} from ${_detectedSmsObs!['sender_bank'] ?? 'bank'} statement SMS.'
                                  : 'Found ₹$candAmount due $candDue from ${_detectedSmsObs!['sender_bank'] ?? 'bank'} SMS.',
                              style:
                                  BambooFonts.ui(12, color: BambooInk.ink700),
                            ),
                          ],
                        ),
                      ),
                      if (!_prefilledFromSms && candAmount != null) ...[
                        const SizedBox(width: AppSpace.xs),
                        TextButton(
                          onPressed: () {
                            setState(() {
                              _amountCtrl.text = candAmount;
                              _selectedObservationId =
                                  _detectedSmsObs!['id'] as String?;
                              _prefilledFromSms = true;
                              if (_detectedSmsObs!['due_date'] != null) {
                                final d = DateTime.tryParse(
                                    _detectedSmsObs!['due_date'] as String);
                                if (d != null) _selectedDate = d;
                              }
                            });
                          },
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 4),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            foregroundColor: BambooInk.jade,
                          ),
                          child: const Text('Use this'),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: AppSpace.md),
              ],

              // Total amount due input
              TextField(
                controller: _amountCtrl,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                style: BambooFonts.money(20, color: BambooInk.ink900),
                decoration: InputDecoration(
                  labelText: 'Total amount due',
                  hintText: 'e.g. 8,331',
                  prefixText: '₹ ',
                  prefixStyle:
                      BambooFonts.money(20, color: BambooInk.ink700),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
              const SizedBox(height: AppSpace.sm),

              // Date picker
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
                              'Due date ($dueSubtitle)',
                              style:
                                  BambooFonts.ui(11, color: BambooInk.ink500),
                            ),
                            Text(
                              DateFormat('EEEE, d MMMM yyyy')
                                  .format(_selectedDate),
                              style: BambooFonts.ui(
                                14,
                                color: BambooInk.ink900,
                                weight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Icon(Icons.arrow_drop_down,
                          color: BambooInk.ink500),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: AppSpace.sm),

              // Minimum due input
              TextField(
                controller: _minDueCtrl,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                style: BambooFonts.money(16, color: BambooInk.ink900),
                decoration: InputDecoration(
                  labelText: 'Minimum amount due (optional)',
                  hintText: 'e.g. 500',
                  prefixText: '₹ ',
                  prefixStyle:
                      BambooFonts.money(16, color: BambooInk.ink700),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
              const SizedBox(height: AppSpace.md),

              if (isAutopay) ...[
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: AppSpace.md, vertical: 10),
                  decoration: BoxDecoration(
                    color: BambooInk.jade.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.autorenew_rounded,
                        size: 16,
                        color: BambooInk.jade,
                      ),
                      const SizedBox(width: AppSpace.sm),
                      Expanded(
                        child: Text(
                          'AutoPay is scheduled for this card on ${DateFormat('d MMM').format(_selectedDate)}',
                          style: BambooFonts.ui(
                            12,
                            weight: FontWeight.w600,
                            color: BambooInk.jade,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpace.sm),
              ],

              // Mark as paid switch
              SwitchListTile.adaptive(
                value: _isPaid,
                onChanged: (val) => setState(() => _isPaid = val),
                title: Text(
                  'Mark bill as paid',
                  style: BambooFonts.ui(14,
                      weight: FontWeight.w600, color: BambooInk.ink900),
                ),
                subtitle: Text(
                  _isPaid
                      ? 'Bill marked as settled for this cycle'
                      : 'Unpaid statement bill',
                  style: BambooFonts.ui(12, color: BambooInk.ink500),
                ),
                activeTrackColor: BambooInk.jade,
                contentPadding: EdgeInsets.zero,
              ),

              if (_error != null) ...[
                const SizedBox(height: AppSpace.xs),
                Text(
                  _error!,
                  style: BambooFonts.ui(12, color: BambooInk.clayInk),
                ),
              ],
              const SizedBox(height: AppSpace.md),

              // Save button
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _saving ? null : _save,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: BambooInk.slate,
                    foregroundColor: BambooInk.lime,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: _saving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor:
                                AlwaysStoppedAnimation(BambooInk.lime),
                          ),
                        )
                      : Text(
                          'Save bill details',
                          style: BambooFonts.ui(
                            15,
                            weight: FontWeight.w600,
                            color: BambooInk.lime,
                          ),
                        ),
                ),
              ),
              const SizedBox(height: AppSpace.xs),

              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TextButton.icon(
                    onPressed: () {
                      Navigator.of(context).pop();
                      context.push('/cards/${card.id}/edit');
                    },
                    icon: const Icon(Icons.settings_outlined, size: 16),
                    label: const Text('Edit card settings'),
                    style: TextButton.styleFrom(
                      foregroundColor: BambooInk.ink700,
                      padding: const EdgeInsets.symmetric(vertical: 8),
                    ),
                  ),
                  if (widget.row.bill != null)
                    TextButton(
                      onPressed: _saving ? null : _resetBill,
                      style: TextButton.styleFrom(
                        foregroundColor: BambooInk.clayInk,
                        padding: const EdgeInsets.symmetric(vertical: 8),
                      ),
                      child: const Text('Reset override'),
                    ),
                ],
              ),
            ],
          ),
        ),
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
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            label,
            style: BambooFonts.heading(17, color: BambooInk.ink900),
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
          ),
        ),
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
                        maxLines: 1,
                      ),
                      if (metaParts.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          metaParts.join(' · '),
                          style: BambooFonts.ui(11.5, color: BambooInk.ink700),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
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
                        maxLines: 1,
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
        overflow: TextOverflow.ellipsis,
        maxLines: 1,
      );
    }
    if (daysUntil < 0) {
      if (commitment.category == CommitmentCategory.subscription) {
        return Text(
          'Active mandate · Auto-debited',
          style: BambooFonts.ui(12, color: BambooInk.ink500),
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
        );
      }
      return Text(
        filter.isUpcoming
            ? 'Past due date · payment status unknown'
            : 'Due ${DateFormat('d MMM').format(commitment.dueOn)} · payment status unknown',
        style: BambooFonts.ui(12, color: BambooInk.clayInk),
        overflow: TextOverflow.ellipsis,
        maxLines: 1,
      );
    }
    if (commitment.isWithinGracePeriod(now)) {
      return Text(
        'Grace window · was due ${DateFormat('d MMM').format(commitment.dueOn)}',
        style: BambooFonts.ui(12, color: BambooInk.amber),
        overflow: TextOverflow.ellipsis,
        maxLines: 1,
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
        overflow: TextOverflow.ellipsis,
        maxLines: 1,
      );
    }
    return Text(
      'Due ${DateFormat('d MMM').format(commitment.dueOn)} · in ${daysUntil}d',
      style: BambooFonts.ui(12, color: BambooInk.ink500),
      overflow: TextOverflow.ellipsis,
      maxLines: 1,
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
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        commitment.category.label,
                        style: BambooFonts.ui(12, color: BambooInk.ink500),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
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
          Flexible(
            child: Text(
              label,
              style: BambooFonts.ui(12.5, color: BambooInk.ink500),
              overflow: TextOverflow.ellipsis,
            ),
          ),
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
                _buildCategoryChip('Investment / SIP', CommitmentCategory.investment),
                _buildCategoryChip('Subscription', CommitmentCategory.subscription),
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
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
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
