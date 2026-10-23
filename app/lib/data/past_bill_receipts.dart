import 'dart:convert';

import 'package:pandapay_domain/pandapay_domain.dart';

import 'local/app_database.dart';
import 'local_sms_parser.dart';

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
  final String? sender;
  final String? body;

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
    this.sender,
    this.body,
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
    'sender': sender,
    'body': body,
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
        orElse: () => PastBillReceiptStatus.paidUnlinked,
      ),
      linkedTransactionId: json['linkedTransactionId'] as String?,
      sender: json['sender'] as String?,
      body: json['body'] as String?,
    );
  }
}

class PastBillReceiptRepository {
  final AppDatabase database;
  final String namespace;

  const PastBillReceiptRepository(this.database, {required this.namespace});

  List<PastBillReceipt> fetchAll({int limit = 100}) {
    final rows = database.db.select(
      'SELECT payload FROM local_past_bill_receipts WHERE namespace = ? '
      'ORDER BY updated_at DESC LIMIT ?',
      [namespace, limit],
    );
    return rows
        .map((row) => PastBillReceipt.fromJson(
              jsonDecode(row['payload'] as String) as Map<String, dynamic>,
            ))
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
  }

  /// Archives a completed merchant e-bill/receipt without creating spending.
  /// The existing transaction remains the accounting source of truth.
  void archiveReceipt({
    required String id,
    required String sender,
    required String body,
    required DateTime receivedAt,
    String? linkedTransactionId,
    required PastBillReceiptStatus status,
  }) {
    final parsed = LocalSmsParser.reviewDraft(
      namespace: namespace,
      body: body,
      sender: sender,
      receivedAt: receivedAt,
    );
    final merchant = parsed.merchantName?.trim().isNotEmpty == true
        ? parsed.merchantName!.trim()
        : sender.trim();
    upsert(
      PastBillReceipt(
        id: id,
        sourceKey: id,
        merchant: merchant.isEmpty ? 'Paid receipt' : merchant,
        amount: parsed.amount ?? LocalSmsParser.extractReceiptAmount(body),
        occurredAt: parsed.occurredAt,
        receivedAt: receivedAt,
        status: status,
        linkedTransactionId: linkedTransactionId,
        sender: sender,
        body: body,
      ),
    );
  }

  void archiveBill({
    required String id,
    required String sender,
    required String merchant,
    required Money? amount,
    required DateTime receivedAt,
    required DateTime? dueDate,
    String? cardLast4,
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
        status: PastBillReceiptStatus.historicalUnpaid,
        sender: sender,
        body: cardLast4 == null ? null : 'Card ending $cardLast4',
      ),
    );
  }
}
