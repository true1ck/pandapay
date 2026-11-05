import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/sync/invalidation_coalescer.dart';

void main() {
  const window = Duration(seconds: 3);

  test('the first change is applied immediately', () {
    fakeAsync((async) {
      final flushed = <Set<String>>[];
      final c = InvalidationCoalescer(
        window: window,
        onFlush: flushed.add,
        now: () => DateTime(2026).add(async.elapsed),
      );
      c.add({'transactions'});
      expect(flushed, [
        {'transactions'},
      ]);
      c.dispose();
    });
  });

  test('a burst inside the window becomes one refresh with every entity', () {
    fakeAsync((async) {
      final flushed = <Set<String>>[];
      final c = InvalidationCoalescer(
        window: window,
        onFlush: flushed.add,
        now: () => DateTime(2026).add(async.elapsed),
      );
      c.add({'transactions'});
      for (var i = 0; i < 20; i++) {
        async.elapse(const Duration(milliseconds: 100));
        c.add(i.isEven ? {'transactions'} : {'user_cards'});
      }
      expect(flushed.length, 1, reason: 'nothing more until the window ends');
      async.elapse(window);
      expect(flushed.length, 2);
      expect(flushed.last, {'transactions', 'user_cards'});
      c.dispose();
    });
  });

  test('a constant stream refreshes once per window, not per change', () {
    fakeAsync((async) {
      var flushes = 0;
      final c = InvalidationCoalescer(
        window: window,
        onFlush: (_) => flushes++,
      );
      for (var i = 0; i < 100; i++) {
        c.add({'transactions'});
        async.elapse(const Duration(milliseconds: 300));
      }
      // 30 seconds of changes: about one refresh per 3 seconds.
      expect(flushes, inInclusiveRange(9, 12));
      c.dispose();
    });
  });

  test('after a quiet window the next change is immediate again', () {
    fakeAsync((async) {
      final flushed = <Set<String>>[];
      final c = InvalidationCoalescer(
        window: window,
        onFlush: flushed.add,
        now: () => DateTime(2026).add(async.elapsed),
      );
      c.add({'a'});
      async.elapse(window * 2);
      c.add({'b'});
      expect(flushed, [
        {'a'},
        {'b'},
      ]);
      c.dispose();
    });
  });

  test('a single change leaves no timer behind', () {
    fakeAsync((async) {
      final flushed = <Set<String>>[];
      final c = InvalidationCoalescer(
        window: window,
        onFlush: flushed.add,
        now: () => DateTime(2026).add(async.elapsed),
      );
      c.add({'a'});
      expect(flushed, [
        {'a'},
      ]);
      expect(async.pendingTimers, isEmpty);
      c.dispose();
    });
  });

  test('dispose cancels a pending refresh', () {
    fakeAsync((async) {
      final flushed = <Set<String>>[];
      final c = InvalidationCoalescer(
        window: window,
        onFlush: flushed.add,
        now: () => DateTime(2026).add(async.elapsed),
      );
      c.add({'a'});
      c.add({'b'});
      c.dispose();
      async.elapse(window * 2);
      expect(flushed, [
        {'a'},
      ]);
    });
  });
}
