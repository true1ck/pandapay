import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:sqlite3/sqlite3.dart';

import 'local/app_database.dart';
import 'user_cards_repository.dart';

/// Guest/no-account mode (ui-spec.md A3) — the on-device counterpart to
/// [UserCardsRepository], scoped to card ownership + ordering only. A
/// guest has no synced transaction history, so cap/points/fee-waiver
/// tracking can't be computed here; every [UserCard] this returns has
/// those fields at their zero/empty default rather than fabricated
/// values. Screens reading those fields for a guest card simply show "no
/// activity yet," which is the true state, not a placeholder.
///
/// [cardName] on the returned [UserCard] comes from joining against the
/// passed-in catalogue rather than being stored locally — the catalogue
/// is the single source of truth for product names and is already free
/// to fetch (cached, no auth), so duplicating it into this table would
/// just be a second place for it to go stale.
class LocalUserCardsRepository {
  final AppDatabase _db;

  LocalUserCardsRepository(this._db);

  Database get _raw => _db.db;

  UserCard _rowToUserCard(Row row, List<CardProduct> catalogue) {
    final cardProductId = row['card_product_id'] as String;
    final product = catalogue.where((c) => c.id == cardProductId).firstOrNull;
    return UserCard(
      id: row['id'] as String,
      cardProductId: cardProductId,
      nickname: row['nickname'] as String?,
      cardName: product?.name ?? 'Card',
      isDefault: (row['is_default'] as int) != 0,
      isArchived: (row['is_archived'] as int) != 0,
    );
  }

  Future<List<UserCard>> fetchUserCards({
    bool includeArchived = false,
    required List<CardProduct> catalogue,
  }) async {
    final rows = _raw.select(
      includeArchived
          ? 'SELECT * FROM local_user_cards ORDER BY sort_order ASC'
          : 'SELECT * FROM local_user_cards WHERE is_archived = 0 ORDER BY sort_order ASC',
    );
    return rows.map((r) => _rowToUserCard(r, catalogue)).toList();
  }

  Future<String> addCard(String cardProductId, {String? nickname}) async {
    final id = 'local_${DateTime.now().microsecondsSinceEpoch}';
    final maxOrderRows = _raw.select('SELECT MAX(sort_order) AS m FROM local_user_cards');
    final maxOrder = (maxOrderRows.first['m'] as num?)?.toDouble() ?? 0;
    final countRows = _raw.select('SELECT COUNT(*) AS c FROM local_user_cards WHERE is_archived = 0');
    final isFirstCard = (countRows.first['c'] as int) == 0;
    _raw.execute(
      'INSERT INTO local_user_cards (id, card_product_id, nickname, is_default, is_archived, sort_order, created_at) '
      'VALUES (?, ?, ?, ?, 0, ?, ?)',
      [id, cardProductId, nickname, isFirstCard ? 1 : 0, maxOrder + 1, DateTime.now().millisecondsSinceEpoch],
    );
    return id;
  }

  Future<void> archiveCard(String userCardId) async {
    _raw.execute('UPDATE local_user_cards SET is_archived = 1 WHERE id = ?', [userCardId]);
  }

  Future<void> unarchiveCard(String userCardId) async {
    _raw.execute('UPDATE local_user_cards SET is_archived = 0 WHERE id = ?', [userCardId]);
  }

  /// Mirrors [UserCardsRepository.setDefaultCard] — clears any existing
  /// default first, since only one card may be default at a time.
  Future<void> setDefaultCard(String userCardId) async {
    _raw.execute('UPDATE local_user_cards SET is_default = 0 WHERE is_default = 1');
    _raw.execute('UPDATE local_user_cards SET is_default = 1 WHERE id = ?', [userCardId]);
  }

  Future<void> reorderCards(List<String> orderedIds) async {
    for (var i = 0; i < orderedIds.length; i++) {
      _raw.execute('UPDATE local_user_cards SET sort_order = ? WHERE id = ?', [i.toDouble(), orderedIds[i]]);
    }
  }

  /// Matches [UserCardsRepository.updateCard]'s signature so call sites
  /// don't need to branch, but only [nickname] is meaningful locally — a
  /// guest card has no cap/points tracking for creditLimitInr/
  /// statementDay/dueDay/pointsBalance to feed into, so those are silently
  /// no-ops rather than persisted-but-unused columns.
  Future<void> updateCard(
    String userCardId, {
    String? nickname,
    double? creditLimitInr,
    int? statementDay,
    int? dueDay,
    double? pointsBalance,
  }) async {
    if (nickname != null) {
      _raw.execute('UPDATE local_user_cards SET nickname = ? WHERE id = ?', [nickname, userCardId]);
    }
  }

  /// Plan Phase 1.2 — the guest wallet as a plain payload for
  /// `POST /user-cards/import`, archived cards included.
  ///
  /// Deliberately not `fetchUserCards`: that one needs a catalogue to resolve
  /// display names and drops the archived rows by default, and neither is
  /// wanted here. The server only needs the product id, the nickname the user
  /// typed, and the two flags — and an archived guest card must still cross
  /// over, or "archive, never delete" (R4) would be quietly violated by the
  /// act of signing up.
  Future<List<Map<String, Object?>>> exportForMigration() async {
    final rows = _raw.select('SELECT * FROM local_user_cards ORDER BY sort_order ASC');
    return rows
        .map(
          (r) => <String, Object?>{
            'localId': r['id'] as String,
            'cardProductId': r['card_product_id'] as String,
            'nickname': r['nickname'] as String?,
            'isDefault': (r['is_default'] as int) != 0,
            'isArchived': (r['is_archived'] as int) != 0,
          },
        )
        .toList();
  }

  Future<int> count() async {
    final rows = _raw.select('SELECT COUNT(*) AS c FROM local_user_cards');
    return rows.first['c'] as int;
  }

  /// Called only after the server has confirmed an import. Dropping these
  /// rows before that confirmation would turn a network error into exactly
  /// the data loss this whole path exists to prevent.
  Future<void> clearAll() async {
    _raw.execute('DELETE FROM local_user_cards');
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
