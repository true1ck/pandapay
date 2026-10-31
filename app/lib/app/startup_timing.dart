import 'package:flutter/foundation.dart';

/// Profile-only elapsed markers for the local splash gates. No account data.
final Stopwatch startupClock = Stopwatch()..start();

void markStartup(String stage) {
  if (kProfileMode) {
    debugPrint('PandaPay startup ${startupClock.elapsedMilliseconds}ms $stage');
  }
}
