import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:sqlite3/sqlite3.dart' show Row;

import '../local_sms_parser.dart';
import 'app_database.dart';

/// One Tier-1 auto-resolution receipt.
///
/// Written when the composite confidence score is high enough that the AI
/// engine files a movement (or a bill) without asking. It is deliberately a
/// separate durable row rather than a flag on the review item: the review row
/// is deleted on resolution, and the user must still be able to see — and
/// undo — what the engine decided.
class AutoResolvedHistoryEntry {
  final String id;
  final String namespace;
  final String sourceKey;
  final String sender;

  /// 'transaction', 'bill' or 'mandate'.
  final String resolvedKind;
  final String title;
  final int amountPaise;
  final String? categorySlug;
  final String? dueDate;
  final String occurredAt;
  final String? instrument;
  final String? accountLast4;
  final double confidence;

  /// 'ai' unless a future flow records a non-AI resolver.
  final String resolvedBy;
  final int autoResolvedAt;
  final bool isUserModified;

  const AutoResolvedHistoryEntry({
    required this.id,
    required this.namespace,
    required this.sourceKey,
    required this.sender,
    required this.resolvedKind,
    required this.title,
    required this.amountPaise,
    this.categorySlug,
    this.dueDate,
    required this.occurredAt,
    this.instrument,
    this.accountLast4,
    required this.confidence,
    this.resolvedBy = 'ai',
    required this.autoResolvedAt,
    this.isUserModified = false,
  });

  String get categoryName =>
      LocalSmsParser.categoryDisplayName(categorySlug) ?? 'Other';

  Money get amount => Money.fromPaise(amountPaise);

  AutoResolvedHistoryEntry copyWith({
    String? categorySlug,
    bool? isUserModified,
  }) => AutoResolvedHistoryEntry(
    id: id,
    namespace: namespace,
    sourceKey: sourceKey,
    sender: sender,
    resolvedKind: resolvedKind,
    title: title,
    amountPaise: amountPaise,
    categorySlug: categorySlug ?? this.categorySlug,
    dueDate: dueDate,
    occurredAt: occurredAt,
    instrument: instrument,
    accountLast4: accountLast4,
    confidence: confidence,
    resolvedBy: resolvedBy,
    autoResolvedAt: autoResolvedAt,
    isUserModified: isUserModified ?? this.isUserModified,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'namespace': namespace,
    'sourceKey': sourceKey,
    'sender': sender,
    'resolvedKind': resolvedKind,
    'title': title,
    'amountPaise': amountPaise,
    'categorySlug': categorySlug,
    'dueDate': dueDate,
    'occurredAt': occurredAt,
    'instrument': instrument,
    'accountLast4': accountLast4,
    'confidence': confidence,
    'resolvedBy': resolvedBy,
    'autoResolvedAt': autoResolvedAt,
    'isUserModified': isUserModified,
  };

  factory AutoResolvedHistoryEntry.fromJson(Map<String, dynamic> json) =>
      AutoResolvedHistoryEntry(
        id: json['id'] as String,
        namespace: json['namespace'] as String,
        sourceKey: json['sourceKey'] as String,
        sender: json['sender'] as String,
        resolvedKind: json['resolvedKind'] as String,
        title: json['title'] as String,
        amountPaise: (json['amountPaise'] as num?)?.toInt() ?? 0,
        categorySlug: json['categorySlug'] as String?,
        dueDate: json['dueDate'] as String?,
        occurredAt: json['occurredAt'] as String,
        instrument: json['instrument'] as String?,
        accountLast4: json['accountLast4'] as String?,
        confidence: (json['confidence'] as num?)?.toDouble() ?? 0,
        resolvedBy: json['resolvedBy'] as String? ?? 'ai',
        autoResolvedAt: (json['autoResolvedAt'] as num?)?.toInt() ?? 0,
        isUserModified: json['isUserModified'] == true,
      );

  factory AutoResolvedHistoryEntry.fromRow(Row row) =>
      AutoResolvedHistoryEntry(
        id: row['id'] as String,
        namespace: row['namespace'] as String,
        sourceKey: row['source_key'] as String,
        sender: row['sender'] as String,
        resolvedKind: row['resolved_kind'] as String,
        title: row['title'] as String,
        amountPaise: (row['amount_paise'] as num).toInt(),
        categorySlug: row['category_slug'] as String?,
        dueDate: row['due_date'] as String?,
        occurredAt: row['occurred_at'] as String,
        instrument: row['instrument'] as String?,
        accountLast4: row['account_last4'] as String?,
        confidence: (row['confidence'] as num).toDouble(),
        resolvedBy: row['resolved_by'] as String? ?? 'ai',
        autoResolvedAt: (row['auto_resolved_at'] as num).toInt(),
        isUserModified: (row['is_user_modified'] as num?)?.toInt() == 1,
      );
}

/// Durable, namespace-scoped access to the Tier-1 auto-resolution receipts.
class AutoResolvedHistoryRepository {
  final AppDatabase database;
  final String namespace;

  const AutoResolvedHistoryRepository(this.database, {required this.namespace});

  List<AutoResolvedHistoryEntry> fetchAll({int limit = 200}) {
    final rows = database.db.select(
      'SELECT * FROM local_auto_resolved_history WHERE namespace=? '
      'ORDER BY auto_resolved_at DESC, id LIMIT ?',
      [namespace, limit],
    );
    return rows
        .map(AutoResolvedHistoryEntry.fromRow)
        .toList(growable: false);
  }

  int count() {
    final rows = database.db.select(
      'SELECT COUNT(*) AS n FROM local_auto_resolved_history WHERE namespace=?',
      [namespace],
    );
    return (rows.single['n'] as int?) ?? 0;
  }

  AutoResolvedHistoryEntry? findById(String id) {
    final rows = database.db.select(
      'SELECT * FROM local_auto_resolved_history WHERE namespace=? AND id=? LIMIT 1',
      [namespace, id],
    );
    return rows.isEmpty ? null : AutoResolvedHistoryEntry.fromRow(rows.single);
  }

  /// Deterministic id (`ai:<sourceKey>`) makes a replay an upsert, never a
  /// second receipt.
  void record(AutoResolvedHistoryEntry entry) {
    database.db.execute(
      '''INSERT OR REPLACE INTO local_auto_resolved_history
         (id, namespace, source_key, sender, resolved_kind, title,
          amount_paise, category_slug, due_date, occurred_at, instrument,
          account_last4, confidence, resolved_by, auto_resolved_at,
          is_user_modified)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
      [
        entry.id,
        namespace,
        entry.sourceKey,
        entry.sender,
        entry.resolvedKind,
        entry.title,
        entry.amountPaise,
        entry.categorySlug,
        entry.dueDate,
        entry.occurredAt,
        entry.instrument,
        entry.accountLast4,
        entry.confidence,
        entry.resolvedBy,
        entry.autoResolvedAt,
        entry.isUserModified ? 1 : 0,
      ],
    );
  }

  /// The category is user-owned once corrected; `is_user_modified` records
  /// that so a later sync never silently restores the AI's guess.
  bool updateCategory(String id, String categorySlug) {
    database.db.execute(
      'UPDATE local_auto_resolved_history '
      'SET category_slug=?, is_user_modified=1 '
      'WHERE namespace=? AND id=?',
      [categorySlug, namespace, id],
    );
    return database.db.updatedRows > 0;
  }

  bool delete(String id) {
    database.db.execute(
      'DELETE FROM local_auto_resolved_history WHERE namespace=? AND id=?',
      [namespace, id],
    );
    return database.db.updatedRows > 0;
  }
}
