import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/api_exception.dart';
import 'package:pandapay/data/user_cards_repository.dart';

void main() {
  final sourceKey = List.filled(64, 'a').join();

  group('submitAiJob', () {
    test(
      'sends the authenticated source once and returns its job id on 200',
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

    test('returns null on explicit server refusals (400, 401, 429, 503)', () async {
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
          reason: 'Server refusal $status should return null to signal refusal',
        );
      }
    });

    test('rethrows network and transport exceptions rather than swallowing as null', () async {
      final offline = UserCardsRepository(
        apiBaseUrl: 'https://api.test',
        accessToken: 'session-token',
        client: MockClient((_) async => throw http.ClientException('offline')),
      );
      expect(
        () => offline.submitAiJob(
          sourceKey: sourceKey,
          sender: 'HDFCBK',
          body: 'Rs 120 debited',
        ),
        throwsA(isA<http.ClientException>()),
      );

      final socketFail = UserCardsRepository(
        apiBaseUrl: 'https://api.test',
        accessToken: 'session-token',
        client: MockClient((_) async => throw const SocketException('Connection reset')),
      );
      expect(
        () => socketFail.submitAiJob(
          sourceKey: sourceKey,
          sender: 'HDFCBK',
          body: 'Rs 120 debited',
        ),
        throwsA(isA<SocketException>()),
      );

      final timedOut = UserCardsRepository(
        apiBaseUrl: 'https://api.test',
        accessToken: 'session-token',
        client: MockClient((_) async => throw TimeoutException('Request timed out')),
      );
      expect(
        () => timedOut.submitAiJob(
          sourceKey: sourceKey,
          sender: 'HDFCBK',
          body: 'Rs 120 debited',
        ),
        throwsA(isA<TimeoutException>()),
      );
    });
  });

  group('fetchAiJobStatus', () {
    test(
      'is source-scoped and returns job status on 200',
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
      },
    );

    test('returns null ONLY on HTTP 404 (not found / not yet queued)', () async {
      final notFound = UserCardsRepository(
        apiBaseUrl: 'https://api.test',
        accessToken: 'session-token',
        client: MockClient((_) async => http.Response('not found', 404)),
      );
      expect(await notFound.fetchAiJobStatus(sourceKey), isNull);
    });

    test('throws ApiException on non-200 non-404 responses (e.g. 500, 503)', () async {
      for (final status in [500, 503]) {
        final serverError = UserCardsRepository(
          apiBaseUrl: 'https://api.test',
          accessToken: 'session-token',
          client: MockClient((_) async => http.Response('server error', status)),
        );
        expect(
          () => serverError.fetchAiJobStatus(sourceKey),
          throwsA(isA<ApiException>()),
        );
      }
    });

    test('rethrows network and transport exceptions rather than returning null', () async {
      final offline = UserCardsRepository(
        apiBaseUrl: 'https://api.test',
        accessToken: 'session-token',
        client: MockClient((_) async => throw http.ClientException('connection refused')),
      );
      expect(
        () => offline.fetchAiJobStatus(sourceKey),
        throwsA(isA<http.ClientException>()),
      );

      final socketFail = UserCardsRepository(
        apiBaseUrl: 'https://api.test',
        accessToken: 'session-token',
        client: MockClient((_) async => throw const SocketException('No route to host')),
      );
      expect(
        () => socketFail.fetchAiJobStatus(sourceKey),
        throwsA(isA<SocketException>()),
      );

      final timedOut = UserCardsRepository(
        apiBaseUrl: 'https://api.test',
        accessToken: 'session-token',
        client: MockClient((_) async => throw TimeoutException('Connection timed out')),
      );
      expect(
        () => timedOut.fetchAiJobStatus(sourceKey),
        throwsA(isA<TimeoutException>()),
      );
    });
  });
}
