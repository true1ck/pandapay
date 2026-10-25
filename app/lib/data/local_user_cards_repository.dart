import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:sqlite3/sqlite3.dart';

import 'local/app_database.dart';
import 'user_cards_repository.dart';
import 'api_exception.dart';

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
    // Only call a card "unresolved" when we actually had a catalogue to miss
    // it in. An empty catalogue means the fetch failed or is still in flight —
    // a transient state that must not present every real card as a removable
    // ghost.
    final unresolved = catalogue.isNotEmpty && product == null;
    return UserCard(
      id: row['id'] as String,
      cardProductId: cardProductId,
      nickname: row['nickname'] as String?,
      last4: row['last4'] as String?,
      cardName: product?.name ?? (unresolved ? 'Unrecognized card' : 'Card'),
      isUnresolved: unresolved,
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

  Future<String> addCard(
    String cardProductId, {
    String? nickname,
    String? last4,
  }) async {
    final normalizedLast4 = last4 == null || last4.trim().isEmpty
        ? null
        : last4.replaceAll(RegExp(r'\D'), '');
    if (normalizedLast4 != null &&
        !RegExp(r'^\d{4}$').hasMatch(normalizedLast4)) {
      throw const FormatException('last4 must be exactly 4 digits');
    }
    final existingRows = _raw.select(
      'SELECT id FROM local_user_cards WHERE card_product_id = ? AND is_archived = 0 LIMIT 1',
      [cardProductId],
    );
    if (existingRows.isNotEmpty) {
      throw const CardAlreadyAddedException();
    }

    // Android/emulator clocks can return the same microsecond value for two
    // back-to-back writes. Keep the readable local prefix, but add a suffix
    // and verify it against SQLite so remove-then-readd can never collide.
    var attempt = 0;
    late String id;
    do {
      id = 'local_${DateTime.now().microsecondsSinceEpoch}_$attempt';
      attempt += 1;
    } while (_raw.select('SELECT 1 FROM local_user_cards WHERE id = ?', [
      id,
    ]).isNotEmpty);
    final maxOrderRows = _raw.select(
      'SELECT MAX(sort_order) AS m FROM local_user_cards',
    );
    final maxOrder = (maxOrderRows.first['m'] as num?)?.toDouble() ?? 0;
    final countRows = _raw.select(
      'SELECT COUNT(*) AS c FROM local_user_cards WHERE is_archived = 0',
    );
    final isFirstCard = (countRows.first['c'] as int) == 0;
    _raw.execute(
      'INSERT INTO local_user_cards (id, card_product_id, nickname, last4, is_default, is_archived, sort_order, created_at) '
      'VALUES (?, ?, ?, ?, ?, 0, ?, ?)',
      [
        id,
        cardProductId,
        nickname,
        normalizedLast4,
        isFirstCard ? 1 : 0,
        maxOrder + 1,
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
    return id;
  }

  Future<void> archiveCard(String userCardId) async {
    _raw.execute('UPDATE local_user_cards SET is_archived = 1 WHERE id = ?', [
      userCardId,
    ]);
  }

  /// Hard-deletes a single local card row. Used only for an [UserCard.isUnresolved]
  /// ghost — a guest card whose product id no longer exists in the catalogue,
  /// so there is nothing to archive/restore and "archive, never delete" (R4)
  /// does not apply: it can never be a real card again.
  Future<void> deleteCard(String userCardId) async {
    _raw.execute('DELETE FROM local_user_cards WHERE id = ?', [userCardId]);
  }

  Future<void> unarchiveCard(String userCardId) async {
    // Mirrors the API's 409 `card_already_added`: a product removed and then
    // added again already has an active row, so restoring the old one must
    // not leave two copies of the same card in the wallet.
    final rows = _raw.select(
      'SELECT card_product_id FROM local_user_cards WHERE id = ?',
      [userCardId],
    );
    if (rows.isNotEmpty) {
      final productId = rows.first['card_product_id'] as String;
      final activeClash = _raw.select(
        'SELECT 1 FROM local_user_cards '
        'WHERE card_product_id = ? AND is_archived = 0 AND id <> ? LIMIT 1',
        [productId, userCardId],
      );
      if (activeClash.isNotEmpty) {
        throw const CardAlreadyAddedException(
          'You already have an active copy of this card. Remove it first.',
        );
      }
    }
    _raw.execute('UPDATE local_user_cards SET is_archived = 0 WHERE id = ?', [
      userCardId,
    ]);
  }

  /// Mirrors [UserCardsRepository.setDefaultCard] — clears any existing
  /// default first, since only one card may be default at a time.
  Future<void> setDefaultCard(String userCardId) async {
    _raw.execute(
      'UPDATE local_user_cards SET is_default = 0 WHERE is_default = 1',
    );
    _raw.execute('UPDATE local_user_cards SET is_default = 1 WHERE id = ?', [
      userCardId,
    ]);
  }

  Future<void> reorderCards(List<String> orderedIds) async {
    for (var i = 0; i < orderedIds.length; i++) {
      _raw.execute('UPDATE local_user_cards SET sort_order = ? WHERE id = ?', [
        i.toDouble(),
        orderedIds[i],
      ]);
    }
  }

  /// Matches [UserCardsRepository.updateCard]'s signature so call sites
  /// don't need to branch. Nickname and the privacy-safe last four digits are
  /// meaningful locally; a guest card has no cap/points tracking for
  /// creditLimitInr/statementDay/dueDay/pointsBalance to feed into, so those
  /// remain silent no-ops rather than persisted-but-unused columns.
  Future<void> updateCard(
    String userCardId, {
    String? nickname,
    double? creditLimitInr,
    int? statementDay,
    int? dueDay,
    double? pointsBalance,
    String? last4,
  }) async {
    if (nickname != null) {
      _raw.execute('UPDATE local_user_cards SET nickname = ? WHERE id = ?', [
        nickname,
        userCardId,
      ]);
    }
    if (last4 != null) {
      final normalized = last4.trim().isEmpty
          ? null
          : last4.replaceAll(RegExp(r'\D'), '');
      if (normalized != null && !RegExp(r'^\d{4}$').hasMatch(normalized)) {
        throw const FormatException('last4 must be exactly 4 digits');
      }
      _raw.execute('UPDATE local_user_cards SET last4 = ? WHERE id = ?', [
        normalized,
        userCardId,
      ]);
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
    final rows = _raw.select(
      'SELECT * FROM local_user_cards ORDER BY sort_order ASC',
    );
    return rows
        .map(
          (r) => <String, Object?>{
            'localId': r['id'] as String,
            'cardProductId': r['card_product_id'] as String,
            'nickname': r['nickname'] as String?,
            'last4': r['last4'] as String?,
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
