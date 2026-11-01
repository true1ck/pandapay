import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// Profile-only elapsed markers for the local splash gates. No account data.
final Stopwatch startupClock = Stopwatch()..start();

void markStartup(String stage) {
  if (kProfileMode) {
    debugPrint('PandaPay startup ${startupClock.elapsedMilliseconds}ms $stage');
  }
}

/// Bounded profile-only frame summary for real scrolling/navigation trials.
void installProfileFrameTiming() {
  if (!kProfileMode) return;
  final ui = <int>[];
  final raster = <int>[];
  var slow60Hz = 0;
  var earlyFrameCount = 0;
  SchedulerBinding.instance.addTimingsCallback((timings) {
    for (final frame in timings) {
      if (earlyFrameCount < 8) {
        debugPrint(
          'PandaPay frame index=${earlyFrameCount + 1} '
          'build_us=${frame.buildDuration.inMicroseconds} '
          'raster_us=${frame.rasterDuration.inMicroseconds}',
        );
        earlyFrameCount++;
      }
      final uiUs = frame.buildDuration.inMicroseconds;
      final rasterUs = frame.rasterDuration.inMicroseconds;
      ui.add(uiUs);
      raster.add(rasterUs);
      if (uiUs > 16667 || rasterUs > 16667) slow60Hz++;
    }
    if (ui.length < 30) return;
    ui.sort();
    raster.sort();
    final p95 = (ui.length * 0.95).floor().clamp(0, ui.length - 1);
    debugPrint(
      'PandaPay frames count=${ui.length} ui_p95_us=${ui[p95]} '
      'raster_p95_us=${raster[p95]} slow_60hz=$slow60Hz',
    );
    ui.clear();
    raster.clear();
    slow60Hz = 0;
  });
}
