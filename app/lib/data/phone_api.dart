import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_exception.dart';

/// Whether this account has a phone number on it, and whether the server's phone
/// lock needs one. The number is typed in, not verified: no code is sent to it.
/// Talks to auth/ (`GET` and `POST /users/me/phone`).
class PhoneStatus {
  /// A number the person typed in is saved on this account.
  final bool claimed;

  /// A verified phone from an older sign-in method is on this account.
  final bool verified;

  /// The server runs with the phone lock on.
  final bool required;

  /// True when the lock is on and the account has no phone yet. The only thing
  /// the person can do is add one.
  final bool needsPhone;

  /// A masked form such as `+91 •••• 3210`, or null when there is no phone.
  final String? phoneHint;

  const PhoneStatus({
    required this.claimed,
    required this.verified,
    required this.required,
    required this.needsPhone,
    this.phoneHint,
  });

  bool get hasPhone => claimed || verified;

  factory PhoneStatus.fromJson(Map<String, dynamic> json) => PhoneStatus(
    claimed: json['claimed'] == true,
    verified: json['verified'] == true,
    required: json['required'] == true,
    needsPhone: json['needs_phone'] == true,
    phoneHint: json['phone_hint'] as String?,
  );
}

class PhoneApi {
  static const _timeout = Duration(seconds: 15);

  final String authBaseUrl;
  final String accessToken;
  final http.Client _client;

  PhoneApi({
    required this.authBaseUrl,
    required this.accessToken,
    http.Client? client,
  }) : _client = client ?? http.Client();

  Map<String, String> get _headers => {
    'Authorization': 'Bearer $accessToken',
    'Content-Type': 'application/json',
  };

  Uri get _uri => Uri.parse('$authBaseUrl/users/me/phone');

  Future<PhoneStatus> status() async {
    final response = await _client.get(_uri, headers: _headers).timeout(_timeout);
    if (response.statusCode != 200) throw _failure('GET', response);
    return PhoneStatus.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  /// Saves [phone] on this account. [phone] is what the person typed, such as
  /// `98765 43210`; the server turns it into one canonical form. Returns the
  /// masked number. A refusal throws an [ApiException] whose `errorCode` is one
  /// of `phone_invalid`, `phone_country_unsupported`, `phone_unavailable`,
  /// `phone_already_set`, `account_unavailable` or `too_many_attempts`, and whose
  /// `userMessage` is the server's plain wording.
  Future<String?> claim(String phone) async {
    final response = await _client
        .post(_uri, headers: _headers, body: jsonEncode({'phone_number': phone}))
        .timeout(_timeout);
    if (response.statusCode != 200) throw _failure('POST', response);
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return body['phone_hint'] as String?;
  }

  ApiException _failure(String method, http.Response response) {
    String? message;
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map && decoded['message'] is String) {
        message = (decoded['message'] as String).trim();
      }
    } catch (_) {
      // Not JSON (a proxy error page, for example): fall back to the generic wording.
    }
    return ApiException(
      '$method /users/me/phone failed: ${response.statusCode} ${response.body}',
      userMessage: message == null || message.isEmpty ? null : message,
    );
  }
}
