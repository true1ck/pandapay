import 'package:sqlite3/sqlite3.dart';

/// Plain words for why an SMS step failed, safe to put on screen.
///
/// A release build scrambles type names (`runtimeType` prints something like
/// `minified:Cd`), so each kind of failure that matters gets its own fixed
/// word. The detail is only ever a developer-written message with long digit
/// runs blanked out and a length cap: never SMS text, which the code does not
/// put into an exception.
String failureKind(Object error) => switch (error) {
  SqliteException() => 'SqliteException',
  StateError() => 'StateError',
  RangeError() => 'RangeError',
  ArgumentError() => 'ArgumentError',
  FormatException() => 'FormatException',
  TypeError() => 'TypeError',
  UnsupportedError() => 'UnsupportedError',
  NoSuchMethodError() => 'NoSuchMethodError',
  ConcurrentModificationError() => 'ConcurrentModificationError',
  _ => 'Error',
};

/// A short description of [error]: its kind, and for a database error its
/// message and code, and for a state or argument error its own message.
String describeFailure(Object error) {
  final detail = switch (error) {
    SqliteException() => '${error.message} (${error.resultCode})',
    StateError() => error.message,
    RangeError() => '${error.message}',
    ArgumentError() => '${error.message}',
    _ => '',
  };
  final clean = detail
      .replaceAll(RegExp(r'\d{5,}'), '#')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  final cut = clean.length > 110 ? '${clean.substring(0, 110)}…' : clean;
  return cut.isEmpty ? failureKind(error) : '${failureKind(error)}: $cut';
}

/// The top frames of [stack] in a few characters each, for a build whose stack
/// frames are scrambled (obfuscated): `I+0x1a2b` is an offset into the isolate's
/// code, which `flutter symbolize` turns back into a function and line with the
/// archived symbols. Frames that are already readable are shortened to their
/// file and line. Only code locations, never values.
String compactStack(StackTrace stack, {int frames = 8}) {
  final out = <String>[];
  for (final line in stack.toString().split('\n')) {
    if (out.length >= frames) break;
    final code = RegExp(r'_kDart(Isolate|Vm)SnapshotInstructions\+0x([0-9a-f]+)').firstMatch(line);
    if (code != null) {
      out.add('${code.group(1) == 'Isolate' ? 'I' : 'V'}+0x${code.group(2)}');
      continue;
    }
    final file = RegExp(r'([\w.]+\.dart):(\d+)').firstMatch(line);
    if (file != null) out.add('${file.group(1)}:${file.group(2)}');
  }
  return out.join(' ');
}
