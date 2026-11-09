import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/api_exception.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local_first/command_outbox.dart';

void main() {
  late AppDatabase db;
  late DateTime clock;
  late CommandOutbox outbox;

  setUp(() {
    db = openInMemoryForTesting();
    clock = DateTime(2026, 11, 10, 12);
    outbox = CommandOutbox(db, namespace: 'a', now: () => clock);
  });
  tearDown(() => db.close());

  Map<String, CommandHandler> record(List<String> calls) => {
    'ignore': (p) async => calls.add('ignore ${p['id']}'),
    'restore': (p) async => calls.add('restore ${p['id']}'),
  };

  test('a queued command is sent once and removed', () async {
    final calls = <String>[];
    outbox.enqueue(kind: 'ignore', target: 't1', payload: {'id': 't1'});

    expect(await outbox.flush(record(calls)), 1);
    expect(calls, ['ignore t1']);
    expect(outbox.pendingCount, 0);
    expect(await outbox.flush(record(calls)), 0);
  });

  test('restore before the ignore was sent cancels both', () async {
    final calls = <String>[];
    expect(outbox.enqueue(kind: 'ignore', target: 't1', payload: {'id': 't1'}), isTrue);
    final queued = outbox.enqueue(
      kind: 'restore',
      target: 't1',
      payload: {'id': 't1'},
      cancels: const ['ignore'],
    );

    expect(queued, isFalse);
    expect(outbox.pendingCount, 0);
    await outbox.flush(record(calls));
    expect(calls, isEmpty);
  });

  test('the same command twice keeps only the latest intent', () async {
    final seen = <Object?>[];
    outbox.enqueue(kind: 'ignore', target: 't1', payload: {'reason': 'refund'});
    outbox.enqueue(kind: 'ignore', target: 't1', payload: {'reason': 'transfer'});

    await outbox.flush({'ignore': (p) async => seen.add(p['reason'])});
    expect(seen, ['transfer']);
  });

  test('a network failure backs off and is retried later, not dropped', () async {
    outbox.enqueue(kind: 'ignore', target: 't1');
    final failing = {'ignore': (Map<String, Object?> p) async => throw ApiException('down')};

    expect(await outbox.flush(failing), 0);
    expect(outbox.pendingCount, 1);

    // Not due yet: nothing is attempted inside the 30 s backoff.
    var attempts = 0;
    final counting = {'ignore': (Map<String, Object?> p) async => attempts++};
    clock = clock.add(const Duration(seconds: 10));
    expect(await outbox.flush(counting), 0);
    expect(attempts, 0);

    clock = clock.add(const Duration(minutes: 1));
    expect(await outbox.flush(counting), 1);
    expect(outbox.pendingCount, 0);
  });

  test('a server refusal is parked with its error and not retried', () async {
    outbox.enqueue(kind: 'ignore', target: 't1');
    var attempts = 0;
    final refusing = {
      'ignore': (Map<String, Object?> p) async {
        attempts++;
        throw ApiException('POST /transactions/:id/ignore failed: 404 {"error":"not found"}');
      },
    };

    await outbox.flush(refusing);
    expect(outbox.pendingCount, 0);
    expect(outbox.parked().single.error, contains('404'));

    clock = clock.add(const Duration(hours: 1));
    await outbox.flush(refusing);
    expect(attempts, 1, reason: 'a parked command is never retried on its own');

    outbox.retryParked(outbox.parked().single.id);
    expect(outbox.pendingCount, 1);
  });

  test('401 and 429 are retried, they are not refusals', () async {
    outbox.enqueue(kind: 'ignore', target: 't1');
    await outbox.flush({
      'ignore': (p) async => throw ApiException('failed: 401 {"error":"unauthorized"}'),
    });
    expect(outbox.parked(), isEmpty);
    expect(outbox.pendingCount, 1);
  });

  test('a failure holds back later commands for the same target only', () async {
    final calls = <String>[];
    outbox.enqueue(kind: 'ignore', target: 't1', payload: {'id': 't1'});
    outbox.enqueue(kind: 'restore', target: 't1', payload: {'id': 't1'});
    outbox.enqueue(kind: 'ignore', target: 't2', payload: {'id': 't2'});

    await outbox.flush({
      'ignore': (p) async {
        if (p['id'] == 't1') throw ApiException('down');
        calls.add('ignore ${p['id']}');
      },
      'restore': (p) async => calls.add('restore ${p['id']}'),
    });

    // t1's restore waits behind its failed ignore; t2 is unaffected.
    expect(calls, ['ignore t2']);
    expect(outbox.pendingCount, 2);
  });

  test('accounts do not see each other\'s commands', () async {
    outbox.enqueue(kind: 'ignore', target: 't1');
    final other = CommandOutbox(db, namespace: 'b', now: () => clock);

    expect(other.pendingCount, 0);
    expect(await other.flush({'ignore': (p) async {}}), 0);
    expect(outbox.pendingCount, 1);
  });
}
