import 'dart:async';

/// Lets one navigation, sheet or dialog open at a time.
///
/// Split buttons open a page or a sheet and give no feedback until it paints,
/// so people tap again. Without a gate each tap stacks another copy of the same
/// screen. [run] ignores a call while an earlier one is still in flight, and the
/// earlier one stays "in flight" until its page or sheet is dismissed, because
/// the push/show future completes only then.
///
/// Keep one gate per screen State and route every page/sheet/dialog opener
/// through it. It is deliberately not global: two screens may each open one
/// thing, but never one screen two of the same thing.
class SharedTapGate {
  bool _busy = false;

  /// True while an opener is still running.
  bool get busy => _busy;

  /// Runs [action] unless another gated action is still running. The gate always
  /// opens again afterwards, even when [action] throws, so a failure cannot
  /// leave the screen dead.
  Future<void> run(FutureOr<void> Function() action) async {
    if (_busy) return;
    _busy = true;
    try {
      await action();
    } finally {
      _busy = false;
    }
  }
}
