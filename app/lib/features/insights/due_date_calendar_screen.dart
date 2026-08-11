import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/user_cards_repository.dart';

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

    return pairs.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => ErrorState(
        message: userFacingErrorMessage(err),
        onRetry: () => ref.invalidate(ownedCardsWithProductProvider),
      ),
      data: (owned) {
        final withDates = owned.where((p) => p.$1.statementDay != null || p.$1.dueDay != null).toList();
        if (owned.isEmpty) {
          return const EmptyState(
            icon: Icons.calendar_month_outlined,
            title: 'No cards yet',
            message: 'Add a card to see its statement and due dates here.',
          );
        }

        final now = DateTime.now();
        return ListView(
          padding: const EdgeInsets.all(AppSpace.lg),
          children: [
            Text(
              '${_monthName(now.month)} ${now.year}',
              style: BambooFonts.heading(16, color: BambooInk.ink900),
            ),
            const SizedBox(height: AppSpace.lg),
            if (withDates.isEmpty)
              const EmptyState(
                icon: Icons.event_busy_rounded,
                title: 'No dates set yet',
                message: 'None of your cards have a statement or due day entered.',
              )
            else
              for (final (userCard, product) in withDates)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpace.md),
                  child: _CardDateTile(
                    userCard: userCard,
                    product: product,
                    reminderOn: reminders.contains(userCard.id),
                    onToggleReminder: () => ref.read(dueDateRemindersProvider.notifier).toggle(userCard.id),
                  ),
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
  final bool reminderOn;
  final VoidCallback onToggleReminder;
  const _CardDateTile({
    required this.userCard,
    required this.product,
    required this.reminderOn,
    required this.onToggleReminder,
  });

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final nextDue = userCard.dueDay == null ? null : _nextOccurrence(userCard.dueDay!, now);
    final nextStatement = userCard.statementDay == null ? null : _nextOccurrence(userCard.statementDay!, now);

    return Container(
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
              Expanded(
                child: Text(
                  userCard.nickname?.isNotEmpty == true ? userCard.nickname! : product.name,
                  style: BambooFonts.heading(14.5, color: BambooInk.ink900),
                ),
              ),
              IconButton(
                tooltip: reminderOn ? 'Reminder on (this device only)' : 'Remind me (this device only)',
                icon: Icon(
                  reminderOn ? Icons.notifications_active_rounded : Icons.notifications_none_rounded,
                  color: reminderOn ? BambooInk.jade : BambooInk.ink300,
                ),
                onPressed: onToggleReminder,
              ),
            ],
          ),
          if (nextStatement != null) ...[
            const SizedBox(height: AppSpace.sm),
            _DateRow(icon: Icons.receipt_outlined, label: 'Statement cuts', date: nextStatement),
          ],
          if (nextDue != null) ...[
            const SizedBox(height: AppSpace.sm),
            _DateRow(icon: Icons.event_outlined, label: 'Payment due', date: nextDue, emphasize: true),
          ],
        ],
      ),
    );
  }

  static DateTime _nextOccurrence(int day, DateTime now) {
    var next = DateTime(now.year, now.month, day);
    if (!next.isAfter(now)) next = DateTime(now.year, now.month + 1, day);
    return next;
  }
}

class _DateRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final DateTime date;
  final bool emphasize;
  const _DateRow({required this.icon, required this.label, required this.date, this.emphasize = false});

  @override
  Widget build(BuildContext context) {
    final daysLeft = date
        .difference(DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day))
        .inDays;
    return Row(
      children: [
        Icon(icon, size: 16, color: emphasize ? BambooInk.clay : BambooInk.ink500),
        const SizedBox(width: AppSpace.sm),
        Expanded(
          child: Text(
            '$label — ${date.day}/${date.month}/${date.year}',
            style: BambooFonts.ui(13.5, color: BambooInk.ink900),
          ),
        ),
        Text(
          '${daysLeft}d',
          style: BambooFonts.ui(12.5, color: emphasize ? BambooInk.clay : BambooInk.ink500),
        ),
      ],
    );
  }
}
