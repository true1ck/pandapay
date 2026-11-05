import 'package:pandapay_domain/pandapay_domain.dart';


/// Original-currency evidence lives beside the INR ledger until billed INR is
/// known. An estimate is never an amount to apply to card or reward state.
class ForeignPayment {
  final String id;
  final String sourceKey;
  final String? originalCurrency;
  final String? originalAmount;
  final DateTime occurredAt;
  final String? merchantName;
  final String? cardLast4;
  final String? accountLast4;
  final String? userCardId;
  final String? categoryId;
  final String? userCategoryId;
  final String? categoryName;
  final String valuationStatus;
  final Money? estimatedInr;
  final Money? billedInr;
  final String? rate;
  final DateTime? rateDate;
  final String? rateSource;
  final String? transactionId;
  final String? confirmationSource;
  final String direction;
  final String? reference;
  final String instrument;
  final bool isLocallyPending;
  final bool userModified;
  final String? syncError;

  const ForeignPayment({
    required this.id,
    required this.sourceKey,
    required this.occurredAt,
    this.originalCurrency,
    this.originalAmount,
    this.merchantName,
    this.cardLast4,
    this.accountLast4,
    this.userCardId,
    this.categoryId,
    this.userCategoryId,
    this.categoryName,
    this.valuationStatus = 'awaiting_amount',
    this.estimatedInr,
    this.billedInr,
    this.rate,
    this.rateDate,
    this.rateSource,
    this.transactionId,
    this.confirmationSource,
    this.direction = 'spend',
    this.reference,
    this.instrument = 'other',
    this.isLocallyPending = false,
    this.userModified = false,
    this.syncError,
  });

  bool get isConfirmed => valuationStatus == 'confirmed';
  bool get isIgnored => valuationStatus == 'ignored';
  bool get isPending => !isConfirmed && !isIgnored;
  String get originalLabel => originalAmount == null
      ? '${originalCurrency ?? 'Foreign currency'} · amount needed'
      : '${originalCurrency ?? 'Currency needed'} $originalAmount';
  String get statusLabel => switch (valuationStatus) {
    'confirmed' => 'Billed INR confirmed',
    'estimated' => 'Estimated INR · awaiting billed amount',
    'awaiting_rate' => 'INR estimate pending',
    'ignored' => 'Dismissed',
    _ => 'Amount or currency needs confirmation',
  };

  Map<String, dynamic> toJson() => {
    'id': id,
    'source_key': sourceKey,
    'original_currency': originalCurrency,
    'original_amount': originalAmount,
    'occurred_at': occurredAt.toUtc().toIso8601String(),
    'merchant_name': merchantName,
    'card_last4': cardLast4,
    'account_last4': accountLast4,
    'user_card_id': userCardId,
    'category_id': categoryId,
    'user_category_id': userCategoryId,
    'category_name': categoryName,
    'valuation_status': valuationStatus,
    'estimated_inr': moneyDecimal(estimatedInr),
    'billed_inr': moneyDecimal(billedInr),
    'rate': rate,
    'rate_date': rateDate?.toIso8601String().substring(0, 10),
    'rate_source': rateSource,
    'transaction_id': transactionId,
    'confirmation_source': confirmationSource,
    'direction': direction,
    'reference': reference,
    'instrument': instrument,
    'locally_pending': isLocallyPending,
    'user_modified': userModified,
    'sync_error': syncError,
  };

  ForeignPayment withPatch(Map<String, dynamic> patch) =>
      ForeignPayment.fromJson({...toJson(), ...patch});

  factory ForeignPayment.fromJson(Map<String, dynamic> json) => ForeignPayment(
    id: json['id'] as String,
    sourceKey: json['source_key'] as String,
    occurredAt: DateTime.parse(json['occurred_at'] as String),
    originalCurrency: json['original_currency'] as String?,
    originalAmount: json['original_amount']?.toString(),
    merchantName: json['merchant_name'] as String?,
    cardLast4: json['card_last4'] as String?,
    accountLast4: json['account_last4'] as String?,
    userCardId: json['user_card_id'] as String?,
    categoryId: json['category_id'] as String?,
    userCategoryId: json['user_category_id'] as String?,
    categoryName: json['category_name'] as String?,
    valuationStatus: json['valuation_status'] as String? ?? 'awaiting_amount',
    estimatedInr: parseInrMoney(json['estimated_inr']),
    billedInr: parseInrMoney(json['billed_inr']),
    rate: json['rate']?.toString(),
    rateDate: DateTime.tryParse(json['rate_date']?.toString() ?? ''),
    rateSource: json['rate_source'] as String?,
    transactionId: json['transaction_id'] as String?,
    confirmationSource: json['confirmation_source'] as String?,
    direction: json['direction'] as String? ?? 'spend',
    reference: json['reference'] as String?,
    instrument: json['instrument'] as String? ?? 'other',
    isLocallyPending: json['locally_pending'] == true,
    userModified: json['user_modified'] == true,
    syncError: json['sync_error'] as String?,
  );
}

Money? parseInrMoney(Object? value) {
  if (value == null) return null;
  final m = RegExp(
    r'^(\d{1,13})(?:\.(\d{1,2}))?$',
  ).firstMatch(value.toString());
  if (m == null) return null;
  return Money.fromPaise(
    int.parse(m[1]!) * 100 + int.parse((m[2] ?? '').padRight(2, '0')),
  );
}

String? moneyDecimal(Money? value) => value == null
    ? null
    : '${value.paise ~/ 100}.${(value.paise.abs() % 100).toString().padLeft(2, '0')}';

class ForeignPaymentsSummary {
  final int pendingCount;
  final int unknownAmountCount;
  final int awaitingRateCount;
  final int confirmedCount;
  final Money estimatedInr;
  const ForeignPaymentsSummary({
    this.pendingCount = 0,
    this.unknownAmountCount = 0,
    this.awaitingRateCount = 0,
    this.confirmedCount = 0,
    this.estimatedInr = const Money.zero(),
  });
  factory ForeignPaymentsSummary.fromPayments(Iterable<ForeignPayment> items) {
    var pending = 0, unknown = 0, rates = 0, confirmed = 0, paise = 0;
    for (final item in items) {
      if (item.isConfirmed) confirmed++;
      if (!item.isPending) continue;
      pending++;
      if (item.originalAmount == null || item.originalCurrency == null) {
        unknown++;
      }
      if (item.valuationStatus == 'awaiting_rate') rates++;
      // Refund estimates are shown in their own record, not netted against
      // confirmed spending before the bank posts the credit.
      if (item.direction == 'spend') paise += item.estimatedInr?.paise ?? 0;
    }
    return ForeignPaymentsSummary(
      pendingCount: pending,
      unknownAmountCount: unknown,
      awaitingRateCount: rates,
      confirmedCount: confirmed,
      estimatedInr: Money.fromPaise(paise),
    );
  }
}
