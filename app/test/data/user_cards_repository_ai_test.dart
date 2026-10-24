import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/user_cards_repository.dart';

void main() {
  final sourceKey = List.filled(64, 'a').join();

  test(
    'submitAiJob sends the authenticated source once and returns its job id',
    () async {
      late http.Request sent;
      final repository = UserCardsRepository(
        apiBaseUrl: 'https://api.test',
        accessToken: 'session-token',
        client: MockClient((request) async {
          sent = request;
          return http.Response(jsonEncode({'jobId': 'job-1'}), 200);
        }),
      );

      final jobId = await repository.submitAiJob(
        sourceKey: sourceKey,
        sender: 'HDFCBK',
        body: 'Available balance Rs 1200',
        occurredAt: DateTime.utc(2026, 10, 24),
      );

      expect(jobId, 'job-1');
      expect(sent.method, 'POST');
      expect(sent.url, Uri.parse('https://api.test/ai/jobs'));
      expect(sent.headers['authorization'], 'Bearer session-token');
      expect(jsonDecode(sent.body), {
        'sourceKey': sourceKey,
        'sender': 'HDFCBK',
        'body': 'Available balance Rs 1200',
        'occurredAt': '2026-10-24T00:00:00.000Z',
      });
    },
  );

  test('submitAiJob treats refusals and network errors as non-fatal', () async {
    for (final status in [400, 401, 429, 503]) {
      final repository = UserCardsRepository(
        apiBaseUrl: 'https://api.test',
        accessToken: 'session-token',
        client: MockClient((_) async => http.Response('refused', status)),
      );

      expect(
        await repository.submitAiJob(
          sourceKey: sourceKey,
          sender: 'HDFCBK',
          body: 'Rs 120 debited',
        ),
        isNull,
        reason: 'AI refusal $status must not block local review',
      );
    }

    final offline = UserCardsRepository(
      apiBaseUrl: 'https://api.test',
      accessToken: 'session-token',
      client: MockClient((_) async => throw http.ClientException('offline')),
    );
    expect(
      await offline.submitAiJob(
        sourceKey: sourceKey,
        sender: 'HDFCBK',
        body: 'Rs 120 debited',
      ),
      isNull,
    );
  });

  test(
    'fetchAiJobStatus is source-scoped and handles missing jobs/offline API',
    () async {
      late http.Request sent;
      final repository = UserCardsRepository(
        apiBaseUrl: 'https://api.test',
        accessToken: 'session-token',
        client: MockClient((request) async {
          sent = request;
          return http.Response(
            jsonEncode({'status': 'queued', 'suggestions': []}),
            200,
          );
        }),
      );

      expect(await repository.fetchAiJobStatus(sourceKey), {
        'status': 'queued',
        'suggestions': <dynamic>[],
      });
      expect(sent.method, 'GET');
      expect(sent.url, Uri.parse('https://api.test/ai/jobs/source/$sourceKey'));
      expect(sent.headers['authorization'], 'Bearer session-token');

      for (final status in [404, 503]) {
        final unavailable = UserCardsRepository(
          apiBaseUrl: 'https://api.test',
          accessToken: 'session-token',
          client: MockClient((_) async => http.Response('unavailable', status)),
        );
        expect(await unavailable.fetchAiJobStatus(sourceKey), isNull);
      }
    },
  );
}
