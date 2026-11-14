import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import '../card_overrides_repository.dart';
import 'command_outbox.dart';

/// A queued field edit of one override (from `sync_pending_changes`).
class OverrideEdit {
  const OverrideEdit(this.id, this.fields);
  final String id;
  final Map<String, Object?> fields;
}

/// Queued edits for `card_overrides`, oldest first. Applied-but-not-yet-purged
/// rows count too (they are still waiting for the refreshed server copy).
List<OverrideEdit> pendingOverrideEdits(Database db, String namespace) => [
  for (final r in db.select(
    "SELECT entity_id, payload_json FROM sync_pending_changes "
    "WHERE namespace=? AND entity='card_overrides' AND op='update' ORDER BY client_seq",
    [namespace],
  ))
    OverrideEdit(
      r['entity_id'] as String,
      Map<String, Object?>.from(jsonDecode(r['payload_json'] as String) as Map),
    ),
];

/// Shows queued override work on top of the last list from the server (WP-C6,
/// W-08): a rule created offline appears (a provisional row), a deleted one
/// disappears, and a queued toggle / card / note edit takes effect, all at
/// once and across restarts.
///
/// [cardLabels] maps a card id to `(name, nickname)` so a rule moved to
/// another card shows that card's name before the server has confirmed it.
List<CardOverride> overlayCardOverrides(
  List<CardOverride> base,
  List<PendingCommand> commands,
  List<OverrideEdit> edits, {
  Map<String, ({String name, String? nickname})> cardLabels = const {},
}) {
  var rows = List<CardOverride>.of(base);
  for (final c in commands) {
    switch (c.kind) {
      case 'create_override':
        final id = c.payload['id'] as String;
        if (rows.any((o) => o.id == id)) break;
        rows.add(_provisional(c.payload));
      case 'delete_override':
        rows = [
          for (final o in rows)
            if (o.id != c.payload['id']) o,
        ];
    }
  }
  // Queued edits sent through the rule's own PATCH route.
  final routeEdits = [
    for (final c in commands)
      if (c.kind == 'update_override')
        OverrideEdit(c.payload['id'] as String, {
          if (c.payload['isEnabled'] != null) 'is_enabled': c.payload['isEnabled'],
          if (c.payload['userCardId'] != null) 'user_card_id': c.payload['userCardId'],
          if (c.payload.containsKey('reasonNote')) 'reason_note': c.payload['reasonNote'],
        }),
  ];
  edits = [...edits, ...routeEdits];
  for (final e in edits) {
    rows = [
      for (final o in rows)
        if (o.id == e.id) _edited(o, e.fields, cardLabels) else o,
    ];
  }
  return rows;
}

CardOverride _provisional(Map<String, Object?> p) => CardOverride(
  id: p['id'] as String,
  userCardId: p['userCardId'] as String,
  scope: OverrideScope.values.firstWhere((s) => s.name == p['scope']),
  vpa: p['vpa'] as String?,
  merchantName: p['merchantName'] as String?,
  categoryId: p['categoryId'] as String?,
  categoryName: p['categoryName'] as String?,
  reasonNote: p['reasonNote'] as String?,
  isEnabled: p['isEnabled'] as bool? ?? true,
  createdAt:
      DateTime.tryParse('${p['createdAt']}') ?? DateTime.fromMillisecondsSinceEpoch(0),
  cardName: p['cardName'] as String? ?? 'Card',
  cardNickname: p['cardNickname'] as String?,
);

CardOverride _edited(
  CardOverride o,
  Map<String, Object?> f,
  Map<String, ({String name, String? nickname})> labels,
) {
  final cardId = f.containsKey('user_card_id') ? f['user_card_id'] as String? : null;
  final label = cardId == null ? null : labels[cardId];
  return CardOverride(
    id: o.id,
    userCardId: cardId ?? o.userCardId,
    scope: o.scope,
    vpa: o.vpa,
    merchantName: o.merchantName,
    categoryId: o.categoryId,
    categoryName: o.categoryName,
    reasonNote: f.containsKey('reason_note')
        ? ((f['reason_note'] as String?)?.isEmpty ?? true ? null : f['reason_note'] as String?)
        : o.reasonNote,
    isEnabled: f['is_enabled'] as bool? ?? o.isEnabled,
    createdAt: o.createdAt,
    cardName: label?.name ?? o.cardName,
    cardNickname: label == null ? o.cardNickname : label.nickname,
  );
}
