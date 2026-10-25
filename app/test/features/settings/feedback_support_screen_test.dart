import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/authenticated_http_client.dart';
import 'package:pandapay/features/settings/feedback_support_screen.dart';

void main() {
  setUp(() {
    PackageInfo.setMockInitialValues(
      appName: 'PandaPay',
      packageName: 'com.pandapay.app',
      version: '1.2.3',
      buildNumber: '42',
      buildSignature: '',
    );
  });

  testWidgets('renders feedback form and allows guest submission without auth token', (tester) async {
    http.Request? capturedRequest;
    final inner = MockClient((request) async {
      capturedRequest = request;
      return http.Response(
        jsonEncode({
          'ticket': {'id': 'st-1', 'state': 'open'}
        }),
        201,
        headers: {'content-type': 'application/json'},
      );
    });
    final client = AuthenticatedHttpClient(
      inner: inner,
      refreshAccessToken: () async => null,
      currentAccessToken: () => null,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accessTokenProvider.overrideWith((ref) => null),
          authenticatedHttpClientProvider.overrideWithValue(client),
        ],
        child: const MaterialApp(
          home: FeedbackSupportScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Feedback & Support'), findsOneWidget);
    expect(find.text('What kind of feedback is this?'), findsOneWidget);

    // Enter message
    await tester.enterText(find.byType(TextField), 'Unable to receive OTP login code');
    await tester.pumpAndSettle();

    // Scroll to Send and tap
    await tester.ensureVisible(find.text('Send'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Send'));
    // Pump frames to complete async submit and present dialog
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    // Dialog displayed
    expect(find.text('Thanks for letting us know'), findsOneWidget);

    // Verify submission
    expect(capturedRequest, isNotNull);
    expect(capturedRequest!.url.path, '/support-tickets');
    final body = jsonDecode(capturedRequest!.body) as Map<String, dynamic>;
    expect(body['kind'], 'general');
    expect(body['message'], 'Unable to receive OTP login code');
    expect(capturedRequest!.headers.containsKey('authorization'), isFalse);

    // Tap OK on dialog
    await tester.tap(find.text('OK'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  });
}
