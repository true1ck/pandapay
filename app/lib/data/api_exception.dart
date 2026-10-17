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

  /// The repositories include the HTTP status in their debug message. Keep
  /// this parsed here so cache-aware readers can distinguish a temporary
  /// network/server failure from an authentication failure. In particular,
  /// cached data must never be shown after the API has rejected the session.
  int? get statusCode {
    final match = RegExp(r':\s(\d{3})\b').firstMatch(debugMessage);
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  /// Machine-readable API error code, when the response ended in JSON.
  /// Screens can use this for a specific recovery path without matching on
  /// human-facing copy.
  String? get errorCode {
    final jsonStart = debugMessage.indexOf('{');
    if (jsonStart == -1) return null;
    try {
      final decoded = jsonDecode(debugMessage.substring(jsonStart));
      if (decoded is Map && decoded['error'] is String) {
        return decoded['error'] as String;
      }
    } catch (_) {
      // Not parseable JSON — there is no machine-readable code.
    }
    return null;
  }

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

/// A protected read could not be completed because the locally restored
/// session was rejected and there was no valid account-scoped snapshot to
/// render. This is deliberately distinct from an honest empty result: the
/// UI must never tell a signed-in user that their budgets or reports do not
/// exist merely because refresh/auth is temporarily unavailable.
class AuthenticationUnavailableException implements Exception {
  final String message;

  const AuthenticationUnavailableException([
    this.message =
        'Your session could not be refreshed. Your saved data is safe; try again when connected.',
  ]);

  @override
  String toString() => message;
}

/// Converts any caught error into UI-safe copy. Use this at every screen's
/// catch site instead of `e.toString()`.
///
/// [StateError] is trusted as-is: unlike a raw HTTP/JSON failure, its
/// message is always hand-written by this codebase for exactly this
/// purpose (see nearby_merchants_screen.dart's location-permission checks).
String userFacingErrorMessage(Object error) {
  if (error is ApiException) return error.userMessage;
  if (error is AuthenticationUnavailableException) return error.message;
  if (error is CardAlreadyAddedException) return error.message;
  if (error is StateError) return error.message;
  return 'Something went wrong. Please check your connection and try again.';
}

/// True when an authenticated read was rejected by the API rather than
/// failing because of malformed data. Read-only screens use this to keep
/// their last local snapshot (or an honest empty state) visible while the
/// shared client attempts token recovery.
bool isAuthenticationFailure(Object error) {
  if (error is! ApiException) return false;
  return error.statusCode == 401 ||
      error.errorCode == 'Missing or invalid access token';
}

/// Used by the local wallet, which has no HTTP response to carry the same
/// duplicate status as the signed-in API.
class CardAlreadyAddedException implements Exception {
  final String message;

  const CardAlreadyAddedException([
    this.message = 'This card is already in your wallet.',
  ]);

  @override
  String toString() => message;
}
