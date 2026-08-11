import 'dart:convert';

/// Shared HTTP-failure exception for every repository/API client in lib/data/.
/// Carries a technical [debugMessage] (method, path, status, raw body — for
/// logs) separate from [userMessage] (safe to render directly in the UI).
/// Screens should show `userMessage`, never `toString()`/`debugMessage`.
class ApiException implements Exception {
  final String userMessage;
  final String debugMessage;

  ApiException(this.debugMessage, {String? userMessage})
    : userMessage = userMessage ?? friendlyMessageFrom(debugMessage);

  @override
  String toString() => debugMessage;

  /// Pulls a `message`/`error` field out of a trailing JSON body in a raw
  /// "METHOD /path failed: STATUS {...}" string, if there is a short,
  /// human-readable one to reuse. Falls back to a generic message otherwise
  /// — never surfaces status codes or raw JSON to the user.
  static String friendlyMessageFrom(String debugMessage) {
    final jsonStart = debugMessage.indexOf('{');
    if (jsonStart != -1) {
      try {
        final decoded = jsonDecode(debugMessage.substring(jsonStart));
        if (decoded is Map) {
          final msg = decoded['message'] ?? decoded['error'];
          if (msg is String && msg.trim().isNotEmpty && msg.length < 160) {
            return msg;
          }
        }
      } catch (_) {
        // Not parseable JSON — fall through to the generic message.
      }
    }
    return 'Something went wrong. Please try again.';
  }
}

/// Converts any caught error into UI-safe copy. Use this at every screen's
/// catch site instead of `e.toString()`.
///
/// [StateError] is trusted as-is: unlike a raw HTTP/JSON failure, its
/// message is always hand-written by this codebase for exactly this
/// purpose (see nearby_merchants_screen.dart's location-permission checks).
String userFacingErrorMessage(Object error) {
  if (error is ApiException) return error.userMessage;
  if (error is StateError) return error.message;
  return 'Something went wrong. Please check your connection and try again.';
}
