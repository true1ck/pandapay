import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/error_handling.dart';

FlutterErrorDetails _fakeDetails() {
  return FlutterErrorDetails(exception: Exception('synthetic build failure'), stack: StackTrace.current);
}

void main() {
  group('AppErrorWidget', () {
    // This is the property that actually matters: ErrorWidget.builder can
    // be handed ANY constraints — a broken Text inside a 20px Row cell is a
    // completely ordinary place for a build error. A naive full-screen
    // replacement widget would itself throw a layout exception in that
    // slot, which is a well-known way for an error-recovery widget to
    // cause a SECOND crash. Every size below must render without the test
    // framework catching a layout exception.
    for (final size in [
      const Size(400, 800), // a normal screen
      const Size(20, 20), // a small icon-sized cell
      const Size(0.5, 0.5), // near-zero — the pathological case
      const Size(2000, 10), // very wide, very short
      const Size(10, 2000), // very tall, very narrow
    ]) {
      testWidgets('renders without throwing at ${size.width}x${size.height}', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: SizedBox(
                width: size.width,
                height: size.height,
                child: AppErrorWidget(details: _fakeDetails()),
              ),
            ),
          ),
        );
        // No exception must have been recorded by the test binding — this
        // is the assertion that catches "the error widget itself errored".
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('CrashLog', () {
    test('records entries newest-first and caps at 20', () {
      // Fresh state: CrashLog is a process-wide singleton, so this test
      // only asserts on RELATIVE behaviour (count doesn't exceed the cap,
      // newest is first) rather than an absolute starting count, since
      // other tests in the same run may have already recorded into it.
      for (var i = 0; i < 25; i++) {
        CrashLog.instance.record(Exception('err $i'), null, source: 'test');
      }
      expect(CrashLog.instance.recent.length, lessThanOrEqualTo(20));
      expect(CrashLog.instance.recent.first.error.toString(), contains('err 24'));
    });
  });
}
