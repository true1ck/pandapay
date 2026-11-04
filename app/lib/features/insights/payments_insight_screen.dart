import 'package:flutter/material.dart';
import 'payments_due_screen.dart';
import 'due_date_calendar_screen.dart';
import 'grouped_insight_screen.dart';
import 'subscriptions_screen.dart';

/// The existing Payments destination, with the original subscription owner
/// embedded as its third tab. No recurring IDs, models or records are migrated.
class PaymentsInsightScreen extends StatelessWidget {
  final String? initialTab;
  const PaymentsInsightScreen({super.key, this.initialTab});

  @override
  Widget build(BuildContext context) => GroupedInsightScreen(
    title: 'Payments',
    initialIndex: switch (initialTab) {
      'due-dates' => 1,
      'subscriptions' => 2,
      _ => 0,
    },
    tabs: const [
      (
        label: 'Bills & commitments',
        body: _RetainedPaymentTab(
          key: PageStorageKey('payments-bills'),
          child: BillsAndCommitmentsTab(),
        ),
      ),
      (
        label: 'Due dates',
        body: _RetainedPaymentTab(
          key: PageStorageKey('payments-due-dates'),
          child: DueDateCalendarScreen(),
        ),
      ),
      (
        label: 'Subscriptions',
        body: _RetainedPaymentTab(
          key: PageStorageKey('payments-subscriptions'),
          child: SubscriptionsScreen(showChrome: false),
        ),
      ),
    ],
  );
}

/// Preserve cadence/filter/provider and scroll state after a visited tab is
/// switched away, and when a service detail is pushed and popped above it.
class _RetainedPaymentTab extends StatefulWidget {
  final Widget child;
  const _RetainedPaymentTab({super.key, required this.child});
  @override
  State<_RetainedPaymentTab> createState() => _RetainedPaymentTabState();
}

class _RetainedPaymentTabState extends State<_RetainedPaymentTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
