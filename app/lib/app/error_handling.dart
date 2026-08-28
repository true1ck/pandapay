import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'design/app_theme.dart';
import 'design/widgets.dart';

/// App-wide "don't unexpectedly die on the user" plumbing.
///
/// Flutter does NOT crash the app on every exception by default — a widget
/// whose `build()` throws is caught by the framework and replaced in place
/// by [ErrorWidget.builder]'s widget, which is why a single broken tile
/// doesn't normally take the whole screen down. But two classes of error
/// fall outside that safety net entirely and, left unhandled, kill the
/// whole Dart isolate — which on a real device looks exactly like what the
/// user described: the app just closes.
///
///   1. An exception thrown from an async callback with no enclosing
///      try/catch (a stray unawaited `Future`, a platform-channel callback,
///      a timer tick) — nothing in the widget tree ever gets a chance to
///      catch these; they surface at the isolate's top level.
///   2. An exception from `main()` itself, before `runApp` even starts.
///
/// [installGlobalErrorHandlers] closes both. [runGuarded] wraps the actual
/// `runApp` call in `runZonedGuarded` as a second, independent net — two
/// layers because `PlatformDispatcher.onError` alone doesn't catch
/// everything either (notably, errors during the synchronous part of
/// `runApp`'s first frame on some platforms), and the two mechanisms don't
/// overlap in exactly the same way on every Flutter version.
///
/// Deliberately NOT wired to a third-party crash-reporting SDK (Sentry,
/// Crashlytics). Adding one is an infra/vendor decision this file
/// shouldn't make unilaterally — see [CrashLog] below for the bounded,
/// local-only, no-network substitute this app has instead.
void installGlobalErrorHandlers() {
  final previousOnError = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails details) {
    CrashLog.instance.record(details.exception, details.stack, source: 'flutter');
    // Preserve whatever Flutter's own default handler does (prints the red
    // screen in debug, a console dump in release) — this hook adds logging,
    // it doesn't replace the framework's own recovery-in-place behavior.
    (previousOnError ?? FlutterError.presentError)(details);
  };

  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    CrashLog.instance.record(error, stack, source: 'platform_dispatcher');
    // Returning true tells the engine this error was handled — without it,
    // an error reaching this callback still terminates the isolate on some
    // platforms/versions. This is the line that actually stops "app just
    // closes" for the class of error this handler exists for.
    return true;
  };
}

/// Runs [body] inside `runZonedGuarded`, logging anything that escapes
/// every other net. See [installGlobalErrorHandlers]'s doc for why both
/// exist rather than either alone.
void runGuarded(void Function() body) {
  runZonedGuarded(body, (error, stack) {
    CrashLog.instance.record(error, stack, source: 'zone');
  });
}

/// A small, bounded, in-memory record of recent errors — NOT a crash
/// reporter. Nothing here ever leaves the device: no network call, no disk
/// write, no analytics event (`Analytics.track`'s prop allowlist is
/// deliberately too narrow to carry a stack trace anyway — see
/// data/analytics.dart — and stuffing one through it would be exactly the
/// kind of free-text leak that allowlist exists to prevent).
///
/// Exists so a future support/diagnostics screen has somewhere to read
/// from, and so `debugPrint` in a release build isn't the only trace of
/// what went wrong. Capped at [_maxEntries] because this is meant to
/// answer "what just happened", not accumulate for the life of the app.
class CrashLog {
  CrashLog._();
  static final CrashLog instance = CrashLog._();

  static const _maxEntries = 20;
  final List<CrashLogEntry> _entries = [];

  List<CrashLogEntry> get recent => List.unmodifiable(_entries);

  void record(Object error, StackTrace? stack, {required String source}) {
    // ignore: no_datetime_now_outside_clock
    _entries.insert(0, CrashLogEntry(error: error, stack: stack, source: source, at: DateTime.now()));
    if (_entries.length > _maxEntries) _entries.removeRange(_maxEntries, _entries.length);
    if (kDebugMode) {
      debugPrint('[CrashLog:$source] $error');
      if (stack != null) debugPrint(stack.toString());
    }
  }
}

class CrashLogEntry {
  final Object error;
  final StackTrace? stack;
  final String source;
  final DateTime at;
  const CrashLogEntry({required this.error, required this.stack, required this.source, required this.at});
}

/// Replaces the default [ErrorWidget] shown wherever a widget's `build()`
/// throws.
///
/// Deliberately NOT a full-screen "Something went wrong" page: this widget
/// can be handed ANY constraints — a broken `Text` inside a 20px-tall
/// `Row` cell is a completely normal place for a build error to occur, and
/// a naive full-size replacement (a `Scaffold`, a fixed-height column of
/// icon+text) would itself throw a layout exception in that slot, which is
/// a well-known way for an error-recovery widget to cause a SECOND crash.
/// `LayoutBuilder` + `FittedBox` keep this safe to render into a space of
/// any size, at the cost of looking like a plain icon glyph when the space
/// is small — that trade is correct here: staying on screen beats looking
/// polished.
///
/// Debug builds keep Flutter's own red screen (via [installGlobalErrorHandlers]
/// not touching `ErrorWidget.builder` there) — the loud, detailed default is
/// what a developer wants; a user never sees a debug build.
class AppErrorWidget extends StatelessWidget {
  final FlutterErrorDetails details;
  const AppErrorWidget({super.key, required this.details});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return Container(
          alignment: Alignment.center,
          color: BambooInk.clay.withValues(alpha: 0.08),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(Icons.error_outline_rounded, color: BambooInk.clay, size: 24),
            ),
          ),
        );
      },
    );
  }
}

/// The full-screen counterpart, used by go_router's `errorBuilder` — unlike
/// [AppErrorWidget] this always renders into a whole page's worth of space
/// (go_router only invokes it to replace an entire route), so it's safe to
/// build a real screen here: reuses [ErrorState], the same visual language
/// every other error surface in the app already uses, so a routing failure
/// doesn't look like a different, unfamiliar kind of broken.
class AppRouteErrorScreen extends StatelessWidget {
  final Object? error;
  final VoidCallback onGoHome;

  const AppRouteErrorScreen({super.key, required this.error, required this.onGoHome});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BambooInk.paper,
      body: AppBackground(
        child: SafeArea(
          child: ErrorState(
            message: "That page couldn't be found. If you followed a link here, it may be out of date.",
            onRetry: onGoHome,
          ),
        ),
      ),
    );
  }
}
