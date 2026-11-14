import '../data/shared_commands.dart';
import '../storage/shared_store.dart';

/// The last-resort copy of a Split screen's data, built from this phone's own
/// SQLite (the pulled projections plus commands still waiting to be sent).
/// Answers in the same JSON shape as the server's list endpoints so the screen
/// mapping code is shared. Everything here is bounded (one page of at most 100
/// rows per section, nothing walks history).
///
/// Returns null when nothing is stored for the key. Search pages and later
/// cursors are deliberately not served (online only).
class SharedLocalReads {
  final SharedExpensesStore store;
  final String accountId;
  const SharedLocalReads(this.store, this.accountId);

  static const _live = {
    SharedCommandState.pending,
    SharedCommandState.sending,
    SharedCommandState.retry,
    SharedCommandState.awaitingAuth,
  };

  /// Commands that still hold a screen row: not refused (those are in the
  /// needs-attention list) and not committed (those arrive as projections).
  List<SharedQueuedCommand> pending({String? contextId}) {
    try {
      return [
        for (final op
            in store
                .readPendingOperations(contextId: contextId, limit: 100)
                .items)
          if (_live.contains(op.state)) op,
      ];
    } catch (_) {
      return const [];
    }
  }

  Map<String, Object?>? read(String key) {
    try {
      if (key.startsWith('contexts:')) return _contexts(key);
      final match = RegExp(r'^context:([0-9a-f-]{36}):(.+)$').firstMatch(key);
      if (match == null) return null;
      final id = match.group(1)!, section = match.group(2)!;
      final revision = RegExp(r'^revision:(.+):first$').firstMatch(section);
      if (revision != null) return _revisions(id, revision.group(1)!);
      return switch (section) {
        'detail' => detail(id),
        'members:first' => _members(id),
        'expenses:first' => _expenses(id),
        'balances:first' => _balances(id),
        'totals' => _totals(id),
        _ => null,
      };
    } catch (_) {
      return null;
    }
  }

  Map<String, Object?> _page(List<Map<String, Object?>> items) => {
    'items': items,
    'hasMore': false,
    'nextCursor': null,
  };

  Map<String, Object?> _createdItem(SharedQueuedCommand op) {
    final p = op.command.toJson()['payload'] as Map;
    return {
      'contextId': op.command.contextId,
      'kind': p['contextKind'],
      'name': p['name'],
      'currency': 'INR',
      'state': 'active',
      'membershipState': 'active',
      'committedSequence': '0',
      'waiting': true,
    };
  }

  SharedQueuedCommand? _create(String contextId) => pending(
    contextId: contextId,
  ).where((op) => op.command.kind == 'context.create').firstOrNull;

  Map<String, Object?>? _contexts(String key) {
    final parts = key.split(':');
    String? kind;
    var search = '', after = parts.skip(1).join(':');
    if (parts.length >= 4 && (parts[1] == 'direct' || parts[1] == 'group')) {
      kind = parts[1];
      search = Uri.decodeComponent(parts[2]).trim().toLowerCase();
      after = parts.skip(3).join(':');
    }
    if (after != 'first') return null;
    final items = <Map<String, Object?>>[
      for (final row in store.readContexts(limit: 100).items)
        {...row.payload, 'contextId': row.id},
    ];
    final seen = {for (final i in items) i['contextId']};
    for (final op in pending()) {
      if (op.command.kind == 'context.create' &&
          seen.add(op.command.contextId)) {
        items.add(_createdItem(op));
      }
    }
    // Nothing stored at all is "unknown", not "you have no splits".
    if (items.isEmpty) return null;
    items.removeWhere(
      (i) =>
          (kind != null && i['kind'] != kind) ||
          (search.isNotEmpty && !'${i['name']}'.toLowerCase().contains(search)),
    );
    // Waiting ones first, then newest first.
    items.sort((a, b) {
      final w = (b['waiting'] == true ? 1 : 0) - (a['waiting'] == true ? 1 : 0);
      return w != 0
          ? w
          : '${b['createdAt'] ?? ''}'.compareTo('${a['createdAt'] ?? ''}');
    });
    return _page(items.take(50).toList());
  }

  /// The context record: the pulled copy, else a stand-in for a group created
  /// on this phone that the server has not confirmed yet.
  Map<String, Object?>? detail(String id) {
    final rows = store.readPage(entity: 'contexts', contextId: id, limit: 1);
    if (rows.items.isNotEmpty) return rows.items.first.payload;
    final create = _create(id);
    return create == null ? null : (_createdItem(create)..remove('waiting'));
  }

  List<Map<String, Object?>> memberRows(String id) {
    final rows = [
      for (final m
          in store
              .readPage(entity: 'members', contextId: id, limit: 100)
              .items)
        m.payload,
    ];
    final pend = pending(contextId: id);
    if (!rows.any((m) => m['profileId'] == accountId) &&
        pend.any((op) => op.command.kind == 'context.create')) {
      rows.add({
        'contextId': id,
        'memberId': sharedPendingOwnerMemberId(id),
        'profileId': accountId,
        'role': 'owner',
        'state': 'active',
        'displayName': 'You',
      });
    }
    final known = {for (final m in rows) m['memberId']};
    for (final op in pend) {
      if (op.command.kind != 'member.invite') continue;
      final p = op.command.toJson()['payload'] as Map;
      if (known.add(p['memberId'])) {
        rows.add({
          'contextId': id,
          'memberId': p['memberId'],
          'profileId': p['profileId'],
          'role': 'member',
          'state': 'invited',
          'displayName': p['displayName'],
        });
      }
    }
    return rows;
  }

  /// The viewer's own member id in [id], or null when it is not known yet.
  String? ownMemberId(String id) => memberRows(id)
      .where((m) => m['profileId'] == accountId && m['state'] == 'active')
      .map((m) => m['memberId'] as String)
      .firstOrNull;

  Map<String, Object?>? _members(String id) {
    if (detail(id) == null) return null;
    final rows = memberRows(id);
    return rows.isEmpty ? null : _page(rows);
  }

  Map<String, Object?>? _balances(String id) {
    if (detail(id) == null) return null;
    return _page([
      for (final b
          in store
              .readPage(entity: 'balances', contextId: id, limit: 100)
              .items)
        b.payload,
    ]);
  }

  static BigInt _amount(Object? v) =>
      v is String ? (BigInt.tryParse(v) ?? BigInt.zero) : BigInt.zero;

  static String _sumFor(Object? rows, String own) {
    var total = BigInt.zero;
    if (rows is List) {
      for (final r in rows) {
        if (r is Map && r['memberId'] == own) {
          total += _amount(r['amountMinor']);
        }
      }
    }
    return total.toString();
  }

  /// Heads (and the newest revision of a head with nothing accepted yet) in
  /// the list shape; [own] is the viewer's member id.
  List<Map<String, Object?>> _expenseItems(String id, String own) {
    final heads = <String, Map<String, Object?>>{};
    final revisions = <String, Map<String, Object?>>{};
    for (final row
        in store
            .readPage(entity: 'expenses', contextId: id, limit: 100)
            .items) {
      final p = row.payload, eid = p['expenseId'] as String?;
      if (eid == null) continue;
      if (p['recordType'] == 'head') {
        heads[eid] = p;
      } else if (p['recordType'] == 'revision') {
        revisions[eid] = p;
      }
    }
    final items = <Map<String, Object?>>[];
    for (final entry in heads.entries) {
      final accepted = entry.value['accepted'];
      final src = accepted is Map
          ? Map<String, Object?>.from(accepted)
          : revisions[entry.key];
      if (src == null) continue;
      final snapshot = (src['snapshot'] as Map?) ?? const {};
      final fields = <String, Object?>{
        'title': src['title'],
        'occurredOn': src['occurredOn'],
        'totalMinor': src['totalMinor'],
        'void': src['void'] == true,
        'bill': src['bill'],
        'yourPaidMinor': _sumFor(snapshot['contributions'], own),
        'yourShareMinor': _sumFor(snapshot['shares'], own),
      };
      items.add(
        accepted is Map
            ? {'expenseId': entry.key, ...fields}
            : {
                'expenseId': entry.key,
                'totalMinor': null,
                'pendingRevision': fields,
              },
      );
    }
    String day(Map<String, Object?> e) =>
        '${e['occurredOn'] ?? (e['pendingRevision'] as Map?)?['occurredOn']}';
    items.sort((a, b) => day(b).compareTo(day(a)));
    return items;
  }

  /// An expense's accepted version, in the shape of the server's revision list,
  /// so its details open at once from this phone. Whether you may approve or
  /// reject is the server's to say, so it is never offered from here; the live
  /// list replaces this page when it arrives.
  Map<String, Object?>? _revisions(String id, String expenseId) {
    final own = ownMemberId(id);
    if (own == null || detail(id) == null) return null;
    for (final row
        in store
            .readPage(entity: 'expenses', contextId: id, limit: 100)
            .items) {
      final p = row.payload;
      if (p['recordType'] != 'head' || p['expenseId'] != expenseId) continue;
      final accepted = p['accepted'];
      if (accepted is! Map) return null;
      final snapshot = (accepted['snapshot'] as Map?) ?? const {};
      return _page([
        {
          'contextId': id,
          'expenseId': expenseId,
          'revisionId': accepted['revisionId'],
          'title': accepted['title'],
          'occurredOn': accepted['occurredOn'],
          'totalMinor': accepted['totalMinor'],
          'void': accepted['void'] == true,
          'bill': accepted['bill'],
          'snapshot': accepted['snapshot'],
          'reviewState': 'accepted',
          'canRespond': false,
          'yourDecision': null,
          'ownMemberId': own,
          'yourPaidMinor': _sumFor(snapshot['contributions'], own),
          'yourShareMinor': _sumFor(snapshot['shares'], own),
        },
      ]);
    }
    return null;
  }

  Map<String, Object?>? _expenses(String id) {
    final own = ownMemberId(id);
    if (own == null || detail(id) == null) return null;
    return _page(_expenseItems(id, own));
  }

  Map<String, Object?>? _totals(String id) {
    final own = ownMemberId(id);
    if (own == null || detail(id) == null) return null;
    var total = BigInt.zero, paid = BigInt.zero, share = BigInt.zero;
    for (final e in _expenseItems(id, own)) {
      if (e['totalMinor'] == null || e['void'] == true) continue;
      total += _amount(e['totalMinor']);
      paid += _amount(e['yourPaidMinor']);
      share += _amount(e['yourShareMinor']);
    }
    return {
      'memberId': own,
      'sharedTotalMinor': total.toString(),
      'yourPaidMinor': paid.toString(),
      'yourShareMinor': share.toString(),
    };
  }
}
