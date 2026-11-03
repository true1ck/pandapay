import 'dart:async';
import 'dart:convert';

import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

/// App Check headers for the phone sync client. The installation ID is stored
/// by the caller and is an admission identifier rather than a hardware claim.
final class DeviceAttestation {
  DeviceAttestation({
    required this.deviceId,
    DateTime Function()? now,
    Future<String?> Function(bool forceRefresh)? fetchToken,
  }) : _now = now ?? DateTime.now,
       _fetchToken = fetchToken {
    if (!RegExp(r'^[A-Za-z0-9_-]{8,128}$').hasMatch(deviceId)) {
      throw ArgumentError.value(deviceId, 'deviceId');
    }
  }

  final String deviceId;
  final DateTime Function() _now;
  final Future<String?> Function(bool forceRefresh)? _fetchToken;
  String? _token;
  DateTime? _expiresAt;
  DateTime? _nextAttemptAt;
  Future<String?>? _pending;
  Future<void>? _activation;

  Future<Map<String, String>> headers() async {
    final token = await _getToken();
    return {
      'X-Sms-Device-Id': deviceId,
      if (token != null) 'X-Device-Attestation': token,
    };
  }

  Future<String?> _getToken() async {
    final now = _now();
    if (_expiresAt != null &&
        now.isBefore(_expiresAt!.subtract(const Duration(minutes: 5)))) {
      return _token;
    }
    if (_nextAttemptAt != null && now.isBefore(_nextAttemptAt!)) {
      return _expiresAt?.isAfter(now) == true ? _token : null;
    }
    return _pending ??= _refresh().whenComplete(() => _pending = null);
  }

  Future<String?> _refresh() async {
    _nextAttemptAt = _now().add(const Duration(seconds: 30));
    try {
      final token = await (_fetchToken ?? _fetchFirebaseToken)(_token != null);
      final expiry = _expiry(token);
      if (token != null && expiry != null && expiry.isAfter(_now())) {
        _token = token;
        _expiresAt = expiry;
      }
    } catch (_) {
      // Monitor mode continues at lower limits when attestation is unavailable.
      // Enforcement is decided by the server and the sync client keeps its queue.
    }
    return _expiresAt?.isAfter(_now()) == true ? _token : null;
  }

  Future<String?> _fetchFirebaseToken(bool forceRefresh) async {
    if (kIsWeb ||
        !{
          TargetPlatform.android,
          TargetPlatform.iOS,
        }.contains(defaultTargetPlatform)) {
      return null;
    }
    try {
      await (_activation ??= _activate());
    } catch (_) {
      _activation = null;
      rethrow;
    }
    return FirebaseAppCheck.instance.getToken(forceRefresh);
  }

  Future<void> _activate() async {
    await Firebase.initializeApp();
    await FirebaseAppCheck.instance.activate(
      providerAndroid: kDebugMode
          ? const AndroidDebugProvider()
          : const AndroidPlayIntegrityProvider(),
      providerApple: kDebugMode
          ? const AppleDebugProvider()
          : const AppleAppAttestProvider(),
    );
  }

  static DateTime? _expiry(String? token) {
    if (token == null || token.length > 8192) return null;
    try {
      final parts = token.split('.');
      if (parts.length != 3) return null;
      final payload = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      );
      final expiry = payload is Map ? payload['exp'] : null;
      return expiry is int
          ? DateTime.fromMillisecondsSinceEpoch(expiry * 1000, isUtc: true)
          : null;
    } on FormatException {
      return null;
    } on RangeError {
      return null;
    }
  }
}
