import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_exception.dart';

/// Plan Phase 1.1. Thin IO boundary over `GET`/`PUT /user-settings`
/// (migration 0028) — the account-level preference blob that follows a user
/// to a new device. Same shape as [ConsentsApi]/[ProfileApi]: constructor
/// takes `{required apiBaseUrl, required accessToken}`, throws [ApiException]
/// on a non-200.
///
/// The blob is deliberately untyped `Map<String, Object?>` at this layer. The
/// key namespace belongs to `features/settings/settings_sync.dart`, which
/// owns the registry mapping each key to its SharedPreferences codec; giving
/// this class a typed model would mean two places to edit every time the app
/// adds a preference, and the server itself stores it opaquely (see 0028's
/// table comment).
class UserSettingsSnapshot {
  final Map<String, Object?> settings;
  final int revision;
  final DateTime? updatedAt;

  const UserSettingsSnapshot({
    required this.settings,
    required this.revision,
    this.updatedAt,
  });

  factory UserSettingsSnapshot.fromJson(Map<String, dynamic> json) {
    return UserSettingsSnapshot(
      settings: Map<String, Object?>.from(json['settings'] as Map? ?? const {}),
      revision: (json['revision'] as num?)?.toInt() ?? 0,
      updatedAt: json['updatedAt'] == null ? null : DateTime.parse(json['updatedAt'] as String),
    );
  }
}

class UserSettingsApi {
  final String apiBaseUrl;
  final String accessToken;
  final http.Client _client;

  UserSettingsApi({required this.apiBaseUrl, required this.accessToken, http.Client? client})
    : _client = client ?? http.Client();

  Map<String, String> get _headers => {
    'Authorization': 'Bearer $accessToken',
    'Content-Type': 'application/json',
  };

  /// A user who has never synced returns `{}` with revision 0, not a 404 —
  /// "nothing stored" and "everything at defaults" are the same state.
  Future<UserSettingsSnapshot> fetch() async {
    final response = await _client.get(Uri.parse('$apiBaseUrl/user-settings'), headers: _headers);
    if (response.statusCode != 200) {
      throw ApiException('GET /user-settings failed: ${response.statusCode} ${response.body}');
    }
    return UserSettingsSnapshot.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  /// Merges [patch] into the stored blob — only the keys present are touched,
  /// so two devices changing different preferences never clobber each other
  /// (the merge happens server-side; see the route's doc comment). A key
  /// mapped to `null` deletes it rather than storing a null.
  Future<UserSettingsSnapshot> patch(Map<String, Object?> patch) async {
    final response = await _client.put(
      Uri.parse('$apiBaseUrl/user-settings'),
      headers: _headers,
      body: jsonEncode({'settings': patch}),
    );
    if (response.statusCode != 200) {
      throw ApiException('PUT /user-settings failed: ${response.statusCode} ${response.body}');
    }
    return UserSettingsSnapshot.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }
}
