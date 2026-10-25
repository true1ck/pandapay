import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:pandapay_console/app/providers.dart';
import 'package:pandapay_console/data/admin_api.dart';
import 'package:pandapay_console/features/queues/support_tickets_screen.dart';

void main() {
  testWidgets('SupportTicketsScreen displays tickets and allows resolving',
      (tester) async {
    var resolveCalled = false;
    final testTickets = [
      {
        'id': 'ticket-1',
        'profile_id': 'user-1',
        'kind': 'general',
        'message': 'Cannot see my recent transaction in wallet',
        'diagnostics': {'appVersion': '1.0.0', 'platform': 'android'},
        'app_version': '1.0.0',
        'state': 'pending',
        'response': null,
        'created_at': '2026-10-24T10:00:00Z',
        'user_email': 'aarav@example.com',
        'user_name': 'Aarav Patel',
        'age_days': 0,
        'is_stale': false,
      },
      {
        'id': 'ticket-2',
        'profile_id': null,
        'kind': 'bug',
        'message': 'Not receiving OTP code during login',
        'diagnostics': null,
        'app_version': '1.0.0',
        'state': 'resolved',
        'response': 'Resolved SMS provider latency',
        'created_at': '2026-10-23T10:00:00Z',
        'user_email': null,
        'user_name': null,
        'age_days': 1,
        'is_stale': false,
      },
    ];

    final client = MockClient((request) async {
      if (request.url.path == '/admin/support-tickets') {
        return http.Response(
          jsonEncode({'supportTickets': testTickets}),
          200,
        );
      }
      if (request.url.path == '/admin/support-tickets/ticket-1/resolve') {
        resolveCalled = true;
        return http.Response(
          jsonEncode({'ok': true, 'ticket': {'id': 'ticket-1', 'state': 'resolved'}}),
          200,
        );
      }
      return http.Response('{"error":"not_found"}', 404);
    });

    final adminApi = AdminApi(
      apiBaseUrl: 'http://test',
      accessToken: 'test-token',
      client: client,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          adminApiProvider.overrideWithValue(adminApi),
        ],
        child: const MaterialApp(
          home: SupportTicketsScreen(),
        ),
      ),
    );

    await tester.pumpAndSettle();

    // Verify ticket 1 is visible
    expect(find.text('Cannot see my recent transaction in wallet'), findsOneWidget);
    expect(find.text('aarav@example.com'), findsOneWidget);
    expect(find.text('General'), findsOneWidget);

    // Verify ticket 2 is visible (guest)
    expect(find.text('Not receiving OTP code during login'), findsOneWidget);
    expect(find.text('Guest / Unauthenticated'), findsOneWidget);
    expect(find.text('Bug'), findsOneWidget);

    // Tap "Resolve" on ticket 1
    await tester.tap(find.text('Resolve'));
    await tester.pumpAndSettle();

    // Confirm dialog appears
    expect(find.text('Resolve Ticket'), findsOneWidget);
    await tester.tap(find.text('Mark Resolved'));
    await tester.pumpAndSettle();

    expect(resolveCalled, isTrue);
  });
}
