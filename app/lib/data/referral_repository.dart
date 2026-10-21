import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_exception.dart';
import 'local/response_cache.dart';

class CachedJsonSnapshot {
  const CachedJsonSnapshot({required this.body, required this.fetchedAt});

  final Map<String, dynamic> body;
  final DateTime fetchedAt;
}

abstract interface class AccountScopedJsonCache {
  Future<CachedJsonSnapshot?> read(String namespace, String key);

  Future<void> write(String namespace, String key, Map<String, dynamic> body);
}

class LocalAccountScopedJsonCache implements AccountScopedJsonCache {
  const LocalAccountScopedJsonCache(this.loadCache);

  final Future<ResponseCache> Function() loadCache;

  @override
  Future<CachedJsonSnapshot?> read(String namespace, String key) async {
    final response = await (await loadCache()).read('$namespace:$key');
    if (response == null) return null;
    try {
      final decoded = jsonDecode(response.rawJson);
      if (decoded is Map) {
        return CachedJsonSnapshot(
          body: Map<String, dynamic>.from(decoded),
          fetchedAt: response.fetchedAt,
        );
      }
    } on FormatException {
      // A corrupt local snapshot is ignored; it can never replace live data.
    } on TypeError {
      // A non-object snapshot is not a valid response for these endpoints.
    }
    return null;
  }

  @override
  Future<void> write(
    String namespace,
    String key,
    Map<String, dynamic> body,
  ) async {
    await (await loadCache()).put('$namespace:$key', jsonEncode(body));
  }
}

/// Exact INR amount carried by the referral/reward API.
///
/// API amounts are accepted as decimal-string paise (preferred) or an exact
/// JSON integer. Floating-point values and rupee-denominated values are
/// rejected so display code cannot silently round an award.
class PaiseAmount {
  const PaiseAmount(this.value);

  final int value;

  factory PaiseAmount.fromJson(Object? raw) {
    final parsed = switch (raw) {
      final String value => int.tryParse(value),
      final int value => value,
      _ => null,
    };
    if (parsed == null) {
      throw const FormatException('Expected an integer paise amount.');
    }
    return PaiseAmount(parsed);
  }

  String get inr {
    final absolute = value.abs();
    final rupees = _indianGrouping((absolute ~/ 100).toString());
    final paise = absolute % 100;
    final decimal = paise == 0 ? '' : '.${paise.toString().padLeft(2, '0')}';
    return '${value < 0 ? '-' : ''}₹$rupees$decimal';
  }

  static String _indianGrouping(String digits) {
    if (digits.length <= 3) return digits;
    final lastThree = digits.substring(digits.length - 3);
    var leading = digits.substring(0, digits.length - 3);
    final groups = <String>[];
    while (leading.length > 2) {
      groups.insert(0, leading.substring(leading.length - 2));
      leading = leading.substring(0, leading.length - 2);
    }
    if (leading.isNotEmpty) groups.insert(0, leading);
    return '${groups.join(',')},$lastThree';
  }
}

class ReferralFriend {
  const ReferralFriend({
    required this.id,
    required this.state,
    this.label,
    this.joinedAt,
    this.completedDays,
    this.requiredDays,
  });

  final String id;
  final String state;
  final String? label;
  final DateTime? joinedAt;
  final int? completedDays;
  final int? requiredDays;

  String get displayState => _referralStateLabel(state);

  factory ReferralFriend.fromJson(Map<String, dynamic> json) {
    final milestone =
        _map(json['milestone']) ??
        _map(json['progress']) ??
        const <String, dynamic>{};
    return ReferralFriend(
      id: _requiredString(json, const ['id', 'referralId']),
      state:
          _string(json, const [
            'state',
            'status',
            'rewardState',
            'reward_state',
          ]) ??
          'joined',
      label: _string(json, const ['label', 'displayName', 'display_name']),
      joinedAt: _date(json, const ['joinedAt', 'joined_at', 'created_at']),
      completedDays:
          _integer(milestone, const [
            'completedDays',
            'completed_days',
            'progressDays',
            'progress_days',
          ]) ??
          _integer(json, const ['completedDays', 'completed_days']),
      requiredDays:
          _integer(milestone, const ['requiredDays', 'required_days']) ??
          _integer(json, const ['requiredDays', 'required_days']),
    );
  }
}

class ReferralPage {
  const ReferralPage({
    required this.year,
    required this.friends,
    this.joinedCount,
    this.awardedPaise,
    this.nextCursor,
    this.code,
    this.rewardsActive,
    this.asOf,
  });

  final int year;
  final List<ReferralFriend> friends;
  final int? joinedCount;
  final int? awardedPaise;
  final String? nextCursor;
  final String? code;
  final bool? rewardsActive;
  final DateTime? asOf;

  factory ReferralPage.fromJson(
    Map<String, dynamic> json, {
    required int year,
  }) {
    final root = _payload(json);
    final joinTotals =
        _map(root['joinTotals']) ??
        _map(root['joinedTotals']) ??
        _map(root['join_totals']) ??
        const <String, dynamic>{};
    final awardTotals =
        _map(root['awardTotals']) ??
        _map(root['awardedTotals']) ??
        _map(root['award_totals']) ??
        const <String, dynamic>{};
    final rawFriends = root['referrals'] ?? root['friends'];
    final friends = rawFriends is List
        ? rawFriends
              .whereType<Map>()
              .map(
                (item) =>
                    ReferralFriend.fromJson(Map<String, dynamic>.from(item)),
              )
              .toList(growable: false)
        : const <ReferralFriend>[];

    return ReferralPage(
      year: year,
      friends: friends,
      joinedCount:
          _integer(joinTotals, const [
            'count',
            'joinedCount',
            'joined_count',
          ]) ??
          _integer(root, const ['joinedCount', 'joined_count']),
      awardedPaise:
          _paise(awardTotals, const [
            'amountPaise',
            'amount_paise',
            'awardedPaise',
            'awarded_paise',
          ]) ??
          _paise(root, const ['awardedPaise', 'awarded_paise']),
      nextCursor: _string(root, const ['nextCursor', 'next_cursor']),
      code: _string(root, const ['code', 'referralCode', 'referral_code']),
      rewardsActive: _boolean(root, const ['rewardsActive', 'rewards_active']),
      asOf: _date(root, const ['asOf', 'as_of', 'lastConfirmedAt']),
    );
  }
}

class ReferralMine {
  const ReferralMine({
    required this.state,
    required this.rewardEligible,
    required this.completedDays,
    required this.requiredDays,
    this.inviterAlias,
    this.joinedAt,
    this.deadlineAt,
  });

  final String state;
  final bool rewardEligible;
  final int completedDays;
  final int requiredDays;
  final String? inviterAlias;
  final DateTime? joinedAt;
  final DateTime? deadlineAt;

  String get displayState => _referralStateLabel(state);

  static ReferralMine? fromJson(Map<String, dynamic> json) {
    final root = _payload(json);
    final raw = root.containsKey('referral')
        ? root['referral']
        : root.containsKey('mine')
        ? root['mine']
        : root;
    if (raw == null) return null;
    final mine = raw is Map ? Map<String, dynamic>.from(raw) : root;
    final milestone = _map(mine['milestone']) ?? _map(mine['progress']) ?? mine;
    return ReferralMine(
      state: _string(mine, const ['state', 'status']) ?? 'joined',
      rewardEligible:
          _boolean(mine, const ['rewardEligible', 'reward_eligible']) ?? false,
      completedDays:
          _integer(milestone, const [
            'completedDays',
            'completed_days',
            'progressDays',
            'progress_days',
          ]) ??
          0,
      requiredDays:
          _integer(milestone, const ['requiredDays', 'required_days']) ?? 3,
      inviterAlias: _string(mine, const ['inviterAlias', 'inviter_alias']),
      joinedAt: _date(mine, const ['joinedAt', 'joined_at']),
      deadlineAt: _date(mine, const ['deadlineAt', 'deadline_at']),
    );
  }
}

class SpinResult {
  const SpinResult({
    required this.entitlementId,
    required this.spinId,
    required this.amount,
    required this.state,
    this.outcomeId,
    this.ledgerEntryId,
    this.replayed = false,
  });

  final String entitlementId;
  final String spinId;
  final PaiseAmount amount;
  final String state;
  final String? outcomeId;
  final String? ledgerEntryId;
  final bool replayed;

  bool get isCredited =>
      (state == 'credited' && ledgerEntryId != null) ||
      (state == 'completed' && amount.value == 0 && ledgerEntryId == null);

  factory SpinResult.fromJson(Map<String, dynamic> json) {
    final outer = _payload(json);
    final nested = outer['spin'] ?? outer['result'];
    final root = nested is Map ? Map<String, dynamic>.from(nested) : outer;
    final result = SpinResult(
      entitlementId: _requiredString(root, const [
        'entitlementId',
        'entitlement_id',
      ]),
      spinId: _requiredString(root, const ['spinId', 'spin_id', 'id']),
      amount: PaiseAmount.fromJson(
        _first(root, const ['amountPaise', 'amount_paise']),
      ),
      state: _string(root, const ['state', 'status']) ?? 'credited',
      outcomeId: _string(root, const ['outcomeId', 'outcome_id']),
      ledgerEntryId: _string(root, const ['ledgerEntryId', 'ledger_entry_id']),
      replayed:
          _boolean(root, const ['replayed']) ??
          _boolean(outer, const ['replayed']) ??
          false,
    );
    if (!result.isCredited ||
        result.amount.value < 0 ||
        result.amount.value > 50000) {
      throw const FormatException('Spin response is not a confirmed credit.');
    }
    return result;
  }
}

class SpinPrize {
  const SpinPrize({
    required this.id,
    required this.amount,
    required this.weight,
  });

  final String id;
  final PaiseAmount amount;
  final int weight;

  factory SpinPrize.fromJson(Map<String, dynamic> json) {
    final id = _string(json, const ['id']);
    final rawWeight = json['weight'];
    final weight = rawWeight is int ? rawWeight : null;
    final amount = PaiseAmount.fromJson(
      json['amountPaise'] ?? json['amount_paise'],
    );
    if (id == null ||
        id.isEmpty ||
        weight == null ||
        weight <= 0 ||
        amount.value < 0 ||
        amount.value > 50000) {
      throw const FormatException('Spin prize configuration is invalid.');
    }
    return SpinPrize(id: id, amount: amount, weight: weight);
  }
}

class SpinConfiguration {
  const SpinConfiguration({
    required this.role,
    required this.campaignVersion,
    required this.prizes,
  });

  final String role;
  final String campaignVersion;
  final List<SpinPrize> prizes;

  int get totalWeight => prizes.fold(0, (total, prize) => total + prize.weight);

  SpinPrize? prizeFor(SpinResult result) {
    for (final prize in prizes) {
      if ((result.outcomeId != null && prize.id == result.outcomeId) ||
          (result.outcomeId == null &&
              prize.amount.value == result.amount.value)) {
        return prize;
      }
    }
    return null;
  }

  factory SpinConfiguration.fromJson(Map<String, dynamic> json) {
    final root = _payload(json);
    final role = _string(root, const ['role']);
    final campaignVersion = _string(root, const [
      'campaignVersion',
      'campaign_version',
    ]);
    final rawPrizes = root['distribution'] ?? root['prizes'];
    if (role == null ||
        !const {'inviter', 'referee'}.contains(role) ||
        campaignVersion == null ||
        rawPrizes is! List ||
        rawPrizes.isEmpty) {
      throw const FormatException('Spin prize configuration is incomplete.');
    }
    final prizes = rawPrizes
        .whereType<Map>()
        .map((prize) => SpinPrize.fromJson(Map<String, dynamic>.from(prize)))
        .toList(growable: false);
    if (prizes.length != rawPrizes.length ||
        prizes.map((prize) => prize.id).toSet().length != prizes.length) {
      throw const FormatException(
        'Spin prize configuration contains invalid prizes.',
      );
    }
    final totalWeight = prizes.fold<int>(
      0,
      (total, prize) => total + prize.weight,
    );
    if (totalWeight <= 0 || totalWeight > 0x7fffffff) {
      throw const FormatException('Spin prize configuration has invalid odds.');
    }
    return SpinConfiguration(
      role: role,
      campaignVersion: campaignVersion,
      prizes: prizes,
    );
  }
}

class RewardEntitlement {
  const RewardEntitlement({
    required this.id,
    required this.state,
    required this.role,
    this.result,
  });

  final String id;
  final String state;
  final String role;
  final SpinResult? result;

  bool get isReady => state == 'ready';
  bool get isHeld => state == 'held' || state == 'under_review';

  factory RewardEntitlement.fromJson(Map<String, dynamic> json) {
    final rawResult = json['spin'] ?? json['result'];
    final directSpinId = _string(json, const ['spinId', 'spin_id']);
    final directAmount = json['amountPaise'] ?? json['amount_paise'];
    final directSpin = directSpinId != null && directAmount != null
        ? <String, dynamic>{
            ...json,
            'state': PaiseAmount.fromJson(directAmount).value == 0
                ? 'completed'
                : 'credited',
          }
        : null;
    return RewardEntitlement(
      id: _requiredString(json, const [
        'id',
        'entitlementId',
        'entitlement_id',
      ]),
      state: _string(json, const ['state', 'status']) ?? 'unknown',
      role:
          _string(json, const [
            'role',
            'beneficiaryRole',
            'beneficiary_role',
          ]) ??
          'member',
      result: rawResult is Map
          ? SpinResult.fromJson(Map<String, dynamic>.from(rawResult))
          : directSpin == null
          ? null
          : SpinResult.fromJson(directSpin),
    );
  }
}

class RewardPage {
  const RewardPage(this.entitlements);

  final List<RewardEntitlement> entitlements;

  factory RewardPage.fromJson(Map<String, dynamic> json) {
    final root = _payload(json);
    final raw = root['rewards'] ?? root['entitlements'];
    if (raw is! List) return const RewardPage([]);
    return RewardPage(
      raw
          .whereType<Map>()
          .map(
            (item) =>
                RewardEntitlement.fromJson(Map<String, dynamic>.from(item)),
          )
          .toList(growable: false),
    );
  }
}

class ReferralDashboard {
  const ReferralDashboard({
    required this.page,
    required this.rewards,
    required this.mine,
    this.code,
    this.isStale = false,
    this.cachedAt,
  });

  final ReferralPage page;
  final List<RewardEntitlement> rewards;
  final ReferralMine? mine;
  final String? code;
  final bool isStale;
  final DateTime? cachedAt;

  factory ReferralDashboard.fromResponses({
    required int year,
    required Map<String, dynamic> overview,
    required Map<String, dynamic> mine,
    required Map<String, dynamic> rewards,
    required Map<String, dynamic> code,
    bool isStale = false,
    DateTime? cachedAt,
  }) {
    final referralPage = ReferralPage.fromJson(overview, year: year);
    final codeRoot = _payload(code);
    final rawCode = codeRoot['code'] is Map
        ? _string(Map<String, dynamic>.from(codeRoot['code'] as Map), const [
            'code',
          ])
        : _string(codeRoot, const ['code', 'referralCode', 'referral_code']);
    return ReferralDashboard(
      page: referralPage,
      rewards: RewardPage.fromJson(rewards).entitlements,
      mine: ReferralMine.fromJson(mine),
      code: rawCode ?? referralPage.code,
      isStale: isStale,
      cachedAt: cachedAt,
    );
  }
}

class _JsonRead {
  const _JsonRead(this.body, {this.isStale = false, this.cachedAt});

  final Map<String, dynamic> body;
  final bool isStale;
  final DateTime? cachedAt;
}

abstract interface class ReferralRepository {
  Future<ReferralDashboard> loadDashboard({required int year});

  Future<ReferralPage> loadMore({required int year, required String cursor});

  Future<SpinConfiguration> loadSpinConfiguration(String entitlementId);

  Future<SpinResult> spin(String entitlementId);
}

/// HTTP implementation of the v2 referral and reward contracts. The old
/// GET /referrals route remains untouched for older app builds.
class HttpReferralRepository implements ReferralRepository {
  HttpReferralRepository({
    required this.apiBaseUrl,
    required this.accessToken,
    this.cache,
    this.cacheNamespace,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final String apiBaseUrl;
  final String accessToken;
  final AccountScopedJsonCache? cache;
  final String Function()? cacheNamespace;
  final http.Client _client;

  Map<String, String> get _headers => {
    'Authorization': 'Bearer $accessToken',
    'Content-Type': 'application/json',
  };

  @override
  Future<ReferralDashboard> loadDashboard({required int year}) async {
    final values = await Future.wait([
      _get('/referrals/v2', query: {'year': '$year'}, cacheKey: 'v2:$year'),
      _get('/referrals/mine', cacheKey: 'mine'),
      _get('/rewards', cacheKey: 'rewards'),
      // This endpoint is specified as idempotent get-or-create. Its response
      // can be reused offline, but spin mutations are never cached/replayed.
      _post('/referrals/code', cacheKey: 'code'),
    ]);
    final dashboard = ReferralDashboard.fromResponses(
      year: year,
      overview: values[0].body,
      mine: values[1].body,
      rewards: values[2].body,
      code: values[3].body,
      isStale: values.any((value) => value.isStale),
      cachedAt: _oldestStaleRead(values),
    );
    if (dashboard.code == null) {
      throw const FormatException(
        'The referral-code response did not include a code.',
      );
    }
    return dashboard;
  }

  @override
  Future<ReferralPage> loadMore({
    required int year,
    required String cursor,
  }) async {
    final body = await _get(
      '/referrals/v2',
      query: {'year': '$year', 'cursor': cursor},
    );
    return ReferralPage.fromJson(body.body, year: year);
  }

  @override
  Future<SpinConfiguration> loadSpinConfiguration(String entitlementId) async {
    final id = Uri.encodeComponent(entitlementId);
    final body = await _get('/rewards/$id/spin-config');
    return SpinConfiguration.fromJson(body.body);
  }

  @override
  Future<SpinResult> spin(String entitlementId) async {
    final id = Uri.encodeComponent(entitlementId);
    final body = await _post('/rewards/$id/spin');
    final result = SpinResult.fromJson(body.body);
    if (result.entitlementId != entitlementId) {
      throw const FormatException(
        'Spin response belongs to a different reward.',
      );
    }
    return result;
  }

  Future<_JsonRead> _get(
    String path, {
    Map<String, String>? query,
    String? cacheKey,
  }) => _read(path, method: 'GET', cacheKey: cacheKey, query: query);

  Future<_JsonRead> _read(
    String path, {
    required String method,
    String? cacheKey,
    Map<String, String>? query,
  }) async {
    final namespace = cacheKey == null ? null : _currentNamespace;
    final uri = _uri(path, query);
    try {
      final response = method == 'GET'
          ? await _client.get(uri, headers: _headers)
          : await _client.post(uri, headers: _headers, body: '{}');
      if (response.statusCode < 200 || response.statusCode >= 300) {
        _throwResponse(method, path, response);
      }
      final body = response.body.isEmpty
          ? <String, dynamic>{}
          : _decodeObject(response.body, path);
      if (cacheKey != null && cache != null) {
        _ensureSameNamespace(namespace!);
        await cache!.write(namespace, cacheKey, body);
      }
      return _JsonRead(body);
    } catch (error) {
      if (cacheKey == null ||
          cache == null ||
          !isTransientNetworkFailure(error)) {
        rethrow;
      }
      _ensureSameNamespace(namespace!);
      final snapshot = await cache!.read(namespace, cacheKey);
      if (snapshot == null) rethrow;
      return _JsonRead(
        snapshot.body,
        isStale: true,
        cachedAt: snapshot.fetchedAt,
      );
    }
  }

  Future<_JsonRead> _post(String path, {String? cacheKey}) =>
      _read(path, method: 'POST', cacheKey: cacheKey);

  String get _currentNamespace => cacheNamespace?.call() ?? 'unscoped';

  void _ensureSameNamespace(String namespace) {
    if (_currentNamespace != namespace) {
      throw const AuthenticationUnavailableException(
        'Your account changed. Refresh to load its referral details.',
      );
    }
  }

  Uri _uri(String path, [Map<String, String>? query]) {
    final base = apiBaseUrl.endsWith('/')
        ? apiBaseUrl.substring(0, apiBaseUrl.length - 1)
        : apiBaseUrl;
    return Uri.parse('$base$path').replace(queryParameters: query);
  }

  Never _throwResponse(String method, String path, http.Response response) {
    String? code;
    String? message;
    try {
      final body = jsonDecode(response.body);
      if (body is Map) {
        code = body['error'] as String? ?? body['code'] as String?;
        message = body['message'] as String?;
      }
    } catch (_) {
      // The status remains useful even if the server returned non-JSON.
    }
    throw ApiException(
      '$method $path failed: ${response.statusCode} ${response.body}',
      userMessage: _referralErrorMessage(response.statusCode, code, message),
    );
  }

  static String _referralErrorMessage(
    int status,
    String? code,
    String? message,
  ) {
    if (message != null && message.trim().isNotEmpty && message.length < 160) {
      return message;
    }
    return switch (code) {
      'reward_not_ready' => 'This reward is not ready to spin yet.',
      'reward_held' => 'This reward is under review. Check back later.',
      'feature_paused' => 'Referral rewards are temporarily paused.',
      'session_invalid' =>
        'Your session expired. Please sign in and try again.',
      'invitation_required' => 'This account cannot access referral rewards.',
      _ when status == 401 || status == 403 =>
        'Referral details are not available for this account.',
      _ when status == 404 => 'This referral item could not be found.',
      _ => 'We could not load referral details. Please try again.',
    };
  }
}

DateTime? _oldestStaleRead(List<_JsonRead> reads) {
  final staleTimes = reads
      .where((read) => read.isStale && read.cachedAt != null)
      .map((read) => read.cachedAt!)
      .toList(growable: false);
  if (staleTimes.isEmpty) return null;
  return staleTimes.reduce(
    (oldest, time) => time.isBefore(oldest) ? time : oldest,
  );
}

Map<String, dynamic> _decodeObject(String body, String path) {
  final decoded = jsonDecode(body);
  if (decoded is! Map) {
    throw FormatException('Expected an object from $path.');
  }
  return Map<String, dynamic>.from(decoded);
}

Map<String, dynamic> _payload(Map<String, dynamic> json) {
  final data = json['data'];
  return data is Map ? Map<String, dynamic>.from(data) : json;
}

Map<String, dynamic>? _map(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : null;

Object? _first(Map<String, dynamic> json, List<String> keys) {
  for (final key in keys) {
    if (json.containsKey(key)) return json[key];
  }
  return null;
}

String? _string(Map<String, dynamic> json, List<String> keys) {
  final value = _first(json, keys);
  return value is String && value.trim().isNotEmpty ? value.trim() : null;
}

String _requiredString(Map<String, dynamic> json, List<String> keys) {
  final value = _string(json, keys);
  if (value == null) {
    throw const FormatException('Required identifier missing.');
  }
  return value;
}

int? _integer(Map<String, dynamic> json, List<String> keys) {
  final value = _first(json, keys);
  if (value is int) return value;
  if (value is String) return int.tryParse(value);
  return null;
}

int? _paise(Map<String, dynamic> json, List<String> keys) {
  final value = _first(json, keys);
  return value == null ? null : PaiseAmount.fromJson(value).value;
}

bool? _boolean(Map<String, dynamic> json, List<String> keys) {
  final value = _first(json, keys);
  return value is bool ? value : null;
}

DateTime? _date(Map<String, dynamic> json, List<String> keys) {
  final value = _first(json, keys);
  return value is String ? DateTime.tryParse(value) : null;
}

String _referralStateLabel(String state) => switch (state) {
  'joined' || 'signed_up' || 'pending' => 'Joined',
  'in_progress' || 'bamboo' || 'progress' => 'Bamboo progress',
  'milestone_complete' || 'qualified' || 'complete' => 'Milestone complete',
  'spin_ready' || 'ready' => 'Spin ready',
  'credited' || 'claimed' => 'Credits added',
  'expired' => 'Expired',
  'access_only' => 'Access only',
  'held' || 'under_review' || 'review' => 'Under review',
  _ => 'Status updating',
};
