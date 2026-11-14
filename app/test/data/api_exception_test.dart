import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pandapay/data/api_exception.dart';
import 'package:pandapay/data/connectivity/known_connectivity.dart';

void main() {
  test('parses the HTTP status for cache fallback decisions', () {
    expect(
      ApiException('GET /insights failed: 401 {"error":"expired"}').statusCode,
      401,
    );
    expect(
      ApiException(
        'GET /insights failed: 503 temporarily unavailable',
      ).statusCode,
      503,
    );
    expect(ApiException('socket closed').statusCode, isNull);
  });

  test('parses a safe server correlation id', () {
    final error = ApiException(
      'POST /statement-imports failed: 500 '
      '{"error":"internal_error","requestId":"req-123"}',
    );

    expect(error.errorCode, 'internal_error');
    expect(error.requestId, 'req-123');
  });

  group('friendlyMessageFrom', () {
    test('formats required_terms_missing to user-facing terms prompt', () {
      expect(
        ApiException.friendlyMessageFrom(
          'POST /onboarding/complete failed: 409 {"error":"required_terms_missing"}',
        ),
        'Please accept the terms to complete setup.',
      );
    });

    test('replaces snake_case errors with generic friendly message', () {
      expect(
        ApiException.friendlyMessageFrom(
          'POST /api failed: 400 {"error":"invalid_parameter_state"}',
        ),
        'Something went wrong. Please try again.',
      );
    });
  });

  group('isOfflineLike', () {
    tearDown(KnownConnectivity.reset);

    test('transport failures and 5xx are offline-like', () {
      expect(isOfflineLike(http.ClientException('connection closed')), isTrue);
      expect(isOfflineLike(TimeoutException('slow')), isTrue);
      expect(
        isOfflineLike(const SocketException('Failed host lookup')),
        isTrue,
      );
      expect(
        isOfflineLike(ApiException('GET /x failed: 503 unavailable')),
        isTrue,
      );
    });

    test('429 and 408 mean "later": queue them, never show an error', () {
      expect(isOfflineLike(ApiException('POST /x failed: 429 {}')), isTrue);
      expect(isOfflineLike(ApiException('POST /x failed: 408 {}')), isTrue);
      expect(isOfflineLike(ApiException('POST /x failed: 409 {}')), isFalse);
      expect(isOfflineLike(ApiException('POST /x failed: 422 {}')), isFalse);
    });

    test('ordinary failures are not offline-like while online', () {
      expect(isOfflineLike(ApiException('POST /x failed: 400 {}')), isFalse);
      expect(isOfflineLike(ApiException('GET /x failed: 401 {}')), isFalse);
      expect(isOfflineLike(ArgumentError('bad')), isFalse);
      expect(isOfflineLike(StateError('nope')), isFalse);
    });

    test('any failure is offline-like once the app is known offline', () {
      KnownConnectivity.online = false;
      expect(isOfflineLike(StateError('nope')), isTrue);
      expect(isOfflineLike(ApiException('POST /x failed: 400 {}')), isTrue);
      KnownConnectivity.online = true;
      expect(isOfflineLike(StateError('nope')), isFalse);
    });

    test('unknown connectivity is treated as online', () {
      KnownConnectivity.online = null;
      expect(isOfflineLike(StateError('nope')), isFalse);
    });

    test('knownOffline can be passed explicitly', () {
      expect(isOfflineLike(StateError('x'), knownOffline: true), isTrue);
      KnownConnectivity.online = false;
      expect(isOfflineLike(StateError('x'), knownOffline: false), isFalse);
    });

    test('isTransientNetworkFailure is unchanged', () {
      expect(isTransientNetworkFailure(const SocketException('x')), isFalse);
      expect(isTransientNetworkFailure(TimeoutException('x')), isTrue);
    });
  });
}
