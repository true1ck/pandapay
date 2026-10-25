import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/api_exception.dart';

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
}
