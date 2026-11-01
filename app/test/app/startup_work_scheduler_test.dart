import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/startup_work_scheduler.dart';

void main() {
  test('coalesces startup work by key and keeps the latest callback', () async {
    final scheduler = StartupWorkScheduler(
      initialDelay: const Duration(milliseconds: 5),
    );
    addTearDown(scheduler.dispose);
    final events = <String>[];

    scheduler.enqueue('refresh', () => events.add('old'));
    scheduler.enqueue('refresh', () => events.add('new'));
    expect(events, isEmpty);

    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(events, ['new']);
  });

  test('runs queued jobs serially and continues after a failure', () async {
    final scheduler = StartupWorkScheduler(
      initialDelay: const Duration(milliseconds: 1),
    );
    addTearDown(scheduler.dispose);
    final releaseFirst = Completer<void>();
    final events = <String>[];

    scheduler.enqueue('first', () async {
      events.add('first-start');
      await releaseFirst.future;
      events.add('first-end');
      throw StateError('expected test failure');
    });
    scheduler.enqueue('second', () => events.add('second'));

    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(events, ['first-start']);
    releaseFirst.complete();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(events, ['first-start', 'first-end', 'second']);
  });

  test('dispose cancels pending startup work', () async {
    final scheduler = StartupWorkScheduler(
      initialDelay: const Duration(milliseconds: 20),
    );
    final events = <String>[];
    scheduler.enqueue('refresh', () => events.add('ran'));
    scheduler.dispose();

    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(events, isEmpty);
  });

  test('bounds a backlog to one callback per event-loop drain', () async {
    final scheduler = StartupWorkScheduler(
      initialDelay: Duration.zero,
      maxJobsPerDrain: 1,
    );
    addTearDown(scheduler.dispose);
    final events = <String>[];
    scheduler.enqueue('one', () => events.add('one'));
    scheduler.enqueue('two', () => events.add('two'));
    scheduler.enqueue('three', () => events.add('three'));

    await Future<void>.delayed(Duration.zero);
    expect(events, ['one']);
    await Future<void>.delayed(Duration.zero);
    expect(events, ['one', 'two']);
    await Future<void>.delayed(Duration.zero);
    expect(events, ['one', 'two', 'three']);
  });
}
