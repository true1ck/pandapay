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
    final sent = DateTime.tryParse(state.get('stats:last-sent') ?? '');
    if (sent != null && now.difference(sent) < const Duration(hours: 24)) {
      return;
    }
    // Yesterday is closed, so hits arriving after today's daily upload are
    // included tomorrow rather than permanently omitted at midnight.
    final payload =
        stats.payload(
          now.toUtc().subtract(const Duration(days: 1)),
          appVersion: appVersion,
          bundleVersion: bundleVersion,
        ) ??
        stats.payload(
          now,
          appVersion: appVersion,
          bundleVersion: bundleVersion,
        );
    if (payload == null || !accountIsCurrent()) return;
    final day = payload['day'] as String;
    try {
      final authHeaders = await headers();
      if (!accountIsCurrent()) return;
      final response = await client
          .post(
            baseUri.resolve('/sms/v2/rule-stats:batch'),
            headers: {...authHeaders, 'Content-Type': 'application/json'},
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
