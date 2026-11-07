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
  s = s.replaceAll(RegExp(r'\s*\([^)]*\)\s*$'), '');
  s = s.replaceFirst(RegExp(r'^[A-Z]{2}-'), '');
  s = s.replaceFirst(RegExp(r'-[STPG]$'), '');
  return s;
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
  var s = body.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).join(' ');
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
    onNonMatch: (t) => t.replaceAll(RegExp(r'\d'), '#'),
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
