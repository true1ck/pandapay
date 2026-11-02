import 'dart:convert';

import 'errors.dart';
import 'schema_data.g.dart';

/// A small JSON Schema (draft 2020-12 subset) interpreter that runs the same
/// schema files as the server's Ajv validators and maps failures to the same
/// error codes.
///
/// Supported keywords are exactly those the v2 schemas use: `$ref`, `type`,
/// `const`, `enum`, `pattern`, `format` (`date`, `date-time`), `minLength`,
/// `maxLength`, `minimum`, `maximum`, `exclusiveMinimum`, `minItems`,
/// `maxItems`, `items`, `contains`, `required`, `properties`,
/// `additionalProperties`, `allOf`, `anyOf`, `oneOf` (with `discriminator`) and
/// `if`/`then`. Error codes come from `x-code`, `x-codes` and
/// `x-required-codes` annotations; a failure with none maps to the fallback.
final class SchemaValidator {
  SchemaValidator._(this._docs);

  /// The validator over the embedded schemas.
  static final SchemaValidator instance = SchemaValidator._(_loadEmbedded());

  final Map<String, Map<String, Object?>> _docs;

  static Map<String, Map<String, Object?>> _loadEmbedded() {
    final docs = <String, Map<String, Object?>>{};
    smsV2SchemaSources.forEach((path, text) {
      docs[path.split('/').last] = jsonDecode(text) as Map<String, Object?>;
    });
    return docs;
  }

  /// Validates [instance] against the schema file [schemaFile] (a basename such
  /// as `fact.schema.json`). Unmapped failures use [fallback].
  List<ContractError> validate(
    String schemaFile,
    Object? instance, {
    required String fallback,
  }) {
    final root = _docs[schemaFile];
    if (root == null) throw ArgumentError('unknown contract schema $schemaFile');
    final out = <ContractError>[];
    _eval(root, instance, '', schemaFile, out, fallback);
    final seen = <String>{};
    return [
      for (final e in out)
        if (seen.add('${e.code}@${e.path}')) e,
    ];
  }

  // ---- evaluation ----

  void _eval(Map<String, Object?> s, Object? v, String path, String file,
      List<ContractError> out, String fb) {
    final ref = s[r'$ref'];
    if (ref is String) {
      final (targetFile, node) = _resolve(ref, file);
      _eval(node, v, path, targetFile, out, fb);
    }

    void err(String keyword, [String? missing]) =>
        out.add(ContractError(_code(s, keyword, missing, fb), path));

    final type = s['type'];
    if (type != null && !_typeOk(type, v)) err('type');

    if (s.containsKey('const') && !_deepEq(s['const'], v)) err('const');
    final en = s['enum'];
    if (en is List && !en.any((e) => _deepEq(e, v))) err('enum');

    if (v is String) {
      final pattern = s['pattern'];
      if (pattern is String && !RegExp(pattern).hasMatch(v)) err('pattern');
      final format = s['format'];
      if (format is String && !_formatOk(format, v)) err('format');
      final minL = s['minLength'];
      if (minL is int && v.runes.length < minL) err('minLength');
      final maxL = s['maxLength'];
      if (maxL is int && v.runes.length > maxL) err('maxLength');
    }

    if (v is num) {
      final min = s['minimum'];
      if (min is num && v < min) err('minimum');
      final max = s['maximum'];
      if (max is num && v > max) err('maximum');
      final exMin = s['exclusiveMinimum'];
      if (exMin is num && v <= exMin) err('exclusiveMinimum');
    }

    if (v is List) {
      final minI = s['minItems'];
      if (minI is int && v.length < minI) err('minItems');
      final maxI = s['maxItems'];
      if (maxI is int && v.length > maxI) err('maxItems');
      final items = s['items'];
      if (items is Map<String, Object?>) {
        for (var i = 0; i < v.length; i++) {
          _eval(items, v[i], '$path/$i', file, out, fb);
        }
      }
      final contains = s['contains'];
      if (contains is Map<String, Object?> &&
          !v.any((e) => _passes(contains, e, file, fb))) {
        err('contains');
      }
    }

    if (v is Map<String, Object?>) {
      final req = s['required'];
      if (req is List) {
        for (final k in req) {
          if (!v.containsKey(k)) err('required', k as String);
        }
      }
      final props = s['properties'];
      if (props is Map<String, Object?>) {
        for (final entry in props.entries) {
          if (v.containsKey(entry.key)) {
            _eval(entry.value as Map<String, Object?>, v[entry.key],
                '$path/${_escape(entry.key)}', file, out, fb);
          }
        }
      }
      final ap = s['additionalProperties'];
      if (ap == false) {
        final known = props is Map ? props.keys.toSet() : <Object?>{};
        if (v.keys.any((k) => !known.contains(k))) err('additionalProperties');
      } else if (ap is Map<String, Object?>) {
        final known = props is Map ? props.keys.toSet() : <Object?>{};
        for (final e in v.entries) {
          if (!known.contains(e.key)) {
            _eval(ap, e.value, '$path/${_escape(e.key)}', file, out, fb);
          }
        }
      }
    }

    final allOf = s['allOf'];
    if (allOf is List) {
      for (final sub in allOf) {
        _eval(sub as Map<String, Object?>, v, path, file, out, fb);
      }
    }
    final anyOf = s['anyOf'];
    if (anyOf is List &&
        !anyOf.any((sub) => _passes(sub as Map<String, Object?>, v, file, fb))) {
      err('anyOf');
    }
    final oneOf = s['oneOf'];
    if (oneOf is List) {
      final disc = s['discriminator'];
      if (disc is Map<String, Object?>) {
        final tag = disc['propertyName'] as String;
        final branch = (v is Map<String, Object?> && v[tag] is String)
            ? _branchFor(oneOf, tag, v[tag] as String, file)
            : null;
        if (branch == null) {
          err('discriminator');
        } else {
          _eval(branch.$2, v, path, branch.$1, out, fb);
        }
      } else {
        final n = oneOf
            .where((sub) => _passes(sub as Map<String, Object?>, v, file, fb))
            .length;
        if (n != 1) err('oneOf');
      }
    }

    final ifS = s['if'];
    if (ifS is Map<String, Object?>) {
      final branch = _passes(ifS, v, file, fb) ? s['then'] : s['else'];
      if (branch is Map<String, Object?>) {
        _eval(branch, v, path, file, out, fb);
      }
    }
  }

  bool _passes(Map<String, Object?> s, Object? v, String file, String fb) {
    final scratch = <ContractError>[];
    _eval(s, v, '', file, scratch, fb);
    return scratch.isEmpty;
  }

  (String, Map<String, Object?>)? _branchFor(
      List<Object?> oneOf, String tag, String value, String file) {
    for (final sub in oneOf) {
      var node = sub as Map<String, Object?>;
      var f = file;
      final ref = node[r'$ref'];
      if (ref is String) {
        final r = _resolve(ref, file);
        f = r.$1;
        node = r.$2;
      }
      final props = node['properties'];
      if (props is Map<String, Object?>) {
        final t = props[tag];
        if (t is Map<String, Object?> && t['const'] == value) return (f, node);
      }
    }
    return null;
  }

  (String, Map<String, Object?>) _resolve(String ref, String file) {
    final hash = ref.indexOf('#');
    final filePart = hash < 0 ? ref : ref.substring(0, hash);
    final pointer = hash < 0 ? '' : ref.substring(hash + 1);
    final target = filePart.isEmpty ? file : filePart.split('/').last;
    Object? node = _docs[target];
    if (node == null) throw StateError('unresolved schema reference $ref');
    if (pointer.isNotEmpty) {
      for (final part in pointer.substring(1).split('/')) {
        node = (node as Map<String, Object?>)[
            part.replaceAll('~1', '/').replaceAll('~0', '~')];
      }
    }
    return (target, node as Map<String, Object?>);
  }

  String _code(Map<String, Object?> s, String keyword, String? missing, String fb) {
    if (keyword == 'required' && missing != null) {
      final rc = s['x-required-codes'];
      if (rc is Map && rc[missing] is String) return rc[missing] as String;
    }
    final codes = s['x-codes'];
    if (codes is Map && codes[keyword] is String) return codes[keyword] as String;
    final single = s['x-code'];
    if (single is String) return single;
    return fb;
  }

  static String _escape(String k) => k.replaceAll('~', '~0').replaceAll('/', '~1');

  static bool _typeOk(Object type, Object? v) {
    if (type is List) return type.any((t) => _typeOk(t as String, v));
    switch (type) {
      case 'object':
        return v is Map;
      case 'array':
        return v is List;
      case 'string':
        return v is String;
      case 'boolean':
        return v is bool;
      case 'null':
        return v == null;
      case 'number':
        return v is num;
      case 'integer':
        return v is int || (v is double && v.isFinite && v == v.truncateToDouble());
    }
    return false;
  }

  static bool _deepEq(Object? a, Object? b) {
    if (a is Map && b is Map) {
      return a.length == b.length &&
          a.keys.every((k) => b.containsKey(k) && _deepEq(a[k], b[k]));
    }
    if (a is List && b is List) {
      return a.length == b.length &&
          List.generate(a.length, (i) => _deepEq(a[i], b[i])).every((x) => x);
    }
    return a == b;
  }

  static bool _formatOk(String format, String v) {
    final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})(?:T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(Z|[+-]\d{2}:\d{2}))?$')
        .firstMatch(v);
    if (m == null) return false;
    final y = int.parse(m[1]!), mo = int.parse(m[2]!), d = int.parse(m[3]!);
    if (mo < 1 || mo > 12 || d < 1) return false;
    final leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
    final dim = const [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][mo - 1] +
        (mo == 2 && leap ? 1 : 0);
    if (d > dim) return false;
    if (format == 'date') return m[4] == null;
    if (m[4] == null) return false;
    return int.parse(m[4]!) < 24 && int.parse(m[5]!) < 60 && int.parse(m[6]!) <= 60;
  }
}
