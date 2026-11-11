import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'api_exception.dart';

/// What the server knows about this account's avatar. The photo bytes are
/// fetched separately ([AvatarApi.fetchPhoto]) and only when [hasPhoto].
class AvatarInfo {
  /// One of the preset ids the app can draw, or null for the initial letter.
  final String? preset;
  final bool hasPhoto;

  /// Changes whenever the avatar does, so a cached photo can tell it is stale.
  final int version;

  const AvatarInfo({this.preset, this.hasPhoto = false, this.version = 0});

  factory AvatarInfo.fromJson(Map<String, dynamic> json) => AvatarInfo(
    preset: json['preset'] as String?,
    hasPhoto: json['has_photo'] == true,
    version: (json['version'] as num?)?.toInt() ?? 0,
  );
}

/// The signed-in person's own avatar. Talks to auth/ (`/users/me/avatar`).
/// Only the owner can read the photo; nobody else's avatar goes through here.
class AvatarApi {
  static const _timeout = Duration(seconds: 20);

  final String authBaseUrl;
  final String accessToken;
  final http.Client _client;

  AvatarApi({
    required this.authBaseUrl,
    required this.accessToken,
    http.Client? client,
  }) : _client = client ?? http.Client();

  Map<String, String> get _auth => {'Authorization': 'Bearer $accessToken'};

  Uri _uri([String suffix = '']) => Uri.parse('$authBaseUrl/users/me/avatar$suffix');

  Future<AvatarInfo> info() async {
    final response = await _client.get(_uri(), headers: _auth).timeout(_timeout);
    if (response.statusCode != 200) throw _failure('GET', response);
    return AvatarInfo.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  /// Picks a preset, or clears it with null (back to the initial letter).
  Future<AvatarInfo> setPreset(String? preset) async {
    final response = await _client
        .put(
          _uri('/preset'),
          headers: {..._auth, 'Content-Type': 'application/json'},
          body: jsonEncode({'preset': preset}),
        )
        .timeout(_timeout);
    if (response.statusCode != 200) throw _failure('PUT', response, '/preset');
    return AvatarInfo.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  /// Uploads an already-prepared JPEG (see `prepareAvatarPhoto`).
  Future<AvatarInfo> uploadPhoto(Uint8List jpeg) async {
    final response = await _client
        .put(
          _uri('/photo'),
          headers: {..._auth, 'Content-Type': 'image/jpeg'},
          body: jpeg,
        )
        .timeout(_timeout);
    if (response.statusCode != 200) throw _failure('PUT', response, '/photo');
    return AvatarInfo.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  /// The owner's photo, or null when there is none.
  Future<Uint8List?> fetchPhoto() async {
    final response = await _client.get(_uri('/photo'), headers: _auth).timeout(_timeout);
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) throw _failure('GET', response, '/photo');
    return response.bodyBytes;
  }

  Future<AvatarInfo> removePhoto() async {
    final response = await _client.delete(_uri('/photo'), headers: _auth).timeout(_timeout);
    if (response.statusCode != 200) throw _failure('DELETE', response, '/photo');
    return AvatarInfo.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  ApiException _failure(String method, http.Response response, [String suffix = '']) {
    String? message;
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map && decoded['message'] is String) {
        message = (decoded['message'] as String).trim();
      }
    } catch (_) {
      // Not JSON: use the generic wording.
    }
    return ApiException(
      '$method /users/me/avatar$suffix failed: ${response.statusCode} ${response.body}',
      userMessage: message == null || message.isEmpty ? null : message,
    );
  }
}
