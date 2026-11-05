import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay_console/app/providers.dart';
import 'package:pandapay_console/data/admin_api.dart';
import 'package:pandapay_console/features/queues/error_reports_screen.dart';

void main() {
  testWidgets(
    'a report on a field without a typed writer offers the manual path, not Approve',
    (tester) async {
      String? rejectBody;
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/reject')) {
          rejectBody = request.body;
          return http.Response(jsonEncode({'ok': true}), 200);
        }
        if (request.url.path.endsWith('/approve')) {
          fail('approve must not be offered for this field');
        }
        return http.Response(
          jsonEncode({
            'errorReports': [
              {
                'id': 'report-9',
                'card_name': 'HDFC Millennia',
                'field_path': 'card_products.annual_fee',
                'shown_value': '1000',
                'claimed_value': '499',
                'state': 'pending',
              },
            ],
          }),
          200,
        );
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            accessTokenProvider.overrideWith((ref) => 'token'),
            adminApiProvider.overrideWithValue(
              AdminApi(
                apiBaseUrl: 'http://errors.invalid',
                accessToken: 'token',
                client: client,
              ),
            ),
          ],
          child: const MaterialApp(home: Scaffold(body: ErrorReportsScreen())),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Approve'), findsNothing);
      expect(
        find.textContaining('Only reward rates can be corrected automatically'),
        findsOneWidget,
      );

      await tester.tap(find.text('Close as fixed in Catalogue'));
      await tester.pumpAndSettle();
      expect(rejectBody, contains('corrected_manually_in_catalogue'));
    },
  );
}
