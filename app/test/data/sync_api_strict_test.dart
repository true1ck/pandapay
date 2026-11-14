import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/sync_api.dart';

void main() {
  test('push asks for strict results and parses them; old replies still work',
      () async {
    Map<String, dynamic>? sent;
    final api = SyncApi(
      apiBaseUrl: 'http://test',
      accessToken: 't',
      client: MockClient((request) async {
        sent = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'results': [
              {
                'clientSeq': 1,
                'applied': true,
                'conflicts': 0,
                'ignoredFields': ['a', 'b'],
                'clampedClocks': ['note'],
              },
              {'clientSeq': 2, 'applied': true, 'conflicts': 0},
              {'clientSeq': 3, 'applied': false, 'reason': 'no_syncable_fields'},
              {'clientSeq': 4, 'applied': false, 'reason': 'transient'},
            ],
          }),
          200,
        );
      }),
    );
    final results = await api.push(deviceId: 'd', changes: const []);
    expect(sent!['strict'], isTrue);
    expect(results[0].ignoredFields, ['a', 'b']);
    expect(results[1].ignoredFields, isEmpty);
    expect(results[2].isPermanentFailure, isTrue);
    expect(results[3].isTransient, isTrue);
    expect(results[3].isPermanentFailure, isFalse);
  });
}
