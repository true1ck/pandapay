/// Dart compiles a `RegExp` every time one is constructed. In functions that
/// run once per SMS (triage, gating, sender checks) that meant dozens of
/// regex compilations per message on the UI isolate, which showed up as the
/// top self-time in a startup profile. Use this instead of `RegExp(` for any
/// pattern built inside a function that can run per message or per row; the
/// compiled expression is created once and reused.
///
/// Only the literal pattern and flags form the key, so it is safe for any
/// pattern that is not built from user input. Never pass an unbounded set of
/// distinct patterns (user text, merchant names): the cache never evicts.
RegExp cachedRegExp(
  String source, {
  bool multiLine = false,
  bool caseSensitive = true,
  bool unicode = false,
  bool dotAll = false,
}) {
  final key =
      '${multiLine ? 'm' : '-'}${caseSensitive ? 'c' : '-'}'
      '${unicode ? 'u' : '-'}${dotAll ? 's' : '-'}$source';
  return _cache[key] ??= RegExp(
    source,
    multiLine: multiLine,
    caseSensitive: caseSensitive,
    unicode: unicode,
    dotAll: dotAll,
  );
}

final Map<String, RegExp> _cache = <String, RegExp>{};
