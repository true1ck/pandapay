// Lane D guard: merchant, bank and brand names are DATA (rule bundles, the
// merchant catalogue), never code. This test fails when non-test Dart under
//   packages/pandapay_domain/lib/src/sms_v2   and   app/lib/features/sms_v2
// names a brand in a string literal or an identifier. Comments are ignored.
//
// To add an exception, add a _Allow entry below WITH a reason. Prefer moving
// the name into a rule or catalogue entry instead.
//
// Fast: one pass over ~100 source files, no I/O besides reading them.
import 'dart:io';

import 'package:test/test.dart';

/// Names that must not appear in classification code. Lower case, matched at
/// the start of a word (so `hdfcbk`, `paytmqr` and `sbiupi` are caught), except
/// entries ending in `$`, which must also end on a word boundary. Words that
/// are also ordinary English or Flutter vocabulary (axis, apple, prime, slice,
/// yes, union, cred, ola, ...) are deliberately not listed bare.
const List<String> _brands = [
  // banks and card networks
  'hdfc', 'icici', 'sbi', 'kotak', 'idfc', 'indusind', 'hsbc', 'amex',
  'american express', 'rbl', 'canara', 'pnb', 'bandhan', 'axis bank', 'axisbk',
  'yes bank', 'bank of baroda', 'federal bank', 'standard chartered',
  'citibank', 'citi bank', 'citi\$', 'au small finance', 'idbi', 'bob card',
  // wallets, UPI apps, gateways
  'paytm', 'phonepe', 'phonpe', 'gpay', 'googpay', 'google pay', 'bhim',
  'mobikwik', 'freecharge', 'amazon pay', 'zomato money', 'ola money',
  'bharatpe', 'razorpay', 'juspay', 'payu', 'billdesk', 'cashfree', 'ccavenue',
  'instamojo', 'pinelabs', 'ezeepay', 'airpay', 'paykun', 'zaakpay',
  'citruspay', 'pluxee', 'sodexo',
  // merchants and services
  'swiggy', 'zomato', 'instamart', 'blinkit', 'zepto', 'bigbasket', 'dunzo',
  'amazon', 'flipkart', 'myntra', 'ajio', 'nykaa', 'meesho', 'netflix',
  'spotify', 'hotstar', 'disney', 'youtube', 'google play', 'apple services',
  'uber', 'rapido', 'irctc', 'makemytrip', 'goibibo', 'cleartrip', 'redbus',
  'bookmyshow', 'groww', 'zerodha', 'upstox', 'jio', 'airtel', 'vodafone',
  'bsnl', 'tata power', 'dmart', 'reliance', 'croma', 'decathlon', 'ikea',
  'lenskart', 'pharmeasy', 'apollo', 'practo', 'starbucks', 'mcdonald',
  'dominos', 'kfc', 'haldiram', 'westside', 'pantaloons', 'adidas', 'nike',
  'puma',
];

class _Allow {
  const _Allow(this.file, this.reason, {this.tokens, this.debt = false});

  /// Path relative to the repository root.
  final String file;

  /// Why this file may name brands.
  final String reason;

  /// Null allows any brand in the file; otherwise only these (prefix match).
  final Set<String>? tokens;

  /// True for tolerated debt that should move to data; reported, not hidden.
  final bool debt;
}

const _roots = [
  'packages/pandapay_domain/lib/src/sms_v2',
  'app/lib/features/sms_v2',
];

const _allow = <_Allow>[
  _Allow(
    'packages/pandapay_domain/lib/src/sms_v2/template/vocabulary.dart',
    'Redaction vocabulary: a safety net of ordinary template words and '
        'well-known brands that are NOT personal names, so the redactor keeps '
        'them and replaces everything else. It never classifies a message.',
  ),
  _Allow(
    'packages/pandapay_domain/lib/src/sms_v2/evaluation/family.dart',
    'Evaluation-only slicing of golden metrics by coarse family; no user-visible '
        'classification depends on it.',
  ),
  _Allow(
    'packages/pandapay_domain/lib/src/sms_v2/engine/transforms.dart',
    'DEBT: faithful port of IndianNarrationSanitizer (payment-gateway and QR '
        'prefixes) until WP-17 deletes the original; move to a rule transform.',
    tokens: {'razorpay', 'paytm', 'cashfree', 'billdesk', 'ccavenue', 'payu', 'instamojo', 'pinelabs', 'ezeepay', 'phonepe', 'airpay', 'paykun', 'zaakpay', 'citruspay', 'bharatpe'},
    debt: true,
  ),
  _Allow(
    'packages/pandapay_domain/lib/src/sms_v2/category/merchant_key.dart',
    'DEBT: payment-gateway words dropped when building a merchant key.',
    tokens: {'razorpay', 'payu', 'billdesk', 'ccavenue', 'paytm'},
    debt: true,
  ),
  _Allow(
    'app/lib/features/sms_v2/instruments/issuer_slugs.dart',
    'DEBT: maps the card catalogue\'s issuer display names to v2 issuerSlugs when '
        'linking existing cards to instruments. It does not classify messages, '
        'but it is a bank-name table in code; move it to the bundle/catalogue.',
    tokens: {'indusind', 'american express', 'amex', 'sbi', 'bank of baroda', 'pnb', 'standard chartered', 'au small finance', 'idfc', 'canara', 'kotak', 'federal bank'},
    debt: true,
  ),
  _Allow(
    'packages/pandapay_domain/lib/src/sms_v2/instruments/instrument_resolver.dart',
    'DEBT: default set of sender brands that are UPI apps, not issuers '
        '(contract issuerKind has no upi_app); move to the bundle.',
    tokens: {'sbi', 'phonpe', 'gpay', 'googpay', 'bhim'},
    debt: true,
  ),
  _Allow(
    'app/lib/features/sms_v2/ui/review_clustering.dart',
    'DEBT: Pay Later provider table that groups Needs review messages into '
        'bundles for display. Display-only: it never classifies a message or '
        'changes stored data; move the providers to the bundle/catalogue.',
    tokens: {'amazon pay', 'amazon', 'flipkart'},
    debt: true,
  ),
];

class _Hit {
  _Hit(this.file, this.line, this.token, this.where);
  final String file;
  final int line;
  final String token;
  final String where;
  @override
  String toString() => '$file:$line  "$token" in $where';
}

/// Splits Dart source into string-literal contents and remaining code, with
/// comments removed. Good enough for guarding; it tracks quotes, raw strings,
/// triple quotes, escapes and nested block comments.
({List<(int, String)> strings, List<(int, String)> code}) _lex(String src) {
  final strings = <(int, String)>[];
  final code = <(int, String)>[];
  var line = 1;
  var i = 0;
  final codeBuf = StringBuffer();
  var codeLine = 1;
  void flushCode() {
    if (codeBuf.isNotEmpty) code.add((codeLine, codeBuf.toString()));
    codeBuf.clear();
  }

  while (i < src.length) {
    final c = src[i];
    final next = i + 1 < src.length ? src[i + 1] : '';
    if (c == '\n') {
      line++;
      codeBuf.write(c);
      i++;
    } else if (c == '/' && next == '/') {
      while (i < src.length && src[i] != '\n') {
        i++;
      }
    } else if (c == '/' && next == '*') {
      var depth = 1;
      i += 2;
      while (i < src.length && depth > 0) {
        if (src[i] == '\n') line++;
        if (src[i] == '/' && i + 1 < src.length && src[i + 1] == '*') {
          depth++;
          i += 2;
        } else if (src[i] == '*' && i + 1 < src.length && src[i + 1] == '/') {
          depth--;
          i += 2;
        } else {
          i++;
        }
      }
    } else if (c == "'" || c == '"' || (c == 'r' && (next == "'" || next == '"'))) {
      final raw = c == 'r';
      if (raw) i++;
      final q = src[i];
      final triple = src.startsWith(q * 3, i);
      final startLine = line;
      i += triple ? 3 : 1;
      final buf = StringBuffer();
      while (i < src.length) {
        final d = src[i];
        if (d == '\n') line++;
        if (!raw && d == r'\') {
          buf.write(i + 1 < src.length ? src[i + 1] : '');
          if (i + 1 < src.length && src[i + 1] == '\n') line++;
          i += 2;
          continue;
        }
        if (triple ? src.startsWith(q * 3, i) : d == q) {
          i += triple ? 3 : 1;
          break;
        }
        if (!triple && d == '\n') break; // unterminated: stop at the line end
        buf.write(d);
        i++;
      }
      strings.add((startLine, buf.toString()));
      codeBuf.write(' ');
    } else {
      if (codeBuf.isEmpty) codeLine = line;
      codeBuf.write(c);
      i++;
    }
  }
  flushCode();
  return (strings: strings, code: code);
}

final RegExp _camel = RegExp(r'([a-z0-9])([A-Z])');
final RegExp _nonAlnum = RegExp(r'[^a-z0-9]+');

final RegExp _brandRe = RegExp(
  '(?<![a-z0-9])(?:${_brands.map((b) => b.endsWith('\$') ? '${RegExp.escape(b.substring(0, b.length - 1))}(?![a-z0-9])' : RegExp.escape(b).replaceAll(r'\ ', ' ')).join('|')})',
);

/// Lower-cases, splits camelCase and collapses punctuation to single spaces.
String _normalise(String s) =>
    ' ${s.replaceAllMapped(_camel, (m) => '${m[1]} ${m[2]}').toLowerCase().replaceAll(_nonAlnum, ' ')} ';

Iterable<String> _brandsIn(String text) =>
    _brandRe.allMatches(_normalise(text)).map((m) => m.group(0)!.trim());

List<File> _dartFiles(Directory root) {
  if (!root.existsSync()) return const [];
  return root
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) =>
          f.path.endsWith('.dart') &&
          !f.path.endsWith('.g.dart') &&
          !f.path.endsWith('.freezed.dart'))
      .toList();
}

void main() {
  // `dart test` runs from the package root.
  final repo = Directory.current.parent.parent;

  test('the guard recognises brand names and ignores look-alikes', () {
    expect(_brandsIn('VM-HDFCBK-S').toList(), ['hdfc']);
    expect(_brandsIn('swiggy@icici').toList(), ['swiggy', 'icici']);
    expect(_brandsIn('PAYTMQR').toList(), ['paytm']);
    expect(_brandsIn('AmazonPay').toList(), ['amazon pay']);
    expect(_brandsIn('crossAxisAlignment Axis.vertical citizen city').toList(), isEmpty);
    expect(_brandsIn('Citi bank card').toList(), ['citi bank']);
    final lexed = _lex("final a = 'Swiggy'; // hdfc\n/* icici */ final b = r'zomato'; var uberHdfc = 1;");
    expect(lexed.strings.map((s) => s.$2).toList(), ['Swiggy', 'zomato']);
    expect(lexed.code.map((s) => s.$2).join().contains('hdfc rules'), isFalse);
    expect(_brandsIn(lexed.code.map((s) => s.$2).join(' ')).toList(), ['uber', 'hdfc']);
  });

  test('no merchant, bank or brand name is hard-coded in SMS v2 Dart', () {
    final allowByFile = {for (final a in _allow) '${repo.path}/${a.file}': a};
    final hits = <_Hit>[];
    final tolerated = <String, Set<String>>{};
    var scanned = 0;
    for (final r in _roots) {
      for (final f in _dartFiles(Directory('${repo.path}/$r'))) {
        scanned++;
        final rel = f.path.substring(repo.path.length + 1);
        final allow = allowByFile[f.path];
        if (allow != null && allow.tokens == null) continue;
        final lexed = _lex(f.readAsStringSync());
        void scan(List<(int, String)> parts, String where) {
          for (final (line, text) in parts) {
            // Report the line of the match, not just of the segment start.
            final lines = text.split('\n');
            for (var k = 0; k < lines.length; k++) {
              for (final token in _brandsIn(lines[k])) {
                if (allow != null && allow.tokens!.any(token.startsWith)) {
                  if (allow.debt) (tolerated[rel] ??= <String>{}).add(token);
                  continue;
                }
                hits.add(_Hit(rel, line + k, token, where));
              }
            }
          }
        }

        scan(lexed.strings, 'a string literal');
        scan(lexed.code, 'an identifier');
      }
    }
    expect(scanned, greaterThan(20), reason: 'the guard must actually scan the SMS v2 sources (cwd ${Directory.current.path})');
    if (tolerated.isNotEmpty) {
      // ignore: avoid_print
      print('hard-coded-logic guard: tolerated debt (move into rules/data):\n  ${tolerated.entries.map((e) => "${e.key}: ${(e.value.toList()..sort()).join(", ")}").join("\n  ")}');
    }
    expect(
      hits,
      isEmpty,
      reason: 'Brand names are data. Move them into a rule bundle or the merchant '
          'catalogue, or add a justified _Allow entry in this test.\n'
          '${hits.join('\n')}',
    );
  });

  test('every allow-list entry points at a file that still exists', () {
    for (final a in _allow) {
      expect(File('${repo.path}/${a.file}').existsSync(), isTrue, reason: '${a.file} moved or was deleted; update the allow-list');
    }
  });
}
