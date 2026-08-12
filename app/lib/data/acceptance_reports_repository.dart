import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_exception.dart';

/// Plan Phase 2.1 — "did this card actually work here?".
///
/// The client half of `POST /acceptance-reports`. Everything that makes this
/// safe to collect lives server-side in `pandapay.submit_acceptance_report()`
/// (migration 0029): the opt-in check, the monthly-rotating pseudonym, the
/// daily quota, the coordinate grid-snap. This class deliberately holds none
/// of it — a client-side privacy control is one an attacker or a stale build
/// can simply skip.
///
/// The one thing it does owe the caller is honest error typing, because two
/// of the server's refusals are not errors in any useful sense and must not
/// be shown as "something went wrong": the user hasn't opted in, or they've
/// hit the day's contribution limit.
enum AcceptanceResult { accepted, declined, notSupported, unknown }

extension AcceptanceResultWire on AcceptanceResult {
  String get wire => switch (this) {
    AcceptanceResult.accepted => 'accepted',
    AcceptanceResult.declined => 'declined',
    AcceptanceResult.notSupported => 'not_supported',
    AcceptanceResult.unknown => 'unknown',
  };
}

/// The user has not turned on contribution sharing. The caller should offer
/// the opt-in rather than reporting a failure.
class NotOptedInException extends ApiException {
  NotOptedInException(super.debugMessage, {super.userMessage});
}

/// The daily per-contributor quota (§6.3 abuse resistance) is spent.
class ContributionQuotaException extends ApiException {
  ContributionQuotaException(super.debugMessage, {super.userMessage});
}

class AcceptanceReportsRepository {
  final String apiBaseUrl;
  final String accessToken;
  final http.Client _client;

  AcceptanceReportsRepository({
    required this.apiBaseUrl,
    required this.accessToken,
    http.Client? client,
  }) : _client = client ?? http.Client();

  /// [gridLat]/[gridLng] must already be rounded to 4 decimal places by the
  /// caller. The server re-snaps regardless (0010's `snap_grid` calls itself
  /// "a second line of defence"), but sending a raw GPS fix over the wire
  /// when a ~11m grid cell is all the dataset may hold would be careless
  /// about the part of this that actually matters.
  Future<String?> submit({
    required String vpa,
    String? displayName,
    required String network,
    required String rail,
    required AcceptanceResult result,
    double? gridLat,
    double? gridLng,
    String? appVersion,
  }) async {
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/acceptance-reports'),
      headers: {'Authorization': 'Bearer $accessToken', 'Content-Type': 'application/json'},
      body: jsonEncode({
        'vpa': vpa,
        'displayName': ?displayName,
        'network': network,
        'rail': rail,
        'result': result.wire,
        'gridLat': ?gridLat,
        'gridLng': ?gridLng,
        'appVersion': ?appVersion,
      }),
    );

    if (response.statusCode == 403) {
      throw NotOptedInException(
        'POST /acceptance-reports refused: not opted in',
        userMessage:
            'Turn on contribution sharing in Privacy & permissions to help other cardholders.',
      );
    }
    if (response.statusCode == 429) {
      throw ContributionQuotaException(
        'POST /acceptance-reports refused: quota exceeded',
        userMessage: 'You\'ve hit today\'s contribution limit. Thanks — try again tomorrow.',
      );
    }
    if (response.statusCode != 201) {
      throw ApiException(
        'POST /acceptance-reports failed: ${response.statusCode} ${response.body}',
      );
    }
    return (jsonDecode(response.body) as Map<String, dynamic>)['merchantId'] as String?;
  }
}
