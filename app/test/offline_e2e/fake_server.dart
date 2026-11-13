// WP-Q1: an in-memory stand-in for the PandaPay API, used by the app-level
// offline -> online scenario tests. Synthetic data only.
//
// It speaks the HTTP contract the real repositories use and is idempotent the
// way the real server is (WP-S2, WP-S345, WP-S01): client ids, replayed:true,
// 409 card_already_added, superseded:true, duplicate-by-mutation-id. Anything
// that would be a duplicate on the real server is counted in [duplicates] so a
// test can fail on it.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// What the network does right now. Switchable at any time mid-test.
enum NetMode {
  /// Requests are served.
  online,

  /// No network: every request throws a [SocketException].
  offline,

  /// Radio up, server never answers (captive Wi-Fi). Hangs until the caller's
  /// own timeout fires.
  captive,

  /// Every request answers 500.
  error500,

  /// Every request answers 401 (token no longer accepted).
  unauthorized,
}

class RecordedRequest {
  RecordedRequest(this.method, this.path, this.query, this.body, this.mode);
  final String method;
  final String path;
  final Map<String, String> query;
  final Map<String, dynamic>? body;
  final NetMode mode;
  @override
  String toString() => '$method $path';
}

final _uuidRe = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);
bool isUuid(String s) => _uuidRe.hasMatch(s);

/// The catalogue the fake knows (product id -> name). Synthetic.
const kProducts = <String, String>{
  'product-1': 'Test Card One',
  'product-2': 'Test Card Two',
};

class FakeServer {
  FakeServer() {
    client = MockClient(_dispatch);
  }

  late final MockClient client;
  NetMode mode = NetMode.online;

  /// Every request the server SAW (also while answering 500). Requests that
  /// died before reaching it (offline/captive) are in [dropped].
  final List<RecordedRequest> log = [];
  final List<RecordedRequest> dropped = [];

  /// The next N mutating requests are applied, then the answer is lost
  /// (the client sees a connection error although the server changed).
  int loseNextResponses = 0;

  /// Path prefix -> status. Lets a test make one route fail (poison row).
  final Map<String, int> failPrefix = {};

  /// A predicate over (method, path, body) -> status; first non-null wins.
  int? Function(String method, String path, Map<String, dynamic>? body)?
  failWhen;

  // ---- state -------------------------------------------------------------
  int _seq = 0;
  String newId() {
    _seq++;
    return '00000000-0000-4000-8000-${_seq.toString().padLeft(12, '0')}';
  }

  final Map<String, Map<String, dynamic>> cards = {};
  final Map<String, Map<String, dynamic>> transactions = {};
  final Map<String, String> txnByMutation = {};
  final Map<String, Map<String, dynamic>> overrides = {};
  final Map<String, Map<String, dynamic>> budgets = {};
  final List<Map<String, dynamic>> consents = [];
  final Set<String> consentMutations = {};
  final List<Map<String, dynamic>> tickets = [];
  final Set<String> ticketIds = {};
  final List<Map<String, dynamic>> notifications = [];
  final Set<String> notificationMutations = {};
  final List<Map<String, dynamic>> recurring = [];
  final Map<String, Map<String, dynamic>> bills = {};
  final List<Map<String, dynamic>> statementBatches = [];
  final Set<String> statementKeys = {};
  final List<Map<String, dynamic>> changeLog = [];
  final Map<String, Object?> profile = {'displayName': 'Test Person'};
  final Set<String> pushedSeqs = {};

  /// Anything the real server would store twice.
  final List<String> duplicates = [];

  /// Requests carrying an id the real server answers 400 invalid_id for.
  final List<String> invalidIdRequests = [];

  /// Requests no route knew (the scenario touched something unmodelled).
  final List<String> unhandled = [];

  /// Extra routes a scenario can add: (method path-prefix) -> handler.
  final Map<String, FutureOr<http.Response> Function(RecordedRequest req)>
  extraRoutes = {};

  // ---- seeding -----------------------------------------------------------
  Map<String, dynamic> seedCard({
    String? id,
    String product = 'product-1',
    String? nickname,
    String? last4,
    bool isDefault = false,
  }) {
    final cid = id ?? newId();
    final row = <String, dynamic>{
      'id': cid,
      'card_product_id': product,
      'nickname': nickname,
      'card_name': kProducts[product] ?? 'Unknown',
      'card_type': 'credit',
      'is_default': isDefault,
      'is_archived': false,
      'last4': last4,
      'cap_states': <Object>[],
      'milestone_states': <Object>[],
      'fee_waiver_states': <Object>[],
      'total_points_earned': 0,
      'points_balance': null,
    };
    cards[cid] = row;
    return row;
  }

  Map<String, dynamic> seedTransaction({
    String? id,
    required double amount,
    String? cardId,
    String merchant = 'Synthetic Shop',
    String? categoryId,
    String? note,
    DateTime? at,
  }) {
    final tid = id ?? newId();
    final row = <String, dynamic>{
      'id': tid,
      'pipeline_version': 1,
      'event_id': null,
      'source_key': null,
      'amount_inr': amount,
      'occurred_at': (at ?? DateTime.utc(2026, 11, 10, 8)).toIso8601String(),
      'merchant_name': merchant,
      'merchant_vpa': null,
      'category_id': categoryId,
      'user_category_id': null,
      'category_name': null,
      'card_name': null,
      'user_card_id': cardId,
      'rail': 'unknown',
      'instrument': 'credit_card',
      'entry_kind': 'spend',
      'source': 'manual',
      'status': 'active',
      'reward_state': 'estimated',
      'note': note,
      'observations': <Object>[],
      'tags': <Object>[],
    };
    transactions[tid] = row;
    return row;
  }

  // ---- views -------------------------------------------------------------
  List<RecordedRequest> requests(String method, String pathPrefix) => [
    for (final r in log)
      if (r.method == method && r.path.startsWith(pathPrefix)) r,
  ];

  int count(String method, String pathPrefix) =>
      requests(method, pathPrefix).length;

  List<Map<String, dynamic>> get activeTransactions => [
    for (final t in transactions.values)
      if (t['status'] == 'active') t,
  ];

  void clearLog() {
    log.clear();
    dropped.clear();
  }

  // ---- http --------------------------------------------------------------
  http.Response _json(int status, Object body, {Map<String, String>? headers}) =>
      http.Response(
        jsonEncode(body),
        status,
        headers: {'content-type': 'application/json', ...?headers},
      );

  Future<http.Response> _dispatch(http.Request request) async {
    Map<String, dynamic>? body;
    if (request.body.isNotEmpty) {
      try {
        final d = jsonDecode(request.body);
        if (d is Map<String, dynamic>) body = d;
      } catch (_) {}
    }
    final rec = RecordedRequest(
      request.method,
      request.url.path,
      request.url.queryParameters,
      body,
      mode,
    );
    switch (mode) {
      case NetMode.offline:
        dropped.add(rec);
        throw const SocketException('Network is unreachable');
      case NetMode.captive:
        dropped.add(rec);
        // Never completes: the caller's own timeout is what ends it.
        return Completer<http.Response>().future;
      case NetMode.error500:
        log.add(rec);
        return _json(500, {'error': 'internal_error'});
      case NetMode.unauthorized:
        log.add(rec);
        return _json(401, {'error': 'Missing or invalid access token'});
      case NetMode.online:
        break;
    }
    log.add(rec);
    // Health probe and public reads are never forced to fail.
    final forced = _forcedFailure(rec);
    if (forced != null) {
      return _json(forced, {'error': forced == 403 ? 'phone_required' : 'x'});
    }
    final mutating = request.method != 'GET';
    final response = await _route(rec, request);
    if (mutating && loseNextResponses > 0) {
      loseNextResponses--;
      throw http.ClientException('Connection closed before response');
    }
    return response;
  }

  int? _forcedFailure(RecordedRequest r) {
    for (final e in failPrefix.entries) {
      if (r.path.startsWith(e.key)) return e.value;
    }
    return failWhen?.call(r.method, r.path, r.body);
  }

  Future<http.Response> _route(RecordedRequest r, http.Request raw) async {
    final p = r.path;
    final segs = p.split('/').where((s) => s.isNotEmpty).toList();
    final key = '${r.method} $p';
    for (final e in extraRoutes.entries) {
      if (key.startsWith(e.key)) return await e.value(r);
    }
    // uuid guard on every id segment of the entity routes.
    const idRoutes = {
      'transactions',
      'user-cards',
      'card-overrides',
      'budgets',
      'recurring',
    };
    if (segs.length >= 2 && idRoutes.contains(segs[0])) {
      const literal = {
        'reorder',
        'read',
        'category-bulk-apply',
        'summary',
        'preview',
      };
      if (!literal.contains(segs[1]) && !isUuid(segs[1])) {
        invalidIdRequests.add(key);
        return _json(400, {'error': 'invalid_id'});
      }
    }

    if (r.method == 'GET' && p == '/app-status') {
      return _json(200, {
        'minSupportedVersion': '1.0.0',
        'maintenanceMode': false,
      });
    }
    if (r.method == 'GET' && p == '/categories') {
      return _json(200, {'categories': <Object>[]});
    }
    if (r.method == 'GET' && p.startsWith('/catalogue')) {
      return _json(200, {'cards': <Object>[], 'products': <Object>[]});
    }

    // ---- user cards ----
    if (segs.isNotEmpty && segs[0] == 'user-cards') {
      return _userCards(r, segs);
    }
    if (segs.isNotEmpty && segs[0] == 'transactions') {
      return _transactions(r, segs);
    }
    if (segs.isNotEmpty && segs[0] == 'sync') return _sync(r, segs);
    if (segs.isNotEmpty && segs[0] == 'card-overrides') {
      return _overrides(r, segs);
    }
    if (segs.isNotEmpty && segs[0] == 'budgets') return _budgets(r, segs);
    if (p == '/consents' && r.method == 'POST') return _consent(r);
    if (p == '/support-tickets' && r.method == 'POST') return _ticket(r);
    if (p == '/notifications' && r.method == 'POST') return _notification(r);
    if (p == '/notifications' && r.method == 'GET') {
      return _json(200, {'notifications': notifications});
    }
    if (p == '/profile' && (r.method == 'PATCH' || r.method == 'PUT')) {
      profile.addAll(r.body ?? const {});
      return _json(200, {'profile': profile});
    }
    if (p == '/self-transfer-rules') return _json(200, {'rules': <Object>[]});
    if (r.method == 'GET' && p == '/spend-by-category') {
      final total = activeTransactions.fold<double>(0, (s, t) => s + (t['amount_inr'] as num));
      return _json(200, {
        'categories': [
          {
            'categoryId': null,
            'categorySlug': null,
            'categoryName': null,
            'totalSpendInr': total,
            'txnCount': activeTransactions.length,
          },
        ],
      });
    }
    if (r.method == 'GET' && p == '/home-summary') {
      return _json(200, {
        'homeSummary': {
          'rewardsThisMonthInr': 0,
          'rewardsAllTimeInr': 0,
          'transactionCount': activeTransactions.length,
          'streakDays': 0,
        },
      });
    }
    if (r.method == 'GET' && p == '/budgets') {
      return _json(200, {'budgets': budgets.values.toList()});
    }
    unhandled.add(key);
    return _json(404, {'error': 'not_found'});
  }

  // ---- cards ----
  Future<http.Response> _userCards(RecordedRequest r, List<String> segs) async {
    if (segs.length == 1) {
      if (r.method == 'GET') {
        final all = r.query['includeArchived'] == 'true';
        return _json(200, {
          'userCards': [
            for (final c in cards.values)
              if (all || c['is_archived'] != true) c,
          ],
        });
      }
      if (r.method == 'POST') return _addCard(r);
    }
    if (segs.length == 2 && segs[1] != 'reorder') {
      final c = cards[segs[1]];
      if (c == null) return _json(404, {'error': 'not found'});
      if (r.method == 'PATCH') {
        final b = r.body ?? {};
        if (b['last4'] != null && _lastFourTaken(c['id'] as String, c, b['last4'] as String)) {
          return _json(409, {'error': 'card_already_added'});
        }
        c.addAll(_cardFields(b));
        return _json(200, {'userCard': c});
      }
      if (r.method == 'DELETE') {
        c['is_archived'] = true;
        return _json(200, {'ok': true});
      }
    }
    if (segs.length == 3 && r.method == 'POST') {
      final c = cards[segs[1]];
      if (c == null) return _json(404, {'error': 'not found'});
      switch (segs[2]) {
        case 'archive':
          c['is_archived'] = true;
          return _json(200, {'ok': true});
        case 'unarchive':
          c['is_archived'] = false;
          return _json(200, {'ok': true});
        case 'default':
          for (final o in cards.values) {
            o['is_default'] = false;
          }
          c['is_default'] = true;
          return _json(200, {'ok': true});
        case 'points-adjustment':
          c['points_balance'] = r.body?['newBalance'];
          return _json(200, {'ok': true});
      }
    }
    unhandled.add('${r.method} ${r.path}');
    return _json(404, {'error': 'not_found'});
  }

  Map<String, dynamic> _cardFields(Map<String, dynamic> b) {
    const map = {
      'nickname': 'nickname',
      'last4': 'last4',
      'annualFeeOverrideInr': 'annual_fee_override_inr',
      'annual_fee_override_inr': 'annual_fee_override_inr',
      'pointsBalance': 'points_balance',
      'points_balance': 'points_balance',
      'is_default': 'is_default',
      'is_archived': 'is_archived',
      'credit_limit_inr': 'credit_limit_inr',
      'creditLimitInr': 'credit_limit_inr',
      'statement_day': 'statement_day',
      'due_day': 'due_day',
    };
    return {
      for (final e in b.entries)
        if (map.containsKey(e.key)) map[e.key]!: e.value,
    };
  }

  bool _lastFourTaken(String self, Map<String, dynamic> card, String last4) {
    for (final o in cards.values) {
      if (o['id'] != self &&
          o['card_product_id'] == card['card_product_id'] &&
          o['last4'] == last4 &&
          o['is_archived'] != true) {
        return true;
      }
    }
    return false;
  }

  http.Response _addCard(RecordedRequest r) {
    final b = r.body ?? {};
    final id = b['id'] as String?;
    if (id != null && !isUuid(id)) {
      invalidIdRequests.add('POST /user-cards id=$id');
      return _json(400, {'error': 'invalid_id'});
    }
    if (id != null && cards.containsKey(id)) {
      return _json(200, {'userCard': cards[id], 'replayed': true});
    }
    final product = b['cardProductId'] as String?;
    if (product == null || !kProducts.containsKey(product)) {
      return _json(404, {'error': 'product not found'});
    }
    final last4 = b['last4'] as String?;
    for (final o in cards.values) {
      if (o['card_product_id'] == product &&
          o['is_archived'] != true &&
          (last4 == null || o['last4'] == last4 || o['last4'] == null)) {
        if (last4 != null && o['last4'] == null) {
          o['last4'] = last4;
          return _json(200, {
            'userCard': o,
            'linkedExisting': true,
            'clientId': ?id,
          });
        }
        if (last4 == o['last4']) {
          return _json(409, {
            'error': 'card_already_added',
            'userCard': o,
            'clientId': ?id,
          });
        }
      }
    }
    final row = seedCard(
      id: id,
      product: product,
      nickname: b['nickname'] as String?,
      last4: last4,
    );
    return _json(201, {'userCard': row});
  }

  // ---- transactions ----
  Future<http.Response> _transactions(RecordedRequest r, List<String> segs) async {
    if (segs.length == 1) {
      if (r.method == 'GET') {
        final status = r.query['status'];
        final rows = [
          for (final t in transactions.values)
            if (status == null
                ? t['status'] == 'active'
                : t['status'] == status)
              t,
        ];
        return _json(200, {
          'transactions': rows,
          'pageInfo': {'hasMore': false, 'nextCursor': null},
        });
      }
      if (r.method == 'POST') return _logTxn(r);
    }
    if (segs.length == 2 && segs[1] == 'category-bulk-apply') {
      final ids = (r.body?['selectedTransactionIds'] as List?) ?? const [];
      for (final id in ids) {
        final t = transactions[id];
        if (t != null) {
          t['category_id'] = r.body?['targetCategoryId'];
        }
      }
      return _json(200, {
        'result': {'appliedCount': ids.length, 'updatedIds': ids},
      });
    }
    if (segs.length == 2) {
      final t = transactions[segs[1]];
      if (t == null) return _json(404, {'error': 'not found'});
      if (r.method == 'GET') return _json(200, {'transaction': t});
      if (r.method == 'PATCH') {
        t.addAll(_txnFields(r.body ?? {}));
        return _json(200, {'transaction': t});
      }
    }
    if (segs.length == 3 && r.method == 'POST') {
      final t = transactions[segs[1]];
      if (t == null) return _json(404, {'error': 'not found'});
      switch (segs[2]) {
        case 'ignore':
          if (t['status'] == 'ignored') {
            return _json(409, {'error': "transaction already 'ignored'"});
          }
          t['status'] = 'ignored';
          return _json(200, {'ok': true});
        case 'restore':
          t['status'] = 'active';
          return _json(200, {'ok': true});
        case 'spend-exclusion':
          t['exclude_from_spend'] = r.body?['excluded'] == true;
          return _json(200, {'ok': true});
      }
    }
    if (segs.length == 3 && segs[2] == 'note' && r.method == 'PATCH') {
      final t = transactions[segs[1]];
      if (t == null) return _json(404, {'error': 'not found'});
      t['note'] = r.body?['note'];
      return _json(200, {'ok': true});
    }
    unhandled.add('${r.method} ${r.path}');
    return _json(404, {'error': 'not_found'});
  }

  Map<String, dynamic> _txnFields(Map<String, dynamic> b) {
    const map = {
      'note': 'note',
      'categoryId': 'category_id',
      'category_id': 'category_id',
      'userCategoryId': 'user_category_id',
      'user_category_id': 'user_category_id',
      'userCardId': 'user_card_id',
      'user_card_id': 'user_card_id',
      'merchantName': 'merchant_name',
      'merchant_name': 'merchant_name',
      'amountInr': 'amount_inr',
      'amount_inr': 'amount_inr',
      'instrument': 'instrument',
      'entryKind': 'entry_kind',
      'entry_kind': 'entry_kind',
      'paymentMethod': 'payment_method',
      'payment_method': 'payment_method',
      'status': 'status',
    };
    return {
      for (final e in b.entries)
        if (map.containsKey(e.key)) map[e.key]!: e.value,
    };
  }

  http.Response _logTxn(RecordedRequest r) {
    final b = r.body ?? {};
    final mutation = b['clientMutationId'] as String?;
    if (mutation != null && txnByMutation.containsKey(mutation)) {
      return _json(200, {'transaction': transactions[txnByMutation[mutation]]});
    }
    final cardId = b['userCardId'] as String?;
    if (cardId != null && !cards.containsKey(cardId)) {
      // A queued transaction naming a card the server never heard of.
      return _json(404, {'error': 'card not found'});
    }
    final row = seedTransaction(
      amount: (b['amountInr'] as num).toDouble(),
      cardId: cardId,
      merchant: (b['merchantName'] as String?) ?? 'Unknown',
      categoryId: b['categoryId'] as String?,
      note: b['note'] as String?,
      at: DateTime.tryParse((b['occurredAt'] as String?) ?? ''),
    );
    row['instrument'] = b['instrument'] ?? row['instrument'];
    row['entry_kind'] = b['entryKind'] ?? row['entry_kind'];
    if (mutation != null) txnByMutation[mutation] = row['id'] as String;
    // The real unique index is on (profile, client_mutation_id); a replay
    // without the id is a duplicate row.
    final sig = '${row['amount_inr']}|${row['merchant_name']}|${row['occurred_at']}';
    final same = transactions.values
        .where((t) =>
            t != row &&
            '${t['amount_inr']}|${t['merchant_name']}|${t['occurred_at']}' == sig &&
            t['status'] == 'active')
        .length;
    if (mutation == null && same > 0) duplicates.add('txn $sig');
    return _json(201, {'transaction': row});
  }

  // ---- sync ----
  Future<http.Response> _sync(RecordedRequest r, List<String> segs) async {
    switch (segs[1]) {
      case 'register-device':
        return _json(201, {'deviceId': 'device-1'});
      case 'push':
        final changes = (r.body?['changes'] as List?) ?? const [];
        final results = <Map<String, dynamic>>[];
        for (final c in changes.cast<Map<String, dynamic>>()) {
          final seq = c['clientSeq'];
          final dupKey = '${c['entity']}|${c['entityId']}|$seq';
          if (!pushedSeqs.add(dupKey)) duplicates.add('push $dupKey');
          final entity = c['entity'] as String;
          final id = c['entityId'] as String;
          final payload =
              (c['payload'] as Map?)?.cast<String, dynamic>() ?? const {};
          if (!isUuid(id)) {
            invalidIdRequests.add('push $entity $id');
            results.add({'clientSeq': seq, 'applied': false, 'reason': 'malformed'});
            continue;
          }
          Map<String, dynamic>? row;
          Map<String, dynamic> fields = payload;
          if (entity == 'transactions') {
            row = transactions[id];
            fields = _txnFields(payload);
          } else if (entity == 'user_cards') {
            row = cards[id];
            fields = _cardFields(payload);
          } else {
            results.add({
              'clientSeq': seq,
              'applied': false,
              'reason': 'unknown_entity',
            });
            continue;
          }
          if (row == null) {
            results.add({'clientSeq': seq, 'applied': false, 'reason': 'not_found'});
            continue;
          }
          if (c['op'] == 'delete') {
            if (entity == 'transactions') row['status'] = 'deleted';
            if (entity == 'user_cards') row['is_archived'] = true;
          } else {
            row.addAll(fields);
          }
          changeLog.add({'entity': entity, 'entity_id': id, 'op': 'update'});
          results.add({'clientSeq': seq, 'applied': true, 'conflicts': 0});
        }
        return _json(200, {'results': results});
      case 'pull':
        final since = int.tryParse(r.query['since'] ?? '0') ?? 0;
        final slice = changeLog.skip(since).take(25).toList();
        return _json(200, {
          'changes': [
            for (var i = 0; i < slice.length; i++)
              {...slice[i], 'server_seq': since + i + 1},
          ],
          'conflicts': <Object>[],
          'hasMore': since + slice.length < changeLog.length,
          'latestServerSeq': since + slice.length,
        });
      case 'ack':
        return _json(200, {'ok': true});
    }
    unhandled.add('${r.method} ${r.path}');
    return _json(404, {'error': 'not_found'});
  }

  // ---- overrides / budgets ----
  Future<http.Response> _overrides(RecordedRequest r, List<String> segs) async {
    if (segs.length == 1 && r.method == 'GET') {
      return _json(200, {'overrides': overrides.values.toList()});
    }
    if (segs.length == 1 && r.method == 'POST') {
      final b = r.body ?? {};
      final id = (b['id'] as String?) ?? newId();
      if (overrides.containsKey(id)) {
        return _json(200, {'override': overrides[id], 'replayed': true});
      }
      if (!cards.containsKey(b['userCardId'])) {
        return _json(404, {'error': 'card not found'});
      }
      overrides[id] = {
        'id': id,
        'user_card_id': b['userCardId'],
        'scope': b['scope'],
        'vpa': b['vpa'],
        'merchant_name': b['merchantName'],
        'category_id': b['categoryId'],
        'reason_note': b['reasonNote'],
        'is_active': true,
      };
      return _json(201, {'override': overrides[id]});
    }
    if (segs.length == 2 && r.method == 'DELETE') {
      if (overrides.remove(segs[1]) == null) {
        return _json(404, {'error': 'override not found'});
      }
      return _json(200, {'ok': true});
    }
    unhandled.add('${r.method} ${r.path}');
    return _json(404, {'error': 'not_found'});
  }

  String _budgetTarget(Map<String, dynamic> b) =>
      '${b['scope']}|${b['scopeRefId'] ?? ''}|${b['period']}';

  Future<http.Response> _budgets(RecordedRequest r, List<String> segs) async {
    if (segs.length == 1 && r.method == 'GET') {
      final now = DateTime.now().toUtc();
      return _json(200, {
        'budgets': [
          for (final b in activeBudgets)
            {
              'id': b['id'],
              'scope': b['scope'],
              'scopeRefId': b['scope_ref_id'],
              'label': 'Budget',
              'period': b['period'],
              'amountInr': b['amount_inr'],
              'spentInr': 0,
              'txnCount': 0,
              'periodStart': DateTime.utc(now.year, now.month, 1).toIso8601String(),
              'periodEnd': DateTime.utc(now.year, now.month + 1, 0).toIso8601String(),
              'consumedFraction': 0,
              'elapsedFraction': 0.4,
            },
        ],
      });
    }
    if (segs.length == 1 && r.method == 'POST') {
      final b = r.body ?? {};
      final id = b['id'] as String?;
      if (id != null && !isUuid(id)) {
        invalidIdRequests.add('POST /budgets id=$id');
        return _json(400, {'error': 'invalid_id'});
      }
      if (id != null && budgets.containsKey(id)) {
        return _json(200, {'budget': budgets[id], 'replayed': true});
      }
      final bid = id ?? newId();
      final edited = b['clientEditedAt'] as String?;
      final target = _budgetTarget(b);
      for (final o in budgets.values) {
        final oe = o['client_edited_at'] as String?;
        if (_budgetTarget({
                  'scope': o['scope'],
                  'scopeRefId': o['scope_ref_id'],
                  'period': o['period'],
                }) ==
                target &&
            oe != null &&
            edited != null &&
            DateTime.parse(oe).isAfter(DateTime.parse(edited))) {
          final row = _budgetRow(bid, b)..['is_active'] = false;
          budgets[bid] = row;
          return _json(200, {'budget': row, 'superseded': true});
        }
      }
      for (final o in budgets.values) {
        if (_budgetTarget({
                  'scope': o['scope'],
                  'scopeRefId': o['scope_ref_id'],
                  'period': o['period'],
                }) ==
                target &&
            o['is_active'] == true) {
          o['is_active'] = false;
        }
      }
      final row = _budgetRow(bid, b);
      budgets[bid] = row;
      return _json(201, {'budget': row});
    }
    if (segs.length == 2 && r.method == 'DELETE') {
      final o = budgets[segs[1]];
      if (o == null || o['is_active'] != true) {
        return _json(404, {'error': 'budget not found'});
      }
      o['is_active'] = false;
      return _json(200, {'ok': true});
    }
    unhandled.add('${r.method} ${r.path}');
    return _json(404, {'error': 'not_found'});
  }

  Map<String, dynamic> _budgetRow(String id, Map<String, dynamic> b) => {
    'id': id,
    'scope': b['scope'],
    'scope_ref_id': b['scopeRefId'],
    'period': b['period'],
    'amount_inr': b['amountInr'],
    'rollover': b['rollover'] ?? false,
    'client_edited_at': b['clientEditedAt'],
    'is_active': true,
  };

  List<Map<String, dynamic>> get activeBudgets => [
    for (final b in budgets.values)
      if (b['is_active'] == true) b,
  ];

  // ---- append-only ----
  http.Response _consent(RecordedRequest r) {
    final b = r.body ?? {};
    final m = b['clientMutationId'] as String?;
    if (m != null && !consentMutations.add(m)) {
      return _json(200, {'consent': consents.last, 'replayed': true});
    }
    if (m == null && consents.any((c) => c['purpose'] == b['purpose'] && c['granted'] == b['granted'])) {
      duplicates.add('consent ${b['purpose']}');
    }
    final row = {...b, 'id': newId()};
    consents.add(row);
    return _json(201, {'consent': row});
  }

  http.Response _ticket(RecordedRequest r) {
    final b = r.body ?? {};
    final id = b['id'] as String?;
    if (id != null && !ticketIds.add(id)) {
      return _json(201, {'ticket': tickets.firstWhere((t) => t['id'] == id)});
    }
    final row = {...b, 'id': id ?? newId()};
    tickets.add(row);
    return _json(201, {'ticket': row});
  }

  http.Response _notification(RecordedRequest r) {
    final b = r.body ?? {};
    final m = b['clientMutationId'] as String?;
    if (m != null && !notificationMutations.add(m)) {
      return _json(200, {
        'notification': notifications.firstWhere(
          (n) => n['clientMutationId'] == m,
        ),
        'replayed': true,
      });
    }
    final row = {...b, 'id': newId()};
    notifications.add(row);
    return _json(201, {'notification': row});
  }
}
