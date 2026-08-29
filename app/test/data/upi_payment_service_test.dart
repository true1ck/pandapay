import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/upi_payment_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('app.pandapay/upi');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('installedApps decodes name/package/icon and drops malformed rows', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getInstalledUpiApps');
      return <Object?>[
        {'packageName': 'com.phonepe.app', 'name': 'PhonePe', 'icon': base64Encode(const [1, 2, 3])},
        {'packageName': 'net.one97.paytm', 'name': 'Paytm', 'icon': null},
        {'name': 'no package'},
      ];
    });

    final apps = await MethodChannelUpiPaymentService().installedApps();

    expect(apps.map((a) => a.packageName), ['com.phonepe.app', 'net.one97.paytm']);
    expect(apps.first.iconPng, isA<Uint8List>());
    expect(apps[1].iconPng, isNull);
  });

  test('installedApps returns [] when the channel is not implemented', () async {
    // No mock handler registered -> MissingPluginException.
    expect(await MethodChannelUpiPaymentService().installedApps(), isEmpty);
  });

  test('pay maps each NPCI status string, defaulting unknown to submitted', () async {
    Future<UpiPaymentStatus> statusFor(String? s) async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'pay');
        expect(call.arguments['uri'], 'upi://pay?pa=x@y&cu=INR');
        expect(call.arguments['packageName'], 'com.phonepe.app');
        return {'status': s, 'response': 'Status=$s'};
      });
      final r = await MethodChannelUpiPaymentService().pay(
        upiUri: 'upi://pay?pa=x@y&cu=INR',
        packageName: 'com.phonepe.app',
      );
      return r.status;
    }

    expect(await statusFor('success'), UpiPaymentStatus.success);
    expect(await statusFor('failure'), UpiPaymentStatus.failure);
    expect(await statusFor('cancelled'), UpiPaymentStatus.cancelled);
    expect(await statusFor('weird'), UpiPaymentStatus.submitted);
    expect(await statusFor(null), UpiPaymentStatus.submitted);
  });

  test('newTransactionRef is prefixed and unique-ish', () {
    final s = MethodChannelUpiPaymentService();
    final a = s.newTransactionRef();
    expect(a, startsWith('PP'));
    expect(a.length, greaterThan(6));
  });
}
