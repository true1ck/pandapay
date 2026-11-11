import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_exception.dart';

/// The name on the account lives in two places: `users.name` in auth/ and
/// `profiles.display_name` in api/. The app and Split read the second, so that
/// one is the source of truth and is saved first; auth/'s copy is then kept in
/// step on a best-effort basis (it is not shown anywhere in the app).
class AccountNameApi {
  static const _timeout = Duration(seconds: 15);

  final String apiBaseUrl;
  final String authBaseUrl;
  final String accessToken;
  final http.Client _client;

  AccountNameApi({
    required this.apiBaseUrl,
    required this.authBaseUrl,
    required this.accessToken,
    http.Client? client,
  }) : _client = client ?? http.Client();

  Map<String, String> get _headers => {
    'Authorization': 'Bearer $accessToken',
    'Content-Type': 'application/json',
  };

  /// What the server will store for [typed]: spaces collapsed and trimmed.
  static String clean(String typed) => typed.replaceAll(RegExp(r'\s+'), ' ').trim();

  /// A reason [typed] cannot be a name, or null when it is fine.
  static String? problemWith(String typed) {
    final name = clean(typed);
    if (name.isEmpty) return 'Enter your name.';
    if (name.length > 60) return 'Keep your name to 60 characters or fewer.';
    if (RegExp(r'[<>\u0000-\u001f\u007f]').hasMatch(name)) {
      return 'Your name can’t contain those characters.';
    }
    return null;
  }

  /// Saves [typed] as the name. Returns the saved profile row.
  Future<Map<String, dynamic>> save(String typed) async {
    final name = clean(typed);
    final response = await _client
        .patch(
          Uri.parse('$apiBaseUrl/profile'),
          headers: _headers,
          body: jsonEncode({'display_name': name}),
        )
        .timeout(_timeout);
    if (response.statusCode != 200) {
      throw ApiException(
        'PATCH /profile failed: ${response.statusCode} ${response.body}',
        userMessage: response.statusCode == 400
            ? 'That name can’t be saved. Check it and try again.'
            : null,
      );
    }
    final profile =
        (jsonDecode(response.body) as Map<String, dynamic>)['profile'] as Map<String, dynamic>;
    try {
      await _client
          .put(
            Uri.parse('$authBaseUrl/users/me/name'),
            headers: _headers,
            body: jsonEncode({'name': name}),
          )
          .timeout(_timeout);
    } catch (_) {
      // Best effort: the visible name is already saved.
    }
    return profile;
  }
}
