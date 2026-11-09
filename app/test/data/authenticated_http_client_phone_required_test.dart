import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/authenticated_http_client.dart';

AuthenticatedHttpClient client(http.Response Function() reply, void Function() onPhone) {
  final c = AuthenticatedHttpClient(
    refreshAccessToken: () async => null,
    onPhoneRequired: onPhone,
    inner: MockClient((_) async => reply()),
  );
  addTearDown(c.close);
  return c;
}

void main() {
  final uri = Uri.parse('https://api.example.test/home-summary');

  test('a 403 phone_required opens the phone gate and the caller still gets the 403', () async {
    var opened = 0;
    final response = await client(
      () => http.Response(jsonEncode({'error': 'phone_required'}), 403),
      () => opened++,
    ).get(uri);
    expect(opened, 1);
    expect(response.statusCode, 403);
    expect(jsonDecode(response.body), {'error': 'phone_required'});
  });

  test('any other 403 leaves the gate alone and is returned unchanged', () async {
    var opened = 0;
    for (final body in [
      jsonEncode({'error': 'membership_required'}),
      jsonEncode({'error': 'step_up_required'}),
      'not json at all',
      '',
    ]) {
      final response = await client(() => http.Response(body, 403), () => opened++).get(uri);
      expect(response.statusCode, 403);
      expect(response.body, body);
    }
    expect(opened, 0);
  });

  test('successful and other failing replies never touch the gate', () async {
    var opened = 0;
    for (final status in [200, 201, 400, 404, 500, 503]) {
      final response = await client(
        () => http.Response(jsonEncode({'error': 'phone_required'}), status),
        () => opened++,
      ).get(uri);
      expect(response.statusCode, status);
    }
    expect(opened, 0, reason: 'only a 403 means the phone lock');
  });

  test('a failing gate callback never breaks the request', () async {
    final response = await client(
      () => http.Response(jsonEncode({'error': 'phone_required'}), 403),
      () => throw StateError('screen not ready'),
    ).get(uri);
    expect(response.statusCode, 403);
  });

  test('without a callback a 403 passes straight through', () async {
    final c = AuthenticatedHttpClient(
      refreshAccessToken: () async => null,
      inner: MockClient((_) async => http.Response(jsonEncode({'error': 'phone_required'}), 403)),
    );
    addTearDown(c.close);
    expect((await c.get(uri)).statusCode, 403);
  });
}
