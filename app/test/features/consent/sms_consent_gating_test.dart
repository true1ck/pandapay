import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/features/consent/sms_reading_consent.dart';
import 'package:pandapay/features/sms_import/ios_sms_intake_controller.dart';
import 'package:pandapay/features/sms_import/sms_listener_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../sms_import/ios_sms_intake_controller_test.dart' show MemoryBridge;

class _FakeSmsService extends SmsListenerService {
  const _FakeSmsService(this.log);

  final List<String> log;

  @override
  Future<bool> hasPermissions() async {
    log.add('hasPermissions');
    return true;
  }

  @override
  void listenForeground(
    void Function(String sender, String body, DateTime receivedAt) onSms,
  ) {
    log.add('listenForeground');
  }
}

ProviderContainer _androidContainer(List<String> log, {required bool consent}) {
  final container = ProviderContainer(
    overrides: [
      smsListenerServiceProvider.overrideWithValue(_FakeSmsService(log)),
      smsReadingConsentProvider.overrideWith((ref) async => consent),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

IosSmsIntakeController _iosController(
  MemoryBridge service, {
  required bool consent,
  List<List<Map<Object?, Object?>>>? captured,
}) => IosSmsIntakeController(
  service: service,
  namespace: () => 'user:a',
  requestUpload: () {},
  capture: (_, _, rows) async {
    captured?.add(rows);
    return [
      for (final row in rows) {'id': row['id']},
    ];
  },
  smsReadingConsent: () async => consent,
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('Android SMS reading waits for the account\'s consent', () {
    test('live listening does not start without consent', () async {
      final log = <String>[];
      final container = _androidContainer(log, consent: false);
      await container.read(smsAutoImportProvider).start();
      expect(log, isNot(contains('listenForeground')));
    });

    test('live listening starts once the account has agreed', () async {
      final log = <String>[];
      final container = _androidContainer(log, consent: true);
      await container.read(smsAutoImportProvider).start();
      expect(log, contains('listenForeground'));
    });

    test('the inbox is not read for history without consent', () async {
      final log = <String>[];
      final container = _androidContainer(log, consent: false);
      final scanned = await container
          .read(smsAutoImportProvider)
          .captureExistingInbox();
      expect(scanned, 0);
      expect(log, isEmpty, reason: 'nothing may touch the inbox');
    });
  });

  group('iPhone Shortcut intake waits for the account\'s consent', () {
    test('a history import is not started without consent', () async {
      final service = MemoryBridge();
      final controller = _iosController(service, consent: false);
      await expectLater(
        controller.startHistory(DateTime(2026, 1, 1), DateTime(2026, 2, 1)),
        throwsStateError,
      );
      expect(service.createdJobs, isEmpty);
    });

    test('a history import starts once the account has agreed', () async {
      final service = MemoryBridge();
      final controller = _iosController(service, consent: true);
      await controller.refresh();
      await controller.startHistory(DateTime(2026, 1, 1), DateTime(2026, 2, 1));
      expect(service.createdJobs, hasLength(1));
    });

    test(
      'shared messages stay in the spool until the account agrees',
      () async {
        final service = MemoryBridge()..rows.add({'id': 'm1'});
        final captured = <List<Map<Object?, Object?>>>[];
        final controller = _iosController(
          service,
          consent: false,
          captured: captured,
        );
        await controller.refresh();
        expect(captured, isEmpty);
        expect(service.rows, hasLength(1));
      },
    );

    test('shared messages are processed once the account has agreed', () async {
      final service = MemoryBridge()..rows.add({'id': 'm1'});
      final captured = <List<Map<Object?, Object?>>>[];
      final controller = _iosController(
        service,
        consent: true,
        captured: captured,
      );
      await controller.refresh();
      expect(captured, hasLength(1));
      expect(service.rows, isEmpty);
    });

    test('live alerts cannot be switched on without consent', () async {
      final service = MemoryBridge()..snapshot['enabled'] = false;
      final controller = _iosController(service, consent: false);
      await expectLater(controller.setEnabled(true), throwsStateError);
      expect(service.snapshot['enabled'], isFalse);
    });
  });
}
