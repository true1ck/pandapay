import 'package:sqlite3/sqlite3.dart';

/// Decoded, immutable rows of one table, kept per database so a whole-table
/// read (the ledger read model rebuilds on every revision bump) only parses
/// the rows that are new or changed.
///
/// A row is reused only when its stored payload text is *equal* to the text
/// that was decoded (string equality, not a hash), so a changed row can never
/// be served stale and writers need no invalidation hook. Reused rows are the
/// very same instances, which is what lets callers answer "did anything
/// change?" with `identical` instead of a deep comparison.
///
/// Only use this for immutable decoded values.
class RowDecodeCache<T extends Object> {
  RowDecodeCache._();

  /// Total rows parsed through any cache, for tests and diagnostics.
  static int decodeCount = 0;

  /// One cache per database and table tag, shared by every store instance
  /// (stores are constructed per call, the database lives for the session).
  static final _byDatabase = Expando<Map<String, Object>>('RowDecodeCache');

  static RowDecodeCache<T> of<T extends Object>(Database db, String table) {
    final caches = _byDatabase[db] ??= <String, Object>{};
    return (caches[table] ??= RowDecodeCache<T>._()) as RowDecodeCache<T>;
  }

  final _namespaces = <String, Map<String, _Row<T>>>{};

  /// Starts a whole-namespace read. Rows not resolved before [finish] are
  /// forgotten, so deleted rows do not accumulate.
  RowDecodePass<T> begin(String namespace) =>
      RowDecodePass<T>._(this, namespace, _namespaces[namespace] ?? const {});
}

class _Row<T> {
  _Row(this.payload, this.value);
  final String payload;
  final T value;
}

class RowDecodePass<T extends Object> {
  RowDecodePass._(this._cache, this._namespace, this._previous);
  final RowDecodeCache<T> _cache;
  final String _namespace;
  final Map<String, _Row<T>> _previous;
  final _next = <String, _Row<T>>{};

  /// The decoded row for [id]: the cached instance when [payload] is
  /// unchanged, otherwise a fresh decode.
  T resolve(String id, String payload, T Function(String payload) decode) {
    final seen = _next[id];
    if (seen != null && seen.payload == payload) return seen.value;
    final known = _previous[id];
    if (known != null && known.payload == payload) {
      _next[id] = known;
      return known.value;
    }
    RowDecodeCache.decodeCount++;
    final value = decode(payload);
    _next[id] = _Row<T>(payload, value);
    return value;
  }

  /// Remembers what this pass resolved. [complete] means the pass saw every
  /// row of the namespace, so rows it did not see are forgotten; a partial
  /// pass (a filtered query) only adds to what is kept.
  void finish({bool complete = true}) {
    if (complete) {
      _cache._namespaces[_namespace] = _next;
    } else {
      (_cache._namespaces[_namespace] ??= <String, _Row<T>>{}).addAll(_next);
    }
  }
}
