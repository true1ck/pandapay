/// Partial matching of an expected JSON value against an actual one.
///
/// - Maps: every listed key must match; unlisted keys are ignored.
/// - Lists: every expected element must match a distinct actual element, in any
///   order; extra actual elements are ignored.
/// - Numbers compare by value; everything else by equality.
/// - `null` expected means the actual value is `null` or absent.
///
/// [ignorePaths] holds dotted paths (list indexes omitted, for example
/// `instrument.issuerSlug`) that are skipped, so a baseline that cannot produce
/// a field is not penalised for it.
bool partialMatch(
  Object? expected,
  Object? actual, {
  Set<String> ignorePaths = const {},
}) => explainMismatch(expected, actual, ignorePaths: ignorePaths) == null;

/// Returns null when [expected] matches, otherwise a short description of the
/// first difference (`path: expected X, got Y`).
String? explainMismatch(
  Object? expected,
  Object? actual, {
  Set<String> ignorePaths = const {},
  String path = '',
}) {
  if (ignorePaths.contains(path)) return null;
  String here(String key) => path.isEmpty ? key : '$path.$key';
  if (expected == null) {
    return actual == null ? null : '$path: expected null, got $actual';
  }
  if (expected is Map) {
    if (actual is! Map) return '$path: expected an object, got $actual';
    for (final e in expected.entries) {
      final p = here(e.key as String);
      if (ignorePaths.contains(p)) continue;
      final r = explainMismatch(
        e.value,
        actual[e.key],
        ignorePaths: ignorePaths,
        path: p,
      );
      if (r != null) return r;
    }
    return null;
  }
  if (expected is List) {
    if (actual is! List) return '$path: expected a list, got $actual';
    final used = <int>{};
    for (final e in expected) {
      var found = false;
      for (var i = 0; i < actual.length; i++) {
        if (used.contains(i)) continue;
        if (explainMismatch(e, actual[i], ignorePaths: ignorePaths, path: path) == null) {
          used.add(i);
          found = true;
          break;
        }
      }
      if (!found) return '$path: no element matches $e';
    }
    return null;
  }
  if (expected is num && actual is num) {
    return expected.toDouble() == actual.toDouble() ? null : '$path: expected $expected, got $actual';
  }
  return expected == actual ? null : '$path: expected $expected, got $actual';
}

/// Splits one expected partial Fact into the dimensions that are scored
/// separately: `kind` (factType and attrs), `amount` (amounts) and
/// `instrument`. Everything else is `other`.
Map<String, Map<String, dynamic>> splitDimensions(Map<String, dynamic> fact) {
  final out = <String, Map<String, dynamic>>{};
  for (final e in fact.entries) {
    final dim = switch (e.key) {
      'factType' || 'attrs' => 'kind',
      'amounts' => 'amount',
      'instrument' => 'instrument',
      _ => 'other',
    };
    out.putIfAbsent(dim, () => {})[e.key] = e.value;
  }
  return out;
}
