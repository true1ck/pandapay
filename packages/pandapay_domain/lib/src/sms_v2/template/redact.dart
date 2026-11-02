import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'vocabulary.dart';

/// Options for [redactSms].
class SmsRedactionOptions {
  SmsRedactionOptions({
    required this.salt,
    Set<String>? merchantCatalogue,
    this.dateShiftDays,
  }) : merchantCatalogue = merchantCatalogue ?? smsMerchantCatalogue;

  /// Mixed into every synthetic value. Use a fresh random salt per run so the
  /// output cannot be mapped back; use a fixed one in tests.
  final String salt;

  /// Lower-case merchant names (one entry per phrase) that may survive.
  final Set<String> merchantCatalogue;

  /// Days added to every date and to `observedAt`. Derived from [salt]
  /// (7 to 89 days) when null. One value per run keeps the order and spacing
  /// of messages, so multi-message scenarios still line up.
  final int? dateShiftDays;

  int get shiftDays => dateShiftDays ?? 7 + (_hashInt('$salt|shift') % 83);
}

/// A message after [redactSms].
class RedactedSms {
  const RedactedSms({
    required this.sender,
    required this.body,
    required this.observedAt,
  });

  final String sender;
  final String body;
  final DateTime observedAt;
}

const String _dateCore =
    r'\d{4}-\d{2}-\d{2}(?::\d{2}:\d{2}:\d{2}|[T ]\d{2}:\d{2}:\d{2})?'
    r'|\d{1,2}[-/.]\d{1,2}[-/.]\d{2,4}'
    r'|\d{1,2}[\s-]?(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*[\s,-]*\d{2,4}';

final RegExp _pass1 = RegExp(
  r'(?<email>[\w.\-+]+@[\w.\-]+)'
  r'|(?<url>https?://\S+|\bwww\.\S+|\b[a-z0-9-]+\.(?:com|in|co|io|ly|me|net|org)(?![A-Za-z])(?:/\S*)?)'
  '|(?<date>(?<!\\d)(?:$_dateCore)(?!\\d)'
  r'|(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+\d{1,2},?\s+\d{2,4}(?!\d))'
  r'|(?<amt>(?<![A-Za-z])(?:rs\.?|inr|₹)\s*\d[\d,]*(?:\.\d+)?(?:\s*/-)?'
  r'|(?<=\b(?:bal|balance|lmt|limit|amt|amount|due|outstanding|total)[\s.:\-]{1,3})\d[\d,]*(?:\.\d+)?'
  r'|(?<![\w.])(?:\d{1,3}(?:,\d{2,3})+(?:\.\d{1,2})?|\d+\.\d{1,2})(?![\w]))'
  r'|(?<phone>(?<!\d)(?<!(?:ref|utr|umrn|txn|id|no|rrn)[\s.:#\-]{0,4})'
  r'(?:(?:\+?91[\s-]?)?[6-9]\d{4}[\s-]?\d{5}|18[06]0[\s-]?\d{3,4}(?:[\s-]?\d{3,4})?|0\d{2,4}[\s-]?\d{6,8})(?!\d))'
  r'|(?<mask>(?<![A-Za-z0-9])(?:[xX*•●·]{1,12}|\.{2,})\d{2,6}(?!\d)'
  r'|\bending(?:\s+(?:with|in))?\s+\d{2,6}(?!\d))'
  r'|(?<dig>(?<!\d)\d{4,}(?!\d))',
  caseSensitive: false,
);

final RegExp _nameToken = RegExp(r"<[A-Z_]+>|[A-Za-z][A-Za-z0-9'&]*");

const List<String> _monthAbbr = [
  'jan', 'feb', 'mar', 'apr', 'may', 'jun',
  'jul', 'aug', 'sep', 'oct', 'nov', 'dec',
];
const List<String> _monthFull = [
  'january', 'february', 'march', 'april', 'may', 'june',
  'july', 'august', 'september', 'october', 'november', 'december',
];

int _hashInt(String s) {
  final d = sha256.convert(utf8.encode(s)).bytes;
  return (d[0] << 24 | d[1] << 16 | d[2] << 8 | d[3]) & 0x7fffffff;
}

class _Ctx {
  _Ctx(this.rnd, this.shift, this.options);

  final Random rnd;
  final int shift;
  final SmsRedactionOptions options;
  final Map<String, String> memo = {};

  /// Replaces every digit of [text] with a different digit, keeping every other
  /// character, and returns the same result for the same [text] in one message.
  String synth(String text, {bool nonZeroLead = false}) {
    return memo.putIfAbsent('$nonZeroLead|$text', () {
      final sb = StringBuffer();
      var first = true;
      for (final ch in text.split('')) {
        final code = ch.codeUnitAt(0);
        if (code < 48 || code > 57) {
          sb.write(ch);
          continue;
        }
        final d = code - 48;
        int n;
        do {
          n = rnd.nextInt(10);
        } while (n == d || (first && nonZeroLead && n == 0));
        first = false;
        sb.write(n);
      }
      return sb.toString();
    });
  }
}

/// Redacts one SMS so that no original name, number, amount or date survives
/// while the shape of the message (formats, wording, separators) is kept.
///
/// - Phone numbers, URLs and emails become `<PHONE>`, `<URL>`, `<EMAIL>`.
///   A UPI ID survives only when every part of its name is a known word or
///   catalogue merchant (for example `add-money@paytm`); otherwise `<VPA>`.
/// - Every digit run of 4 or more characters, and every account mask
///   (`XX1234`, `ending 5678`), gets synthetic digits of the same length,
///   consistent within the message.
/// - Amounts keep their printed format (`Rs.`, `INR`, `₹`, commas, decimals)
///   but get synthetic values.
/// - Dates keep their format and move by [SmsRedactionOptions.shiftDays];
///   `observedAt` moves by the same amount.
/// - Person and party names become `<PARTY>`. A merchant survives only when it
///   is in [SmsRedactionOptions.merchantCatalogue].
RedactedSms redactSms({
  required String sender,
  required String body,
  required DateTime observedAt,
  required SmsRedactionOptions options,
}) {
  final shift = options.shiftDays;
  final seed = _hashInt('${options.salt}|$sender|${observedAt.toIso8601String()}|$body');
  final ctx = _Ctx(Random(seed), shift, options);

  var text = body.replaceAllMapped(_pass1, (m) => _replacePass1(m as RegExpMatch, ctx));
  text = _redactNames(text, options);

  final digitsInSender = RegExp(r'\d').allMatches(sender).length;
  final outSender = digitsInSender >= 7 ? '<PHONE>' : sender;
  return RedactedSms(
    sender: outSender,
    body: text,
    observedAt: observedAt.toUtc().add(Duration(days: shift)),
  );
}

String _replacePass1(RegExpMatch m, _Ctx ctx) {
  final all = m[0]!;
  if (m.namedGroup('email') != null) return _replaceEmailOrVpa(all, ctx.options);
  if (m.namedGroup('url') != null) return '<URL>';
  if (m.namedGroup('date') != null) {
    return _shiftDate(all, ctx.shift) ?? _digitRuns(all, ctx);
  }
  if (m.namedGroup('phone') != null) return '<PHONE>';
  if (m.namedGroup('amt') != null || m.namedGroup('mask') != null) {
    final i = all.indexOf(RegExp(r'\d'));
    if (i < 0) return all;
    final isMask = m.namedGroup('mask') != null;
    final prefix = all.substring(0, i);
    final number = all.substring(i);
    return prefix + ctx.synth(number, nonZeroLead: !isMask);
  }
  return ctx.synth(all, nonZeroLead: true);
}

String _digitRuns(String text, _Ctx ctx) =>
    text.replaceAllMapped(RegExp(r'\d{4,}'), (m) => ctx.synth(m[0]!));

String _replaceEmailOrVpa(String text, SmsRedactionOptions o) {
  final at = text.indexOf('@');
  final local = text.substring(0, at);
  final domain = text.substring(at + 1);
  if (domain.contains('.')) return '<EMAIL>';
  if (RegExp(r'\d').hasMatch(local)) return '<VPA>';
  final parts = local
      .toLowerCase()
      .split(RegExp(r'[._\-+]'))
      .where((p) => p.isNotEmpty)
      .toList();
  if (parts.isEmpty) return '<VPA>';
  final known = {...smsTemplateVocabulary, ...o.merchantCatalogue};
  final allKnown = parts.every(known.contains);
  return allKnown ? text : '<VPA>';
}

String? _shiftDate(String text, int shift) {
  String pad2(int v) => v.toString().padLeft(2, '0');
  DateTime? valid(int y, int mo, int d) {
    if (mo < 1 || mo > 12 || d < 1 || d > 31) return null;
    final dt = DateTime.utc(y, mo, d);
    return dt.month == mo && dt.day == d ? dt : null;
  }

  int fullYear(String s) {
    final v = int.parse(s);
    return s.length == 2 ? 2000 + v : v;
  }

  String yearOut(DateTime dt, String original) =>
      original.length == 2 ? pad2(dt.year % 100) : dt.year.toString();

  String dayOut(DateTime dt, String original) =>
      original.length >= 2 ? pad2(dt.day) : dt.day.toString();

  String monthName(DateTime dt, String original) {
    final lower = original.toLowerCase();
    final full = lower.length > 3 && lower != 'sept';
    var name = full ? _monthFull[dt.month - 1] : _monthAbbr[dt.month - 1];
    if (original == original.toUpperCase()) {
      name = name.toUpperCase();
    } else if (original[0] == original[0].toUpperCase()) {
      name = name[0].toUpperCase() + name.substring(1);
    }
    return name;
  }

  int? monthIndex(String name) {
    final l = name.toLowerCase();
    final a = _monthAbbr.indexOf(l);
    if (a >= 0) return a + 1;
    final f = _monthFull.indexOf(l);
    if (f >= 0) return f + 1;
    if (l == 'sept') return 9;
    return null;
  }

  var m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})(.*)$', dotAll: true).firstMatch(text);
  if (m != null) {
    final dt = valid(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
    if (dt == null) return null;
    final s = dt.add(Duration(days: shift));
    return '${s.year}-${pad2(s.month)}-${pad2(s.day)}${m[4]}';
  }
  m = RegExp(r'^(\d{1,2})([-/.])(\d{1,2})([-/.])(\d{2,4})$').firstMatch(text);
  if (m != null) {
    if (m[5]!.length == 3) return null;
    final dt = valid(fullYear(m[5]!), int.parse(m[3]!), int.parse(m[1]!));
    if (dt == null) return null;
    final s = dt.add(Duration(days: shift));
    final mo = m[3]!.length >= 2 ? pad2(s.month) : s.month.toString();
    return '${dayOut(s, m[1]!)}${m[2]}$mo${m[4]}${yearOut(s, m[5]!)}';
  }
  m = RegExp(r'^(\d{1,2})([\s-]?)([A-Za-z]+)([\s,-]*)(\d{2,4})$').firstMatch(text);
  if (m != null) {
    final mo = monthIndex(m[3]!);
    if (mo == null || m[5]!.length == 3) return null;
    final dt = valid(fullYear(m[5]!), mo, int.parse(m[1]!));
    if (dt == null) return null;
    final s = dt.add(Duration(days: shift));
    return '${dayOut(s, m[1]!)}${m[2]}${monthName(s, m[3]!)}${m[4]}${yearOut(s, m[5]!)}';
  }
  m = RegExp(r'^([A-Za-z]+)(\.?\s+)(\d{1,2})(,?\s+)(\d{2,4})$').firstMatch(text);
  if (m != null) {
    final mo = monthIndex(m[1]!);
    if (mo == null || m[5]!.length == 3) return null;
    final dt = valid(fullYear(m[5]!), mo, int.parse(m[3]!));
    if (dt == null) return null;
    final s = dt.add(Duration(days: shift));
    return '${monthName(s, m[1]!)}${m[2]}${dayOut(s, m[3]!)}${m[4]}${yearOut(s, m[5]!)}';
  }
  return null;
}

class _Word {
  _Word(this.start, this.end, this.text)
    : lower = text.toLowerCase(),
      key = text.toLowerCase().replaceFirst(RegExp(r'\d+$'), ''),
      hasDigit = RegExp(r'\d').hasMatch(text),
      isCap = text[0] == text[0].toUpperCase();

  final int start;
  final int end;
  final String text;
  final String lower;
  final String key;
  final bool hasDigit;
  final bool isCap;
  bool protected = false;
  bool replace = false;
}

final RegExp _nameGap = RegExp(r'^[\s:.\-,]{0,3}$');
final RegExp _runGap = RegExp(r'^(?: |\.|-| ?& ?)$');

String _redactNames(String text, SmsRedactionOptions o) {
  final words = <_Word>[];
  for (final m in _nameToken.allMatches(text)) {
    final t = m[0]!;
    if (t.startsWith('<')) continue;
    words.add(_Word(m.start, m.end, t));
  }
  if (words.isEmpty) return text;

  bool adjacent(int i, int j, RegExp gap) =>
      j < words.length && gap.hasMatch(text.substring(words[i].end, words[j].start));

  // Catalogue merchants are protected, longest phrase first.
  for (var i = 0; i < words.length; i++) {
    for (var len = 3; len >= 1; len--) {
      if (i + len > words.length) continue;
      var ok = true;
      for (var k = 0; k < len - 1; k++) {
        if (!RegExp(r'^ $').hasMatch(text.substring(words[i + k].end, words[i + k + 1].start))) {
          ok = false;
          break;
        }
      }
      if (!ok) continue;
      final phrase = words.sublist(i, i + len).map((w) => w.lower).join(' ');
      if (o.merchantCatalogue.contains(phrase)) {
        for (var k = 0; k < len; k++) {
          words[i + k].protected = true;
        }
        break;
      }
    }
  }

  bool known(_Word w) =>
      smsTemplateVocabulary.contains(w.lower) ||
      smsTemplateVocabulary.contains(w.key) ||
      o.merchantCatalogue.contains(w.key);

  bool accept(_Word w) {
    if (w.protected || w.replace) return false;
    if (w.hasDigit && w.key.length < 4) return false;
    if (smsStructuralWords.contains(w.key)) return false;
    return !known(w);
  }

  // Names after a trigger word.
  for (var i = 0; i < words.length; i++) {
    if (!smsNameTriggers.contains(words[i].lower)) continue;
    var j = i + 1;
    var taken = 0;
    final run = <_Word>[];
    while (j < words.length && taken < 5) {
      final gapOk = adjacent(j - 1, j, taken == 0 ? _nameGap : _runGap);
      if (!gapOk) break;
      final w = words[j];
      if (smsTitles.contains(w.lower) && taken == 0) {
        run.add(w);
        j++;
        continue;
      }
      if (!accept(w)) break;
      run.add(w);
      taken++;
      j++;
    }
    if (taken > 0) {
      for (final w in run) {
        w.replace = true;
      }
    }
  }

  // Safety net: any other capitalised word that is not known text.
  for (final w in words) {
    if (w.protected || w.replace || !w.isCap) continue;
    if (w.hasDigit && w.key.length < 4) continue;
    if (known(w)) continue;
    w.replace = true;
  }

  // Merge neighbouring replaced words into one <PARTY>, right to left.
  final spans = <List<int>>[];
  for (var i = 0; i < words.length; i++) {
    if (!words[i].replace) continue;
    var s = words[i].start;
    var e = words[i].end;
    while (i + 1 < words.length && words[i + 1].replace && adjacent(i, i + 1, _runGap)) {
      i++;
      e = words[i].end;
    }
    spans.add([s, e]);
  }
  var out = text;
  for (final s in spans.reversed) {
    out = out.replaceRange(s[0], s[1], '<PARTY>');
  }
  return out;
}
