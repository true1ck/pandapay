import 'dart:convert';

import 'package:http/http.dart' as http;

/// How this phone's unread message layouts stand with the AI drafts worker, as
/// the server sees it (counts only; no message text).
class AiServerStatus {
  const AiServerStatus({
    required this.countedNow,
    required this.eligible,
    this.total = 0,
    this.held = 0,
    this.queued = 0,
    this.working = 0,
    this.ready = 0,
    this.covered = 0,
    this.failed = 0,
  });

  /// Whether layouts sent now would be queued for the AI. False means they are
  /// held and never reach it (the phone passed no App Check and is not a tester).
  final bool countedNow;

  /// Whether any layout this phone sent so far was queued.
  final bool eligible;
  final int total;
  final int held;
  final int queued;
  final int working;
  final int ready;
  final int covered;
  final int failed;

  /// Layouts the AI has not finished: waiting or being drafted.
  int get inProgress => queued + working;

  factory AiServerStatus.fromJson(Map<String, Object?> json) {
    int n(String key) {
      final v = json[key];
      return v is int && v > 0 ? v : 0;
    }

    return AiServerStatus(
      countedNow: json['countedNow'] == true,
      eligible: json['eligible'] == true,
      total: n('total'),
      held: n('held'),
      queued: n('queued'),
      working: n('working'),
      ready: n('ready'),
      covered: n('covered'),
      failed: n('failed'),
    );
  }
}

/// Asks the server for [AiServerStatus]. Returns null when the server cannot be
/// reached or answers anything but a good summary: the bar then falls back to
/// what the phone itself knows, and never shows an error.
Future<AiServerStatus?> fetchAiServerStatus({
  required http.Client client,
  required Uri baseUri,
  required Future<Map<String, String>> Function() headers,
}) async {
  try {
    final response = await client
        .get(baseUri.resolve('/sms/v2/ai-status'), headers: await headers())
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) return null;
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) return null;
    return AiServerStatus.fromJson(decoded.cast<String, Object?>());
  } catch (_) {
    return null;
  }
}
