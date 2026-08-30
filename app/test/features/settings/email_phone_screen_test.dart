import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/recovery_api.dart';
import 'package:pandapay/features/settings/email_phone_screen.dart';

/// Regression: the Phone row used to be read from api/'s `profiles.phone_number`,
/// which is only written on the email-OTP *sign-up* path — so the row appeared
/// or vanished depending on how the account was first created. It now comes
/// from the auth service's recovery-status (`phone_hint` / `phone_verified`),
/// the same source the recovery banner already trusted.
void main() {
  RecoveryStatus status({
    bool phoneVerified = false,
    bool emailVerified = true,
    bool hasBackupChannel = true,
    String? phoneHint,
  }) {
    return RecoveryStatus(
      phoneVerified: phoneVerified,
      emailVerified: emailVerified,
      hasBackupChannel: hasBackupChannel,
      phoneHint: phoneHint,
    );
  }

  Future<void> pump(
    WidgetTester tester, {
    Map<String, dynamic>? profile,
    RecoveryStatus? recovery,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          profileProvider.overrideWith((ref) async => profile),
          recoveryStatusProvider.overrideWith((ref) async => recovery),
        ],
        child: const MaterialApp(home: EmailPhoneScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('verified phone from auth: shows the masked hint and a Verified badge', (tester) async {
    await pump(
      tester,
      profile: {'id': 'p1'}, // no phone_number in the profiles row at all
      recovery: status(phoneVerified: true, phoneHint: '+91•••••••3210'),
    );

    expect(find.text('+91•••••••3210'), findsOneWidget);
    expect(find.text('Verified'), findsOneWidget); // phone only — email absent below
    expect(
      find.textContaining('confirmed by a code we sent to it'),
      findsOneWidget,
    );
  });

  testWidgets('linked but unverified phone: hint shows with an Unverified badge', (tester) async {
    await pump(
      tester,
      profile: {'id': 'p1'},
      recovery: status(
        phoneVerified: false,
        hasBackupChannel: false,
        phoneHint: '+91•••••••3210',
      ),
    );

    expect(find.text('+91•••••••3210'), findsOneWidget);
    expect(find.text('Unverified'), findsOneWidget);
    expect(find.textContaining('linked but not proven'), findsOneWidget);
  });

  testWidgets('no phone anywhere: Not on file, no badge, sign-up prompt', (tester) async {
    await pump(
      tester,
      profile: {'id': 'p1', 'email': 'sujaykurtikar2@gmail.com'},
      recovery: status(hasBackupChannel: false),
    );

    expect(find.text('Not on file'), findsOneWidget); // the Phone row; Email row shows the address
    // No phone badge at all (the lone "Verified" belongs to the Email row).
    expect(find.text('Unverified'), findsNothing);
    expect(
      find.textContaining('Add one at sign-up'),
      findsOneWidget,
    );
  });

  testWidgets('recovery still loading: falls back to the profiles phone as Unverified', (tester) async {
    await pump(
      tester,
      profile: {'id': 'p1', 'phone_number': '+919876543210'},
      recovery: null,
    );

    expect(find.text('+919876543210'), findsOneWidget);
    expect(find.text('Unverified'), findsOneWidget);
  });
}
