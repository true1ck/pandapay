import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local_first/command_outbox.dart';

/// H3-3 / H3-4.
void main() {
  late AppDatabase db;
  late CommandOutbox outbox;
  setUp(() {
    db = openInMemoryForTesting();
    outbox = CommandOutbox(db, namespace: 'a');
  });
  tearDown(() => db.close());

  test('a command with no handler stays queued: not parked, no attempt', () async {
    outbox.enqueue(kind: 'add_card', target: 'prov-1');
    expect(await outbox.flush({}), 0);
    expect(outbox.parked(), isEmpty);
    expect(outbox.pendingCount, 1);
    expect(
      db.db.select('SELECT attempts FROM command_outbox').single['attempts'],
      0,
    );
    // Once the handler exists the same row is delivered.
    var calls = 0;
    expect(await outbox.flush({'add_card': (p) async => calls++}), 1);
    expect(calls, 1);
  });

  test('a network failure marks the pass unreachable; a clean pass resets it', () async {
    outbox.enqueue(kind: 'k', target: 't1');
    await outbox.flush({'k': (p) async => throw TimeoutException('x')});
    expect(outbox.lastFlushUnreachable, isTrue);
    await outbox.flush({'k': (p) async {}});
    expect(outbox.lastFlushUnreachable, isFalse);
  });
}
