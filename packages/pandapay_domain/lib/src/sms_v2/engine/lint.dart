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
  // Two branches of this group, or of a repeatable group inside, can start
  // matching at the same text. Under an unbounded quantifier that backtracks
  // exponentially, as in `(a|aa)+`.
  bool ambiguous = false;
  final List<String> alts = [];
  int segStart = 0;
}

final List<String> _sampleChars = [
  for (var code = 0; code < 128; code++) String.fromCharCode(code),
  '\u00e9',
  '\u20b9',
  '\u00a0',
];

/// First token of an alternative: an escape, a class, `.` or a literal
/// character. Null when the branch may start with something else (a group, an
/// optional first token, an anchor), which counts as overlapping.
String? _firstToken(String alt) {
  if (alt.isEmpty) return null;
  final String token;
  final c = alt[0];
  if (c == r'\') {
    if (alt.length < 2) return null;
    final end = alt[1] == 'x' ? 4 : (alt[1] == 'u' ? 6 : 2);
    token = alt.substring(0, end > alt.length ? alt.length : end);
  } else if (c == '[') {
    var j = 1;
    if (j < alt.length && alt[j] == '^') j++;
    if (j < alt.length && alt[j] == ']') j++;
    while (j < alt.length && alt[j] != ']') {
      j += alt[j] == r'\' ? 2 : 1;
    }
    if (j >= alt.length) return null;
    token = alt.substring(0, j + 1);
  } else if ('(*+?{|)^\$'.contains(c)) {
    return null;
  } else {
    token = String.fromCharCodes([alt.runes.first]);
  }
  final next = alt.substring(token.length, alt.length < token.length + 2 ? alt.length : token.length + 2);
  if (next.startsWith('?') || next.startsWith('*') || next.startsWith('{0')) return null;
  return token;
}

bool _tokensOverlap(String a, String b, String flags) {
  final RegExp ra, rb;
  try {
    ra = RegExp('^(?:$a)\$', caseSensitive: !flags.contains('i'), dotAll: flags.contains('s'));
    rb = RegExp('^(?:$b)\$', caseSensitive: !flags.contains('i'), dotAll: flags.contains('s'));
  } on FormatException {
    return true;
  }
  return _sampleChars.any((ch) => ra.hasMatch(ch) && rb.hasMatch(ch));
}

final RegExp _literalAlt = RegExp(r'^[^\\\[\](){}.*+?|^$]*$');

/// True when two branches of one group can both start matching at the same text.
bool _altConflict(List<String> alts, String flags) {
  if (alts.length < 2) return false;
  String fold(String x) => flags.contains('i') ? x.toLowerCase() : x;
  for (var i = 0; i < alts.length; i++) {
    for (var j = i + 1; j < alts.length; j++) {
      final x = alts[i], y = alts[j];
      if (x.isEmpty || y.isEmpty) return true;
      if (_literalAlt.hasMatch(x) && _literalAlt.hasMatch(y)) {
        if (fold(x).startsWith(fold(y)) || fold(y).startsWith(fold(x))) return true;
        continue;
      }
      final tx = _firstToken(x), ty = _firstToken(y);
      if (tx == null || ty == null || _tokensOverlap(tx, ty, flags)) return true;
    }
  }
  return false;
}

/// Checks that [pattern] behaves the same in JavaScript and Dart: named groups
/// and the flags `i`, `m`, `s` only; no backreferences, no variable-length
/// lookbehind, no nested quantifiers such as `(a+)+`, no constructs only one
/// of the two engines knows; no ambiguous alternation under an unbounded
/// quantifier such as `(a|aa)+` or `(\w|\d)+`, which backtrack exponentially
/// (`(x|y)*` with disjoint branches is fine); at most 2,000 characters. The
/// server's `lintPattern` (api/src/sms_v2/rules_admin_route.js) applies the
/// same rules.
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
      stack.add(_Group(kind)..segStart = i + skip);
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
      g.alts.add(pattern.substring(g.segStart, i));
      // Lookaround groups never repeat, so their alternation stays inside.
      g.ambiguous = !g.kind.startsWith('look') && (g.ambiguous || _altConflict(g.alts, flags));
      if (g.ambiguous) parent.ambiguous = true;
      if (g.kind == 'lookbehind' && g.hasVariable) {
        add('lint.regex.lookbehind_variable', 'lookbehind must have a fixed length');
      }
      lastGroup = g;
      i++;
      continue;
    }
    if (c == '|') {
      stack.last.hasVariable = true;
      stack.last.alts.add(pattern.substring(stack.last.segStart, i));
      stack.last.segStart = i + 1;
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
      if (lastGroup != null && lastGroup.ambiguous && unbounded) {
        add('lint.regex.nested_quantifier', 'an unbounded quantifier follows a group whose alternatives can start with the same text (backtracks exponentially, as in (a|aa)+); use a character class or a bounded count');
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

/// How wide a skip may be before a mask capture. A gap of a few characters
/// holds an introducer such as "no." or "ending"; anything wider can step over
/// words and land on another number.
const int maxMaskSkip = 6;

final RegExp _openSkipBeforeCapture = RegExp(
  r'(?:\[\^[^\]]*\]|\[\\s\\S\]|\[\\S\\s\]|\\S|\\W|\\D|\.)'
  r'(\{\d*,?\d*\}|\*|\+)\??'
  r'(?:\s|\\s\*|\(\?:[^()]*\)\??)*$',
);

/// True when the capture group [group] sits right behind a wide open skip (a
/// negated class, `.`, `\S`, ... repeated more than [maxMaskSkip] times).
///
/// A mask that follows such a skip can latch onto any number after the card
/// or account word: a reference, a UPI id, an amount. The digits printed after
/// "card ending from UPI CR ADJ" are not a card. A mask must be introduced by
/// a closed list of words (`ending`, `no`, `number`, ...) and mask characters.
bool maskFollowsOpenSkip(String pattern, String group) {
  final at = pattern.indexOf('(?<$group>');
  if (at <= 0) return false;
  final before = pattern.substring(at > 120 ? at - 120 : 0, at);
  final m = _openSkipBeforeCapture.firstMatch(before);
  if (m == null) return false;
  final q = m.group(1)!;
  if (q == '*' || q == '+') return true;
  final bounds = RegExp(r'^\{(\d*),?(\d*)\}$').firstMatch(q);
  if (bounds == null) return true;
  final hasComma = q.contains(',');
  final hi = hasComma ? bounds.group(2)! : bounds.group(1)!;
  if (hi.isEmpty) return true; // {n,} has no upper bound
  return int.parse(hi) > maxMaskSkip;
}
