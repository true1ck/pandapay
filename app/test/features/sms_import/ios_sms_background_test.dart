import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/features/sms_import/ios_sms_background.dart';
import 'package:pandapay/features/sms_import/ios_sms_intake_service.dart';

class _Bridge extends IosSmsIntakeService {
  final calls = <String>[];
  final rows = <Map<Object?, Object?>>[];
  final outcomes = <Map>[];
  String generation = 'g1';
  void Function()? afterAck;
  _Bridge(int count) {
    for (var i = 0; i < count; i++) {
      rows.add({
        'id': '$i',
        'namespace': 'user:a',
        'generation': 'g1',
        'sender': 'VM-TESTBK',
        'body': 'Welcome to synthetic service $i.',
        'receivedAt': '2026-03-07T06:00:00Z',
      });
    }
  }
  @override
  Future<Object?> call(String method, [Map<String, Object?>? arguments]) async {
    calls.add(method);
    switch (method) {
      case 'snapshot':
        return {
          'enabled': true,
          'namespace': 'user:a',
          'generation': generation,
        };
      case 'pending':
        return rows.take(50).toList();
      case 'acknowledge':
        final receipts = (arguments!['outcomes'] as List).cast<Map>();
        outcomes.addAll(receipts);
        final ids = receipts.map((r) => r['id']).toSet();
        rows.removeWhere((r) => ids.contains(r['id']));
        afterAck?.call();
        return null;
      default:
        throw StateError('Unexpected background operation: $method');
    }
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'cold processing drains bounded batches, including a legacy security alert',
    () async {
      final bridge = _Bridge(115);
      bridge.rows[1]['body'] =
          'Registration Alert: Device Name: SYNTHETIC PHONE.';
      final drain = IosSmsBackgroundDrain(
        service: bridge,
        openDatabase: () async => openInMemoryForTesting(),
        readNamespace: () async => 'user:a',
      );
      expect(await drain.run(), {'success': true});
      expect(bridge.rows, isEmpty);
      expect(bridge.calls.where((m) => m == 'acknowledge'), hasLength(3));
      final excluded = bridge.outcomes.singleWhere((r) => r['id'] == '1');
      expect(excluded['outcome'], 'excluded_security');
      expect(excluded.containsKey('sourceKey'), isFalse);
      expect(
        bridge.outcomes.where((r) => r['outcome'] == 'ignored'),
        hasLength(114),
      );
    },
  );

  test(
    'expiration stops after a committed batch and preserves the rest',
    () async {
      final bridge = _Bridge(115);
      final drain = IosSmsBackgroundDrain(
        service: bridge,
        openDatabase: () async => openInMemoryForTesting(),
        readNamespace: () async => 'user:a',
      );
      bridge.afterAck = () => drain.stopped = true;
      expect(await drain.run(), {'success': false});
      expect(bridge.outcomes, hasLength(50));
      expect(bridge.rows, hasLength(65));
    },
  );

  test('a changed generation fences the next batch', () async {
    final bridge = _Bridge(115);
    final drain = IosSmsBackgroundDrain(
      service: bridge,
      openDatabase: () async => openInMemoryForTesting(),
      readNamespace: () async => 'user:a',
    );
    bridge.afterAck = () => bridge.generation = 'revoked';
    expect(await drain.run(), {'success': false});
    expect(bridge.outcomes, hasLength(50));
    expect(bridge.rows, hasLength(65));
  });

  test('signed-out cold launch never opens the financial database', () async {
    final bridge = _Bridge(1);
    final drain = IosSmsBackgroundDrain(
      service: bridge,
      openDatabase: () async => throw StateError('Database must stay closed'),
      readNamespace: () async => 'signed-out',
    );
    expect(await drain.run(), {'success': false});
    expect(bridge.calls, ['snapshot']);
    expect(bridge.rows, hasLength(1));
  });
}
