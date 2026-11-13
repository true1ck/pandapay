import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'api_exception.dart';
import 'avatar_api.dart';

/// Another Split member's avatar. Talks to api/ (`/avatars/:profileId`).
/// The server decides what this caller may see: the preset by default, the
/// photo only when the member opted in, and nothing for non-co-members.
class MemberAvatarApi {
  static const _timeout = Duration(seconds: 15);
  static const _maxConcurrent = 4;

  final String apiBaseUrl;
  final String accessToken;
  final http.Client _client;

  int _running = 0;
  final _waiting = <Completer<void>>[];

  MemberAvatarApi({
    required this.apiBaseUrl,
    required this.accessToken,
    http.Client? client,
  }) : _client = client ?? http.Client();

  Map<String, String> get _auth => {'Authorization': 'Bearer $accessToken'};

  Uri _uri(String profileId, [String suffix = '']) =>
      Uri.parse('$apiBaseUrl/avatars/${Uri.encodeComponent(profileId)}$suffix');

  /// A roster loads ~20 avatars at once; keep only a few requests in flight.
  Future<T> _limited<T>(Future<T> Function() run) async {
    if (_running >= _maxConcurrent) {
      final turn = Completer<void>();
      _waiting.add(turn);
      await turn.future;
    } else {
      _running++;
    }
    try {
      return await run();
    } finally {
      if (_waiting.isEmpty) {
        _running--;
      } else {
        _waiting.removeAt(0).complete(); // hand the slot over
      }
    }
  }

  /// The member's avatar info, or null when the server has none to show (404:
  /// not a co-member or unknown). Other failures throw [ApiException].
  Future<AvatarInfo?> info(String profileId) => _limited(() async {
    final response = await _client.get(_uri(profileId), headers: _auth).timeout(_timeout);
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      throw ApiException('GET /avatars failed: ${response.statusCode}');
    }
    return AvatarInfo.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  });

  /// The member's own PandaPay name, or null when there is none to show (not a
  /// co-member, no name set, or unknown). Other failures throw [ApiException].
  Future<String?> profileName(String profileId) => _limited(() async {
    final response = await _client.get(_uri(profileId, '/profile-name'), headers: _auth).timeout(_timeout);
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      throw ApiException('GET /avatars profile-name failed: ${response.statusCode}');
    }
    final name = (jsonDecode(response.body) as Map<String, dynamic>)['profile_name'];
    return name is String && name.trim().isNotEmpty ? name.trim() : null;
  });

  /// The member's photo bytes, or null when not available to this caller.
  Future<Uint8List?> photo(String profileId) => _limited(() async {
    final response = await _client.get(_uri(profileId, '/photo'), headers: _auth).timeout(_timeout);
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      throw ApiException('GET /avatars photo failed: ${response.statusCode}');
    }
    return response.bodyBytes;
  });
}
