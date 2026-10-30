import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../data/local_sms_parser.dart';

/// Transport only. Platform-independent intake and financial policy live in
/// the existing capture owner, not in this channel or native App Intents.
class IosSmsIntakeService {
  static const channel = MethodChannel('pandapay/ios_sms_intake');
  bool get supported => !kIsWeb && Platform.isIOS;

  Future<Object?> call(String method, [Map<String, Object?>? arguments]) =>
      channel.invokeMethod<Object?>(method, arguments);

  void listen(Future<void> Function()? onReady) {
    channel.setMethodCallHandler(
      onReady == null
          ? null
          : (call) async {
              if (call.method == 'ready') await onReady();
            },
    );
  }

  Future<Map<String, Object?>> configure(
    String namespace, {
    bool? enabled,
    bool reset = false,
  }) async => Map<String, Object?>.from(
    (await call('configure', {
          'namespace': namespace,
          'enabled': ?enabled,
          'reset': reset,
          'parserVersion': LocalSmsParser.version,
        }))!
        as Map,
  );

  Future<void> revoke(String namespace) async {
    if (supported) await configure(namespace, reset: true);
  }
}

class IosSmsWindow {
  final DateTime start;
  final DateTime end;
  const IosSmsWindow(this.start, this.end);
  Map<String, String> toJson() => {
    'start': start.toUtc().toIso8601String(),
    'end': end.toUtc().toIso8601String(),
  };
}

/// Calendar components retain local month/day boundaries (including DST), then
/// frozen instants are sent to native storage. No fixed 30-day approximation.
List<IosSmsWindow> iosSmsWindows(
  DateTime start,
  DateTime end, {
  required bool monthly,
}) {
  if (!start.isBefore(end)) {
    throw ArgumentError('Choose a nonempty date range.');
  }
  final windows = <IosSmsWindow>[];
  var cursor = start;
  while (cursor.isBefore(end)) {
    final boundary = cursor.isUtc
        ? (monthly
              ? DateTime.utc(cursor.year, cursor.month + 1)
              : DateTime.utc(cursor.year, cursor.month, cursor.day + 1))
        : (monthly
              ? DateTime(cursor.year, cursor.month + 1)
              : DateTime(cursor.year, cursor.month, cursor.day + 1));
    final next = boundary.isBefore(end) ? boundary : end;
    windows.add(IosSmsWindow(cursor, next));
    if (windows.length > 2400) {
      throw ArgumentError('Choose a shorter date range.');
    }
    cursor = next;
  }
  return List.unmodifiable(windows);
}

DateTime iosSmsMonthsAgo(DateTime cutoff, int months) {
  if (months < 1) throw ArgumentError.value(months);
  final target = DateTime(cutoff.year, cutoff.month - months);
  final lastDay = DateTime(target.year, target.month + 1, 0).day;
  return DateTime(
    target.year,
    target.month,
    cutoff.day.clamp(1, lastDay),
    cutoff.hour,
    cutoff.minute,
    cutoff.second,
    cutoff.millisecond,
    cutoff.microsecond,
  );
}
