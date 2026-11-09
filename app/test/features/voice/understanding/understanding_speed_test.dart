import 'package:flutter_test/flutter_test.dart';

import '../../../../lib/features/voice/understanding/utterance_reader.dart';

// Understanding runs once per sentence, on the UI isolate, so it must stay
// far below a frame. This is a loose guard against an accidental slowdown,
// not a benchmark: the bound is generous for a debug-mode VM.
void main() {
  test('a long three-entry dictation is understood in a few milliseconds', () {
    const reader = UtteranceReader();
    const text =
        'yesterday i spent two thousand five hundred on groceries at '
        'bigbasket using my hdfc card and then paid 1,350 rupees for lunch '
        'with colleagues, um also 450 for an uber to the airport no sorry 480 '
        'and I paid about 3k for my electricity bill last friday';
    final now = DateTime(2026, 11, 11, 15, 30);
    // Warm up the compiled-regex cache and the JIT.
    for (var i = 0; i < 50; i++) {
      reader.read(text, now);
    }
    const runs = 1000;
    final watch = Stopwatch()..start();
    for (var i = 0; i < runs; i++) {
      reader.read(text, now);
    }
    watch.stop();
    final perCallMs = watch.elapsedMicroseconds / runs / 1000;
    // ignore: avoid_print
    print('understanding: ${perCallMs.toStringAsFixed(3)} ms per sentence');
    expect(perCallMs, lessThan(10));
    expect(reader.read(text, now).entries, hasLength(4));
  });
}
