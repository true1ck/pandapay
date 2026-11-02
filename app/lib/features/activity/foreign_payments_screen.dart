import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/category_picker.dart';
import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/catalogue_repository.dart';
import '../../data/foreign_payment.dart';

List<ForeignPayment> foreignPaymentsForPeriod(
  Iterable<ForeignPayment> payments, {
  DateTime? from,
  DateTime? to,
  String? query,
  String? categoryId,
}) {
  final needle = query?.trim().toLowerCase() ?? '';
  final start = from == null ? null : DateTime(from.year, from.month, from.day);
  final end = to == null ? null : DateTime(to.year, to.month, to.day + 1);
  return payments.where((payment) {
    final date = payment.occurredAt.toLocal();
    return (start == null || !date.isBefore(start)) &&
        (end == null || date.isBefore(end)) &&
        (categoryId == null || payment.categoryId == categoryId) &&
        (needle.isEmpty ||
            '${payment.merchantName ?? ''} ${payment.originalLabel} ${payment.categoryName ?? ''}'
                .toLowerCase()
                .contains(needle));
  }).toList()..sort((a, b) => b.occurredAt.compareTo(a.occurredAt));
}

/// A second, explicitly estimated figure. It never adds to the INR ledger total.
class ForeignPaymentSummaryCard extends StatelessWidget {
  final List<ForeignPayment> payments;
  final VoidCallback? onTap;
  final bool compact;

  const ForeignPaymentSummaryCard({
    super.key,
    required this.payments,
    this.onTap,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final pending = payments.where((payment) => payment.isPending).toList();
    if (pending.isEmpty) return const SizedBox.shrink();
    var estimated = const Money.zero();
    var estimatedRefunds = const Money.zero();
    var unvalued = 0;
    var unknown = 0;
    for (final payment in pending) {
      final amount = payment.estimatedInr;
      if (amount == null) {
        unvalued++;
      } else {
        if (payment.direction == 'refund') {
          estimatedRefunds += amount;
        } else {
          estimated += amount;
        }
      }
      if (payment.originalAmount == null || payment.originalCurrency == null) {
        unknown++;
      }
    }
    return Material(
      color: BambooInk.paperMuted,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        key: const Key('foreign-payment-summary'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: EdgeInsets.all(compact ? AppSpace.sm : AppSpace.md),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.currency_exchange,
                color: BambooInk.jade,
                size: 20,
              ),
              const SizedBox(width: AppSpace.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Foreign payments awaiting INR confirmation',
                      style: BambooFonts.ui(12.5, weight: FontWeight.w700),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      [
                        if (estimated.paise > 0)
                          '${estimated.format(hidePaise: true)} estimated purchases',
                        if (estimatedRefunds.paise > 0)
                          '${estimatedRefunds.format(hidePaise: true)} estimated refunds',
                        '${pending.length} payment${pending.length == 1 ? '' : 's'}',
                        if (unknown > 0)
                          '$unknown amount${unknown == 1 ? '' : 's'} unclear',
                        if (unvalued > unknown)
                          '${unvalued - unknown} awaiting a rate',
                      ].join(' · '),
                      style: BambooFonts.ui(12, color: BambooInk.ink500),
                    ),
                    if (!compact) ...[
                      const SizedBox(height: 4),
                      Text(
                        'Shown separately from confirmed spending. Bank fees may change the final amount.',
                        style: BambooFonts.ui(11.5, color: BambooInk.ink500),
                      ),
                    ],
                  ],
                ),
              ),
              if (onTap != null)
                const Icon(
                  Icons.chevron_right,
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

class ForeignPaymentTile extends StatelessWidget {
  final ForeignPayment payment;
  final VoidCallback onTap;

  const ForeignPaymentTile({
    super.key,
    required this.payment,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    color: BambooInk.paper,
    elevation: 0,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
      side: const BorderSide(color: BambooInk.hairlineOnPaper),
    ),
    child: ListTile(
      key: ValueKey('foreign-payment-${payment.id}'),
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSpace.md,
        vertical: 4,
      ),
      leading: const Icon(Icons.currency_exchange, color: BambooInk.jade),
      title: Text(
        payment.merchantName ?? 'Foreign payment',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: BambooFonts.ui(14, weight: FontWeight.w700),
      ),
      subtitle: Text(
        '${DateFormat('d MMM yyyy').format(payment.occurredAt.toLocal())} · ${payment.statusLabel}'
        '${payment.isLocallyPending ? ' · Saved on this device' : ''}',
        style: BambooFonts.ui(11.5, color: BambooInk.ink500),
      ),
      trailing: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 145),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              payment.originalLabel,
              maxLines: 2,
              textAlign: TextAlign.right,
              overflow: TextOverflow.ellipsis,
              style: BambooFonts.ui(13, weight: FontWeight.w700),
            ),
            if (payment.billedInr != null || payment.estimatedInr != null)
              Text(
                payment.isConfirmed && payment.billedInr != null
                    ? '${payment.billedInr!.format()} billed'
                    : payment.billedInr != null
                    ? '${payment.billedInr!.format()} · sync pending'
                    : '≈ ${payment.estimatedInr!.format()}',
                style: BambooFonts.ui(11, color: BambooInk.ink500),
              ),
          ],
        ),
      ),
    ),
  );
}

Future<void> openForeignPayment(BuildContext context, ForeignPayment payment) =>
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ForeignPaymentDetailScreen(
          paymentId: payment.id,
          initialPayment: payment,
        ),
      ),
    );

enum _ForeignView { pending, all, confirmed, ignored }

class ForeignPaymentsScreen extends ConsumerStatefulWidget {
  final DateTime? from;
  final DateTime? to;

  const ForeignPaymentsScreen({super.key, this.from, this.to});

  @override
  ConsumerState<ForeignPaymentsScreen> createState() =>
      _ForeignPaymentsScreenState();
}

class _ForeignPaymentsScreenState extends ConsumerState<ForeignPaymentsScreen> {
  _ForeignView _view = _ForeignView.pending;
  String _query = '';

  Future<void> _refresh() async {
    try {
      await ref.read(foreignPaymentsRepositoryProvider).refresh();
      ref.invalidate(foreignPaymentsProvider);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(error))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(foreignPaymentsProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Foreign payments'),
        actions: [
          IconButton(
            tooltip: 'Refresh foreign payments',
            onPressed: _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: AppBackground(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpace.lg,
                AppSpace.sm,
                AppSpace.lg,
                0,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: 'Merchant or currency',
                    ),
                    onChanged: (value) => setState(() => _query = value),
                  ),
                  const SizedBox(height: AppSpace.sm),
                  Wrap(
                    spacing: 6,
                    children: [
                      for (final view in _ForeignView.values)
                        ChoiceChip(
                          label: Text(switch (view) {
                            _ForeignView.pending => 'Awaiting INR',
                            _ForeignView.all => 'All',
                            _ForeignView.confirmed => 'Confirmed',
                            _ForeignView.ignored => 'Ignored',
                          }),
                          selected: _view == view,
                          onSelected: (_) => setState(() => _view = view),
                        ),
                    ],
                  ),
                  if (widget.from != null || widget.to != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        '${widget.from == null ? 'All dates' : DateFormat('d MMM yyyy').format(widget.from!)} – '
                        '${widget.to == null ? 'now' : DateFormat('d MMM yyyy').format(widget.to!)}',
                        style: BambooFonts.ui(12, color: BambooInk.ink500),
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: state.when(
                skipLoadingOnRefresh: true,
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (error, _) => ErrorState(
                  message: userFacingErrorMessage(error),
                  onRetry: _refresh,
                ),
                data: (all) {
                  final period = foreignPaymentsForPeriod(
                    all,
                    from: widget.from,
                    to: widget.to,
                    query: _query,
                  );
                  final visible = period
                      .where(
                        (payment) => switch (_view) {
                          _ForeignView.pending => payment.isPending,
                          _ForeignView.all => !payment.isIgnored,
                          _ForeignView.confirmed => payment.isConfirmed,
                          _ForeignView.ignored => payment.isIgnored,
                        },
                      )
                      .toList();
                  return RefreshIndicator(
                    onRefresh: _refresh,
                    child: ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.all(AppSpace.lg),
                      children: [
                        ForeignPaymentSummaryCard(payments: period),
                        const SizedBox(height: AppSpace.md),
                        if (visible.isEmpty)
                          const EmptyState(
                            icon: Icons.currency_exchange,
                            title: 'No foreign payments here',
                            message:
                                'Foreign purchases appear here with their original currency. Confirmed billed INR is included in spending once.',
                          ),
                        for (final payment in visible)
                          Padding(
                            padding: const EdgeInsets.only(bottom: AppSpace.sm),
                            child: ForeignPaymentTile(
                              payment: payment,
                              onTap: () => openForeignPayment(context, payment),
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ForeignPaymentDetailScreen extends ConsumerStatefulWidget {
  final String paymentId;
  final ForeignPayment? initialPayment;

  const ForeignPaymentDetailScreen({
    super.key,
    required this.paymentId,
    this.initialPayment,
  });

  @override
  ConsumerState<ForeignPaymentDetailScreen> createState() =>
      _ForeignPaymentDetailScreenState();
}

class _ForeignPaymentDetailScreenState
    extends ConsumerState<ForeignPaymentDetailScreen> {
  bool _busy = false;
  ForeignPayment? _updated;

  Future<void> _run(Future<ForeignPayment> Function() action) async {
    setState(() => _busy = true);
    try {
      final payment = await action();
      ref.invalidate(foreignPaymentsProvider);
      if (mounted) setState(() => _updated = payment);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(error))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit(ForeignPayment payment) async {
    final form = GlobalKey<FormState>();
    final currency = TextEditingController(
      text: payment.originalCurrency ?? '',
    );
    final amount = TextEditingController(text: payment.originalAmount ?? '');
    final merchant = TextEditingController(text: payment.merchantName ?? '');
    final saved = await _showForeignDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Original payment'),
        content: SingleChildScrollView(
          child: Form(
            key: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Enter the purchase amount from the merchant or bank. Do not use a balance or credit limit.',
                ),
                const SizedBox(height: 12),
                TextFormField(
                  key: const Key('foreign-original-currency'),
                  controller: currency,
                  textCapitalization: TextCapitalization.characters,
                  maxLength: 3,
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp('[a-zA-Z]')),
                  ],
                  decoration: const InputDecoration(
                    labelText: 'Currency code',
                    hintText: 'USD, EUR, GBP…',
                  ),
                  validator: (value) =>
                      RegExp(
                            r'^[A-Z]{3}$',
                          ).hasMatch((value ?? '').trim().toUpperCase()) &&
                          value!.trim().toUpperCase() != 'INR'
                      ? null
                      : 'Enter a foreign currency code',
                ),
                TextFormField(
                  key: const Key('foreign-original-amount'),
                  controller: amount,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Original amount',
                  ),
                  validator: (value) => _positiveDecimal(value)
                      ? null
                      : 'Enter the actual positive purchase amount',
                ),
                TextFormField(
                  controller: merchant,
                  maxLength: 120,
                  decoration: const InputDecoration(labelText: 'Merchant'),
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
              if (form.currentState!.validate()) {
                Navigator.pop(dialogContext, true);
              }
            },
            child: const Text('Save original amount'),
          ),
        ],
      ),
    );
    final originalCurrency = currency.text.trim().toUpperCase();
    final originalAmount = amount.text.trim();
    final name = merchant.text.trim();
    currency.dispose();
    amount.dispose();
    merchant.dispose();
    if (saved == true && mounted) {
      await _run(
        () => ref
            .read(foreignPaymentsRepositoryProvider)
            .editOriginal(
              payment.id,
              currency: originalCurrency,
              amount: originalAmount,
              merchantName: name.isEmpty ? null : name,
            ),
      );
    }
  }

  Future<void> _confirm(ForeignPayment payment) async {
    final controller = TextEditingController();
    final form = GlobalKey<FormState>();
    final cards = ref.read(userCardsProvider).valueOrNull ?? const [];
    String? cardId;
    if (payment.cardLast4 != null) {
      final matching = cards
          .where((card) => card.last4 == payment.cardLast4)
          .toList();
      if (matching.length == 1) cardId = matching.single.id;
    }
    final saved = await _showForeignDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Confirm billed INR'),
        content: SingleChildScrollView(
          child: Form(
            key: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Use the INR amount billed for this payment in your bank statement or posting. This will count as confirmed spending; an exchange-rate estimate is not proof of the billed amount.',
                ),
                const SizedBox(height: 12),
                TextFormField(
                  key: const Key('foreign-billed-inr'),
                  controller: controller,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Actual billed INR',
                    prefixText: '₹',
                  ),
                  validator: (value) => _inrMoney(value) == null
                      ? 'Enter the actual INR amount, up to two decimals'
                      : null,
                ),
                if (cards.isNotEmpty)
                  DropdownButtonFormField<String>(
                    initialValue: cardId,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Card (optional)',
                    ),
                    items: [
                      const DropdownMenuItem(
                        value: '',
                        child: Text('No linked card'),
                      ),
                      for (final card in cards)
                        DropdownMenuItem(
                          value: card.id,
                          child: Text(
                            card.nickname ?? card.cardName,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (value) => cardId = value == '' ? null : value,
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
              if (form.currentState!.validate()) {
                Navigator.pop(dialogContext, true);
              }
            },
            child: const Text('Confirm billed amount'),
          ),
        ],
      ),
    );
    final billed = _inrMoney(controller.text);
    controller.dispose();
    if (saved == true && billed != null && mounted) {
      await _run(
        () => ref
            .read(foreignPaymentsRepositoryProvider)
            .confirmBilled(payment.id, billedInr: billed, userCardId: cardId),
      );
    }
  }

  Future<void> _category(ForeignPayment payment) async {
    try {
      final categories = await ref.read(categoriesProvider.future);
      if (!mounted) return;
      final selected = await showCategoryBottomSheet(
        context,
        ref,
        categories,
        selectedId: payment.categoryId,
      );
      if (selected != null && mounted) {
        final chosen = categories
            .where((category) => category.id == selected)
            .firstOrNull;
        await _run(
          () => ref
              .read(foreignPaymentsRepositoryProvider)
              .editOriginal(
                payment.id,
                categoryId: chosen?.isCustom == true ? null : selected,
                userCategoryId: chosen?.isCustom == true
                    ? userCategoryIdForServer(selected)
                    : null,
              ),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(error))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(foreignPaymentsProvider);
    final payment =
        state.valueOrNull
            ?.where((item) => item.id == widget.paymentId)
            .firstOrNull ??
        _updated ??
        widget.initialPayment;
    return Scaffold(
      appBar: AppBar(title: const Text('Foreign payment')),
      body: payment == null
          ? state.isLoading
                ? const Center(child: CircularProgressIndicator())
                : ErrorState(
                    message:
                        'This foreign payment is not available on this account.',
                    onRetry: () => ref.invalidate(foreignPaymentsProvider),
                  )
          : AppBackground(
              child: ListView(
                padding: const EdgeInsets.all(AppSpace.lg),
                children: [
                  Text(
                    payment.originalLabel,
                    style: BambooFonts.heading(30, color: BambooInk.ink900),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    payment.merchantName ?? 'Foreign payment',
                    style: BambooFonts.ui(17, weight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    payment.statusLabel,
                    style: BambooFonts.ui(13, color: BambooInk.jade),
                  ),
                  const SizedBox(height: AppSpace.lg),
                  _DetailLine(
                    'Date',
                    DateFormat(
                      'd MMM yyyy',
                    ).format(payment.occurredAt.toLocal()),
                  ),
                  _DetailLine(
                    'Category',
                    payment.categoryName ?? 'Not assigned',
                  ),
                  if (payment.cardLast4 != null)
                    _DetailLine('Card', '•••• ${payment.cardLast4}'),
                  if (payment.direction == 'refund')
                    const _DetailLine('Type', 'Refund'),
                  if (payment.billedInr != null)
                    _DetailLine(
                      payment.isConfirmed ? 'Billed INR' : 'INR to confirm',
                      payment.billedInr!.format(),
                    ),
                  if (payment.estimatedInr != null && !payment.isConfirmed) ...[
                    _DetailLine(
                      'Estimated INR',
                      '≈ ${payment.estimatedInr!.format()}',
                    ),
                    if (payment.rate != null)
                      _DetailLine(
                        'Reference rate',
                        '1 ${payment.originalCurrency ?? ''} = ₹${payment.rate}',
                      ),
                    if (payment.rateDate != null)
                      _DetailLine(
                        'Rate date',
                        DateFormat('d MMM yyyy').format(payment.rateDate!),
                      ),
                    if (payment.rateSource != null)
                      _DetailLine('Rate source', payment.rateSource!),
                  ],
                  const SizedBox(height: AppSpace.md),
                  Text(
                    payment.isConfirmed
                        ? payment.direction == 'refund'
                              ? 'This bank-confirmed refund is recorded separately from purchases. The original purchase amount is preserved.'
                              : 'The billed INR amount is counted once in your spending. The original currency is kept for reference.'
                        : payment.originalAmount == null ||
                              payment.originalCurrency == null
                        ? 'The original purchase amount or currency is unclear. Credit limits and balances are excluded. Add the amount from the merchant or bank to get an estimate.'
                        : 'This payment is shown separately from confirmed INR spending. The reference conversion is an estimate; the bank’s rate and fees may differ.',
                    style: BambooFonts.ui(13, color: BambooInk.ink500),
                  ),
                  if (payment.isLocallyPending) ...[
                    const SizedBox(height: AppSpace.sm),
                    Text(
                      'Saved on this device. Changes will sync when your account and connection are available.',
                      style: BambooFonts.ui(12, color: BambooInk.ink500),
                    ),
                  ],
                  if (payment.syncError != null) ...[
                    const SizedBox(height: AppSpace.sm),
                    Text(
                      payment.syncError!,
                      style: BambooFonts.ui(12, color: BambooInk.amber),
                    ),
                  ],
                  const SizedBox(height: AppSpace.lg),
                  if (payment.isConfirmed && payment.transactionId != null)
                    FilledButton.icon(
                      onPressed: () =>
                          context.push('/activity/${payment.transactionId}'),
                      icon: const Icon(Icons.receipt_long),
                      label: const Text('View billed transaction'),
                    ),
                  if (payment.isPending) ...[
                    FilledButton(
                      onPressed: _busy ? null : () => _confirm(payment),
                      child: const Text('Confirm actual billed INR'),
                    ),
                    const SizedBox(height: AppSpace.sm),
                    OutlinedButton(
                      onPressed: _busy ? null : () => _edit(payment),
                      child: const Text('Edit original amount or currency'),
                    ),
                    TextButton(
                      onPressed: _busy ? null : () => _category(payment),
                      child: const Text('Choose spending category'),
                    ),
                    TextButton.icon(
                      onPressed: _busy
                          ? null
                          : () => _run(
                              () => ref
                                  .read(foreignPaymentsRepositoryProvider)
                                  .retry(payment.id),
                            ),
                      icon: const Icon(Icons.refresh),
                      label: const Text('Retry conversion and sync'),
                    ),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => _run(
                              () => ref
                                  .read(foreignPaymentsRepositoryProvider)
                                  .ignore(payment.id),
                            ),
                      child: const Text('Ignore this payment'),
                    ),
                  ],
                  if (payment.isIgnored)
                    OutlinedButton(
                      onPressed: _busy
                          ? null
                          : () => _run(
                              () => ref
                                  .read(foreignPaymentsRepositoryProvider)
                                  .restore(payment.id),
                            ),
                      child: const Text('Restore payment'),
                    ),
                  if (_busy) const Center(child: CircularProgressIndicator()),
                ],
              ),
            ),
    );
  }
}

class _DetailLine extends StatelessWidget {
  final String label;
  final String value;
  const _DetailLine(this.label, this.value);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 112,
          child: Text(
            label,
            style: BambooFonts.ui(13, color: BambooInk.ink500),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: BambooFonts.ui(14, color: BambooInk.ink900),
          ),
        ),
      ],
    ),
  );
}

bool _positiveDecimal(String? text) {
  final value = text?.trim() ?? '';
  return RegExp(r'^\d{1,15}(?:\.\d{1,3})?$').hasMatch(value) &&
      RegExp('[1-9]').hasMatch(value);
}

/// Adds original-currency context to the single, confirmed INR ledger row.
class ForeignTransactionInfo extends ConsumerWidget {
  final String transactionId;
  const ForeignTransactionInfo({super.key, required this.transactionId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final payment = ref
        .watch(foreignPaymentsProvider)
        .valueOrNull
        ?.where(
          (payment) =>
              payment.transactionId == transactionId && payment.isConfirmed,
        )
        .firstOrNull;
    if (payment == null) return const SizedBox.shrink();
    return Material(
      color: BambooInk.paperMuted,
      borderRadius: BorderRadius.circular(14),
      child: ListTile(
        leading: const Icon(Icons.currency_exchange, color: BambooInk.jade),
        title: Text(
          payment.originalLabel,
          style: BambooFonts.ui(14, weight: FontWeight.w700),
        ),
        subtitle: Text(
          'Original currency · billed INR counted once',
          style: BambooFonts.ui(12, color: BambooInk.ink500),
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => openForeignPayment(context, payment),
      ),
    );
  }
}

Money? _inrMoney(String? text) {
  final value = text?.trim() ?? '';
  if (!RegExp(r'^\d{1,10}(?:\.\d{1,2})?$').hasMatch(value)) return null;
  final pieces = value.split('.');
  final paise =
      int.parse(pieces.first) * 100 +
      int.parse(pieces.length == 1 ? '0' : pieces.last.padRight(2, '0'));
  return paise > 0 ? Money.fromPaise(paise) : null;
}

// A dialog's push result completes before its reverse animation. Wait until
// the route is removed before callers dispose its text controllers.
Future<T?> _showForeignDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) async {
  final route = DialogRoute<T>(context: context, builder: builder);
  final result = await Navigator.of(context, rootNavigator: true).push(route);
  await route.completed;
  return result;
}
