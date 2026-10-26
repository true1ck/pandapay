import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/card_bill_ledger.dart';
import '../../data/user_cards_repository.dart';
import '../../domain/cycle_engine.dart';
import '../cards/card_visual.dart';
import 'card_bill_review_section.dart';
import 'payments_due_screen.dart' show DuePayment, paymentsDueProvider;

final dueDateCalendarMonthProvider = StateProvider<DateTime>((ref) {
  final now = ref.watch(clockProvider).now();
  return DateTime(now.year, now.month);
});

/// ui-spec.md E8 Due Date Calendar. Statement/due days come from Task E-0's
/// gap-fill (statementDay already existed client-side; dueDay is new).
/// Reminder toggles are LOCAL-ONLY (see dueDateRemindersProvider's
/// doc-comment in app/providers.dart for why) — actual reminder delivery
/// is out of scope here (H3's territory), this screen only owns the
/// on/off state and the calendar view.
class DueDateCalendarScreen extends ConsumerWidget {
  const DueDateCalendarScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pairs = ref.watch(ownedCardsWithProductProvider);
    final reminders = ref.watch(dueDateRemindersProvider);
    final duePayments = ref.watch(paymentsDueProvider).valueOrNull ?? const <DuePayment>[];
    final ledgers = ref.watch(cardBillLedgerProvider).valueOrNull ??
        const <String, CardBillLedger>{};
    final month = ref.watch(dueDateCalendarMonthProvider);
    final monthHeader = Row(
      children: [
        IconButton(
          tooltip: 'Previous month',
          icon: const Icon(Icons.chevron_left_rounded),
          onPressed: () => ref.read(dueDateCalendarMonthProvider.notifier).state =
              DateTime(month.year, month.month - 1),
        ),
        Expanded(
          child: Text(
            '${_monthName(month.month)} ${month.year}',
            textAlign: TextAlign.center,
            style: BambooFonts.heading(16, color: BambooInk.ink900),
          ),
        ),
        IconButton(
          tooltip: 'Next month',
          icon: const Icon(Icons.chevron_right_rounded),
          onPressed: () => ref.read(dueDateCalendarMonthProvider.notifier).state =
              DateTime(month.year, month.month + 1),
        ),
      ],
    );

    return pairs.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => ErrorState(
        message: userFacingErrorMessage(err),
        onRetry: () => ref.invalidate(ownedCardsWithProductProvider),
      ),
      data: (owned) {
        if (owned.isEmpty) {
          return ListView(
            padding: const EdgeInsets.all(AppSpace.lg),
            children: [
              monthHeader,
              const SizedBox(height: AppSpace.md),
              Container(
                padding: const EdgeInsets.all(AppSpace.md),
                decoration: BoxDecoration(
                  color: BambooInk.paperMuted,
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  border: Border.all(color: BambooInk.hairlineOnPaper),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.calendar_month_outlined,
                      size: 20,
                      color: BambooInk.ink500,
                    ),
                    const SizedBox(width: AppSpace.sm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'No cards yet',
                            style: BambooFonts.heading(13.5, color: BambooInk.ink900),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Add a card to see its statement and due dates here.',
                            style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        }

        return ListView(
          padding: const EdgeInsets.all(AppSpace.lg),
          children: [
            monthHeader,
            const SizedBox(height: AppSpace.lg),
            // Show every active card. A missing issuer date is shown as
            // unknown instead of hiding that card or inventing a date.
            for (final (userCard, product) in owned)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpace.md),
                child: _CardDateTile(
                  userCard: userCard,
                  product: product,
                  duePayment: duePayments.where((d) => d.card.id == userCard.id).firstOrNull,
                  ledger: ledgers[userCard.id],
                  month: month,
                  reminderOn: reminders.contains(userCard.id),
                  onToggleReminder: () => ref
                      .read(dueDateRemindersProvider.notifier)
                      .toggle(userCard.id),
                ),
              ),
            CardBillReviewSection(
              includes: (item) {
                final date = item.dueDate ?? item.receivedAt;
                return date.year == month.year && date.month == month.month;
              },
            ),
          ],
        );
      },
    );
  }

  static String _monthName(int month) => const [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ][month - 1];
}

class _CardDateTile extends StatelessWidget {
  final UserCard userCard;
  final CardProduct product;
  final DuePayment? duePayment;
  final CardBillLedger? ledger;
  final DateTime month;
  final bool reminderOn;
  final VoidCallback onToggleReminder;
  const _CardDateTile({
    required this.userCard,
    required this.product,
    this.duePayment,
    this.ledger,
    required this.month,
    required this.reminderOn,
    required this.onToggleReminder,
  });

  @override
  Widget build(BuildContext context) {
    bool inMonth(DateTime date) => date.year == month.year && date.month == month.month;
    final observedDue = ledger?.history
            .where((bill) => bill.dueDate != null && inMonth(bill.dueDate!))
            .firstOrNull?.dueDate ??
        (duePayment != null && inMonth(duePayment!.dueOn)
            ? duePayment!.dueOn : null);
    final observedStatement = ledger?.history
            .where((bill) => bill.statementDateExplicit && inMonth(bill.statementDate))
            .firstOrNull?.statementDate ??
        (duePayment?.bill?.statementDateExplicit == true &&
                inMonth(duePayment!.bill!.statementDate)
            ? duePayment!.bill!.statementDate : null);
    final nextDue = observedDue ??
        (userCard.dueDay == null ? null : _dateInMonth(userCard.dueDay!, month));
    final nextStatement = observedStatement ??
        (userCard.statementDay == null ? null : _dateInMonth(userCard.statementDay!, month));
    final displayName = userCard.nickname?.isNotEmpty == true
        ? userCard.nickname!
        : product.name;

    return Pressable(
      semanticLabel: 'Open details for $displayName',
      haptic: false,
      onTap: () => context.push('/cards/${userCard.id}?tab=statement'),
      child: Container(
        decoration: BoxDecoration(
          color: BambooInk.glassFillOnPaper,
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(color: BambooInk.hairlineOnPaper),
        ),
        padding: const EdgeInsets.all(AppSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                SizedBox(
                  width: 62,
                  child: CardVisual(
                    product: product,
                    userCard: userCard,
                    showProductName: false,
                    effectiveBillingDay: nextStatement?.day ?? userCard.statementDay,
                    effectiveDueDay: nextDue?.day ?? userCard.dueDay,
                  ),
                ),
                const SizedBox(width: AppSpace.sm),
                Expanded(
                  child: Text(
                    displayName,
                    style: BambooFonts.heading(14.5, color: BambooInk.ink900),
                  ),
                ),
                const Icon(
                  Icons.chevron_right_rounded,
                  color: BambooInk.ink300,
                ),
                IconButton(
                  tooltip: reminderOn
                      ? 'Reminder on (this device only)'
                      : 'Remind me (this device only)',
                  icon: Icon(
                    reminderOn
                        ? Icons.notifications_active_rounded
                        : Icons.notifications_none_rounded,
                    color: reminderOn ? BambooInk.jade : BambooInk.ink300,
                  ),
                  onPressed: onToggleReminder,
                ),
              ],
            ),
            if (nextStatement != null) ...[
              const SizedBox(height: AppSpace.sm),
              _DateRow(
                icon: Icons.receipt_outlined,
                label: observedStatement == null ? 'Statement cuts (scheduled)' : 'Statement cuts',
                date: nextStatement,
              ),
            ],
            if (nextDue != null) ...[
              const SizedBox(height: AppSpace.sm),
              _DateRow(
                icon: Icons.event_outlined,
                label: observedDue == null ? 'Payment due (scheduled)' : 'Payment due',
                date: nextDue,
                emphasize: true,
              ),
            ],
            if (nextDue == null) ...[
              const SizedBox(height: AppSpace.sm),
              const _MissingDateRow(),
            ],
          ],
        ),
      ),
    );
  }

  static DateTime _dateInMonth(int day, DateTime month) =>
      CycleEngine.nextOccurrence(day, DateTime(month.year, month.month, 1));
}

class _MissingDateRow extends StatelessWidget {
  const _MissingDateRow();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(
          Icons.event_busy_outlined,
          size: 16,
          color: BambooInk.ink500,
        ),
        const SizedBox(width: AppSpace.sm),
        Expanded(
          child: Text(
            'Payment due — issuer date not available',
            style: BambooFonts.ui(13.5, color: BambooInk.ink500),
          ),
        ),
      ],
    );
  }
}

class _DateRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final DateTime date;
  final bool emphasize;
  const _DateRow({
    required this.icon,
    required this.label,
    required this.date,
    this.emphasize = false,
  });

  @override
  Widget build(BuildContext context) {
    final daysLeft = date
        .difference(
          DateTime(
            DateTime.now().year,
            DateTime.now().month,
            DateTime.now().day,
          ),
        )
        .inDays;
    return Row(
      children: [
        Icon(
          icon,
          size: 16,
          color: emphasize ? BambooInk.clay : BambooInk.ink500,
        ),
        const SizedBox(width: AppSpace.sm),
        Expanded(
          child: Text(
            '$label — ${date.day}/${date.month}/${date.year}',
            style: BambooFonts.ui(13.5, color: BambooInk.ink900),
          ),
        ),
        Text(
          daysLeft < 0 ? '${-daysLeft}d ago' : '${daysLeft}d',
          style: BambooFonts.ui(
            12.5,
            color: emphasize ? BambooInk.clay : BambooInk.ink500,
          ),
        ),
      ],
    );
  }
}
