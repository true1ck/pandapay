import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_exception.dart';
import 'referral_repository.dart' show AccountScopedJsonCache, PaiseAmount;

class SubscriptionCreditBalance {
  const SubscriptionCreditBalance({
    required this.available,
    required this.reserved,
    required this.currency,
    this.used,
    this.lastConfirmedAt,
  });

  final PaiseAmount available;
  final PaiseAmount reserved;
  final PaiseAmount? used;
  final String currency;
  final DateTime? lastConfirmedAt;

  factory SubscriptionCreditBalance.fromJson(Map<String, dynamic> json) {
    final root = _creditPayload(json);
    final balances = _map(root['balances']) ?? root;
    final currency = _string(root, const ['currency']) ?? 'INR';
    if (currency != 'INR') {
      throw const FormatException(
        'Subscription credits must be denominated in INR.',
      );
    }
    return SubscriptionCreditBalance(
      available: PaiseAmount.fromJson(
        _first(balances, const ['availablePaise', 'available_paise']),
      ),
      reserved: PaiseAmount.fromJson(
        _first(balances, const ['reservedPaise', 'reserved_paise']),
      ),
      used: _optionalPaise(balances, const ['usedPaise', 'used_paise']),
      currency: currency,
      lastConfirmedAt: _date(root, const ['asOf', 'as_of', 'lastConfirmedAt']),
    );
  }
}

class SubscriptionCreditLedgerEntry {
  const SubscriptionCreditLedgerEntry({
    required this.id,
    required this.kind,
    required this.state,
    required this.amount,
    this.createdAt,
    this.expiresAt,
  });

  final String id;
  final String kind;
  final String state;
  final PaiseAmount amount;
  final DateTime? createdAt;
  final DateTime? expiresAt;

  String get displayKind => switch (kind) {
    'award' || 'reward_award' => 'Referral reward',
    'reserve' || 'redemption_reserved' => 'Reserved for subscription benefit',
    'redeem' ||
    'redemption' ||
    'redemption_confirmed' => 'Subscription benefit',
    'release' || 'reservation_released' => 'Reservation released',
    'refund' || 'reversal' => 'Adjustment',
    _ => 'Credit activity',
  };

  factory SubscriptionCreditLedgerEntry.fromJson(Map<String, dynamic> json) {
    final amount = _first(json, const ['amountPaise', 'amount_paise']);
    final delta = _first(json, const [
      'availableDeltaPaise',
      'available_delta_paise',
      'deltaPaise',
      'delta_paise',
    ]);
    return SubscriptionCreditLedgerEntry(
      id: _requiredString(json, const ['id', 'entryId', 'entry_id']),
      kind:
          _string(json, const ['kind', 'eventType', 'event_type', 'type']) ??
          'activity',
      state: _string(json, const ['state', 'status']) ?? 'posted',
      amount: PaiseAmount.fromJson(amount ?? delta),
      createdAt: _date(json, const ['createdAt', 'created_at']),
      expiresAt: _date(json, const ['expiresAt', 'expires_at']),
    );
  }
}

class SubscriptionCreditLedgerPage {
  const SubscriptionCreditLedgerPage({required this.entries, this.nextCursor});

  final List<SubscriptionCreditLedgerEntry> entries;
  final String? nextCursor;

  factory SubscriptionCreditLedgerPage.fromJson(Map<String, dynamic> json) {
    final root = _creditPayload(json);
    final raw = root['ledger'] ?? root['entries'];
    final entries = raw is List
        ? raw
              .whereType<Map>()
              .map(
                (entry) => SubscriptionCreditLedgerEntry.fromJson(
                  Map<String, dynamic>.from(entry),
                ),
              )
              .toList(growable: false)
        : const <SubscriptionCreditLedgerEntry>[];
    return SubscriptionCreditLedgerPage(
      entries: entries,
      nextCursor: _string(root, const ['nextCursor', 'next_cursor']),
    );
  }
}

class SubscriptionCreditData {
  const SubscriptionCreditData({
    required this.balance,
    required this.ledger,
    this.isStale = false,
    this.cachedAt,
  });

  final SubscriptionCreditBalance balance;
  final SubscriptionCreditLedgerPage ledger;
  final bool isStale;
  final DateTime? cachedAt;
}

abstract interface class SubscriptionCreditsRepository {
  Future<SubscriptionCreditData> load();

  Future<SubscriptionCreditLedgerPage> loadMore(String cursor);
}

class HttpSubscriptionCreditsRepository
    implements SubscriptionCreditsRepository {
  HttpSubscriptionCreditsRepository({
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
  Future<SubscriptionCreditData> load() async {
    final responses = await Future.wait([
      _get('/subscription-credits', cacheKey: 'balance'),
      _get('/subscription-credits/ledger', cacheKey: 'ledger'),
    ]);
    final staleTimes = responses
        .where((response) => response.isStale && response.cachedAt != null)
        .map((response) => response.cachedAt!)
        .toList(growable: false);
    return SubscriptionCreditData(
      balance: SubscriptionCreditBalance.fromJson(responses[0].body),
      ledger: SubscriptionCreditLedgerPage.fromJson(responses[1].body),
      isStale: responses.any((response) => response.isStale),
      cachedAt: staleTimes.isEmpty
          ? null
          : staleTimes.reduce(
              (oldest, time) => time.isBefore(oldest) ? time : oldest,
            ),
    );
  }

  @override
  Future<SubscriptionCreditLedgerPage> loadMore(String cursor) async {
    final response = await _get(
      '/subscription-credits/ledger',
      query: {'cursor': cursor},
    );
    return SubscriptionCreditLedgerPage.fromJson(response.body);
  }

  Future<_CreditRead> _get(
    String path, {
    Map<String, String>? query,
    String? cacheKey,
  }) async {
    final namespace = cacheKey == null ? null : _currentNamespace;
    final base = apiBaseUrl.endsWith('/')
        ? apiBaseUrl.substring(0, apiBaseUrl.length - 1)
        : apiBaseUrl;
    final uri = Uri.parse('$base$path').replace(queryParameters: query);
    try {
      final response = await _client.get(uri, headers: _headers);
      if (response.statusCode != 200) {
        String? message;
        try {
          final decoded = jsonDecode(response.body);
          if (decoded is Map && decoded['message'] is String) {
            message = decoded['message'] as String;
          }
        } catch (_) {
          // Use the safe fallback below for non-JSON errors.
        }
        throw ApiException(
          'GET $path failed: ${response.statusCode} ${response.body}',
          userMessage: message != null && message.trim().isNotEmpty
              ? message
              : response.statusCode == 401 || response.statusCode == 403
              ? 'Subscription credit details are not available for this account.'
              : 'We could not load subscription credits. Please try again.',
        );
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map) {
        throw FormatException('Expected an object from $path.');
      }
      final body = Map<String, dynamic>.from(decoded);
      if (cacheKey != null && cache != null) {
        _ensureSameNamespace(namespace!);
        await cache!.write(namespace, cacheKey, body);
      }
      return _CreditRead(body);
    } catch (error) {
      if (cacheKey == null ||
          cache == null ||
          !isTransientNetworkFailure(error)) {
        rethrow;
      }
      _ensureSameNamespace(namespace!);
      final snapshot = await cache!.read(namespace, cacheKey);
      if (snapshot == null) rethrow;
      return _CreditRead(
        snapshot.body,
        isStale: true,
        cachedAt: snapshot.fetchedAt,
      );
    }
  }

  String get _currentNamespace => cacheNamespace?.call() ?? 'unscoped';

  void _ensureSameNamespace(String namespace) {
    if (_currentNamespace != namespace) {
      throw const AuthenticationUnavailableException(
        'Your account changed. Refresh to load its subscription credits.',
      );
    }
  }
}

class _CreditRead {
  const _CreditRead(this.body, {this.isStale = false, this.cachedAt});

  final Map<String, dynamic> body;
  final bool isStale;
  final DateTime? cachedAt;
}

Map<String, dynamic> _creditPayload(Map<String, dynamic> json) {
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
  if (value == null) throw const FormatException('Required ledger id missing.');
  return value;
}

PaiseAmount? _optionalPaise(Map<String, dynamic> json, List<String> keys) {
  final value = _first(json, keys);
  return value == null ? null : PaiseAmount.fromJson(value);
}

DateTime? _date(Map<String, dynamic> json, List<String> keys) {
  final value = _first(json, keys);
  return value is String ? DateTime.tryParse(value) : null;
}
