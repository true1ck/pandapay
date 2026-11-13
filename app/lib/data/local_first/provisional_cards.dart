import 'package:sqlite3/sqlite3.dart';

/// Ids of wallet cards that exist only on the phone: a queued `add_card`
/// command (parked or not) or a card row still stored with `pending=1`.
/// Anything that names such an id must wait until the add is delivered and
/// the id remapped (H3-1/2). Tolerates missing tables (nothing queued yet).
Set<String> provisionalCardIds(Database db, String ns) {
  final ids = <String>{};
  bool has(String t) => db.select(
    "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",
    [t],
  ).isNotEmpty;
  if (has('command_outbox')) {
    for (final r in db.select(
      "SELECT target FROM command_outbox WHERE namespace=? AND kind='add_card'",
      [ns],
    )) {
      ids.add(r['target'] as String);
    }
  }
  if (has('financial_entities')) {
    for (final r in db.select(
      "SELECT id FROM financial_entities WHERE namespace=? AND entity='cards' AND pending=1",
      [ns],
    )) {
      ids.add(r['id'] as String);
    }
  }
  return ids;
}

/// True when the `add_card` for [cardId] is parked (the server refused it for
/// good), so waiting for the remap would never end.
bool cardAddParked(Database db, String ns, String cardId) {
  final has = db.select(
    "SELECT 1 FROM sqlite_master WHERE type='table' AND name='command_outbox'",
  ).isNotEmpty;
  if (!has) return false;
  return db.select(
    "SELECT 1 FROM command_outbox WHERE namespace=? AND kind='add_card' AND target=? AND parked=1",
    [ns, cardId],
  ).isNotEmpty;
}
