import 'dart:convert';

/// A decoded JSON object.
typedef Json = Map<String, Object?>;

/// Deep equality for decoded JSON values. Numbers compare by value, so `1`
/// equals `1.0`.
bool jsonDeepEquals(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final k in a.keys) {
      if (!b.containsKey(k) || !jsonDeepEquals(a[k], b[k])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!jsonDeepEquals(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

/// Canonical JSON: keys sorted, no whitespace, UTF-8 when encoded. This is the
/// form the rule-bundle signature covers.
String canonicalJson(Object? value) {
  final sb = StringBuffer();
  _write(sb, value);
  return sb.toString();
}

void _write(StringBuffer sb, Object? v) {
  if (v is Map) {
    final keys = v.keys.cast<String>().toList()..sort();
    sb.write('{');
    for (var i = 0; i < keys.length; i++) {
      if (i > 0) sb.write(',');
      sb.write(jsonEncode(keys[i]));
      sb.write(':');
      _write(sb, v[keys[i]]);
    }
    sb.write('}');
  } else if (v is List) {
    sb.write('[');
    for (var i = 0; i < v.length; i++) {
      if (i > 0) sb.write(',');
      _write(sb, v[i]);
    }
    sb.write(']');
  } else if (v is double && v == v.truncateToDouble() && v.abs() < 1e15) {
    sb.write(v.toInt());
  } else {
    sb.write(jsonEncode(v));
  }
}

/// A deep, unmodifiable copy of decoded JSON.
Object? freezeJson(Object? v) {
  if (v is Map) {
    return Map<String, Object?>.unmodifiable({
      for (final e in v.entries) e.key as String: freezeJson(e.value),
    });
  }
  if (v is List) return List<Object?>.unmodifiable(v.map(freezeJson));
  return v;
}

/// A plain mutable deep copy of decoded JSON, for returning from `toJson`.
Object? thawJson(Object? v) {
  if (v is Map) {
    return <String, Object?>{
      for (final e in v.entries) e.key as String: thawJson(e.value),
    };
  }
  if (v is List) return <Object?>[for (final e in v) thawJson(e)];
  return v;
}

/// Base for immutable value types: equality and hash come from [toJson].
abstract class JsonValue {
  const JsonValue();

  Json toJson();

  @override
  bool operator ==(Object other) =>
      other is JsonValue &&
      other.runtimeType == runtimeType &&
      jsonDeepEquals(toJson(), other.toJson());

  @override
  int get hashCode => canonicalJson(toJson()).hashCode;

  @override
  String toString() => '$runtimeType(${canonicalJson(toJson())})';
}

DateTime parseUtc(String s) => DateTime.parse(s).toUtc();

/// ISO-8601 UTC with `Z`, no fractional seconds when zero.
String formatUtc(DateTime t) {
  final u = t.toUtc();
  String p(int n, [int w = 2]) => n.toString().padLeft(w, '0');
  final base =
      '${p(u.year, 4)}-${p(u.month)}-${p(u.day)}T${p(u.hour)}:${p(u.minute)}:${p(u.second)}';
  if (u.millisecond == 0 && u.microsecond == 0) return '${base}Z';
  final frac = (u.millisecond * 1000 + u.microsecond).toString().padLeft(6, '0');
  return '$base.${frac.replaceFirst(RegExp(r'0+$'), '')}Z';
}
