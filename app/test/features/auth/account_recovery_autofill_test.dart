import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/auth_api.dart';
import 'package:pandapay/features/auth/account_recovery_screen.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('recovery code field requests native one-time-code autofill', (
    tester,
  ) async {
    final authApi = AuthApi(
      authBaseUrl: 'http://auth.test',
      client: MockClient((_) async => http.Response(jsonEncode({}), 200)),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [authApiProvider.overrideWithValue(authApi)],
        child: const MaterialApp(home: AccountRecoveryScreen()),
      ),
    );
    await tester.enterText(find.byType(TextField), 'user@example.com');
    await tester.tap(find.text('Send code'));
    await tester.pumpAndSettle();

    final codeField = tester.widget<TextField>(find.byType(TextField));
    expect(codeField.autofillHints, const [AutofillHints.oneTimeCode]);
    expect(codeField.focusNode?.hasFocus, isTrue);

    await tester.enterText(find.byType(TextField), '12a345');
    expect(codeField.controller!.text, '1234');
  });
}
