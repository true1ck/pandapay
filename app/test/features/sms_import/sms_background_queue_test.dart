import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:pandapay/features/sms_import/sms_listener_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The handover between the SMS background isolate and the app.
///
/// The property that matters most here is that nothing is dropped by
/// accident: a bank alert that arrived while the app was closed exists
/// nowhere else on the device, so the queue must survive a failed upload,
/// a corrupt entry, and being offline.
QueuedSms _sms(String body, {String sender = 'VM-HDFCBK', DateTime? at}) =>
    QueuedSms(sender: sender, body: body, receivedAt: at ?? DateTime(2026, 8, 25, 10, 30));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a queued message round-trips through storage', () async {
    final prefs = await SharedPreferences.getInstance();
    await SmsBackgroundQueue.enqueue(prefs, _sms('Rs.450 spent on card XX1234'));

    final read = SmsBackgroundQueue.read(prefs);
    expect(read, hasLength(1));
    expect(read.first.sender, 'VM-HDFCBK');
    expect(read.first.body, 'Rs.450 spent on card XX1234');
    expect(read.first.receivedAt, DateTime(2026, 8, 25, 10, 30));
  });

  test('messages come back oldest first, in arrival order', () async {
    final prefs = await SharedPreferences.getInstance();
    await SmsBackgroundQueue.enqueue(prefs, _sms('first'));
    await SmsBackgroundQueue.enqueue(prefs, _sms('second'));
    await SmsBackgroundQueue.enqueue(prefs, _sms('third'));

    expect(SmsBackgroundQueue.read(prefs).map((m) => m.body), ['first', 'second', 'third']);
  });

  test('the queue is bounded, dropping the oldest when full', () async {
    // A phone left closed for weeks must not accumulate unbounded raw SMS
    // text on disk. The newest are the ones most likely to still matter.
    final prefs = await SharedPreferences.getInstance();
    for (var i = 0; i < SmsBackgroundQueue.maxQueued + 5; i++) {
      await SmsBackgroundQueue.enqueue(prefs, _sms('msg$i'));
    }
    final read = SmsBackgroundQueue.read(prefs);
    expect(read, hasLength(SmsBackgroundQueue.maxQueued));
    expect(read.first.body, 'msg5', reason: 'the five oldest were dropped');
    expect(read.last.body, 'msg${SmsBackgroundQueue.maxQueued + 4}');
  });

  test('a corrupt entry is skipped without stranding the rest', () async {
    // One bad row must not make the whole queue unreadable and strand every
    // message behind it.
    SharedPreferences.setMockInitialValues({
      SmsBackgroundQueue.storageKey: [
        '{"sender":"A","body":"good one","receivedAt":"2026-08-25T10:30:00.000"}',
        'not json at all',
        '{"sender":"B"}',
        '{"sender":"C","body":"good two","receivedAt":"2026-08-25T11:00:00.000"}',
      ],
    });
    final prefs = await SharedPreferences.getInstance();
    final read = SmsBackgroundQueue.read(prefs);
    expect(read.map((m) => m.body), ['good one', 'good two']);
  });

  test('replace with an empty list clears the key entirely', () async {
    final prefs = await SharedPreferences.getInstance();
    await SmsBackgroundQueue.enqueue(prefs, _sms('one'));
    await SmsBackgroundQueue.replace(prefs, const []);
    expect(prefs.getStringList(SmsBackgroundQueue.storageKey), isNull);
  });

  group('flushBackgroundQueue', () {
    test('clears only what the upload actually handled', () async {
      final prefs = await SharedPreferences.getInstance();
      await SmsBackgroundQueue.enqueue(prefs, _sms('keep me'));
      await SmsBackgroundQueue.enqueue(prefs, _sms('send me'));

      final handled = await SmsListenerService().flushBackgroundQueue(
        (sender, body, at) async => body == 'send me',
        prefs: prefs,
      );

      expect(handled, 1);
      expect(SmsBackgroundQueue.read(prefs).map((m) => m.body), ['keep me']);
    });

    test('an offline upload keeps everything queued for next time', () async {
      // A bank alert dropped here is not recoverable from anywhere else on
      // the device, so a network failure must lose nothing.
      final prefs = await SharedPreferences.getInstance();
      await SmsBackgroundQueue.enqueue(prefs, _sms('one'));
      await SmsBackgroundQueue.enqueue(prefs, _sms('two'));

      final handled = await SmsListenerService().flushBackgroundQueue(
        (sender, body, at) async => throw Exception('offline'),
        prefs: prefs,
      );

      expect(handled, 0);
      expect(SmsBackgroundQueue.read(prefs), hasLength(2));
    });

    test('a fully successful flush empties the queue', () async {
      final prefs = await SharedPreferences.getInstance();
      await SmsBackgroundQueue.enqueue(prefs, _sms('one'));
      await SmsBackgroundQueue.enqueue(prefs, _sms('two'));

      final handled = await SmsListenerService().flushBackgroundQueue(
        (sender, body, at) async => true,
        prefs: prefs,
      );

      expect(handled, 2);
      expect(SmsBackgroundQueue.read(prefs), isEmpty);
    });

    test('the original arrival time is passed through, not the flush time', () async {
      // The transaction must be filed under when the bank sent the alert,
      // not when the user next happened to open the app — which could be
      // days later and in a different month.
      final prefs = await SharedPreferences.getInstance();
      final arrived = DateTime(2026, 7, 31, 22, 15);
      await SmsBackgroundQueue.enqueue(prefs, _sms('late', at: arrived));

      DateTime? seen;
      await SmsListenerService().flushBackgroundQueue(
        (sender, body, at) async {
          seen = at;
          return true;
        },
        prefs: prefs,
      );

      expect(seen, arrived);
    });

    test('an empty queue is a no-op', () async {
      final prefs = await SharedPreferences.getInstance();
      var called = false;
      final handled = await SmsListenerService().flushBackgroundQueue(
        (sender, body, at) async {
          called = true;
          return true;
        },
        prefs: prefs,
      );
      expect(handled, 0);
      expect(called, isFalse);
    });
  });
}
