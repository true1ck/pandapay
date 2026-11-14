import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:sqlite3/sqlite3.dart' show Database;

import '../../app/env.dart';
import '../../app/providers.dart'
    show
        accessTokenProvider,
        authenticatedHttpClientProvider,
        cacheNamespaceProvider,
        commandOutboxProvider,
        commandOutboxRevisionProvider,
        outboxFlushRequestProvider,
        pendingOutboxCountProvider,
        responseCacheProvider;
import '../../data/api_exception.dart';
import '../../data/local/financial_store.dart';
import '../../data/local_first/command_outbox.dart';

/// WP-C17 kill switch. `false` = nothing is queued, pulled or sent (behaves as
/// before: these three stores stay phone-only).
const bool kSyncLocalState = true;

/// The three kinds of phone-only state that now sync (server table
/// `user_local_state`, keyed by kind + key).
abstract final class UserStateKind {
  static const billCardAssignment = 'bill_card_assignment';
  static const bankBalance = 'bank_balance';
  static const subscriptionOverride = 'subscription_override';
  static const all = [billCardAssignment, bankBalance, subscriptionOverride];
}

abstract final class UserStateCommand {
  static const put = 'user_state_put';
  static const delete = 'user_state_delete';
  static const kinds = {put, delete};
}

/// The server said it has no such route (an old server): keep everything on
/// the phone and do not ask again until the next app start.
class UserStateUnsupported implements Exception {
  @override
  String toString() => 'User-state sync is not supported by this server yet';
}

bool _unsupported = false;
bool get userStateUnsupported => _unsupported;

/// Test hook: forget that the server was found unsupported.
void resetUserStateUnsupported() => _unsupported = false;

/// One synced item as the server returns it.
class UserStateItem {
  UserStateItem({
    required this.kind,
    required this.key,
    required this.payload,
    required this.clientEditedAt,
    required this.deleted,
    this.undecryptable = false,
  });

  /// The server could not decrypt it (key rotated away): never a delete, never
  /// applied.
  final bool undecryptable;
  final String kind;
  final String key;
  final Map<String, dynamic>? payload;
  final DateTime clientEditedAt;
  final bool deleted;

  factory UserStateItem.fromJson(Map<String, dynamic> j) => UserStateItem(
    kind: j['kind'] as String,
    key: j['key'] as String,
    payload: (j['payload'] as Map?)?.cast<String, dynamic>(),
    clientEditedAt:
        DateTime.tryParse('${j['clientEditedAt']}')?.toUtc() ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    deleted: j['deleted'] == true,
    undecryptable: j['undecryptable'] == true,
  );
}

class UserStatePage {
  UserStatePage(this.items, this.cursor, {this.hasMore = false});
  final bool hasMore;
  final List<UserStateItem> items;
  final String? cursor;
}

/// HTTP calls. Never puts a payload in an error message or a log line.
class UserStateApi {
  UserStateApi({
    required this.apiBaseUrl,
    required this.accessToken,
    required this.client,
  });
  final String apiBaseUrl;
  final String accessToken;
  final http.Client client;

  static const _timeout = Duration(seconds: 15);

  Map<String, String> get _headers => {
    'Authorization': 'Bearer $accessToken',
    'Content-Type': 'application/json',
  };

  Uri _item(String kind, String key) => Uri.parse(
    '$apiBaseUrl/user-state/${Uri.encodeComponent(kind)}/${Uri.encodeComponent(key)}',
  );

  Never _fail(String method, http.Response r) {
    if (r.statusCode == 404) {
      _unsupported = true;
      throw UserStateUnsupported();
    }
    String? code;
    try {
      final b = jsonDecode(r.body);
      if (b is Map && b['error'] is String) code = b['error'] as String;
    } catch (_) {}
    throw ApiException(
      '$method /user-state failed: ${r.statusCode} ${code ?? ''}',
    );
  }

  Future<UserStatePage> pull({String? since}) async {
    final uri = Uri.parse(
      '$apiBaseUrl/user-state',
    ).replace(queryParameters: {'since': ?since});
    final r = await client.get(uri, headers: _headers).timeout(_timeout);
    if (r.statusCode != 200) _fail('GET', r);
    final b = jsonDecode(r.body) as Map<String, dynamic>;
    return UserStatePage([
      for (final i in (b['items'] as List? ?? const []))
        UserStateItem.fromJson((i as Map).cast<String, dynamic>()),
    ], b['cursor']?.toString(), hasMore: b['hasMore'] == true);
  }

  /// Returns the server's copy when a newer server edit won, else null.
  Future<UserStateItem?> put(
    String kind,
    String key,
    Map<String, dynamic> payload,
    DateTime clientEditedAt,
  ) async {
    final r = await client
        .put(
          _item(kind, key),
          headers: _headers,
          body: jsonEncode({
            'payload': payload,
            'clientEditedAt': clientEditedAt.toUtc().toIso8601String(),
          }),
        )
        .timeout(_timeout);
    if (r.statusCode != 200) _fail('PUT', r);
    return _superseded(r);
  }

  Future<UserStateItem?> delete(
    String kind,
    String key,
    DateTime clientEditedAt,
  ) async {
    final r = await client
        .delete(
          _item(kind, key),
          headers: {
            ..._headers,
            'X-Client-Edited-At': clientEditedAt.toUtc().toIso8601String(),
          },
        )
        .timeout(_timeout);
    if (r.statusCode != 200) _fail('DELETE', r);
    return _superseded(r);
  }

  UserStateItem? _superseded(http.Response r) {
    try {
      final b = jsonDecode(r.body);
      if (b is Map && b['superseded'] == true && b['item'] is Map) {
        return UserStateItem.fromJson(
          (b['item'] as Map).cast<String, dynamic>(),
        );
      }
    } catch (_) {}
    return null;
  }
}

/// The phone side of the three stores, behind one read / apply / remove.
/// `apply` and `remove` never queue anything: they are for what the server
/// told us.
class UserStateLocal {
  UserStateLocal(this.store, this.ns);
  final FinancialStore store;
  final String ns;

  Database get _db => store.database.db;

  static String? _entity(String kind) => switch (kind) {
    UserStateKind.billCardAssignment => 'bill_card_assignments',
    UserStateKind.bankBalance => 'manual_bank_balances',
    _ => null,
  };

  /// The wire payload and the local edit time, or null when the row is absent.
  ({Map<String, dynamic> payload, int editedAtMs})? read(
    String kind,
    String key,
  ) {
    if (kind == UserStateKind.subscriptionOverride) {
      final rows = _db.select(
        'SELECT payload, updated_at FROM subscription_overrides '
        'WHERE namespace=? AND series_id=?',
        [ns, key],
      );
      if (rows.isEmpty) return null;
      return (
        payload: (jsonDecode(rows.single['payload'] as String) as Map)
            .cast<String, dynamic>(),
        editedAtMs: rows.single['updated_at'] as int,
      );
    }
    final entity = _entity(kind);
    if (entity == null) return null;
    final row = store.userStateEntity(ns, entity, key);
    if (row == null) return null;
    final b = row.body;
    if (kind == UserStateKind.billCardAssignment) {
      return (
        payload: {
          'userCardId': b['user_card_id'],
          'billKey': key,
          'amountDuePaise': b['amount_due_paise'],
          'dueDate': b['due_date'],
          'statementDate': b['statement_date'],
        },
        editedAtMs: row.editedAtMs,
      );
    }
    final paise = (b['balance_paise'] as num?)?.round() ?? 0;
    return (
      payload: {...b, 'amount': paise / 100, 'accountLabel': key, 'label': key},
      editedAtMs: row.editedAtMs,
    );
  }

  void apply(String kind, String key, Map<String, dynamic> p, int editedAtMs) {
    switch (kind) {
      case UserStateKind.subscriptionOverride:
        _db.execute(
          'INSERT OR REPLACE INTO subscription_overrides VALUES (?,?,?,?)',
          [ns, key, jsonEncode(p), editedAtMs],
        );
      case UserStateKind.billCardAssignment:
        store.applyUserStateEntity(ns, 'bill_card_assignments', key, {
          'observation_id': key,
          'user_card_id': p['userCardId'],
          'amount_due_paise': p['amountDuePaise'],
          'due_date': p['dueDate'],
          'statement_date': p['statementDate'],
        }, editedAtMs);
      case UserStateKind.bankBalance:
        final paise =
            (p['balance_paise'] as num?)?.round() ??
            (((p['amount'] as num?) ?? 0) * 100).round();
        store.applyUserStateEntity(ns, 'manual_bank_balances', key, {
          'id': key,
          'balance_paise': paise,
          'updated_at':
              p['updated_at'] ??
              DateTime.fromMillisecondsSinceEpoch(
                editedAtMs,
                isUtc: true,
              ).toIso8601String(),
        }, editedAtMs);
    }
  }

  /// True when none of the three stores holds a row (a fresh or restored phone).
  bool get isEmpty =>
      _db.select(
        'SELECT 1 FROM subscription_overrides WHERE namespace=? LIMIT 1',
        [ns],
      ).isEmpty &&
      _db.select(
        "SELECT 1 FROM financial_entities WHERE namespace=? AND entity IN "
        "('bill_card_assignments','manual_bank_balances') LIMIT 1",
        [ns],
      ).isEmpty;

  void remove(String kind, String key) {
    if (kind == UserStateKind.subscriptionOverride) {
      _db.execute(
        'DELETE FROM subscription_overrides WHERE namespace=? AND series_id=?',
        [ns, key],
      );
      return;
    }
    final entity = _entity(kind);
    if (entity != null) store.removeUserStateEntity(ns, entity, key);
  }
}

/// Pure: does the server's edit (at [serverMs]) beat what the phone has?
/// [localMs] is the stored row's edit time, [pendingMs] the time of a queued
/// push for the same item (a queued delete leaves no row). Nothing local at
/// all: the server wins. A tie keeps the phone (it is our own edit echoed).
bool serverWins({int? localMs, int? pendingMs, required int serverMs}) {
  final mine = [localMs, pendingMs].whereType<int>();
  if (mine.isEmpty) return true;
  return serverMs > mine.reduce(math.max);
}

/// Applies one server [item] to the phone by last-writer-wins. Never queues.
/// Returns true when the phone changed. A bill assignment naming a card the
/// phone does not have yet is kept as is (the card arrives separately).
bool applyUserStateItem(
  UserStateLocal local,
  UserStateItem item, {
  int? pendingMs,
}) {
  if (!UserStateKind.all.contains(item.kind) || item.undecryptable) {
    return false;
  }
  final mine = local.read(item.kind, item.key);
  final ms = item.clientEditedAt.millisecondsSinceEpoch;
  if (!serverWins(
    localMs: mine?.editedAtMs,
    pendingMs: pendingMs,
    serverMs: ms,
  )) {
    return false;
  }
  if (item.deleted || item.payload == null) {
    if (mine == null) return false;
    local.remove(item.kind, item.key);
    return true;
  }
  local.apply(item.kind, item.key, item.payload!, ms);
  return true;
}

/// Queues the push for [kind]/[key] from what the phone holds now: a put when
/// the row exists, a delete when it is gone. A later call for the same item
/// replaces the earlier one. Returns false when nothing was queued.
bool enqueueUserState(
  CommandOutbox commands,
  UserStateLocal local,
  String kind,
  String key, {
  DateTime? now,
}) {
  if (!kSyncLocalState) return false;
  final row = local.read(kind, key);
  final target = '$kind/$key';
  // A bill with no card chosen has nothing to restore: send it as a delete.
  final hasCard =
      kind != UserStateKind.billCardAssignment ||
      row?.payload['userCardId'] != null;
  if (row != null && hasCard) {
    // One object of at most 4 KiB, or the server refuses it for good.
    if (jsonEncode(row.payload).length > 4096) return false;
    return commands.enqueue(
      kind: UserStateCommand.put,
      target: target,
      replaces: const [UserStateCommand.delete],
      payload: {
        'kind': kind,
        'key': key,
        'clientEditedAt': DateTime.fromMillisecondsSinceEpoch(
          row.editedAtMs,
          isUtc: true,
        ).toIso8601String(),
        'payload': row.payload,
      },
    );
  }
  return commands.enqueue(
    kind: UserStateCommand.delete,
    target: target,
    replaces: const [UserStateCommand.put],
    payload: {
      'kind': kind,
      'key': key,
      'clientEditedAt': (now ?? DateTime.now()).toUtc().toIso8601String(),
    },
  );
}

/// Key of a typed bank balance, the same id the store uses.
String bankBalanceKey(String issuer, String accountLast4) =>
    '${canonicalBankSender(issuer)}:$accountLast4';

/// The handlers for [UserStateCommand]. [api] / [local] are resolved when a
/// command runs. An old server (404) is not a failure of the command: it
/// stays queued (retryable, backed off) and is not asked again until the next
/// app start.
Map<String, CommandHandler> userStateHandlers({
  required Future<UserStateApi?> Function() api,
  required Future<UserStateLocal?> Function() local,
  void Function()? onAdopted,
}) {
  Future<UserStateApi> needApi() async {
    if (!kSyncLocalState || _unsupported) throw UserStateUnsupported();
    return await api() ?? (throw StateError('Sign in to send this'));
  }

  Future<void> adopt(UserStateItem? item) async {
    if (item == null) return;
    final l = await local();
    if (l != null && applyUserStateItem(l, item)) onAdopted?.call();
  }

  return {
    UserStateCommand.put: (p) async {
      final a = await needApi();
      await adopt(
        await a.put(
          p['kind'] as String,
          p['key'] as String,
          (p['payload'] as Map).cast<String, dynamic>(),
          DateTime.parse(p['clientEditedAt'] as String),
        ),
      );
    },
    UserStateCommand.delete: (p) async {
      final a = await needApi();
      await adopt(
        await a.delete(
          p['kind'] as String,
          p['key'] as String,
          DateTime.parse(p['clientEditedAt'] as String),
        ),
      );
    },
  };
}

// --- provider wiring (a `Ref` or `WidgetRef`, hence dynamic) ---------------

Future<UserStateLocal?> userStateLocalFor(dynamic ref) async {
  final ns = ref.read(cacheNamespaceProvider) as String;
  if (!ns.startsWith('user:')) return null;
  final cache = await ref.read(responseCacheProvider.future);
  return UserStateLocal(cache.financialStore as FinancialStore, ns);
}

UserStateApi? userStateApiFor(dynamic ref) {
  final token = ref.read(accessTokenProvider) as String?;
  if (token == null) return null;
  return UserStateApi(
    apiBaseUrl: Env.apiBaseUrl,
    accessToken: token,
    client: ref.read(authenticatedHttpClientProvider) as http.Client,
  );
}

/// Spread into `accountCommandHandlers` (one line), so the background flush
/// and the sign-out flush both send these.
Map<String, CommandHandler> userStateCommandHandlers(dynamic ref) =>
    userStateHandlers(
      api: () async => userStateApiFor(ref),
      local: () => userStateLocalFor(ref),
      onAdopted: () {
        try {
          ref.read(commandOutboxRevisionProvider.notifier).state++;
        } catch (_) {}
      },
    );

/// Call after a local write to one of the three stores. Queues the push and
/// asks for a flush. Never throws and never blocks the screen.
Future<void> queueUserStatePush(dynamic ref, String kind, String key) async {
  if (!kSyncLocalState) return;
  try {
    final local = await userStateLocalFor(ref);
    if (local == null) return;
    final commands =
        await ref.read(commandOutboxProvider.future) as CommandOutbox;
    if (!enqueueUserState(commands, local, kind, key)) return;
    ref.read(commandOutboxRevisionProvider.notifier).state++;
    ref.read(outboxFlushRequestProvider.notifier).state++;
    ref.invalidate(pendingOutboxCountProvider);
  } catch (_) {}
}
