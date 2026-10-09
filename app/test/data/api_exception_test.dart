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
}
