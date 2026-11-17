import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
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

  group('shareQr', () {
    test('sends the package and a PNG of the QR, never a payment link', () async {
      Map<Object?, Object?>? args;
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'shareQr');
        args = call.arguments as Map<Object?, Object?>;
        return true;
      });

      final ok = await MethodChannelUpiPaymentService().shareQr(
        packageName: 'com.phonepe.app',
        qrData: 'upi://pay?pa=shop%40ybl&pn=Shop&am=10.00&cu=INR',
      );

      expect(ok, isTrue);
      expect(args!['packageName'], 'com.phonepe.app');
      final png = args!['png'] as Uint8List;
      // PNG signature.
      expect(png.sublist(0, 8), [137, 80, 78, 71, 13, 10, 26, 10]);
      expect(args!.containsKey('uri'), isFalse);
    });

    test('is false when the app refuses, the platform throws or is missing', () async {
      final svc = MethodChannelUpiPaymentService();
      messenger.setMockMethodCallHandler(channel, (call) async => false);
      expect(await svc.shareQr(packageName: 'a', qrData: 'upi://pay?pa=x@y'), isFalse);
      messenger.setMockMethodCallHandler(channel, (call) async => null);
      expect(await svc.shareQr(packageName: 'a', qrData: 'upi://pay?pa=x@y'), isFalse);
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'bad_args');
      });
      expect(await svc.shareQr(packageName: 'a', qrData: 'upi://pay?pa=x@y'), isFalse);
      messenger.setMockMethodCallHandler(channel, null);
      expect(await svc.shareQr(packageName: 'a', qrData: 'upi://pay?pa=x@y'), isFalse);
    });
  });

  group('openApp', () {
    test('sends only the package name, never a payment link', () async {
      Map<Object?, Object?>? args;
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'openApp');
        args = call.arguments as Map<Object?, Object?>;
        return true;
      });

      expect(await MethodChannelUpiPaymentService().openApp('com.phonepe.app'), isTrue);
      expect(args, {'packageName': 'com.phonepe.app'});
    });

    test('is false when the app could not be opened', () async {
      messenger.setMockMethodCallHandler(channel, (call) async => false);
      expect(await MethodChannelUpiPaymentService().openApp('com.phonepe.app'), isFalse);
    });

    test('is false when the channel returns nothing', () async {
      messenger.setMockMethodCallHandler(channel, (call) async => null);
      expect(await MethodChannelUpiPaymentService().openApp('com.phonepe.app'), isFalse);
    });

    test('is false when the platform throws', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'bad_args');
      });
      expect(await MethodChannelUpiPaymentService().openApp('com.phonepe.app'), isFalse);
    });

    test('is false when the channel is not implemented (iOS, tests)', () async {
      expect(await MethodChannelUpiPaymentService().openApp('com.phonepe.app'), isFalse);
    });
  });

  group('iOS: the UPI apps are found by their own URL schemes', () {
    const link = 'upi://pay?pa=shop%40ybl&pn=Shop%20Name&am=10.00&cu=INR&tn=Tea%20%26%20snacks';

    IosUpiPaymentService service({
      Set<String> installed = const {},
      List<Uri>? launched,
      bool launchResult = true,
      bool launchThrows = false,
    }) => IosUpiPaymentService(
      canLaunch: (uri) async => installed.contains(uri.scheme),
      launch: (uri) async {
        if (launchThrows) throw PlatformException(code: 'x');
        launched?.add(uri);
        return launchResult;
      },
    );

    test('lists only the apps that are installed, then "Another UPI app"', () async {
      final apps = await service(installed: {'credpay', 'phonepe'}).installedApps();
      expect(apps.map((a) => a.name), ['PhonePe', 'CRED', 'Another UPI app']);
      expect(apps.map((a) => a.packageName), ['phonepe', 'cred', 'upi']);
    });

    test('Google Pay is found by either of its schemes', () async {
      expect(
        (await service(installed: {'tez'}).installedApps()).first.name,
        'Google Pay',
      );
      expect(
        (await service(installed: {'gpay'}).installedApps()).first.name,
        'Google Pay',
      );
    });

    test('no known app means an empty list, so the caller keeps its own fallback', () async {
      expect(await service(installed: {'upi'}).installedApps(), isEmpty);
      expect(await service().installedApps(), isEmpty);
    });

    test('opens the chosen app with the payee and amount, query unchanged', () async {
      final launched = <Uri>[];
      final ok = await service(installed: {'credpay', 'phonepe'}, launched: launched)
          .launchUpiLink(packageName: 'cred', uri: link);
      expect(ok, isTrue);
      expect(launched, hasLength(1));
      expect(launched.single.scheme, 'credpay');
      expect(
        launched.single.toString(),
        'credpay://upi/pay${link.substring(link.indexOf('?'))}',
      );
    });

    test('each app gets its own scheme, never another app\'s', () async {
      final launched = <Uri>[];
      final svc = service(
        installed: {'credpay', 'phonepe', 'paytmmp', 'tez', 'bhim'},
        launched: launched,
      );
      for (final id in ['gpay', 'phonepe', 'paytm', 'cred', 'bhim']) {
        await svc.launchUpiLink(packageName: id, uri: link);
      }
      expect(launched.map((u) => u.scheme), ['tez', 'phonepe', 'paytmmp', 'credpay', 'bhim']);
    });

    test('"Another UPI app" sends the plain link', () async {
      final launched = <Uri>[];
      await service(installed: {'phonepe'}, launched: launched)
          .launchUpiLink(packageName: 'upi', uri: link);
      expect(launched.single.toString(), link);
    });

    test('is false for an app that is not installed, unknown, refused, or throws', () async {
      expect(
        await service(installed: {'phonepe'}).launchUpiLink(packageName: 'cred', uri: link),
        isFalse,
      );
      expect(
        await service(installed: {'phonepe'}).launchUpiLink(packageName: 'nope', uri: link),
        isFalse,
      );
      expect(
        await service(installed: {'phonepe'}, launchResult: false)
            .launchUpiLink(packageName: 'phonepe', uri: link),
        isFalse,
      );
      expect(
        await service(installed: {'phonepe'}, launchThrows: true)
            .launchUpiLink(packageName: 'phonepe', uri: link),
        isFalse,
      );
    });

    test('openApp opens the app on its home screen, and shareQr is not offered', () async {
      final launched = <Uri>[];
      final svc = service(installed: {'phonepe'}, launched: launched);
      expect(await svc.openApp('phonepe'), isTrue);
      expect(launched.single.toString(), 'phonepe://');
      expect(await svc.openApp('cred'), isFalse);
      expect(await svc.shareQr(packageName: 'phonepe', qrData: link), isFalse);
    });

    test('card apps are found too, and are only opened with the UPI ID copied by the caller', () async {
      final launched = <Uri>[];
      final svc = service(
        installed: {'scapia', 'tnupi', 'kiwi', 'phonepe'},
        launched: launched,
      );
      final apps = await svc.installedApps();
      expect(apps.map((a) => a.name), ['PhonePe', 'Scapia', 'Tata Neu', 'Kiwi', 'Another UPI app']);
      // Only the apps with a documented payment link say they fill the payment in.
      expect(
        {for (final a in apps) a.name: a.prefillsPayment},
        {
          'PhonePe': true,
          'Scapia': false,
          'Tata Neu': false,
          'Kiwi': false,
          'Another UPI app': true,
        },
      );

      expect(await svc.launchUpiLink(packageName: 'scapia', uri: link), isTrue);
      // No payment link is sent to an app that has no documented one.
      expect(launched.single.toString(), 'scapia://');
    });

    test('every app has its logo bundled and every installed one carries it', () async {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      expect(pubspec, contains('- assets/upi_apps/'));
      for (final spec in iosUpiAppSpecs) {
        expect(File(spec.logoAsset).existsSync(), isTrue, reason: spec.logoAsset);
      }
      final apps = await service(
        installed: {for (final spec in iosUpiAppSpecs) spec.schemes.first},
      ).installedApps();
      final named = apps.where((a) => a.packageName != iosOtherUpiAppId);
      expect(named, hasLength(iosUpiAppSpecs.length));
      expect(named.every((a) => a.logoAsset != null), isTrue);
    });

    test('every scheme is declared in Info.plist, within Apple\'s 25-entry cap', () {
      final plist = File('ios/Runner/Info.plist').readAsStringSync();
      final block = RegExp(
        r'<key>LSApplicationQueriesSchemes</key>\s*<array>(.*?)</array>',
        dotAll: true,
      ).firstMatch(plist)!.group(1)!;
      final declared = RegExp(r'<string>([^<]+)</string>')
          .allMatches(block)
          .map((m) => m.group(1)!)
          .toList();

      expect(declared.toSet(), hasLength(declared.length), reason: 'no duplicates');
      // 25 is the cap for an app linked against the iOS 27 SDK; 50 before that.
      expect(declared.length, lessThanOrEqualTo(25));
      // canLaunchUrl is always false for an undeclared scheme, so a missing one
      // would silently hide an app.
      for (final spec in iosUpiAppSpecs) {
        for (final scheme in spec.schemes) {
          expect(declared, contains(scheme), reason: '${spec.name}: $scheme');
        }
      }
      // The plain-link fallback in the scan screen asks about `upi` too.
      expect(declared, contains('upi'));
    });

    test('the iPhone gets this service, other platforms keep the channel one', () {
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      for (final (platform, isIos) in [
        (TargetPlatform.iOS, true),
        (TargetPlatform.android, false),
      ]) {
        debugDefaultTargetPlatformOverride = platform;
        final container = ProviderContainer();
        addTearDown(container.dispose);
        expect(
          container.read(upiPaymentServiceProvider),
          isIos ? isA<IosUpiPaymentService>() : isA<MethodChannelUpiPaymentService>(),
        );
      }
    });
  });
}
