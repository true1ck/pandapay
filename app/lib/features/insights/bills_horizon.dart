import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/design/app_theme.dart';
import '../../app/providers.dart';
import '../../data/past_bill_receipts.dart';
import '../../data/pending_bills.dart';

/// What slice of time the Bills & commitments tab is answering for.
///
/// This is a horizon, not a plain date filter: the tab stacks live
/// obligations (card dues, autopay mandates) with dated records (bill SMS,
/// receipts, commitments). A calendar month alone would hide the next card
/// due, an annual renewal, or an autopay mandate that has no due date at all.
enum BillsHorizon { upcoming, currentMonth, lastMonth, lastThreeMonths, allHistory }

/// Defaults to [BillsHorizon.upcoming] so the tab never opens on an empty
/// past month.
final billsHorizonProvider = StateProvider<BillsHorizon>(
  (ref) => BillsHorizon.upcoming,
);

class BillsHorizonFilter {
  final BillsHorizon horizon;
  final DateTime now;

  const BillsHorizonFilter(this.horizon, this.now);

  DateTime get today => DateTime(now.year, now.month, now.day);

  DateTime get _thisMonthStart => DateTime(now.year, now.month, 1);
  DateTime get _nextMonthStart => DateTime(now.year, now.month + 1, 1);

  DateTime? get windowStart => switch (horizon) {
    BillsHorizon.upcoming || BillsHorizon.allHistory => null,
    BillsHorizon.currentMonth => _thisMonthStart,
    BillsHorizon.lastMonth => DateTime(now.year, now.month - 1, 1),
    BillsHorizon.lastThreeMonths => DateTime(now.year, now.month - 2, 1),
  };

  DateTime? get windowEnd => switch (horizon) {
    BillsHorizon.upcoming || BillsHorizon.allHistory => null,
    BillsHorizon.currentMonth || BillsHorizon.lastThreeMonths => _nextMonthStart,
    BillsHorizon.lastMonth => _thisMonthStart,
  };

  bool get isUpcoming => horizon == BillsHorizon.upcoming;

  /// Autopay mandates carry no due date, so they are exempt from the month
  /// windows and only shown where they still matter: now and this month.
  bool get showsAutopay => isUpcoming || horizon == BillsHorizon.currentMonth;

  String get label => switch (horizon) {
    BillsHorizon.upcoming => 'Upcoming',
    BillsHorizon.currentMonth => _monthLabel(now.year, now.month),
    BillsHorizon.lastMonth => _monthLabel(now.year, now.month - 1),
    BillsHorizon.lastThreeMonths => _monthRange(
      DateTime(now.year, now.month - 2),
      DateTime(now.year, now.month),
    ),
    BillsHorizon.allHistory => 'All history',
  };

  String get description => switch (horizon) {
    BillsHorizon.upcoming => 'Next due dates and unpaid bills',
    BillsHorizon.currentMonth =>
      'Bills and receipts in ${_longMonth(now.year, now.month)}',
    BillsHorizon.lastMonth =>
      'Bills and receipts in ${_longMonth(now.year, now.month - 1)}',
    BillsHorizon.lastThreeMonths =>
      'Bills and receipts ${_monthRange(DateTime(now.year, now.month - 2), DateTime(now.year, now.month))}',
    BillsHorizon.allHistory => 'Everything recorded so far',
  };

  bool matchesDue(DateTime date) {
    switch (horizon) {
      case BillsHorizon.upcoming:
        return !date.isBefore(today);
      case BillsHorizon.allHistory:
        return !date.isAfter(today);
      case BillsHorizon.currentMonth:
      case BillsHorizon.lastMonth:
      case BillsHorizon.lastThreeMonths:
        return !date.isBefore(windowStart!) && date.isBefore(windowEnd!);
    }
  }

  /// Upcoming keeps recently overdue unpaid rows visible; the month windows
  /// never widen.
  bool matchesOpenDue(DateTime date) {
    if (isUpcoming) {
      return !date.isBefore(today.subtract(const Duration(days: 90)));
    }
    return matchesDue(date);
  }

  bool matchesSmsBill(SmsBillRow bill) {
    final date = bill.dueDate ?? bill.receivedAt;
    if (isUpcoming) {
      if (bill.state == SmsBillState.linked) return false;
      return !date.isBefore(today.subtract(const Duration(days: 90)));
    }
    return matchesDue(date);
  }

  bool matchesReceipt(PastBillReceipt receipt) {
    if (isUpcoming) return true;
    return matchesDue(receipt.occurredAt);
  }

  /// The scheduled occurrence of a recurring card due day inside the selected
  /// window, so a month view can answer "what was due in September?" even
  /// though the card row only carries the next due date.
  ///
  /// Upcoming returns null because that horizon uses the next actual due date.
  DateTime? scheduledOccurrence(int day) {
    DateTime clamp(int year, int month) {
      final last = DateTime(year, month + 1, 0).day;
      return DateTime(year, month, day > last ? last : day);
    }

    switch (horizon) {
      case BillsHorizon.upcoming:
        return null;
      case BillsHorizon.currentMonth:
        return clamp(now.year, now.month);
      case BillsHorizon.lastMonth:
        return clamp(now.year, now.month - 1);
      case BillsHorizon.lastThreeMonths:
      case BillsHorizon.allHistory:
        final thisMonth = clamp(now.year, now.month);
        // A due day later than today belongs to the next cycle here.
        return thisMonth.isAfter(today)
            ? clamp(now.year, now.month - 1)
            : thisMonth;
    }
  }

  static const _months = <String>[
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

  static String _monthLabel(int year, int month) =>
      '${_months[DateTime(year, month).month - 1]} ${DateTime(year, month).year}';

  static String _monthRange(DateTime start, DateTime end) {
    if (start.year == end.year) {
      return '${_months[start.month - 1]} – ${_months[end.month - 1]} ${end.year}';
    }
    return '${_months[start.month - 1]} ${start.year} – ${_months[end.month - 1]} ${end.year}';
  }

  static String _longMonth(int year, int month) {
    const long = <String>[
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
    ];
    final normalized = DateTime(year, month);
    return '${long[normalized.month - 1]} ${normalized.year}';
  }
}

/// Compact period pill in the style of the Spending tab's date selector.
class BillsHorizonFilterBar extends ConsumerWidget {
  const BillsHorizonFilterBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.watch(clockProvider).now();
    final filter = BillsHorizonFilter(ref.watch(billsHorizonProvider), now);
    return OutlinedButton(
      onPressed: () => _chooseHorizon(context, ref),
      style: OutlinedButton.styleFrom(
        foregroundColor: BambooInk.ink900,
        side: const BorderSide(color: BambooInk.hairlineOnPaper),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        minimumSize: const Size(0, 40),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.calendar_month_rounded, size: 16),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              filter.label,
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ),
          const SizedBox(width: 2),
          const Icon(Icons.keyboard_arrow_down_rounded, size: 16),
        ],
      ),
    );
  }

  Future<void> _chooseHorizon(BuildContext context, WidgetRef ref) async {
    final now = ref.read(clockProvider).now();
    final choice = await showModalBottomSheet<BillsHorizon>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: BambooInk.paper,
      clipBehavior: Clip.antiAlias,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (_) => _BillsHorizonSheet(
        selected: ref.read(billsHorizonProvider),
        now: now,
      ),
    );
    if (choice == null) return;
    ref.read(billsHorizonProvider.notifier).state = choice;
  }
}

class _BillsHorizonSheet extends StatefulWidget {
  final BillsHorizon selected;
  final DateTime now;

  const _BillsHorizonSheet({required this.selected, required this.now});

  @override
  State<_BillsHorizonSheet> createState() => _BillsHorizonSheetState();
}

class _BillsHorizonSheetState extends State<_BillsHorizonSheet> {
  late BillsHorizon _draft = widget.selected;

  @override
  Widget build(BuildContext context) {
    final draftFilter = BillsHorizonFilter(_draft, widget.now);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(AppSpace.lg, 0, AppSpace.lg, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Choose period',
                    style: BambooFonts.heading(20, color: BambooInk.ink900),
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded, size: 28),
                  color: BambooInk.ink900,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
            const SizedBox(height: AppSpace.xs),
            Text(
              'Selected: ${draftFilter.label}',
              style: BambooFonts.ui(13, color: BambooInk.ink900),
            ),
            const SizedBox(height: 3),
            Text(
              draftFilter.description,
              style: BambooFonts.ui(12.5, color: BambooInk.ink500),
            ),
            const SizedBox(height: AppSpace.lg),
            _option(
              BillsHorizon.upcoming,
              Icons.event_available_rounded,
              'Upcoming',
              'Next due dates and unpaid bills',
            ),
            _option(
              BillsHorizon.currentMonth,
              Icons.calendar_month_rounded,
              'This month',
              BillsHorizonFilter(BillsHorizon.currentMonth, widget.now).description,
            ),
            _option(
              BillsHorizon.lastMonth,
              Icons.history_rounded,
              'Last month',
              BillsHorizonFilter(BillsHorizon.lastMonth, widget.now).description,
            ),
            _option(
              BillsHorizon.lastThreeMonths,
              Icons.date_range_rounded,
              'Last 3 months',
              BillsHorizonFilter(BillsHorizon.lastThreeMonths, widget.now).description,
            ),
            _option(
              BillsHorizon.allHistory,
              Icons.all_inbox_rounded,
              'All history',
              'Everything recorded so far',
            ),
            const SizedBox(height: AppSpace.md),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => Navigator.pop(context, _draft),
                style: FilledButton.styleFrom(
                  backgroundColor: BambooInk.lime,
                  foregroundColor: BambooInk.ink900,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: const Text('Apply'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _option(
    BillsHorizon horizon,
    IconData icon,
    String title,
    String subtitle,
  ) {
    final selected = _draft == horizon;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.sm),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => setState(() => _draft = horizon),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpace.md,
            vertical: AppSpace.md,
          ),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFFF1FFDF) : BambooInk.paper,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: selected ? BambooInk.lime : BambooInk.hairlineOnPaper,
              width: selected ? 2 : 1,
            ),
          ),
          child: Row(
            children: [
              Icon(icon, color: BambooInk.ink900, size: 21),
              const SizedBox(width: AppSpace.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: BambooFonts.ui(
                        13.5,
                        weight: FontWeight.w700,
                        color: BambooInk.ink900,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: BambooFonts.ui(11.5, color: BambooInk.ink500),
                    ),
                  ],
                ),
              ),
              if (selected)
                const Icon(
                  Icons.check_circle_rounded,
                  color: BambooInk.jade,
                  size: 20,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
