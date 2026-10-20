import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/spend_reports_repository.dart';
import '../cards/card_summary.dart';
import '../../main.dart' show MoneyText;

const _subscriptionIcons = <IconData>[
  Icons.autorenew_rounded,
  Icons.play_circle_outline_rounded,
  Icons.receipt_long_outlined,
  Icons.workspace_premium_outlined,
  Icons.favorite_border_rounded,
];
const _subscriptionAccent = BambooInk.jade;
const _subscriptionTint = BambooInk.rankBadgeBg;

bool _isDisplayableSubscription(RecurringSeries series) {
  final name = series.displayName.trim();
  if (name.length < 2 || !RegExp(r'[A-Za-z]{2,}').hasMatch(name)) {
    return false;
  }
  final incompleteActiveMandate = series.isMandate && series.hasActiveAutoPay;
  if ((!incompleteActiveMandate && series.typicalAmount.paise <= 0) ||
      (!incompleteActiveMandate && series.nextExpectedOn == null)) {
    return false;
  }
  // Raw UPI VPAs containing '@' are peer/merchant transfer handles, not subscriptions
  if (name.contains('@')) {
    return false;
  }
  // Fuel fill-ups and petrol pumps are variable spends, not subscriptions
  if (RegExp(
    r'\b(petroleum|petrol|fuel|gas\s*station|oil\s*co|hpcl|bpcl|iocl)\b',
    caseSensitive: false,
  ).hasMatch(name)) {
    return false;
  }

  final normalized = name
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .trim();
  return !RegExp(
    r'^(daily|weekly|fortnightly|monthly|quarterly|half yearly|yearly|annual)\s*'
    r'(payment|charge|debit|subscription|mandate|autopay|plan)?$',
  ).hasMatch(normalized);
}

/// Subscriptions — the charges that repeat, found in the user's own history.
///
/// Detected rather than declared. Asking someone to list their
/// subscriptions is asking them to remember the ones they've forgotten,
/// which are exactly the ones worth surfacing. Everything needed was
/// already in the transaction history; nothing had ever read it.
///
/// The annual figure is the point. A ₹649 monthly charge doesn't feel like
/// much; ₹7,788 a year does, and that is the same fact stated in the unit
/// people actually make decisions in.
class SubscriptionsScreen extends ConsumerWidget {
  const SubscriptionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final report = ref.watch(recurringReportProvider);
    // Keep the signed-out copy tied to the app-wide session, not to a
    // report's temporary null value while that session is being restored.
    final signedIn = ref.watch(cacheNamespaceProvider) != 'signed-out';

    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, size: 25),
          color: BambooInk.ink900,
          tooltip: 'Back',
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        titleSpacing: 0,
        title: Text(
          'Subscriptions',
          style: BambooFonts.heading(20, color: BambooInk.ink900),
        ),
        actions: [
          if (signedIn)
            IconButton(
              tooltip: 'Add subscription',
              onPressed: () => _addSubscription(context, ref),
              icon: const Icon(Icons.add_rounded, size: 27),
              color: BambooInk.jade,
            ),
        ],
      ),
      body: AppBackground(
        child: report.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (err, _) => ErrorState(
            message: userFacingErrorMessage(err),
            onRetry: () => ref.invalidate(recurringReportProvider),
          ),
          data: (data) {
            if (data == null) {
              if (signedIn) {
                return RefreshableEmptyState(
                  icon: Icons.sync_problem_rounded,
                  title: 'Subscriptions are still loading',
                  message:
                      'Your account is signed in, but the subscription report is not available yet.',
                  onRefresh: () async =>
                      ref.invalidate(recurringReportProvider),
                );
              }
              return const EmptyState(
                icon: Icons.lock_outline_rounded,
                title: 'Sign in to find your subscriptions',
                message:
                    'Recurring charges are found in your transaction history, which lives '
                    'with your account.',
              );
            }
            final subscriptions = data.series
                .where(_isDisplayableSubscription)
                .toList(growable: false);
            if (subscriptions.isEmpty) {
              // Refreshable, not a dead end: this screen only fills in once
              // a third matching charge lands, so "nothing yet" is the
              // state a user most wants to retry from.
              return RefreshableEmptyState(
                icon: Icons.autorenew_rounded,
                title: 'No confirmed subscriptions found yet',
                message:
                    'PandaPay shows recurring services with a real merchant name. '
                    'Active AutoPay alerts may still be waiting for amount or cadence details.',
                onRefresh: () async => ref.invalidate(recurringReportProvider),
              );
            }
            final totalAnnual = subscriptions.fold(
              const Money.zero(),
              (total, subscription) => total + subscription.annualCost,
            );
            return RefreshIndicator(
              onRefresh: () async => ref.invalidate(recurringReportProvider),
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(
                  AppSpace.lg,
                  AppSpace.sm,
                  AppSpace.lg,
                  AppShell.navClearance,
                ),
                children: [
                  _TotalCard(series: subscriptions, totalAnnual: totalAnnual),
                  const SizedBox(height: AppSpace.lg),
                  for (var i = 0; i < subscriptions.length; i++) ...[
                    _SeriesCard(series: subscriptions[i], toneIndex: i),
                    const SizedBox(height: AppSpace.md),
                  ],
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpace.xs),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(
                          Icons.verified_outlined,
                          size: 16,
                          color: BambooInk.ink500,
                        ),
                        const SizedBox(width: AppSpace.sm),
                        Expanded(
                          child: Text(
                            'Renewal dates are shown only when the charge pattern or AutoPay alert confirms them.',
                            style: BambooFonts.ui(
                              11.5,
                              color: BambooInk.ink500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _addSubscription(BuildContext context, WidgetRef ref) async {
    final draft = await showDialog<_SubscriptionDraft>(
      context: context,
      builder: (_) => const _AddSubscriptionDialog(),
    );
    if (draft == null || !context.mounted) return;

    final repository = ref.read(spendReportsRepositoryProvider);
    if (repository == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sign in to add a subscription.')),
      );
      return;
    }

    try {
      await repository.createRecurring(
        displayName: draft.displayName,
        amountInr: draft.amountInr,
        cadenceDays: draft.cadenceDays,
        nextExpectedOn: draft.nextExpectedOn,
        autopayStatus: draft.autopayStatus,
      );
      ref.invalidate(recurringReportProvider);
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Subscription added.')));
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(error))));
      }
    }
  }
}

class _SubscriptionDraft {
  final String displayName;
  final double amountInr;
  final int cadenceDays;
  final DateTime nextExpectedOn;
  final String autopayStatus;

  const _SubscriptionDraft({
    required this.displayName,
    required this.amountInr,
    required this.cadenceDays,
    required this.nextExpectedOn,
    required this.autopayStatus,
  });
}

class _AddSubscriptionDialog extends StatefulWidget {
  const _AddSubscriptionDialog();

  @override
  State<_AddSubscriptionDialog> createState() => _AddSubscriptionDialogState();
}

class _AddSubscriptionDialogState extends State<_AddSubscriptionDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _amountController = TextEditingController();
  int _cadenceDays = 30;
  String _autopayStatus = 'unknown';
  DateTime _nextExpectedOn = _dateAfterCycle(30);
  bool _renewalDateEdited = false;

  @override
  void dispose() {
    _nameController.dispose();
    _amountController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.sizeOf(context).height * 0.88;
    return Dialog(
      backgroundColor: BambooInk.paper,
      surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: const BorderSide(color: BambooInk.hairlineOnPaper),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 480, maxHeight: maxHeight),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Add subscription',
                        style: BambooFonts.heading(19, color: BambooInk.ink900),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close_rounded),
                      color: BambooInk.ink500,
                    ),
                  ],
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      CardSummaryPanel(
                        elevated: false,
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _FormFieldGroup(
                              title: 'Service name',
                              child: TextFormField(
                                controller: _nameController,
                                textCapitalization: TextCapitalization.words,
                                style: BambooFonts.ui(
                                  14,
                                  weight: FontWeight.w500,
                                ),
                                decoration: _fieldDecoration(
                                  'e.g. Music or video plan',
                                  icon: Icons.subscriptions_outlined,
                                ),
                                validator: (value) {
                                  final name = value?.trim() ?? '';
                                  if (name.length < 2 ||
                                      !RegExp(r'[A-Za-z]{2,}').hasMatch(name)) {
                                    return 'Enter a service name';
                                  }
                                  if (name.length > 80) {
                                    return 'Use 80 characters or fewer';
                                  }
                                  return null;
                                },
                              ),
                            ),
                            const _SubscriptionFormDivider(),
                            _FormFieldGroup(
                              title: 'Typical amount',
                              child: TextFormField(
                                controller: _amountController,
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                      decimal: true,
                                    ),
                                style: BambooFonts.ui(
                                  14,
                                  weight: FontWeight.w500,
                                ),
                                decoration: _fieldDecoration(
                                  '0.00',
                                  icon: Icons.currency_rupee_rounded,
                                ),
                                validator: (value) {
                                  final amount = double.tryParse(
                                    value?.trim() ?? '',
                                  );
                                  if (amount == null ||
                                      amount <= 0 ||
                                      amount > 10000000) {
                                    return 'Enter a valid amount';
                                  }
                                  return null;
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: AppSpace.md),
                      CardSummaryPanel(
                        elevated: false,
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _FormFieldGroup(
                              title: 'Billing frequency',
                              child: _CycleSelector(
                                selectedDays: _cadenceDays,
                                onChanged: _selectCadence,
                              ),
                            ),
                            const SizedBox(height: AppSpace.md),
                            _FormFieldGroup(
                              title: 'Next renewal',
                              child: _renewalDateField(),
                            ),
                            const SizedBox(height: AppSpace.md),
                            _FormFieldGroup(
                              title: 'AutoPay status',
                              child: _AutoPaySelector(
                                value: _autopayStatus,
                                onChanged: (value) => setState(
                                  () => _autopayStatus = value,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: AppSpace.md),
                      Container(
                        padding: const EdgeInsets.all(AppSpace.md),
                        decoration: BoxDecoration(
                          color: BambooInk.rankBadgeBg,
                          borderRadius: BorderRadius.circular(AppRadius.md),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(
                              Icons.info_outline_rounded,
                              size: 18,
                              color: BambooInk.jade,
                            ),
                            const SizedBox(width: AppSpace.sm),
                            Expanded(
                              child: Text(
                                'This tracks the renewal date. A payment appears in Expenses when it is recorded by SMS or added as a transaction.',
                                style: BambooFonts.ui(
                                  11.5,
                                  color: BambooInk.ink700,
                                  height: 1.35,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                child: Row(
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      style: TextButton.styleFrom(
                        foregroundColor: BambooInk.ink700,
                        minimumSize: const Size(76, 48),
                      ),
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: AppSpace.sm),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _save,
                        style: FilledButton.styleFrom(
                          backgroundColor: BambooInk.slate,
                          foregroundColor: BambooInk.lime,
                          minimumSize: const Size.fromHeight(48),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(AppRadius.md),
                          ),
                        ),
                        icon: const Icon(Icons.add_rounded, size: 18),
                        label: const Text('Add subscription'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _renewalDateField() => Material(
    color: BambooInk.slate.withValues(alpha: 0.035),
    borderRadius: BorderRadius.circular(12),
    child: InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: _pickRenewalDate,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Row(
          children: [
            const Icon(Icons.event_outlined, size: 19, color: BambooInk.ink700),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                '${_nextExpectedOn.day} ${_monthName(_nextExpectedOn.month)} ${_nextExpectedOn.year}',
                style: BambooFonts.ui(
                  14,
                  weight: FontWeight.w500,
                  color: BambooInk.ink900,
                ),
              ),
            ),
            const Icon(
              Icons.edit_calendar_outlined,
              color: BambooInk.ink500,
              size: 19,
            ),
          ],
        ),
      ),
    ),
  );

  InputDecoration _fieldDecoration(String hint, {required IconData icon}) =>
      InputDecoration(
        hintText: hint,
        hintStyle: BambooFonts.ui(14, color: BambooInk.ink500),
        filled: true,
        fillColor: BambooInk.slate.withValues(alpha: 0.035),
        prefixIcon: Icon(icon, size: 19, color: BambooInk.ink700),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: BambooInk.slate),
        ),
      );

  void _selectCadence(int cadenceDays) {
    setState(() {
      _cadenceDays = cadenceDays;
      if (!_renewalDateEdited) {
        _nextExpectedOn = _dateAfterCycle(cadenceDays);
      }
    });
  }

  Future<void> _pickRenewalDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _nextExpectedOn,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      setState(() {
        _nextExpectedOn = DateUtils.dateOnly(picked);
        _renewalDateEdited = true;
      });
    }
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.pop(
      context,
      _SubscriptionDraft(
        displayName: _nameController.text.trim(),
        amountInr: double.parse(_amountController.text.trim()),
        cadenceDays: _cadenceDays,
        nextExpectedOn: _nextExpectedOn,
        autopayStatus: _autopayStatus,
      ),
    );
  }

  static String _monthName(int month) => const [
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
  ][month - 1];

  static DateTime _dateAfterCycle(int cadenceDays) {
    final today = DateUtils.dateOnly(DateTime.now());
    final targetYear = cadenceDays == 365 ? today.year + 1 : today.year;
    final targetMonth = cadenceDays == 365 ? today.month : today.month + 1;
    final normalizedYear = targetMonth > 12 ? targetYear + 1 : targetYear;
    final normalizedMonth = targetMonth > 12 ? targetMonth - 12 : targetMonth;
    final lastDay = DateTime(normalizedYear, normalizedMonth + 1, 0).day;
    return DateTime(
      normalizedYear,
      normalizedMonth,
      today.day.clamp(1, lastDay),
    );
  }
}

class _FormFieldGroup extends StatelessWidget {
  final String title;
  final Widget child;

  const _FormFieldGroup({required this.title, required this.child});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        title,
        style: BambooFonts.ui(
          12,
          weight: FontWeight.w600,
          color: BambooInk.ink700,
        ),
      ),
      const SizedBox(height: 10),
      child,
    ],
  );
}

class _SubscriptionFormDivider extends StatelessWidget {
  const _SubscriptionFormDivider();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(vertical: 14),
    child: Divider(height: 1, color: BambooInk.hairlineOnPaper),
  );
}

class _CycleSelector extends StatelessWidget {
  final int selectedDays;
  final ValueChanged<int> onChanged;

  const _CycleSelector({required this.selectedDays, required this.onChanged});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(4),
    decoration: BoxDecoration(
      color: BambooInk.slate.withValues(alpha: 0.045),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Row(
      children: [
        for (final option in const [(30, 'Monthly'), (365, 'Yearly')])
          Expanded(
            child: _CycleOption(
              label: option.$2,
              selected: selectedDays == option.$1,
              onTap: () => onChanged(option.$1),
            ),
          ),
      ],
    ),
  );
}

class _CycleOption extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _CycleOption({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    child: Material(
      color: selected ? BambooInk.lime : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 11),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: BambooFonts.ui(
              12,
              weight: selected ? FontWeight.w600 : FontWeight.w500,
              color: selected ? BambooInk.ink900 : BambooInk.ink700,
            ),
          ),
        ),
      ),
    ),
  );
}

class _AutoPaySelector extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;

  const _AutoPaySelector({required this.value, required this.onChanged});

  static const _labels = <String, String>{
    'unknown': 'Not confirmed',
    'active': 'Active',
    'cancelled': 'Cancelled',
  };

  @override
  Widget build(BuildContext context) => DropdownButtonFormField<String>(
    initialValue: _labels.containsKey(value) ? value : 'unknown',
    isExpanded: true,
    decoration: InputDecoration(
      filled: true,
      fillColor: BambooInk.slate.withValues(alpha: 0.035),
      prefixIcon: const Icon(Icons.bolt_outlined, color: BambooInk.ink700),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: BambooInk.slate),
      ),
    ),
    style: BambooFonts.ui(14, weight: FontWeight.w500, color: BambooInk.ink900),
    items: _labels.entries
        .map(
          (entry) => DropdownMenuItem<String>(
            value: entry.key,
            child: Text(entry.value),
          ),
        )
        .toList(),
    onChanged: (next) {
      if (next != null) onChanged(next);
    },
  );
}

class _InfoPill extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final Color background;

  const _InfoPill({
    required this.icon,
    required this.label,
    required this.color,
    required this.background,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: color.withValues(alpha: 0.16)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 5),
          Text(
            label,
            style: BambooFonts.ui(11.5, weight: FontWeight.w600, color: color),
          ),
        ],
      ),
    );
  }
}

class _TotalCard extends StatelessWidget {
  final List<RecurringSeries> series;
  final Money totalAnnual;
  const _TotalCard({required this.series, required this.totalAnnual});

  @override
  Widget build(BuildContext context) {
    final monthly = Money.fromPaise((totalAnnual.paise / 12).round());
    return ClipRRect(
      borderRadius: BorderRadius.circular(26),
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              BambooInk.slateRaised,
              BambooInk.slate,
              BambooInk.slateLow,
            ],
          ),
        ),
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.all(AppSpace.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: BambooInk.lime.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(AppRadius.md),
                          border: Border.all(
                            color: BambooInk.lime.withValues(alpha: 0.22),
                          ),
                        ),
                        child: const Icon(
                          Icons.calendar_month_rounded,
                          size: 21,
                          color: BambooInk.lime,
                        ),
                      ),
                      const SizedBox(width: AppSpace.md),
                      Expanded(
                        child: Text(
                          'Your recurring spend',
                          style: BambooFonts.heading(
                            15,
                            color: BambooInk.onSlate,
                            letterSpacing: -0.2,
                          ),
                        ),
                      ),
                      Text(
                        '${series.length} subscription${series.length == 1 ? '' : 's'}',
                        style: BambooFonts.ui(
                          11.5,
                          weight: FontWeight.w600,
                          color: BambooInk.onSlateMuted,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpace.lg),
                  Text(
                    'Estimated annual cost',
                    style: BambooFonts.ui(12.5, color: BambooInk.onSlateMuted),
                  ),
                  const SizedBox(height: AppSpace.xs),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Flexible(
                        child: MoneyText(
                          totalAnnual,
                          confidence: Confidence.estimated,
                          style: BambooFonts.money(
                            30,
                            color: BambooInk.onSlate,
                          ),
                        ),
                      ),
                      const SizedBox(width: AppSpace.sm),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 3),
                        child: Text(
                          '/ year',
                          style: BambooFonts.ui(
                            12.5,
                            color: BambooInk.onSlateMuted,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpace.sm),
                  Text(
                    'About ${monthly.format(hidePaise: true)} a month',
                    style: BambooFonts.ui(12.5, color: BambooInk.onSlateSubtle),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SeriesCard extends ConsumerWidget {
  final RecurringSeries series;
  final int toneIndex;

  const _SeriesCard({required this.series, required this.toneIndex});

  static const _months = [
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

  static String _formatDate(DateTime date) =>
      '${date.day} ${_months[date.month - 1]} ${date.year}';

  static DateTime _advanceCycle(DateTime date, int cadenceDays) {
    final current = DateUtils.dateOnly(date);
    if (cadenceDays >= 350) {
      final year = current.year + 1;
      final lastDay = DateTime(year, current.month + 1, 0).day;
      return DateTime(year, current.month, current.day.clamp(1, lastDay));
    }
    if (cadenceDays >= 26 && cadenceDays <= 32) {
      final nextMonth = current.month == 12 ? 1 : current.month + 1;
      final year = current.month == 12 ? current.year + 1 : current.year;
      final lastDay = DateTime(year, nextMonth + 1, 0).day;
      return DateTime(year, nextMonth, current.day.clamp(1, lastDay));
    }
    return current.add(Duration(days: cadenceDays));
  }

  static DateTime _nextEditableDate(DateTime date, int cadenceDays) {
    var next = DateUtils.dateOnly(date);
    final today = DateUtils.dateOnly(DateTime.now());
    while (next.isBefore(today)) {
      next = _advanceCycle(next, cadenceDays);
    }
    return next;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final next = series.nextExpectedOn;
    final icon = _subscriptionIcons[toneIndex % _subscriptionIcons.length];
    return Container(
      decoration: BoxDecoration(
        color: BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: BambooInk.hairlineOnPaper),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0D2B313A),
            blurRadius: 14,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 14, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: _subscriptionTint,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, color: _subscriptionAccent, size: 19),
                ),
                const SizedBox(width: AppSpace.md),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Text(
                      series.displayName,
                      style: BambooFonts.heading(
                        16,
                        color: BambooInk.ink900,
                        height: 1.15,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpace.sm),
                if (series.typicalAmount.paise > 0)
                  Flexible(
                    child: MoneyText(
                      series.typicalAmount,
                      confidence: Confidence.estimated,
                      style: BambooFonts.money(16, color: BambooInk.ink900),
                    ),
                  )
                else
                  Text(
                    'Amount varies',
                    style: BambooFonts.ui(12, color: BambooInk.ink500),
                  ),
              ],
            ),
            const SizedBox(height: AppSpace.md),
            Wrap(
              spacing: AppSpace.xs,
              runSpacing: AppSpace.xs,
              children: [
                _InfoPill(
                  icon: Icons.schedule_rounded,
                  label: series.cadenceConfirmed
                      ? series.cadenceLabel
                      : 'Cadence not confirmed',
                  color: _subscriptionAccent,
                  background: _subscriptionTint,
                ),
                if (series.detectionSource == 'manual')
                  const _InfoPill(
                    icon: Icons.edit_outlined,
                    label: 'Added by you',
                    color: _subscriptionAccent,
                    background: _subscriptionTint,
                  ),
                if (series.hasActiveAutoPay)
                  const _InfoPill(
                    icon: Icons.bolt_rounded,
                    label: 'AutoPay',
                    color: _subscriptionAccent,
                    background: _subscriptionTint,
                  ),
                if (series.needsReview)
                  const _InfoPill(
                    icon: Icons.warning_amber_rounded,
                    label: 'Needs review',
                    color: Color(0xFF9B6500),
                    background: Color(0xFFFFF3D6),
                  ),
              ],
            ),
            const SizedBox(height: AppSpace.xs),
            Text(
              series.typicalAmount.paise > 0
                  ? '${series.annualCost.format(hidePaise: true)} estimated per year'
                  : 'Amount not stated in the AutoPay alert',
              style: BambooFonts.ui(12, color: BambooInk.ink500),
            ),
            if (next != null && !series.needsReview) ...[
              const SizedBox(height: AppSpace.xs),
              Row(
                children: [
                  Icon(
                    Icons.event_available_outlined,
                    size: 16,
                    color: _subscriptionAccent,
                  ),
                  const SizedBox(width: AppSpace.xs),
                  Expanded(
                    child: Text(
                      'Renews around ${next.day} ${_months[next.month - 1]} ${next.year}',
                      style: BambooFonts.ui(
                        12,
                        weight: FontWeight.w600,
                        color: BambooInk.ink700,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            if (series.needsReview &&
                !series.hasPastRenewal &&
                series.lastSeenOn != null) ...[
              const SizedBox(height: AppSpace.xs),
              Row(
                children: [
                  const Icon(
                    Icons.history_toggle_off_rounded,
                    size: 16,
                    color: Color(0xFF9B6500),
                  ),
                  const SizedBox(width: AppSpace.xs),
                  Expanded(
                    child: Text(
                      'No recent charge detected since ${_formatDate(series.lastSeenOn!)}',
                      style: BambooFonts.ui(
                        12,
                        weight: FontWeight.w600,
                        color: BambooInk.ink700,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            if (series.needsReview && series.hasPastRenewal) ...[
              const SizedBox(height: AppSpace.xs),
              Row(
                children: [
                  const Icon(
                    Icons.event_busy_outlined,
                    size: 16,
                    color: Color(0xFF9B6500),
                  ),
                  const SizedBox(width: AppSpace.xs),
                  Expanded(
                    child: Text(
                      'Saved renewal date has passed; please review it',
                      style: BambooFonts.ui(
                        12,
                        weight: FontWeight.w600,
                        color: BambooInk.ink700,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            if (series.cardName != null) ...[
              const SizedBox(height: AppSpace.xs),
              Row(
                children: [
                  const Icon(
                    Icons.credit_card_outlined,
                    size: 16,
                    color: BambooInk.ink500,
                  ),
                  const SizedBox(width: AppSpace.xs),
                  Expanded(
                    child: Text(
                      series.cardName!,
                      style: BambooFonts.ui(11.5, color: BambooInk.ink500),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: AppSpace.md),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _edit(context, ref),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(42),
                      foregroundColor: BambooInk.ink900,
                      side: BorderSide(color: BambooInk.hairlineOnPaper),
                      backgroundColor: Colors.white.withValues(alpha: 0.52),
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppRadius.md),
                      ),
                    ),
                    icon: const Icon(Icons.edit_outlined, size: 16),
                    label: const Text('Edit'),
                  ),
                ),
                const SizedBox(width: AppSpace.sm),
                Expanded(
                  child: TextButton.icon(
                    onPressed: () => _dismiss(context, ref),
                    style: TextButton.styleFrom(
                      minimumSize: const Size.fromHeight(42),
                      foregroundColor: BambooInk.ink700,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    icon: const Icon(Icons.visibility_off_outlined, size: 16),
                    label: const Text('Ignore'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _edit(BuildContext context, WidgetRef ref) async {
    final name = TextEditingController(text: series.displayName);
    final amount = TextEditingController(
      text: series.typicalAmount.rupees.toStringAsFixed(2),
    );
    final cadence = TextEditingController(text: series.cadenceDays.toString());
    var autopayStatus = series.hasActiveAutoPay ? 'active' : series.autopayStatus;
    var next = _nextEditableDate(
      series.nextExpectedOn ?? DateTime.now().add(const Duration(days: 30)),
      series.cadenceDays,
    );
    final formKey = GlobalKey<FormState>();
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(
            'Edit subscription',
            style: BambooFonts.heading(18, color: BambooInk.ink900),
          ),
          content: Form(
            key: formKey,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    controller: name,
                    decoration: const InputDecoration(
                      labelText: 'Service name',
                    ),
                    validator: (v) => (v == null || v.trim().length < 2)
                        ? 'Enter a service name'
                        : null,
                  ),
                  const SizedBox(height: AppSpace.sm),
                  TextFormField(
                    controller: amount,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(labelText: 'Amount (₹)'),
                    validator: (v) => (double.tryParse(v ?? '') ?? 0) <= 0
                        ? 'Enter a valid amount'
                        : null,
                  ),
                  const SizedBox(height: AppSpace.sm),
                  TextFormField(
                    controller: cadence,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Renewal interval (days)',
                    ),
                    validator: (v) {
                      final n = int.tryParse(v ?? '');
                      return n == null || n < 1 || n > 3650
                          ? 'Enter 1–3650 days'
                          : null;
                    },
                  ),
                  const SizedBox(height: AppSpace.sm),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.calendar_month_outlined),
                    title: Text(
                      'Next renewal',
                      style: BambooFonts.ui(
                        13.5,
                        weight: FontWeight.w600,
                        color: BambooInk.ink900,
                      ),
                    ),
                    subtitle: Text(
                      _formatDate(next),
                      style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                    ),
                    onTap: () async {
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: next,
                        firstDate: DateUtils.dateOnly(DateTime.now()),
                        lastDate: DateTime(2100),
                      );
                      if (picked != null) {
                        setDialogState(() => next = picked);
                      }
                    },
                  ),
                  const SizedBox(height: AppSpace.sm),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'AutoPay status',
                      style: BambooFonts.ui(
                        13.5,
                        weight: FontWeight.w600,
                        color: BambooInk.ink900,
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpace.xs),
                  _AutoPaySelector(
                    value: autopayStatus,
                    onChanged: (value) => setDialogState(
                      () => autopayStatus = value,
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (formKey.currentState!.validate()) {
                  Navigator.pop(dialogContext, true);
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (saved == true && context.mounted) {
      try {
        await ref
            .read(spendReportsRepositoryProvider)!
            .updateRecurring(
              series.id,
              displayName: name.text.trim(),
              amountInr: double.parse(amount.text),
              cadenceDays: int.parse(cadence.text),
              nextExpectedOn: next,
              autopayStatus: autopayStatus,
            );
        if (!context.mounted) return;
        ref.invalidate(recurringReportProvider);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Subscription updated.')));
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(e))));
        }
      }
    }
    name.dispose();
    amount.dispose();
    cadence.dispose();
  }

  Future<void> _dismiss(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          'Ignore this subscription?',
          style: BambooFonts.heading(18, color: BambooInk.ink900),
        ),
        content: Text(
          'Hide ${series.displayName} from your subscriptions. You can still find its charges in Transactions.',
          style: BambooFonts.ui(13.5, color: BambooInk.ink500, height: 1.35),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Ignore'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await ref
          .read(spendReportsRepositoryProvider)!
          .dismissRecurring(series.id);
      if (!context.mounted) return;
      ref.invalidate(recurringReportProvider);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Subscription hidden.')));
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(e))));
      }
    }
  }
}
