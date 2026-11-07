import 'dart:convert';

import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../../data/user_cards_repository.dart';

/// What makes two transactions "the same kind" for a bulk change. Always an
/// exact match on stored keys, never fuzzy.
class SimilarCriteria {
  const SimilarCriteria._(this.sql, this.args, this.label);

  /// The same shop as the SMS prints it.
  factory SimilarCriteria.shop(String merchantKey) =>
      SimilarCriteria._('f.merchant_key = ?', [merchantKey], 'shop');

  /// The same card or account, as first detected, from the same rule.
  factory SimilarCriteria.instrument({
    required String instrumentId,
    required String ruleId,
  }) => SimilarCriteria._(
    'f.instrument_id = ? AND f.rule_id = ?',
    [instrumentId, ruleId],
    'instrument',
  );

  /// The same rule and the same current type.
  factory SimilarCriteria.type({
    required String ruleId,
    required EventType type,
  }) => SimilarCriteria._(
    'f.rule_id = ? AND e.type = ?',
    [ruleId, type.wire],
    'type',
  );

  final String sql;
  final List<Object?> args;
  final String label;
}

/// Where the next page starts: after this fact, walking from newest to oldest.
class SimilarCursor {
  const SimilarCursor(this.observedAt, this.factId);
  final String observedAt;
  final String factId;
}

class SimilarExample {
  const SimilarExample({
    required this.eventId,
    required this.occurredAt,
    required this.amountPaise,
    this.merchantName,
  });
  final String eventId;
  final DateTime occurredAt;
  final int amountPaise;
  final String? merchantName;
}

class SimilarSummary {
  const SimilarSummary({required this.count, required this.examples});
  final int count;

  /// The newest few, for the person to recognise.
  final List<SimilarExample> examples;
  bool get isEmpty => count == 0;
}

/// Finds the other transactions a change could also apply to. One indexed
/// query per call: a count, a few examples, or one page of event ids.
///
/// Transactions the person already edited (`user_confirmed`) and readings that
/// are not money are left out, so the count says exactly what would change.
class SimilarFinder {
  SimilarFinder(this.db, {required this.namespace});
  final Database db;
  final String namespace;

  static const _from =
      'FROM v2_facts f JOIN v2_events e ON e.namespace = f.namespace AND e.event_id = f.fact_id '
      "WHERE f.namespace = ? AND e.status != 'user_confirmed' AND e.type != 'unknown'";

  (String, List<Object?>) _where(
    SimilarCriteria criteria,
    String? excludeEventId,
  ) => (
    '$_from AND ${criteria.sql}${excludeEventId == null ? '' : ' AND f.fact_id != ?'}',
    [namespace, ...criteria.args, ?excludeEventId],
  );

  int count(SimilarCriteria criteria, {String? excludeEventId}) {
    final (where, args) = _where(criteria, excludeEventId);
    return db.select('SELECT COUNT(*) AS n $where', args).single['n'] as int;
  }

  /// Up to [limit] events, newest first, after [after].
  List<({String eventId, SimilarCursor cursor})> page(
    SimilarCriteria criteria, {
    required int limit,
    String? excludeEventId,
    SimilarCursor? after,
  }) {
    final (where, args) = _where(criteria, excludeEventId);
    final rows = db.select(
      'SELECT f.fact_id AS id, f.observed_at AS at $where'
      '${after == null ? '' : ' AND (f.observed_at, f.fact_id) < (?, ?)'} '
      'ORDER BY f.observed_at DESC, f.fact_id DESC LIMIT ?',
      [...args, ?after?.observedAt, ?after?.factId, limit],
    );
    return [
      for (final row in rows)
        (
          eventId: row['id'] as String,
          cursor: SimilarCursor(row['at'] as String, row['id'] as String),
        ),
    ];
  }

  SimilarSummary summarize(
    SimilarCriteria criteria, {
    String? excludeEventId,
    int examples = 3,
  }) {
    final total = count(criteria, excludeEventId: excludeEventId);
    if (total == 0) return const SimilarSummary(count: 0, examples: []);
    final newest = page(
      criteria,
      limit: examples,
      excludeEventId: excludeEventId,
    );
    return SimilarSummary(
      count: total,
      examples: [
        for (final item in newest) ?example(item.eventId),
      ],
    );
  }

  /// The display row of one event, for showing the person an example.
  SimilarExample? example(String eventId) {
    final rows = db.select(
      "SELECT payload FROM financial_entities WHERE namespace=? AND entity='transactions' AND json_extract(payload,'\$.event_id')=? LIMIT 1",
      [namespace, eventId],
    );
    if (rows.isEmpty) return null;
    final entry = TransactionEntry.fromJson(
      (jsonDecode(rows.single['payload'] as String) as Map)
          .cast<String, dynamic>(),
    );
    return SimilarExample(
      eventId: eventId,
      occurredAt: entry.occurredAt,
      amountPaise: entry.amount.paise,
      merchantName: entry.merchantName,
    );
  }
}
