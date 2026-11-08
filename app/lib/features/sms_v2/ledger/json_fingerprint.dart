/// A compact stand-in for a decoded JSON value, used to notice that a row is
/// unchanged without keeping the previous decoded copy in memory.
///
/// The key holds the number of values visited plus two independent 32-bit
/// hashes over every key, string, number, type tag and nesting, in order.
/// Equal JSON always gives an equal key. Two different documents would have to
/// match in size and in both hashes (about 2^-64 for unrelated input) to be
/// mistaken for each other. Map key order is part of the key: reordered keys
/// only cost a re-decode, never a stale row.
String jsonFingerprint(Object? root) {
  final f = _Fingerprint()..walk(root);
  return '${f.size}:${f.h1}:${f.h2}';
}

class _Fingerprint {
  int h1 = 0x811C9DC5;
  int h2 = 0x01000193;
  int size = 0;

  void mix(int unit) {
    h1 = ((h1 ^ unit) * 0x01000193) & 0xFFFFFFFF;
    h2 = ((h2 * 31) + unit + 0x9E3779B9) & 0xFFFFFFFF;
    size++;
  }

  void mixString(String value) {
    final length = value.length;
    mix(length);
    for (var i = 0; i < length; i++) {
      mix(value.codeUnitAt(i));
    }
  }

  void walk(Object? value) {
    if (value is String) {
      mix(1);
      mixString(value);
    } else if (value is Map) {
      mix(2);
      mix(value.length);
      for (final entry in value.entries) {
        mixString(entry.key as String);
        walk(entry.value);
      }
    } else if (value is List) {
      mix(3);
      mix(value.length);
      for (final item in value) {
        walk(item);
      }
    } else if (value == null) {
      mix(4);
    } else if (value is bool) {
      mix(value ? 5 : 6);
    } else if (value is int) {
      mix(7);
      mixString(value.toString());
    } else {
      mix(8);
      mixString(value.toString());
    }
  }
}
