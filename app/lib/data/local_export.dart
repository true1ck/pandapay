import 'dart:convert';

import 'user_cards_repository.dart';

/// Offline data export (WP-C10): builds the same JSON / CSV the API's
/// `GET /export` returns, from the phone's own stored rows, so it works with
/// no connection and includes changes the server has not accepted yet.
/// Column set and order match `api/src/index.js` `GET /export` so files
/// written before and after this change import the same way.
Map<String, dynamic> _txnRow(TransactionEntry t) {
  final j = t.toJson();
  final account =
      t.cardDisplayName ?? (j['instrument'] as String?) ?? t.instrument.wireValue;
  return {
    'id': t.id,
    'source_account': t.cardLast4 == null
        ? account
        : '$account •••• ${t.cardLast4}',
    'user_card_id': t.userCardId,
    'amount_inr': t.amount.rupees,
    'occurred_at': t.occurredAt.toUtc().toIso8601String(),
    'merchant_name': t.merchantName,
    'category_id': j['category_id'],
    'user_category_id': j['user_category_id'],
    'category_name': t.categoryName,
    'subcategory_name': t.subcategoryName,
    'entry_kind': t.entryKind.wireValue,
    'instrument': t.instrument.wireValue,
    'rail': j['rail'],
    'source': t.source,
    'expected_value_inr': t.rewardValue?.rupees,
    'note': t.note,
    'status': t.status,
    'tags': [for (final tag in t.tags) tag.toJson()],
  };
}

Map<String, dynamic> _cardRow(UserCard c) => {
  'id': c.id,
  'nickname': c.nickname,
  'card_name': c.cardName,
  'is_default': c.isDefault,
  'opened_on': c.openedOn?.toIso8601String(),
  'statement_day': c.statementDay,
  'due_day': c.dueDay,
  'credit_limit_inr': c.creditLimit?.rupees,
};

String _csv(List<Map<String, dynamic>> rows) {
  if (rows.isEmpty) return '';
  final headers = rows.first.keys.toList();
  String esc(Object? v) {
    if (v == null) return '';
    final s = v is Map || v is List ? jsonEncode(v) : '$v';
    return RegExp(r'[",\n]').hasMatch(s) ? '"${s.replaceAll('"', '""')}"' : s;
  }

  return [
    headers.join(','),
    for (final r in rows) headers.map((h) => esc(r[h])).join(','),
  ].join('\n');
}

/// [scope] is `transactions`, `cards` or `all`; [format] `json` or `csv`.
String buildLocalExport({
  required String scope,
  required String format,
  required List<TransactionEntry> transactions,
  required List<UserCard> cards,
}) {
  final withTxns = scope == 'transactions' || scope == 'all';
  final withCards = scope == 'cards' || scope == 'all';
  final txnRows = [for (final t in transactions) _txnRow(t)];
  final cardRows = [for (final c in cards) _cardRow(c)];
  if (format == 'json') {
    final tags = <String, Map<String, dynamic>>{};
    for (final t in transactions) {
      for (final tag in t.tags) {
        tags[tag.id] = {
          'id': tag.id,
          'name': tag.name,
          'color': tag.color,
          'archived_at': tag.archivedAt?.toUtc().toIso8601String(),
          'updated_at': tag.updatedAt?.toUtc().toIso8601String(),
        };
      }
    }
    return const JsonEncoder.withIndent('  ').convert({
      if (withTxns) 'transactions': txnRows,
      if (withTxns) 'tags': tags.values.toList(),
      if (withCards) 'cards': cardRows,
    });
  }
  return [
    if (withTxns) '# transactions\n${_csv(txnRows)}',
    if (withCards) '# cards\n${_csv(cardRows)}',
  ].join('\n\n');
}
