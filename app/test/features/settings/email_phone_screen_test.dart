import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/phone_api.dart';
import 'package:pandapay/data/recovery_api.dart';
import 'package:pandapay/data/recovery_email_api.dart';
import 'package:pandapay/features/settings/email_phone_screen.dart';

/// The Phone row comes from the auth service (the number typed at sign-up, or an
/// older verified one), never from api/'s profiles row. The Recovery email section
/// and its banner come from the recovery-email status.
void main() {
  Future<void> pump(
    WidgetTester tester, {
    Map<String, dynamic>? profile,
    PhoneStatus? phone,
    RecoveryStatus? recovery,
    RecoveryEmailStatus? recoveryEmail,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          profileProvider.overrideWith((ref) async => profile),
          phoneStatusProvider.overrideWith((ref) async => phone),
          recoveryStatusProvider.overrideWith((ref) async => recovery),
          recoveryEmailStatusProvider.overrideWith((ref) async => recoveryEmail),
        ],
        child: const MaterialApp(home: EmailPhoneScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  PhoneStatus typed(String hint) => PhoneStatus(
    claimed: true,
    verified: false,
    required: true,
    needsPhone: false,
    phoneHint: hint,
  );

  testWidgets('a number typed at sign-up shows masked, as not verified, with how to change it', (tester) async {
    await pump(tester, profile: {'id': 'p1'}, phone: typed('+91 •••• 3210'));
    expect(find.text('+91 •••• 3210'), findsOneWidget);
    expect(find.text('Not verified'), findsOneWidget);
    expect(find.textContaining('tie this account to one number'), findsOneWidget);
    expect(find.textContaining('Contact support to change it'), findsOneWidget);
  });

  testWidgets('an older verified phone shows as Verified', (tester) async {
    await pump(
      tester,
      profile: {'id': 'p1'},
      recovery: const RecoveryStatus(
        phoneVerified: true,
        emailVerified: true,
        hasBackupChannel: true,
        phoneHint: '+91•••••••3210',
      ),
    );
    expect(find.text('+91•••••••3210'), findsOneWidget);
    expect(find.text('Verified'), findsOneWidget);
    expect(find.textContaining('Confirmed by a code we sent to it'), findsOneWidget);
  });

  testWidgets('no phone anywhere: says so plainly and shows no badge', (tester) async {
    await pump(tester, profile: {'id': 'p1', 'email': 'person@example.com'});
    expect(find.text('Not on file'), findsOneWidget);
    expect(find.text('Not verified'), findsNothing);
    expect(find.text('No phone number is saved on this account.'), findsOneWidget);
  });

  testWidgets('while the phone status loads, the profiles phone is a fallback shown as not verified', (tester) async {
    await pump(tester, profile: {'id': 'p1', 'phone_number': '+919876543210'});
    expect(find.text('+919876543210'), findsOneWidget);
    expect(find.text('Not verified'), findsOneWidget);
  });

  testWidgets('no recovery email: a banner and an Add button explain the risk', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pump(
      tester,
      profile: {'id': 'p1', 'email': 'person@example.com'},
      recoveryEmail: const RecoveryEmailStatus(hasRecoveryEmail: false),
    );
    expect(find.text('No way back if you lose your email'), findsOneWidget);
    expect(find.text('Not added'), findsOneWidget);
    expect(find.text('Add a recovery email'), findsNWidgets(2), reason: 'the banner button and the card button');
    expect(find.text('Remove recovery email'), findsNothing);
  });

  testWidgets('with a recovery email: the masked address, Change and Remove, and no banner', (tester) async {
    await pump(
      tester,
      profile: {'id': 'p1', 'email': 'person@example.com'},
      recoveryEmail: const RecoveryEmailStatus(hasRecoveryEmail: true, hint: 'b•••@outlook.com'),
    );
    expect(find.text('No way back if you lose your email'), findsNothing);
    expect(find.text('b•••@outlook.com'), findsOneWidget);
    expect(find.text('Added'), findsOneWidget);
    expect(find.text('Change recovery email'), findsOneWidget);
    expect(find.text('Remove recovery email'), findsOneWidget);
  });

  testWidgets('an older server or a failed lookup shows no recovery email section and no alarm', (tester) async {
    await pump(tester, profile: {'id': 'p1', 'email': 'person@example.com'});
    expect(find.text('Recovery email'.toUpperCase()), findsNothing);
    expect(find.text('No way back if you lose your email'), findsNothing);
  });
}
