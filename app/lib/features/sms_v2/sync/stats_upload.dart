import 'dart:convert';

import 'package:http/http.dart' as http;

import '../storage/stats_store.dart';
import '../storage/sync_state_store.dart';

class StatsUpload {
  const StatsUpload({
    required this.stats,
    required this.state,
    required this.client,
    required this.baseUri,
    required this.headers,
    required this.accountIsCurrent,
  });
  final StatsStore stats;
  final SyncStateStore state;
  final http.Client client;
  final Uri baseUri;
  final Future<Map<String, String>> Function() headers;
  final bool Function() accountIsCurrent;

  Future<void> send(
    DateTime now, {
    required String appVersion,
    required int bundleVersion,
  }) async {
    final payload = stats.payload(
      now,
      appVersion: appVersion,
      bundleVersion: bundleVersion,
    );
    if (payload == null || !accountIsCurrent()) return;
    final day = payload['day'] as String;
    final sent = DateTime.tryParse(state.get('stats:last-sent') ?? '');
    if (sent != null && now.difference(sent) < const Duration(hours: 24)) {
      return;
    }
    try {
      final response = await client
          .post(
            baseUri.resolve('/sms/v2/rule-stats:batch'),
            headers: {...await headers(), 'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 30));
      if (accountIsCurrent() && response.statusCode == 202) {
        state.put('stats:last-sent', now.toUtc().toIso8601String());
        state.put('stats:day', day);
      }
    } catch (_) {
      /* Counts remain durable for a future daily pass. */
    }
  }
}
