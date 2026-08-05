import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:pandapay_domain/pandapay_domain.dart';

double _num(dynamic v) => v == null ? 0 : (v is num ? v.toDouble() : double.parse(v as String));

/// Chunk 17: the CURRENTLY-ACTIVE period's cap/milestone consumption for
/// this owned card — a missing entry for a given cap/milestone rule id
/// means nothing's been logged against it yet this period (full headroom),
/// matching exactly what CardSnapshot.capRemaining/milestoneProgress
/// already default to when a key is absent.
class UserCard {
  final String id;
  final String cardProductId;
  final String? nickname;
  final String cardName;
  final bool isDefault;
  final Map<String, Money> capConsumed; // capRule.id -> consumed (in the cap's own measure unit)
  final Map<String, Money> milestoneQualifiedSpend; // milestoneRule.id -> qualified spend so far

  const UserCard({
    required this.id,
    required this.cardProductId,
    this.nickname,
    required this.cardName,
    required this.isDefault,
    this.capConsumed = const {},
    this.milestoneQualifiedSpend = const {},
  });

  factory UserCard.fromJson(Map<String, dynamic> json) {
    final capStates = (json['cap_states'] as List? ?? const [])
        .cast<Map<String, dynamic>>();
    final milestoneStates = (json['milestone_states'] as List? ?? const [])
        .cast<Map<String, dynamic>>();
    return UserCard(
      id: json['id'] as String,
      cardProductId: json['card_product_id'] as String,
      nickname: json['nickname'] as String?,
      cardName: json['card_name'] as String,
      isDefault: json['is_default'] as bool? ?? false,
      capConsumed: {
        for (final s in capStates)
          s['cap_rule_id'] as String: Money.fromRupees(_num(s['consumed'])),
      },
      milestoneQualifiedSpend: {
        for (final s in milestoneStates)
          s['milestone_rule_id'] as String: Money.fromRupees(_num(s['qualified_spend'])),
      },
    );
  }
}

class UserCardsRepository {
  final String apiBaseUrl;
  final String accessToken;
  final http.Client _client;

  UserCardsRepository({required this.apiBaseUrl, required this.accessToken, http.Client? client})
      : _client = client ?? http.Client();

  Map<String, String> get _headers => {
        'Authorization': 'Bearer $accessToken',
        'Content-Type': 'application/json',
      };

  Future<List<UserCard>> fetchUserCards() async {
    final response = await _client.get(Uri.parse('$apiBaseUrl/user-cards'), headers: _headers);
    if (response.statusCode != 200) {
      throw UserCardsException('GET /user-cards failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['userCards'] as List)
        .cast<Map<String, dynamic>>()
        .map(UserCard.fromJson)
        .toList();
  }

  Future<void> addCard(String cardProductId, {String? nickname}) async {
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/user-cards'),
      headers: _headers,
      body: jsonEncode({'cardProductId': cardProductId, 'nickname': ?nickname}),
    );
    if (response.statusCode != 201) {
      throw UserCardsException('POST /user-cards failed: ${response.statusCode} ${response.body}');
    }
  }

  Future<void> archiveCard(String userCardId) async {
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/user-cards/$userCardId/archive'),
      headers: _headers,
    );
    if (response.statusCode != 200) {
      throw UserCardsException('archive failed: ${response.statusCode} ${response.body}');
    }
  }

  /// UA-3+ (Chunk 17): manual transaction entry — the only source txn_source
  /// supports today (no SMS/email/statement import). Updates cap_states/
  /// milestone_states server-side in the same write, so a follow-up
  /// GET /user-cards (userCardsProvider.invalidate) immediately reflects
  /// real consumed headroom.
  Future<void> logTransaction({
    required String userCardId,
    required Money amount,
    String? categoryId,
  }) async {
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/transactions'),
      headers: _headers,
      body: jsonEncode({
        'userCardId': userCardId,
        'amountInr': amount.rupees,
        'categoryId': ?categoryId,
      }),
    );
    if (response.statusCode != 201) {
      throw UserCardsException('POST /transactions failed: ${response.statusCode} ${response.body}');
    }
  }

  /// UA-3+ (Chunk 18): the Activity tab's data source.
  Future<List<TransactionEntry>> fetchTransactions() async {
    final response = await _client.get(Uri.parse('$apiBaseUrl/transactions'), headers: _headers);
    if (response.statusCode != 200) {
      throw UserCardsException('GET /transactions failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['transactions'] as List)
        .cast<Map<String, dynamic>>()
        .map(TransactionEntry.fromJson)
        .toList();
  }
}

class TransactionEntry {
  final String id;
  final Money amount;
  final DateTime occurredAt;
  final String? merchantName;
  final String? categoryName;
  final String? cardDisplayName; // nickname if set, else the card's own name

  const TransactionEntry({
    required this.id,
    required this.amount,
    required this.occurredAt,
    this.merchantName,
    this.categoryName,
    this.cardDisplayName,
  });

  factory TransactionEntry.fromJson(Map<String, dynamic> json) {
    final nickname = json['card_nickname'] as String?;
    final cardName = json['card_name'] as String?;
    return TransactionEntry(
      id: json['id'] as String,
      amount: Money.fromRupees(_num(json['amount_inr'])),
      occurredAt: DateTime.parse(json['occurred_at'] as String),
      merchantName: json['merchant_name'] as String?,
      categoryName: json['category_name'] as String?,
      cardDisplayName: (nickname?.isNotEmpty == true) ? nickname : cardName,
    );
  }
}

class UserCardsException implements Exception {
  final String message;
  UserCardsException(this.message);
  @override
  String toString() => message;
}
