// Lint core for rule patterns. The CLI `lint` command and the admin console
// both call this; neither re-implements it.

/// One lint finding.
class LintIssue {
  const LintIssue(this.code, this.message, {this.ruleId});

  /// Stable machine code, e.g. `lint.regex.backreference`.
  final String code;
  final String message;

  /// The rule (or ignore rule, link rule, ...) the finding belongs to.
  final String? ruleId;

  Map<String, Object?> toJson() => {
        'code': code,
        'message': message,
        if (ruleId != null) 'ruleId': ruleId,
      };

  @override
  String toString() => '${ruleId == null ? '' : '[$ruleId] '}$code: $message';
}

const int maxPatternLength = 2000;

class _Group {
  _Group(this.kind);
  final String kind; // capture, noncapture, lookahead, lookbehind, root
  bool hasUnbounded = false;
  bool hasVariable = false; // any quantifier that is not exactly-n, or an alternation
}

/// Checks that [pattern] behaves the same in JavaScript and Dart: named groups
/// and the flags `i`, `m`, `s` only; no backreferences, no variable-length
/// lookbehind, no nested quantifiers such as `(a+)+`, no constructs only one
/// of the two engines knows; at most 2,000 characters.
List<LintIssue> lintRegexDialect(String pattern, String flags, {String? ruleId}) {
  final out = <LintIssue>[];
  void add(String code, String message) => out.add(LintIssue(code, message, ruleId: ruleId));

  if (pattern.length > maxPatternLength) {
    add('lint.regex.too_long', 'pattern has ${pattern.length} characters; the limit is $maxPatternLength');
  }
  for (final f in flags.split('')) {
    if (!'ims'.contains(f)) add('lint.regex.flags', 'flag "$f" is not allowed; use only i, m, s');
  }
  if (flags.split('').toSet().length != flags.length) {
    add('lint.regex.flags', 'duplicate flag in "$flags"');
  }

  final stack = <_Group>[_Group('root')];
  _Group? lastGroup; // the group just closed, when the previous atom was a group
  var i = 0;
  final n = pattern.length;
  while (i < n) {
    final c = pattern[i];
    if (c == r'\') {
      if (i + 1 >= n) {
        add('lint.regex.invalid', 'pattern ends with a lone backslash');
        break;
      }
      final d = pattern[i + 1];
      if (RegExp('[1-9]').hasMatch(d)) {
        add('lint.regex.backreference', 'backreference \\$d is not allowed; use a named group instead of reusing a capture');
      } else if (d == 'k') {
        add('lint.regex.backreference', r'named backreference \k is not allowed');
      } else if ('AZzGhHRXQE'.contains(d)) {
        add('lint.regex.unsupported', '\\$d is not understood the same way in JavaScript and Dart');
      } else if (d == 'p' || d == 'P') {
        add('lint.regex.unsupported', '\\$d{...} needs the unicode flag, which is not allowed');
      }
      i += 2;
      lastGroup = null;
      continue;
    }
    if (c == '[') {
      var j = i + 1;
      if (j < n && pattern[j] == '^') j++;
      if (j < n && pattern[j] == ']') j++;
      while (j < n && pattern[j] != ']') {
        if (pattern[j] == r'\') j++;
        if (pattern.startsWith('[:', j)) {
          add('lint.regex.unsupported', 'POSIX class in a character class is not portable');
        }
        j++;
      }
      i = j + 1;
      lastGroup = null;
      continue;
    }
    if (c == '(') {
      String kind = 'capture';
      var skip = 1;
      if (pattern.startsWith('(?', i)) {
        if (pattern.startsWith('(?:', i)) {
          kind = 'noncapture';
          skip = 3;
        } else if (pattern.startsWith('(?=', i) || pattern.startsWith('(?!', i)) {
          kind = 'lookahead';
          skip = 3;
        } else if (pattern.startsWith('(?<=', i) || pattern.startsWith('(?<!', i)) {
          kind = 'lookbehind';
          skip = 4;
        } else if (RegExp(r'^\(\?<[A-Za-z_]\w*>').hasMatch(pattern.substring(i))) {
          kind = 'capture';
          skip = pattern.indexOf('>', i) - i + 1;
        } else {
          add('lint.regex.unsupported', 'group syntax "${pattern.substring(i, i + 3 > n ? n : i + 3)}" is not portable (no atomic groups, inline flags, conditionals or (?P<name>))');
          skip = 2;
        }
      }
      stack.add(_Group(kind));
      i += skip;
      lastGroup = null;
      continue;
    }
    if (c == ')') {
      if (stack.length == 1) {
        add('lint.regex.invalid', 'unbalanced ")"');
        i++;
        continue;
      }
      final g = stack.removeLast();
      final parent = stack.last;
      parent.hasUnbounded = parent.hasUnbounded || g.hasUnbounded;
      parent.hasVariable = parent.hasVariable || g.hasVariable;
      if (g.kind == 'lookbehind' && g.hasVariable) {
        add('lint.regex.lookbehind_variable', 'lookbehind must have a fixed length');
      }
      lastGroup = g;
      i++;
      continue;
    }
    if (c == '|') {
      stack.last.hasVariable = true;
      i++;
      lastGroup = null;
      continue;
    }
    // Quantifiers.
    int? qMin;
    int? qMax; // null = unbounded
    var qLen = 0;
    if (c == '*') {
      qMin = 0;
      qLen = 1;
    } else if (c == '+') {
      qMin = 1;
      qLen = 1;
    } else if (c == '?') {
      qMin = 0;
      qMax = 1;
      qLen = 1;
    } else if (c == '{') {
      final m = RegExp(r'^\{(\d+)(?:(,)(\d*))?\}').firstMatch(pattern.substring(i));
      if (m != null) {
        qMin = int.parse(m.group(1)!);
        if (m.group(2) == null) {
          qMax = qMin;
        } else if (m.group(3)!.isNotEmpty) {
          qMax = int.parse(m.group(3)!);
        }
        qLen = m.group(0)!.length;
      }
    }
    if (qLen > 0) {
      final unbounded = qMax == null;
      final variable = unbounded || qMin != qMax;
      if (lastGroup != null && lastGroup.hasUnbounded && (unbounded || qMax > 1)) {
        add('lint.regex.nested_quantifier', 'a quantified group contains an unbounded quantifier (nested quantifier such as (a+)+)');
      }
      final top = stack.last;
      if (unbounded) top.hasUnbounded = true;
      if (variable) top.hasVariable = true;
      i += qLen;
      // Lazy "?" is fine; a possessive "+" is not portable.
      if (i < n && pattern[i] == '?') {
        i++;
      } else if (i < n && pattern[i] == '+') {
        add('lint.regex.unsupported', 'possessive quantifier is not portable');
        i++;
      }
      lastGroup = null;
      continue;
    }
    i++;
    lastGroup = null;
  }
  if (stack.length > 1) add('lint.regex.invalid', 'unbalanced "("');

  try {
    RegExp(pattern,
        caseSensitive: !flags.contains('i'),
        multiLine: flags.contains('m'),
        dotAll: flags.contains('s'));
  } on FormatException catch (e) {
    add('lint.regex.invalid', 'pattern does not compile: ${e.message}');
  }
  return out;
}

final RegExp _groupNameInPattern = RegExp(r'\(\?<([A-Za-z_]\w*)>');

/// Names of the named groups declared in [pattern].
Set<String> patternGroupNames(String pattern) =>
    {for (final m in _groupNameInPattern.allMatches(pattern)) m.group(1)!};
