import '../contract/enums.dart';
import '../contract/rule_bundle.dart';
import 'sender.dart';
import 'transforms.dart';

/// The engine's own version. A phone refuses a bundle whose `minEngineVersion`
/// is newer.
const String smsEngineVersion = '2.0.0';

/// Why a bundle cannot be used.
class BundleRefusedException implements Exception {
  BundleRefusedException(this.code, this.message);

  /// `engine_too_old`, `bundle_invalid`, `regex_invalid`, `transform_unknown`.
  final String code;
  final String message;

  @override
  String toString() => 'BundleRefusedException($code: $message)';
}

/// -1, 0, 1 comparing two `major.minor.patch` versions. Missing parts are 0.
int compareSemver(String a, String b) {
  List<int> parts(String v) {
    final core = v.split(RegExp(r'[-+]')).first.split('.');
    return [for (var i = 0; i < 3; i++) i < core.length ? int.tryParse(core[i]) ?? 0 : 0];
  }

  final x = parts(a), y = parts(b);
  for (var i = 0; i < 3; i++) {
    if (x[i] != y[i]) return x[i] < y[i] ? -1 : 1;
  }
  return 0;
}

RegExp _compileRegex(String pattern, String flags) => RegExp(
      pattern,
      caseSensitive: !flags.contains('i'),
      multiLine: flags.contains('m'),
      dotAll: flags.contains('s'),
    );

bool _isAsciiAlnum(String c) {
  final u = c.codeUnitAt(0);
  return (u >= 48 && u <= 57) || (u >= 65 && u <= 90) || (u >= 97 && u <= 122);
}

/// Lowercase literal runs that every match of [pattern] must contain, at most
/// three, longest first. Used to skip a regex that cannot match before running
/// it. It is conservative: anything it cannot read (top-level alternation, a
/// named back-reference, a unicode escape) yields no literals, a literal
/// followed by `?`, `*` or `{` is dropped, and groups and classes are skipped.
List<String> requiredLiterals(String pattern) {
  final runs = <String>[];
  final run = StringBuffer();
  void flush() {
    if (run.length >= 3) runs.add(run.toString());
    run.clear();
  }

  final n = pattern.length;
  var i = 0;
  // Adds [ch] unless a following quantifier makes it optional.
  void literal(String ch) {
    final u = ch.codeUnitAt(0);
    if (u < 32 || u > 126) {
      flush();
      return;
    }
    final q = i < n ? pattern[i] : '';
    if (q == '?' || q == '*' || q == '{') {
      flush();
    } else if (q == '+') {
      run.write(ch.toLowerCase());
      flush();
    } else {
      run.write(ch.toLowerCase());
    }
  }

  while (i < n) {
    final c = pattern[i];
    switch (c) {
      case '|':
        return const [];
      case '\\':
        if (i + 1 >= n) return const [];
        final e = pattern[i + 1];
        i += 2;
        if ('kpPuxc'.contains(e)) return const [];
        if (_isAsciiAlnum(e)) {
          flush();
        } else {
          literal(e);
        }
      case '[':
        flush();
        var j = i + 1;
        while (j < n && pattern[j] != ']') {
          j += pattern[j] == '\\' ? 2 : 1;
        }
        if (j >= n) return const [];
        i = j + 1;
      case '(':
        flush();
        var depth = 0;
        var j = i;
        while (j < n) {
          final d = pattern[j];
          if (d == '\\') {
            j += 2;
            continue;
          }
          if (d == '[') {
            j++;
            while (j < n && pattern[j] != ']') {
              j += pattern[j] == '\\' ? 2 : 1;
            }
            j++;
            continue;
          }
          if (d == '(') depth++;
          if (d == ')' && --depth == 0) break;
          j++;
        }
        if (j >= n) return const [];
        i = j + 1;
      case ')':
        return const [];
      case '{':
        flush();
        final close = pattern.indexOf('}', i);
        i = close < 0 ? i + 1 : close + 1;
      case '^' || r'$' || '.' || '?' || '*' || '+' || '}' || ']':
        flush();
        i++;
      default:
        i++;
        literal(c);
    }
  }
  flush();
  runs.sort((a, b) => b.length.compareTo(a.length));
  return [...runs.toSet().take(3)];
}

/// A rule with its regex built once.
class CompiledRule {
  CompiledRule(this.rule, this.regex)
      : literals = requiredLiterals(rule.match.pattern),
        requireAll = [for (final s in rule.match.requireAll ?? const <String>[]) s.toLowerCase()],
        rejectAny = [for (final s in rule.match.rejectAny ?? const <String>[]) s.toLowerCase()];

  final Rule rule;
  final RegExp regex;
  final List<String> requireAll;
  final List<String> rejectAny;

  /// Substrings (lowercase) that any match of [regex] contains.
  final List<String> literals;

  String? get templateHash => rule.match.templateHash;

  /// Whether the body can match: the regex's own required literals, then
  /// `requireAll` and `rejectAny`, all case-insensitive substring checks on
  /// the whole body. It is cheap, so the engine runs it before the regex.
  bool passes(String lowerBody) {
    for (final s in literals) {
      if (!lowerBody.contains(s)) return false;
    }
    for (final s in requireAll) {
      if (!lowerBody.contains(s)) return false;
    }
    for (final s in rejectAny) {
      if (lowerBody.contains(s)) return false;
    }
    return true;
  }
}

class CompiledIgnore {
  CompiledIgnore(this.rule, this.regex);
  final IgnoreRule rule;
  final RegExp regex;
}

class CompiledPurpose {
  CompiledPurpose(this.purpose)
      : vpa = purpose.vpaPattern == null
            ? null
            : RegExp(purpose.vpaPattern!, caseSensitive: false),
        name = purpose.namePattern == null
            ? null
            : RegExp(purpose.namePattern!, caseSensitive: false);

  final CounterpartyPurpose purpose;
  final RegExp? vpa;
  final RegExp? name;
}

/// A rule bundle prepared for matching: validated, regexes built, rules
/// indexed by brand and sorted. Compile once per bundle, never per message.
class CompiledBundle {
  CompiledBundle._(
    this.bundle,
    this.ignores,
    this._byBrand,
    this.generic,
    this.purposes,
    this.sendersByBrand,
  );

  /// Validates [bundle] and builds the matcher. Throws [BundleRefusedException]
  /// when the bundle breaks the contract, needs a newer engine, or holds a
  /// pattern this engine cannot compile.
  static CompiledBundle compile(RuleBundle bundle, {String engineVersion = smsEngineVersion}) {
    if (compareSemver(bundle.minEngineVersion, engineVersion) > 0) {
      throw BundleRefusedException(
        'engine_too_old',
        'bundle needs engine ${bundle.minEngineVersion}; this is $engineVersion',
      );
    }
    final v = bundle.validate();
    if (!v.ok) {
      throw BundleRefusedException('bundle_invalid', v.errors.take(5).join('; '));
    }

    final ignores = <CompiledIgnore>[];
    for (final r in bundle.ignoreRules) {
      try {
        ignores.add(CompiledIgnore(r, _compileRegex(r.pattern, r.flags)));
      } on FormatException catch (e) {
        throw BundleRefusedException('regex_invalid', 'ignore rule ${r.id}: ${e.message}');
      }
    }
    ignores.sort((a, b) => a.rule.id.compareTo(b.rule.id));

    final compiled = <CompiledRule>[];
    for (final r in bundle.rules) {
      if (r.status != RuleStatus.active && r.status != RuleStatus.provisional) continue;
      for (final e in r.emit) {
        for (final t in (e.counterparty?['transforms'] as List?) ?? const []) {
          if (!knownTransforms.contains(t)) {
            throw BundleRefusedException('transform_unknown', 'rule ${r.id}: transform $t');
          }
        }
      }
      try {
        compiled.add(CompiledRule(r, _compileRegex(r.match.pattern, r.match.flags)));
      } on FormatException catch (e) {
        throw BundleRefusedException('regex_invalid', 'rule ${r.id}: ${e.message}');
      }
    }

    int order(CompiledRule a, CompiledRule b) {
      final p = b.rule.priority.compareTo(a.rule.priority);
      if (p != 0) return p;
      // At equal priority a brand rule comes before a generic one.
      final ga = a.rule.senders.contains('*') ? 1 : 0;
      final gb = b.rule.senders.contains('*') ? 1 : 0;
      if (ga != gb) return ga.compareTo(gb);
      return a.rule.id.compareTo(b.rule.id);
    }

    final generic = [
      for (final c in compiled)
        if (c.rule.senders.contains('*')) c,
    ]..sort(order);
    final brands = <String>{
      for (final c in compiled)
        for (final s in c.rule.senders)
          if (s != '*') s,
    };
    final byBrand = <String, List<CompiledRule>>{
      for (final b in brands)
        b: [
          for (final c in compiled)
            if (c.rule.senders.contains(b) || c.rule.senders.contains('*')) c,
        ]..sort(order),
    };

    final purposes = <CompiledPurpose>[];
    for (final p in bundle.counterpartyPurposes) {
      try {
        purposes.add(CompiledPurpose(p));
      } on FormatException catch (e) {
        throw BundleRefusedException('regex_invalid', 'counterparty purpose ${p.id}: ${e.message}');
      }
    }

    return CompiledBundle._(
      bundle,
      List.unmodifiable(ignores),
      byBrand,
      List.unmodifiable(generic),
      List.unmodifiable(purposes),
      {for (final s in bundle.senders) s.brand: s},
    );
  }

  final RuleBundle bundle;
  final List<CompiledIgnore> ignores;
  final Map<String, List<CompiledRule>> _byBrand;

  /// Generic (`*`) rules, sorted.
  final List<CompiledRule> generic;
  final List<CompiledPurpose> purposes;
  final Map<String, SenderEntry> sendersByBrand;

  /// Rules to try for [brand], already merged with generic rules and sorted by
  /// priority descending, then id.
  List<CompiledRule> rulesFor(String brand) => _byBrand[brand] ?? generic;

  /// Normalises [sender] using this bundle's sender entries.
  NormalizedSender normalize(String sender) => normalizeSenderBrand(sender, bundle.senders);
}
