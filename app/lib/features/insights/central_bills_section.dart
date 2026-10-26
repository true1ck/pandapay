import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../app/design/app_theme.dart';
import '../../app/env.dart';
import '../../app/providers.dart';
import '../../data/bills_projection_api.dart';
import '../../data/commitments_repository.dart';
import '../../data/local/response_cache.dart';
import 'bills_horizon.dart';

String _identity(String? value) =>
    (value ?? '').toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');

/// Returns true if a central projection represents a credit card obligation.
bool isCreditCardBill(BillProjection row) {
  if (row.projectionKind != 'bill_obligation') return false;
  final title = (row.billerName ?? row.serviceName ?? '').toLowerCase();
  final kind = (row.projection['obligationKind'] as String? ?? '').toLowerCase();
  final category = (row.projection['category'] as String? ?? '').toLowerCase();
  if (kind.contains('credit_card') || kind.contains('card')) return true;
  if (category.contains('credit_card') || category.contains('card')) return true;
  if (title.contains('credit card') || title.contains('card bill')) return true;
  const issuers = [
    'hdfc', 'sbi', 'icici', 'axis', 'kotak', 'amex',
    'citi', 'rbl', 'indusind', 'bob', 'pnb', 'idfc', 'onecard'
  ];
  final hasIssuer = issuers.any((b) => title.contains(b));
  if (hasIssuer && (title.contains('card') || title.contains('credit'))) return true;
  return false;
}

/// Local NACH/auto-debit evidence that has not been turned into a
/// subscription. Shared so the tab's empty state and the section agree.
List<Map<String, dynamic>> localAutopayMandates(
  ResponseCache? cache,
  String namespace,
) {
  if (cache == null) return const [];
  final keys = <String>{};
  final unique = <Map<String, dynamic>>[];
  for (final row in cache.financialStore.entities(namespace, 'sms_observations')) {
    if (row['event_type'] != 'autopay' ||
        row['autopay_limit_paise'] is! num ||
        isSubscriptionAutoPay(row['biller_name'] as String?)) {
      continue;
    }
    final key = '${_identity(row['biller_name'] as String?)}'
        '|${row['card_last4'] ?? row['account_last4'] ?? ''}';
    if (keys.add(key)) unique.add(row);
  }
  return unique;
}

String _localMandateKey(Map<String, dynamic> row) =>
    '${_identity(row['biller_name'] as String?)}'
    '|${row['card_last4'] ?? row['account_last4'] ?? ''}';

/// Fingerprint of a card row already rendered by the Bills & commitments tab.
/// Central bill projections matching this evidence stay hidden from the
/// second list.
class CentralBillDedupKey {
  final String? last4;
  final DateTime dueOn;
  final double? amountInr;

  const CentralBillDedupKey({
    required this.last4,
    required this.dueOn,
    required this.amountInr,
  });
}

final centralBillsProjectionApiProvider = Provider<BillsProjectionApi?>((ref) {
  ref.watch(cacheNamespaceProvider);
  final token = ref.read(accessTokenProvider);
  if (token == null) return null;
  return BillsProjectionApi(
    apiBaseUrl: Env.apiBaseUrl,
    accessToken: token,
    client: ref.read(authenticatedHttpClientProvider),
  );
});

final centralBillsProjectionProvider =
    FutureProvider<BillProjectionSnapshot>((ref) async {
  final api = ref.watch(centralBillsProjectionApiProvider);
  if (api == null) return const BillProjectionSnapshot.unavailable();
  return api.fetch();
});

/// Optional server-backed rows for Bills & Commitments. Errors are hidden so a
/// network outage never removes the existing local/offline commitments list.
class CentralBillsSection extends ConsumerWidget {
  final List<CentralBillDedupKey> cardRows;
  final BillsHorizonFilter? filter;

  const CentralBillsSection({super.key, this.cardRows = const [], this.filter});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cache = ref.watch(responseCacheProvider).valueOrNull;
    final namespace = ref.watch(cacheNamespaceProvider);
    final uniqueLocalMandates = localAutopayMandates(cache, namespace);
    final localMandateKeys = {
      for (final row in uniqueLocalMandates) _localMandateKey(row),
    };
    final snapshot = ref.watch(centralBillsProjectionProvider).valueOrNull;
    final localCommitments = ref.watch(commitmentsProvider).valueOrNull ?? const <Commitment>[];
    final today = filter?.today ?? DateTime.now();
    final startOfToday = DateTime(today.year, today.month, today.day);
    final rows = (snapshot?.available == true ? snapshot!.projections : const <BillProjection>[])
        .where((row) => row.projectionKind == 'bill_obligation' || row.projectionKind == 'mandate')
        .where((row) => row.projectionKind != 'mandate' ||
            !isSubscriptionAutoPay(row.billerName ?? row.serviceName))
        .where((row) => row.projectionKind == 'mandate' ||
            (row.dueDate != null &&
                (filter == null
                    ? !row.dueDate!.isBefore(startOfToday)
                    : filter!.matchesDue(row.dueDate!))))
        .where((row) => row.projectionKind == 'mandate' || !_duplicatesExistingBill(row, cardRows, localCommitments))
        .toList(growable: false);

    final showMandates = filter == null || filter!.showsAutopay;
    final bills = rows
        .where((row) => row.projectionKind == 'bill_obligation')
        .where((row) => !isCreditCardBill(row))
        .toList();
    final mandates = showMandates
        ? rows.where((row) {
            if (row.projectionKind != 'mandate') return false;
            if (isSubscriptionAutoPay(row.billerName ?? row.serviceName)) return false;
            final key = '${_identity(row.billerName ?? row.serviceName)}'
                '|${row.last4 ?? ''}';
            return !localMandateKeys.contains(key);
          }).toList()
        : const <BillProjection>[];
    final localMandateRows =
        showMandates ? uniqueLocalMandates : const <Map<String, dynamic>>[];
    if (bills.isEmpty && mandates.isEmpty && localMandateRows.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (bills.isNotEmpty) ...[
          const _CentralHeader(label: 'Bills from messages'),
          const SizedBox(height: AppSpace.md),
          for (final row in bills) CentralRow(row: row),
          if (mandates.isNotEmpty || localMandateRows.isNotEmpty)
            const SizedBox(height: AppSpace.lg),
        ],
        if (mandates.isNotEmpty || localMandateRows.isNotEmpty) ...[
          const _CentralHeader(label: 'Autopay authorizations'),
          const SizedBox(height: AppSpace.md),
          for (final row in localMandateRows) LocalMandateRow(row: row),
          for (final row in mandates) CentralRow(row: row),
          const SizedBox(height: AppSpace.lg),
        ],
      ],
    );
  }
}

bool _sameLocalDay(DateTime a, DateTime b) {
  final left = a.toLocal();
  final right = b.toLocal();
  return left.year == right.year &&
      left.month == right.month &&
      left.day == right.day;
}

bool _duplicatesExistingBill(
  BillProjection row,
  List<CentralBillDedupKey> cardRows,
  List<Commitment> localCommitments,
) {
  final date = row.dueDate;
  if (date == null) return false;
  final amount = row.amountInr;
  bool sameAmount(double? value) => amount != null &&
      value != null &&
      (value - amount).abs() < 0.01;

  if (row.last4 != null &&
      cardRows.any((card) =>
          card.last4 == row.last4 &&
          _sameLocalDay(card.dueOn, date) &&
          sameAmount(card.amountInr))) {
    return true;
  }

  // Hosted facts created from issuer/aggregator bill messages may not carry
  // a suffix. Once the local ledger has resolved that exact amount and due
  // date to an owned card, the suffix-less projection is the same bill, not
  // a second generic "HDFC Credit Card" obligation.
  if (row.last4 == null &&
      cardRows.any((card) =>
          _sameLocalDay(card.dueOn, date) && sameAmount(card.amountInr))) {
    return true;
  }

  final title = _identity(row.billerName ?? row.serviceName);
  if (title.isEmpty) return false;
  return localCommitments.any((commitment) {
    final localTitle = _identity(commitment.title);
    final sameTitle = localTitle == title ||
        localTitle.contains(title) ||
        title.contains(localTitle);
    final localAmount = commitment.amount?.rupees;
    return sameTitle &&
        _sameLocalDay(commitment.dueOn, date) &&
        sameAmount(localAmount);
  });
}

/// Whether any central row would render under [filter]. The same dedup and
/// kind filters as [CentralBillsSection] apply, so an empty state is never
/// hidden behind rows the section itself suppresses.
bool hasVisibleCentralBills(
  BillProjectionSnapshot? snapshot,
  BillsHorizonFilter? filter, {
  List<CentralBillDedupKey> cardRows = const [],
  List<Commitment> localCommitments = const [],
}) {
  if (snapshot == null || !snapshot.available) return false;
  final today = filter?.today ?? DateTime.now();
  final startOfToday = DateTime(today.year, today.month, today.day);
  return snapshot.projections.any((row) {
    if (row.projectionKind != 'bill_obligation' &&
        row.projectionKind != 'mandate') {
      return false;
    }
    if (row.projectionKind == 'bill_obligation' && isCreditCardBill(row)) {
      return false;
    }
    if (row.projectionKind == 'mandate') {
      if (isSubscriptionAutoPay(row.billerName ?? row.serviceName)) return false;
      return filter == null || filter.showsAutopay;
    }
    final due = row.dueDate;
    if (due == null) return false;
    final inWindow = filter == null ? !due.isBefore(startOfToday) : filter.matchesDue(due);
    if (!inWindow) return false;
    return !_duplicatesExistingBill(row, cardRows, localCommitments);
  });
}

class _CentralHeader extends StatelessWidget {
  final String label;
  const _CentralHeader({required this.label});

  @override
  Widget build(BuildContext context) => Text(
    label,
    style: BambooFonts.ui(13, color: BambooInk.ink700, weight: FontWeight.w700),
  );
}

class LocalMandateRow extends StatelessWidget {
  final Map<String, dynamic> row;
  const LocalMandateRow({super.key, required this.row});

  @override
  Widget build(BuildContext context) {
    final title = (row['biller_name'] as String?)?.trim();
    final paise = (row['autopay_limit_paise'] as num).toInt();
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpace.sm),
      padding: const EdgeInsets.all(AppSpace.md),
      decoration: BoxDecoration(
        color: BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      child: Row(children: [
        const Icon(Icons.receipt_long_rounded, color: BambooInk.ink500, size: 20),
        const SizedBox(width: AppSpace.sm),
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title == null || title.isEmpty ? 'AutoPay authorization' : title,
                style: BambooFonts.ui(14, color: BambooInk.ink900, weight: FontWeight.w600)),
            const SizedBox(height: 3),
            Text('AutoPay setup reported', style: BambooFonts.ui(11, color: BambooInk.ink500)),
          ],
        )),
        Text('AutoPay limit ₹${(paise / 100).toStringAsFixed(0)}',
            style: BambooFonts.money(14, color: BambooInk.ink900)),
      ]),
    );
  }
}

class CentralRow extends StatelessWidget {
  final BillProjection row;
  const CentralRow({super.key, required this.row});

  @override
  Widget build(BuildContext context) {
    final title = row.billerName ?? row.serviceName ?? 'Financial obligation';
    final date = row.dueDate ?? row.asOfAt;
    final amount = row.amountInr ?? row.authorizationLimitInr;
    final amountLabel = row.projectionKind == 'mandate'
        ? (amount == null ? null : 'AutoPay limit ₹${amount.toStringAsFixed(0)}')
        : (amount == null ? null : '₹${amount.toStringAsFixed(0)}');
    final subtitle = row.projectionKind == 'mandate'
        ? [
            'AutoPay setup reported',
            if (date != null) DateFormat('d MMM yyyy').format(date.toLocal()),
          ].join(' · ')
        : [
            if (date != null) 'Due ${DateFormat('d MMM yyyy').format(date.toLocal())}',
            'Check payment status',
          ].join(' · ');
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpace.sm),
      padding: const EdgeInsets.all(AppSpace.md),
      decoration: BoxDecoration(
        color: BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      child: Row(
        children: [
          const Icon(Icons.receipt_long_rounded, color: BambooInk.ink500, size: 20),
          const SizedBox(width: AppSpace.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: BambooFonts.ui(14, color: BambooInk.ink900, weight: FontWeight.w600)),
                const SizedBox(height: 3),
                Text(subtitle, style: BambooFonts.ui(11, color: BambooInk.ink500)),
              ],
            ),
          ),
          if (amountLabel != null)
            Text(
              amountLabel,
              style: BambooFonts.money(14, color: BambooInk.ink900),
            ),
        ],
      ),
    );
  }
}
