import 'dart:convert';

import 'package:http/http.dart' as http;

/// A row from GET /user-cards — the signed-in user's own wallet, RLS-owned
/// (see api/'s route comment). `cardProductId` is the FK back into the
/// catalogue this app already fetches via CatalogueRepository — kept as two
/// separate fetches rather than one denormalized endpoint, since the
/// catalogue is public/cacheable and user_cards is private/small.
class UserCard {
  final String id;
  final String cardProductId;
  final String? nickname;
  final String cardName;
  final bool isDefault;

  const UserCard({
    required this.id,
    required this.cardProductId,
    this.nickname,
    required this.cardName,
    required this.isDefault,
  });

  factory UserCard.fromJson(Map<String, dynamic> json) => UserCard(
        id: json['id'] as String,
        cardProductId: json['card_product_id'] as String,
        nickname: json['nickname'] as String?,
        cardName: json['card_name'] as String,
        isDefault: json['is_default'] as bool? ?? false,
      );
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
}

class UserCardsException implements Exception {
  final String message;
  UserCardsException(this.message);
  @override
  String toString() => message;
}
