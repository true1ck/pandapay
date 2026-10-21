import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay_console/app/providers.dart';
import 'package:pandapay_console/data/admin_api.dart';
import 'package:pandapay_console/features/referrals/referral_operations_screen.dart';

void main() {
  testWidgets('shows worker and switch status; hold action requires a reason', (
    tester,
  ) async {
    http.Request? holdRequest;
    final api = AdminApi(
      apiBaseUrl: 'https://api.test',
      accessToken: 'admin-token',
      client: MockClient((request) async {
        if (request.method == 'PUT') holdRequest = request;
        return http.Response(
          jsonEncode({
            'hold': {'paused': true},
          }),
          200,
        );
      }),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          adminApiProvider.overrideWithValue(api),
          referralOperationsProvider.overrideWith(
            (ref) async => {
              'access': {'admissionMode': 'invite_only'},
              'campaign': null,
              'workers': [],
              'outbox': {
                'countsByState': {'pending': 2},
                'oldestPendingAgeSeconds': 15,
              },
              'activeHolds': [],
              'recentAudit': [],
            },
          ),
        ],
        child: const MaterialApp(home: ReferralOperationsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('New member admission'), findsOneWidget);
    expect(find.text('invite_only'), findsOneWidget);
    expect(find.text('No worker heartbeat recorded'), findsOneWidget);
    expect(find.textContaining('pending'), findsOneWidget);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Pause').first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Confirm'));
    await tester.pumpAndSettle();
    expect(find.text('Enter at least 10 characters.'), findsOneWidget);
    expect(holdRequest, isNull);

    await tester.enterText(
      find.byType(TextFormField),
      'Pause admissions during incident',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Confirm'));
    await tester.pumpAndSettle();
    expect(holdRequest?.method, 'PUT');
    expect(holdRequest?.url.path, '/admin/referrals/holds/admission');
    expect(jsonDecode(holdRequest!.body), {
      'paused': true,
      'reason': 'Pause admissions during incident',
    });
  });
}
