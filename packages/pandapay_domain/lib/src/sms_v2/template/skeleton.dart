import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Sender brand used for template identity: upper case, with an iOS filter tag
/// such as `(smsft_fi)` removed, a 2-letter operator prefix (`VM-`) removed and
/// a `-S`, `-T`, `-P` or `-G` suffix removed.
///
/// WP-03's `normalizeSenderBrand` in `engine/` is the production
/// implementation; this one only exists so templates can be hashed before the
/// engine lands, and must agree with it.
String smsTemplateBrand(String sender) {
  var s = sender.trim().toUpperCase();
  s = s.replaceAll(_iosTag, '');
  s = s.replaceFirst(_operatorPrefix, '');
  s = s.replaceFirst(_operatorSuffix, '');
  return s;
}

final RegExp _iosTag = RegExp(r'\s*\([^)]*\)\s*$');
final RegExp _operatorPrefix = RegExp(r'^[A-Z]{2}-');
final RegExp _operatorSuffix = RegExp(r'-[STPG]$');
final RegExp _spaces = RegExp(r'\s+');
final RegExp _anyDigit = RegExp(r'\d');

/// The most name or removed-word slots (`<PARTY>`, `<W>`, or a tag this build does not know) a layout may hold.
/// The server refuses a layout with more (`MAX_WILDCARDS` in api/src/sms_v2/layout_matcher.js, checked against the
/// shared fixture `layout_corpus.json`), so the phone does not spend an upload slot on one.
const int smsMaxLayoutWildcards = 4;

/// The most loose slots (names, removed words, phone numbers, unknown tags) a layout may hold with only spaces between
/// them (`MAX_ADJACENT_LOOSE`; the server refuses more as `layout_adjacent_wildcards`).
const int smsMaxAdjacentLooseSlots = 2;

final RegExp _layoutTag = RegExp(r'<([A-Z][A-Z_]*)>');
const Set<String> _strictSlotKinds = {'AMT', 'DATE', 'MASK', 'REF', 'EMAIL', 'VPA', 'URL'};
const Set<String> _fixedSlotKinds = {..._strictSlotKinds, 'PHONE'};

/// How many wildcard slots [layout] has: every tag that is not one of the fixed value kinds. Same rule as the
/// server's matcher, which reads an unknown tag as a name too.
int smsLayoutWildcards(String layout) {
  var count = 0;
  for (final m in _layoutTag.allMatches(layout)) {
    if (!_fixedSlotKinds.contains(m[1])) count++;
  }
  return count;
}

/// The longest run of loose slots in [layout] with nothing but spaces between them. A phone number counts as loose here
/// (its pattern backtracks like a name), as in the server's matcher.
int smsLayoutLooseRun(String layout) {
  var best = 0, run = 0, end = 0;
  for (final m in _layoutTag.allMatches(layout)) {
    if (layout.substring(end, m.start).trim().isNotEmpty) run = 0;
    run = _strictSlotKinds.contains(m[1]) ? 0 : run + 1;
    if (run > best) best = run;
    end = m.end;
  }
  return best;
}

final RegExp _url = RegExp(
  r'https?://\S+|\bwww\.\S+|\b[a-z0-9-]+\.(?:com|in|co|io|ly|me|net|org)(?:/\S*)?',
  caseSensitive: false,
);
// The part before the @ may be partly hidden by the bank (`ab***@gmail.com`), so the hiding characters count too.
final RegExp _vpa = RegExp(r'[\w.\-+*•●]+@[\w.\-]+');
final RegExp _prefixedAmount = RegExp(
  r'(?<![A-Za-z])(?:rs\.?|inr|₹)\s*\d[\d,]*(?:\.\d+)?(?:\s*/-)?',
  caseSensitive: false,
);
final RegExp _date = RegExp(
  r'(?<!\d)(?:'
  r'\d{4}-\d{2}-\d{2}(?::\d{2}:\d{2}:\d{2}|[T ]\d{2}:\d{2}:\d{2})?'
  r'|\d{1,2}[-/.]\d{1,2}[-/.]\d{2,4}'
  r'|\d{1,2}[\s-]?(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*[\s,-]*\d{2,4}'
  r')(?!\d)'
  r'|(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+\d{1,2},?\s+\d{2,4}(?!\d)',
  caseSensitive: false,
);
final RegExp _bareAmount = RegExp(
  r'(?<![\w.])(?:\d{1,3}(?:,\d{2,3})+(?:\.\d{1,2})?|\d+\.\d{1,2})(?![\w])',
);
final RegExp _mask = RegExp(
  r'(?<![A-Za-z0-9])(?:[xX*•●·]{1,12}|\.{2,})\d{2,6}(?!\d)'
  r'|(?<![A-Za-z0-9])\d{2,6}[xX*•●·]{2,12}\d{2,6}(?!\d)'
  r'|\bending(?:\s+(?:with|in))?\s+\d{2,6}(?!\d)',
  caseSensitive: false,
);
final RegExp _ref = RegExp(r'(?<!\d)\d{6,}(?!\d)');
final RegExp _placeholder = RegExp(r'<[A-Z_]+>');
final RegExp _word = RegExp(r"<[A-Z_]+>|[A-Za-z][A-Za-z']*");
final RegExp _wordRuns = RegExp(r'<W>(?:[ ]+<W>)+');

/// Builds the skeleton of a message body.
///
/// Amounts become `<AMT>`, dates `<DATE>`, masks `<MASK>`, UPI IDs and emails
/// `<VPA>`, URLs `<URL>`, digit runs of 6 or more `<REF>` and every other
/// digit `#`. Placeholders already present (from redaction) are kept.
String smsSkeleton(String body) {
  var s = body.split(_spaces).where((w) => w.isNotEmpty).join(' ');
  // Emails first: `ab***@gmail.com` must not be left as `ab***@<URL>`, which still carries an address.
  s = s.replaceAll(_vpa, '<VPA>');
  s = s.replaceAll(_url, '<URL>');
  s = s.replaceAll(_prefixedAmount, '<AMT>');
  s = s.replaceAll(_date, '<DATE>');
  s = s.replaceAll(_bareAmount, '<AMT>');
  s = s.replaceAllMapped(_mask, (m) => '<MASK>');
  s = s.replaceAll(_ref, '<REF>');
  // Keep placeholders intact, replace every remaining digit.
  s = s.splitMapJoin(
    _placeholder,
    onMatch: (m) => m[0]!,
    onNonMatch: (t) => t.replaceAll(_anyDigit, '#'),
  );
  return s;
}

final RegExp _digit = RegExp(r'\d');
final RegExp _addressOrLink = RegExp(r'@|https?://', caseSensitive: false);

/// True when [skeleton] may leave the phone as a shared template: no digit, no `@` and no link survive, and it is
/// not huge. The server applies the same rule and refuses a case whose template breaks it, so the phone checks
/// first and sends the correction without the template instead of having the whole correction refused.
bool smsSkeletonIsShareable(String skeleton) =>
    skeleton.isNotEmpty &&
    skeleton.length <= 20000 &&
    !_digit.hasMatch(skeleton) &&
    !_addressOrLink.hasMatch(skeleton);

final RegExp _threeDigits = RegExp(r'\d{3,}');
final RegExp _wwwLink = RegExp(r'\bwww\.', caseSensitive: false);

/// The message for the AI to read the wording of: [redacted] (every number made up by [redactSms], names hidden,
/// links and addresses gone) with its spaces collapsed, or null when anything of [original] could still be in it.
///
/// A run of 3 or more digits of the original (an amount, an account or a reference number) must not appear in the
/// result, whatever it is part of; years are public, so dates are not looked at. This is a guard on [redactSms],
/// which already changes every one of them: a mistake there sends the layout alone, never the wording.
String? smsSample({required String original, required String redacted}) {
  final text = redacted.split(_spaces).where((w) => w.isNotEmpty).join(' ');
  if (text.isEmpty || text.length > 2000) return null;
  if (_addressOrLink.hasMatch(text) || _wwwLink.hasMatch(text) || _url.hasMatch(text)) return null;
  for (final run in _threeDigits.allMatches(original.replaceAll(_date, ' '))) {
    if (text.contains(run[0]!)) return null;
  }
  return text;
}

/// Counts, for each lower-case word, how many of [skeletons] contain it.
Map<String, int> skeletonWordFrequency(Iterable<String> skeletons) {
  final df = <String, int>{};
  for (final sk in skeletons) {
    final seen = <String>{};
    for (final m in _word.allMatches(sk)) {
      final t = m[0]!;
      if (t.startsWith('<')) continue;
      seen.add(t.toLowerCase());
    }
    for (final w in seen) {
      df[w] = (df[w] ?? 0) + 1;
    }
  }
  return df;
}

/// Replaces every word seen in fewer than [minMessages] messages (by
/// [wordFrequency]) with `<W>`, and collapses runs of `<W>`. This is what
/// turns merchant and person names into placeholders when clustering.
String coarsenSkeleton(
  String skeleton,
  Map<String, int> wordFrequency, {
  int minMessages = 5,
}) {
  final out = skeleton.replaceAllMapped(_word, (m) {
    final t = m[0]!;
    if (t.startsWith('<')) return t;
    return (wordFrequency[t.toLowerCase()] ?? 0) < minMessages ? '<W>' : t;
  });
  return out.replaceAll(_wordRuns, '<W>');
}

/// `sha256(brand + "\n" + skeleton)` as lower-case hex.
String smsTemplateHash(String brand, String skeleton) =>
    sha256.convert(utf8.encode('$brand\n$skeleton')).toString();
