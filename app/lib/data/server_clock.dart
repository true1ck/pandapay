import 'dart:io';

/// Process-wide estimate of "server time minus device time", learnt from the
/// `Date` header of successful API responses (WP-C1, decision D9).
///
/// Field clocks on queued edits are compared by the server. A phone whose
/// clock is minutes or days wrong would otherwise lose (or wrongly win) every
/// conflict. While online we measure the skew; while offline [now] keeps
/// using the last measured skew, so edits made on a wrong clock are still
/// stamped close to server time.
///
/// Behaviour when nothing was learnt yet (or the skew is under two seconds)
/// is exactly `DateTime.now()`: [offset] is [Duration.zero] and [now] returns
/// the device clock value untouched.
class ServerClock {
  ServerClock({DateTime Function()? deviceNow})
    : _deviceNow = deviceNow ?? DateTime.now;

  /// The instance the app uses. Tests construct their own.
  static final ServerClock instance = ServerClock();

  /// A skew larger than this is not believed in full. The server also clamps
  /// future client clocks; this only bounds how far the client moves its own.
  static const Duration maxOffset = Duration(days: 7);

  /// Date headers have one-second resolution and include network latency, so
  /// anything smaller than this is noise, not skew.
  static const Duration noiseFloor = Duration(seconds: 2);

  final DateTime Function() _deviceNow;
  Duration _offset = Duration.zero;

  Duration get offset => _offset;
  bool get hasOffset => _offset != Duration.zero;

  /// Server-adjusted "now". Equal to the device clock when no offset is known.
  DateTime now() {
    final device = _deviceNow();
    return _offset == Duration.zero ? device : device.add(_offset);
  }

  /// Records a measurement. [serverTime] is the server's clock at (about) the
  /// moment the device clock read [receivedAt] (default: now). Returns whether
  /// the stored offset changed.
  bool observeServerTime(DateTime serverTime, {DateTime? receivedAt}) {
    var next = serverTime.difference(receivedAt ?? _deviceNow());
    if (next.abs() < noiseFloor) next = Duration.zero;
    if (next > maxOffset) next = maxOffset;
    if (next < -maxOffset) next = -maxOffset;
    final changed = next != _offset;
    _offset = next;
    return changed;
  }

  /// Parses an HTTP `Date` header. A missing or unparsable value is ignored
  /// and returns false.
  bool observeDateHeader(String? header, {DateTime? receivedAt}) {
    if (header == null || header.trim().isEmpty) return false;
    final DateTime parsed;
    try {
      parsed = HttpDate.parse(header.trim());
    } catch (_) {
      return false;
    }
    observeServerTime(parsed, receivedAt: receivedAt);
    return true;
  }

  void reset() => _offset = Duration.zero;
}
