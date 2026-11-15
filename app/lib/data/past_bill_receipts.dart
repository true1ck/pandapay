import 'dart:async';
import 'dart:convert';

import 'package:pandapay_domain/pandapay_domain.dart';

import 'commitments_repository.dart';
import 'local/app_database.dart';
import '../features/sms_v2/ledger/premium_notices.dart';

enum PastBillReceiptStatus {
  paidLinked,
  paidUnlinked,
  historicalUnpaid,
  needsConfirmation,
  userSavedPurchase,
}

enum PastBillReceiptKind { receipt, bill }

class PastBillReceipt {
  final String id;
  final String sourceKey;
  final String merchant;
  final PastBillReceiptKind kind;
  final Money? amount;
  final DateTime occurredAt;
  final DateTime receivedAt;
  final DateTime? dueDate;
  final PastBillReceiptStatus status;
  final String? linkedTransactionId;
  final String? cardLast4;
  final String? accountLast4;
  final String? sender;
  final String? body;

  /// What the bill is: a [CommitmentCategory] name, or `creditCard`.
  /// Null on rows saved before bills were tagged.
  final String? categoryName;

  /// The notice named a month and no day, so [dueDate] is that month's last day.
  final bool dueMonthOnly;

  const PastBillReceipt({
    required this.id,
    required this.sourceKey,
    required this.merchant,
    this.kind = PastBillReceiptKind.receipt,
    required this.amount,
    required this.occurredAt,
    required this.receivedAt,
    this.dueDate,
    required this.status,
    this.linkedTransactionId,
    this.cardLast4,
    this.accountLast4,
    this.sender,
    this.body,
    this.categoryName,
    this.dueMonthOnly = false,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'sourceKey': sourceKey,
    'merchant': merchant,
    'kind': kind.name,
    'amountPaise': amount?.paise,
    'occurredAt': occurredAt.toIso8601String(),
    'receivedAt': receivedAt.toIso8601String(),
    'dueDate': dueDate?.toIso8601String(),
    'status': status.name,
    'linkedTransactionId': linkedTransactionId,
    'cardLast4': cardLast4,
    'accountLast4': accountLast4,
    'sender': sender,
    'body': body,
    'categoryName': categoryName,
    'dueMonthOnly': dueMonthOnly,
  };

  factory PastBillReceipt.fromJson(Map<String, dynamic> json) {
    final amountPaise = (json['amountPaise'] as num?)?.toInt();
    return PastBillReceipt(
      id: json['id'] as String,
      sourceKey: json['sourceKey'] as String,
      merchant: json['merchant'] as String,
      kind: PastBillReceiptKind.values.firstWhere(
        (value) => value.name == json['kind'],
        orElse: () => PastBillReceiptKind.receipt,
      ),
      amount: amountPaise == null ? null : Money.fromPaise(amountPaise),
      occurredAt: DateTime.parse(json['occurredAt'] as String),
      receivedAt: DateTime.parse(json['receivedAt'] as String),
      dueDate: DateTime.tryParse(json['dueDate'] as String? ?? ''),
      status: PastBillReceiptStatus.values.firstWhere(
        (value) => value.name == json['status'],
        orElse: () => PastBillReceiptStatus.needsConfirmation,
      ),
      linkedTransactionId: json['linkedTransactionId'] as String?,
      // Compatibility with archives written before identity had its own fields.
      // Only the old exact synthetic label is migrated; raw SMS is not parsed.
      cardLast4: json.containsKey('cardLast4')
          ? json['cardLast4'] as String?
          : RegExp(
              r'^Card ending (\d{4})$',
            ).firstMatch(json['body'] as String? ?? '')?.group(1),
      accountLast4: json['accountLast4'] as String?,
      sender: json['sender'] as String?,
      body: json['body'] as String?,
      categoryName: json['categoryName'] as String?,
      dueMonthOnly: json['dueMonthOnly'] as bool? ?? false,
    );
  }
}

class PastBillReceiptRepository {
  static final StreamController<String> _changes =
      StreamController<String>.broadcast(sync: true);

  static Stream<String> get changes => _changes.stream;

  final AppDatabase database;
  final String namespace;

  const PastBillReceiptRepository(this.database, {required this.namespace});

  List<PastBillReceipt> fetchAll({int? limit = 100}) {
    final rows = database.db.select(
      'SELECT payload FROM local_past_bill_receipts WHERE namespace = ? '
      'ORDER BY updated_at DESC ${limit == null ? '' : 'LIMIT ?'}',
      [namespace, ?limit],
    );
    return rows
        .map(
          (row) => PastBillReceipt.fromJson(
            jsonDecode(row['payload'] as String) as Map<String, dynamic>,
          ),
        )
        .toList(growable: false);
  }

  void upsert(PastBillReceipt receipt) {
    final now = DateTime.now().millisecondsSinceEpoch;
    database.db.execute(
      '''INSERT INTO local_past_bill_receipts
         (namespace, id, payload, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?)
         ON CONFLICT(namespace, id) DO UPDATE SET
           payload = excluded.payload,
           updated_at = excluded.updated_at''',
      [namespace, receipt.id, jsonEncode(receipt.toJson()), now, now],
    );
    _changes.add(namespace);
  }

  void delete(String id) {
    database.db.execute(
      'DELETE FROM local_past_bill_receipts WHERE namespace = ? AND id = ?',
      [namespace, id],
    );
    _changes.add(namespace);
  }

  void archiveBill({
    required String id,
    required String sender,
    required String merchant,
    required Money? amount,
    required DateTime receivedAt,
    required DateTime? dueDate,
    String? cardLast4,
    String? accountLast4,
    String? body,
    PastBillReceiptStatus status = PastBillReceiptStatus.historicalUnpaid,
    String? linkedTransactionId,
  }) {
    upsert(
      PastBillReceipt(
        id: id,
        sourceKey: id,
        merchant: merchant.trim().isEmpty ? sender.trim() : merchant.trim(),
        kind: PastBillReceiptKind.bill,
        amount: amount,
        occurredAt: dueDate ?? receivedAt,
        receivedAt: receivedAt,
        dueDate: dueDate,
        status: status,
        linkedTransactionId: linkedTransactionId,
        cardLast4: cardLast4,
        accountLast4: accountLast4,
        sender: sender,
        body: body ?? (cardLast4 == null ? null : 'Card ending $cardLast4'),
      ),
    );
  }
}

final RegExp _cardWord = RegExp(r'card|credit', caseSensitive: false);

/// Past bills from the SMS-derived [bills] (ids `v2:<factId>`): every bill whose
/// due date is before [now], newest first. Paid bills keep their receipt link;
/// an unpaid one says its payment was not detected, which is all SMS can show.
List<PastBillReceipt> pastBillReceiptsFromBills(
  Iterable<Commitment> bills,
  DateTime now,
) {
  final today = DateTime(now.year, now.month, now.day);
  final out = <PastBillReceipt>[];
  for (final bill in bills) {
    if (!bill.id.startsWith('v2:') ||
        bill.status == CommitmentStatus.dismissed ||
        !bill.dueOn.isBefore(today)) {
      continue;
    }
    final isCard = _cardWord.hasMatch(bill.title);
    out.add(
      PastBillReceipt(
        id: 'past-${bill.id}',
        sourceKey: bill.sourceKey ?? bill.id,
        merchant: bill.title,
        kind: PastBillReceiptKind.bill,
        amount: bill.amount,
        occurredAt: bill.paidOn ?? bill.dueOn,
        receivedAt: bill.dueOn,
        dueDate: bill.dueOn,
        status: switch (bill.status) {
          CommitmentStatus.paid =>
            bill.linkedTransactionId != null
                ? PastBillReceiptStatus.paidLinked
                : PastBillReceiptStatus.paidUnlinked,
          CommitmentStatus.needsConfirmation ||
          CommitmentStatus.inGracePeriod =>
            PastBillReceiptStatus.needsConfirmation,
          _ => PastBillReceiptStatus.historicalUnpaid,
        },
        linkedTransactionId: bill.linkedTransactionId,
        cardLast4: isCard ? bill.identifier : null,
        accountLast4: isCard ? null : bill.identifier,
        categoryName: isCard
            ? 'creditCard'
            : bill.category == CommitmentCategory.investment &&
                  bill.cadence != CommitmentCadence.oneTime
            ? 'sip'
            : bill.category.name,
      ),
    );
  }
  return out..sort((a, b) => b.dueDate!.compareTo(a.dueDate!));
}

/// Past months from month-only notices: one row per policy and month, shown as
/// history that needs confirming (SMS cannot say it was paid). A month still
/// ahead is an upcoming reminder.
List<PastBillReceipt> pastPremiumReceiptsFromNotices(
  Iterable<PremiumNotice> notices,
  DateTime now,
) {
  final thisMonth = DateTime(now.year, now.month);
  final byCycle = <String, PastBillReceipt>{};
  for (final n in notices) {
    if (!n.month.isBefore(thisMonth)) continue;
    final cycle = '${n.displayTitle}|${n.policyLast4 ?? ''}|${n.month}';
    final previous = byCycle[cycle];
    if (previous != null && !n.receivedAt.isAfter(previous.receivedAt)) {
      continue;
    }
    byCycle[cycle] = PastBillReceipt(
      id: 'past-premium-${n.sourceKey}',
      sourceKey: n.sourceKey,
      merchant: n.displayTitle,
      kind: PastBillReceiptKind.bill,
      amount: null,
      occurredAt: n.receivedAt,
      receivedAt: n.receivedAt,
      // The month's last day, flagged below: the day was never stated.
      dueDate: DateTime(n.month.year, n.month.month + 1, 0),
      dueMonthOnly: true,
      status: PastBillReceiptStatus.needsConfirmation,
      accountLast4: n.policyLast4,
      categoryName: n.category.name,
    );
  }
  return byCycle.values.toList()
    ..sort((a, b) => b.occurredAt.compareTo(a.occurredAt));
}
