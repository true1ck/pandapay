import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

void main() {
  test('logTransaction and editTransaction send occurredAt as UTC (Z)', () async {
    final bodies = <Map<String, dynamic>>[];
    final repo = UserCardsRepository(
      apiBaseUrl: 'https://api.test',
      accessToken: 't',
      client: MockClient((request) async {
        bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
        return http.Response(jsonEncode({'transaction': {'id': 'tx1'}}), 200);
      }),
    );
    final local = DateTime(2026, 11, 14, 9, 30);
    await repo.logTransaction(amount: Money.fromRupees(10), occurredAt: local);
    await repo.editTransaction('tx1', occurredAt: local);
    for (final body in bodies) {
      final sent = body['occurredAt'] as String;
      expect(sent.endsWith('Z'), isTrue);
      expect(DateTime.parse(sent).isAtSameMomentAs(local), isTrue);
    }
    expect(bodies, hasLength(2));
  });
}
