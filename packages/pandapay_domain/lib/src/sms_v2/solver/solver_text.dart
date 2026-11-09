// ignore_for_file: prefer_interpolation_to_compose_strings (the token pattern joins raw string pieces)
/// Text layer of the evidence solver: turns an SMS body into typed tokens and
/// matches pack phrases against them.
///
/// Everything here is mechanism. It contains no bank, wording or threshold
/// knowledge; that comes from the pack. All regular expressions are linear
/// (no nested quantifiers) so a hostile message cannot make them slow.
library;

enum TokKind { word, amt, mask, date, vpa, url, ref, num }

class Tok {
  const Tok({
    required this.kind,
    required this.text,
    required this.start,
    required this.end,
    required this.sentence,
    this.minor,
    this.unit,
    this.digits,
  });

  final TokKind kind;
  final String text;
  final int start;
  final int end;

  /// Index of the sentence this token is in; windows never cross it.
  final int sentence;

  /// For `amt`: the amount in minor units (paise / cents) and its currency.
  final int? minor;
  final String? unit;

  /// For `mask`: the digits shown.
  final String? digits;

  String get lower => text.toLowerCase();

  @override
  String toString() => '$kind:$text';
}

const _months =
    r'(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)(?![A-Za-z])';

final RegExp _tokenRe = RegExp(
  r'(?<url>https?://\S+|www\.\S+)'
          r'|(?<vpa>[A-Za-z0-9][\w.\-+*]*@[A-Za-z][\w\-]*)'
          r'|(?<amt>(?<![A-Za-z])(?<cur>rs\.?|inr|₹|usd|us\$|\$|eur|gbp|aed|sgd)\s*:?\s*(?<val>\d[\d,]*(?:\.\d+)?)(?:\s*/-)?)'
          // Currency AFTER the number: "12345INR", "500 Rs".
          r'|(?<amt2>(?<![\d.,])(?<val2>\d[\d,]*(?:\.\d+)?)\s?(?<cur2>inr|rs\.?|₹)(?![A-Za-z]))'
          r'|(?<date>\d{4}-\d{2}-\d{2}(?:[ T]\d{2}:\d{2}(?::\d{2})?)?'
          r'|\d{1,2}[-/.]\d{1,2}[-/.]\d{2,4}'
          r'|\d{1,2}[-\s]?' +
      _months +
      r'(?:[-\s,]*\d{2,4})?'
          r'|' +
      _months +
      r'\.?\s+\d{1,2}(?:,?\s*\d{4})?'
          r'|\d{1,2}/\d{1,2}(?!\d)'
          r'|\d{1,2}:\d{2}(?::\d{2})?)'
          r'|(?<mask>\d{2,6}[xX*]{2,}(?<m1>\d{2,6})'
          r'|(?<![A-Za-z0-9])[xX*•●]{1,12}[\s\-]?(?<m2>\d{2,6})(?!\d)'
          r'|(?<![A-Za-z])ending\s+(?:with\s+|in\s+)?(?<m3>\d{2,6})(?!\d))'
          r'|(?<ref>\d{6,})'
          r'|(?<num>\d+(?:[.,]\d+)*)'
          r'|(?<word>(?<![A-Za-z])a/c(?![A-Za-z])|[A-Za-z]+(?:[\-'
          "'"
          r'][A-Za-z]+)*)'
          r'|(?<punct>[.!?;])',
  caseSensitive: false,
);

/// Words that end in a full stop without ending the sentence ("Avl. Bal",
/// "No. 123"). The pack can add more; these are the universal ones.
const _abbrev = {
  'no',
  'avl',
  'bal',
  'rs',
  'txn',
  'amt',
  'ref',
  'dr',
  'cr',
  'pvt',
  'ltd',
  'co',
  'inc',
  'mr',
  'mrs',
  'ms',
  'a/c',
  'acct',
  'est',
  'approx',
  'info',
  'vs',
};

int? _minorOf(String val) {
  final cleaned = val.replaceAll(',', '');
  final parts = cleaned.split('.');
  final whole = int.tryParse(parts[0]);
  if (whole == null) return null;
  var frac = 0;
  if (parts.length > 1 && parts[1].isNotEmpty) {
    final f = parts[1].padRight(2, '0').substring(0, 2);
    frac = int.tryParse(f) ?? 0;
  }
  return whole * 100 + frac;
}

String _unitOf(String cur) {
  switch (cur.toLowerCase().replaceAll('.', '')) {
    case 'rs':
    case 'inr':
    case '₹':
      return 'INR';
    case 'usd':
    case 'us\$':
    case '\$':
      return 'USD';
    default:
      return cur.toUpperCase();
  }
}

/// The token stream of one message. Punctuation is not kept as tokens; it only
/// sets the [Tok.sentence] of the tokens after it.
class SolverText {
  SolverText._(this.body, this.toks);

  final String body;
  final List<Tok> toks;

  static const _accountCues = {'a/c', 'account', 'acct', 'ac'};
  static const _skipBeforeAccountNumber = {'no', 'number', 'num'};

  static SolverText parse(String body) {
    final raw = <Tok>[];
    var sentence = 0;
    for (final m in _tokenRe.allMatches(body)) {
      final start = m.start;
      final end = m.end;
      final text = body.substring(start, end);
      if (m.namedGroup('punct') != null) {
        if (text != '.') {
          sentence++;
        } else if (_dotEndsSentence(body, start, raw)) {
          sentence++;
        }
        continue;
      }
      Tok tok;
      if (m.namedGroup('url') != null) {
        tok = Tok(
          kind: TokKind.url,
          text: text,
          start: start,
          end: end,
          sentence: sentence,
        );
      } else if (m.namedGroup('vpa') != null) {
        tok = Tok(
          kind: TokKind.vpa,
          text: text,
          start: start,
          end: end,
          sentence: sentence,
        );
      } else if (m.namedGroup('amt2') != null) {
        tok = Tok(
          kind: TokKind.amt,
          text: text,
          start: start,
          end: end,
          sentence: sentence,
          minor: _minorOf(m.namedGroup('val2')!),
          unit: _unitOf(m.namedGroup('cur2')!),
        );
      } else if (m.namedGroup('amt') != null) {
        final val = m.namedGroup('val')!;
        tok = Tok(
          kind: TokKind.amt,
          text: text,
          start: start,
          end: end,
          sentence: sentence,
          minor: _minorOf(val),
          unit: _unitOf(m.namedGroup('cur')!),
        );
      } else if (m.namedGroup('date') != null) {
        tok = Tok(
          kind: TokKind.date,
          text: text,
          start: start,
          end: end,
          sentence: sentence,
        );
      } else if (m.namedGroup('mask') != null) {
        final d =
            m.namedGroup('m1') ??
            m.namedGroup('m2') ??
            m.namedGroup('m3') ??
            '';
        tok = Tok(
          kind: TokKind.mask,
          text: text,
          start: start,
          end: end,
          sentence: sentence,
          digits: d.length > 4 ? d.substring(d.length - 4) : d,
        );
      } else if (m.namedGroup('ref') != null) {
        tok = Tok(
          kind: TokKind.ref,
          text: text,
          start: start,
          end: end,
          sentence: sentence,
        );
      } else if (m.namedGroup('num') != null) {
        tok = Tok(
          kind: TokKind.num,
          text: text,
          start: start,
          end: end,
          sentence: sentence,
        );
      } else {
        tok = Tok(
          kind: TokKind.word,
          text: text,
          start: start,
          end: end,
          sentence: sentence,
        );
      }
      raw.add(tok);
    }
    return SolverText._(body, _promoteAccountNumbers(raw));
  }

  /// "A/c 9034" and "account no 12345678": a bare number right after an account
  /// word is a (partly shown) account number, so it becomes a mask.
  static List<Tok> _promoteAccountNumbers(List<Tok> toks) {
    final out = <Tok>[];
    for (var i = 0; i < toks.length; i++) {
      final t = toks[i];
      if ((t.kind == TokKind.num || t.kind == TokKind.ref) &&
          RegExp(r'^\d{4,}$').hasMatch(t.text)) {
        var j = out.length - 1;
        while (j >= 0 &&
            out.length - j <= 3 &&
            out[j].kind == TokKind.word &&
            _skipBeforeAccountNumber.contains(out[j].lower)) {
          j--;
        }
        if (j >= 0 &&
            out[j].kind == TokKind.word &&
            _accountCues.contains(out[j].lower)) {
          final d = t.text;
          out.add(
            Tok(
              kind: TokKind.mask,
              text: t.text,
              start: t.start,
              end: t.end,
              sentence: t.sentence,
              digits: d.length > 4 ? d.substring(d.length - 4) : d,
            ),
          );
          continue;
        }
      }
      out.add(t);
    }
    return out;
  }

  static bool _dotEndsSentence(String body, int at, List<Tok> before) {
    if (before.isEmpty) return false;
    final prev = before.last;
    if (prev.end != at) {
      return true; // "word ." with a gap is unusual; treat as end
    }
    if (prev.kind == TokKind.word && _abbrev.contains(prev.lower)) return false;
    // A dot between two words with no space ("Avl.Bal") is not an end.
    final next = at + 1 < body.length ? body[at + 1] : '';
    if (next.isNotEmpty &&
        next != ' ' &&
        next != '\n' &&
        next != '\r' &&
        next != '\t') {
      return false;
    }
    return true;
  }
}

// ---- phrases ----

class _Slot {
  _Slot(this.alts, {this.optional = false, this.skip = false});
  final Set<String> alts;
  final bool optional;
  final bool skip;

  bool matches(Tok t) {
    for (final a in alts) {
      if (a.startsWith('<')) {
        switch (a) {
          case '<amt>':
            if (t.kind == TokKind.amt) return true;
          case '<mask>':
            if (t.kind == TokKind.mask) return true;
          case '<date>':
            if (t.kind == TokKind.date) return true;
          case '<vpa>':
            if (t.kind == TokKind.vpa) return true;
          case '<ref>':
            if (t.kind == TokKind.ref || t.kind == TokKind.num) return true;
        }
      } else if (t.kind == TokKind.word) {
        final w = t.lower;
        if (w == a) return true;
        // "mandate-ICICI", "UPI-Mandate": a hyphenated word also matches on its parts.
        if (w.contains('-') && w.split('-').contains(a)) return true;
      }
    }
    return false;
  }
}

class PhraseHit {
  const PhraseHit(this.start, this.end);

  /// Token indexes, `end` exclusive.
  final int start;
  final int end;
}

/// One phrase of a pack lexicon. Syntax: space-separated slots. A slot is a word
/// or `a|b|c` alternatives, `<amt>` / `<mask>` / `<date>` / `<vpa>` / `<ref>`
/// for a typed token, `*` for "skip up to three tokens in the same sentence",
/// and a trailing `?` for optional. Slots are lower-case.
class Phrase {
  Phrase._(this.source, this._slots);

  final String source;
  final List<_Slot> _slots;

  static const maxSkip = 3;

  factory Phrase.parse(String source) {
    final slots = <_Slot>[];
    for (final raw in source.trim().split(RegExp(r'\s+'))) {
      if (raw.isEmpty) continue;
      if (raw == '*') {
        slots.add(_Slot({}, skip: true));
        continue;
      }
      var s = raw;
      var optional = false;
      if (s.length > 1 && s.endsWith('?')) {
        optional = true;
        s = s.substring(0, s.length - 1);
      }
      final alts = s.split('|').map((a) => a.toLowerCase()).toSet();
      // "t&c" style words are several tokens in the stream.
      if (alts.length == 1 && !s.startsWith('<')) {
        final pieces = SolverText.parse(s).toks;
        if (pieces.isEmpty) {
          throw FormatException(
            'phrase "$source": "$raw" can never match a token',
          );
        }
        if (pieces.length > 1) {
          for (final p in pieces) {
            slots.add(_Slot({p.lower}));
          }
          continue;
        }
      } else {
        // Every alternative is one placeholder or one plain word.
        for (final a in alts) {
          if (a.startsWith('<')) {
            if (!const {
              '<amt>',
              '<mask>',
              '<date>',
              '<vpa>',
              '<ref>',
            }.contains(a)) {
              throw FormatException('phrase "$source": unknown placeholder $a');
            }
            continue;
          }
          final pieces = SolverText.parse(a).toks;
          if (pieces.length != 1 ||
              pieces.first.kind != TokKind.word ||
              pieces.first.lower != a) {
            throw FormatException('phrase "$source": "$a" is not one word');
          }
        }
      }
      slots.add(_Slot(alts, optional: optional));
    }
    if (slots.isEmpty || slots.every((s) => s.skip || s.optional)) {
      throw FormatException('phrase "$source" has nothing to match');
    }
    if (slots.first.skip || slots.last.skip) {
      throw FormatException('phrase "$source" must not start or end with *');
    }
    return Phrase._(source, slots);
  }

  /// Every non-overlapping match, left to right.
  List<PhraseHit> findAll(List<Tok> toks) {
    final hits = <PhraseHit>[];
    var i = 0;
    while (i < toks.length) {
      final end = _matchAt(toks, i, 0);
      if (end != null && end > i) {
        hits.add(PhraseHit(i, end));
        i = end;
      } else {
        i++;
      }
    }
    return hits;
  }

  int? _matchAt(List<Tok> toks, int pos, int slot) {
    if (slot == _slots.length) return pos;
    final s = _slots[slot];
    if (s.skip) {
      // Try skipping 0..maxSkip tokens inside the sentence of the previous token.
      for (var k = 0; k <= maxSkip; k++) {
        final p = pos + k;
        if (p > toks.length) break;
        if (k > 0 &&
            p - 1 < toks.length &&
            pos < toks.length &&
            toks[p - 1].sentence != toks[pos].sentence) {
          break;
        }
        final r = _matchAt(toks, p, slot + 1);
        if (r != null) return r;
      }
      return null;
    }
    if (pos < toks.length && s.matches(toks[pos])) {
      final r = _matchAt(toks, pos + 1, slot + 1);
      if (r != null) return r;
    }
    if (s.optional) return _matchAt(toks, pos, slot + 1);
    return null;
  }
}

// ---- dates ----

/// A calendar date as printed in a message (no time zone: the sender's local day).
class SolverDate {
  const SolverDate(this.year, this.month, this.day);

  final int year;
  final int month;
  final int day;

  /// `YYYY-MM-DD`.
  String get iso =>
      '${year.toString().padLeft(4, '0')}-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}';

  DateTime get utcMidnight => DateTime.utc(year, month, day);

  @override
  bool operator ==(Object other) =>
      other is SolverDate &&
      other.year == year &&
      other.month == month &&
      other.day == day;

  @override
  int get hashCode => Object.hash(year, month, day);

  @override
  String toString() => iso;
}

const _monthNumbers = {
  'jan': 1,
  'feb': 2,
  'mar': 3,
  'apr': 4,
  'may': 5,
  'jun': 6,
  'jul': 7,
  'aug': 8,
  'sep': 9,
  'oct': 10,
  'nov': 11,
  'dec': 12,
};

final RegExp _isoDate = RegExp(r'(\d{4})-(\d{2})-(\d{2})');
final RegExp _dmyDate = RegExp(r'(\d{1,2})[-/.](\d{1,2})[-/.](\d{2,4})');
final RegExp _dMonDate = RegExp(
  r'(\d{1,2})[-\s]?([A-Za-z]{3})[A-Za-z]*(?:[-\s,]*(\d{2,4}))?',
);
final RegExp _monDDate = RegExp(
  r'([A-Za-z]{3})[A-Za-z]*\.?\s+(\d{1,2})(?:,?\s*(\d{4}))?',
);
final RegExp _dmDate = RegExp(r'^(\d{1,2})/(\d{1,2})$');

SolverDate? _checked(int y, int m, int d) {
  if (m < 1 || m > 12 || d < 1 || d > 31 || y < 2000 || y > 2100) return null;
  final t = DateTime.utc(y, m, d);
  if (t.month != m || t.day != d) return null;
  return SolverDate(y, m, d);
}

int _fullYear(String raw) {
  final n = int.parse(raw);
  return raw.length <= 2 ? 2000 + n : n;
}

/// Reads a `date` token as a calendar date, or null for a bare time of day.
/// Indian order (day first). A date with no year takes the year of [reference]
/// that puts it nearest to it: forward for a due date ([preferFuture]), else back.
SolverDate? parseSolverDate(
  String text,
  DateTime reference, {
  bool preferFuture = true,
}) {
  final s = text.trim();
  SolverDate? withoutYear(int m, int d) {
    final same = _checked(reference.year, m, d);
    if (same == null) return null;
    final ref = DateTime.utc(reference.year, reference.month, reference.day);
    if (preferFuture) {
      // A due date is never more than about three months behind the message.
      if (same.utcMidnight.isBefore(ref.subtract(const Duration(days: 90)))) {
        return _checked(reference.year + 1, m, d);
      }
    } else if (same.utcMidnight.isAfter(ref.add(const Duration(days: 30)))) {
      return _checked(reference.year - 1, m, d);
    }
    return same;
  }

  var m = _isoDate.firstMatch(s);
  if (m != null) {
    return _checked(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
  }
  m = _dmyDate.firstMatch(s);
  if (m != null) {
    return _checked(_fullYear(m[3]!), int.parse(m[2]!), int.parse(m[1]!));
  }
  m = _dmDate.firstMatch(s);
  if (m != null) return withoutYear(int.parse(m[2]!), int.parse(m[1]!));
  if (s.contains(':') && !RegExp(r'[A-Za-z]{3}').hasMatch(s)) return null;
  m = _dMonDate.firstMatch(s);
  if (m != null) {
    final mon = _monthNumbers[m[2]!.toLowerCase()];
    if (mon != null) {
      final d = int.parse(m[1]!);
      return m[3] != null
          ? _checked(_fullYear(m[3]!), mon, d)
          : withoutYear(mon, d);
    }
  }
  m = _monDDate.firstMatch(s);
  if (m != null) {
    final mon = _monthNumbers[m[1]!.toLowerCase()];
    if (mon != null) {
      final d = int.parse(m[2]!);
      return m[3] != null
          ? _checked(int.parse(m[3]!), mon, d)
          : withoutYear(mon, d);
    }
  }
  return null;
}
