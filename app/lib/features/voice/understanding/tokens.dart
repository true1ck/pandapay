import '../../../data/cached_regexp.dart';

enum TokenKind { number, word, symbol, punct }

/// One piece of a spoken or typed sentence, with its position in the source
/// so every later decision can point back at the exact words it came from.
class Token {
  const Token({
    required this.kind,
    required this.raw,
    required this.text,
    required this.start,
    required this.end,
    this.number,
    this.suffix = '',
    this.rupeeSlash = false,
  });

  final TokenKind kind;

  /// Exactly as written in the source.
  final String raw;

  /// Lower-case word, numeric string without grouping commas, or the symbol.
  final String text;
  final int start;

  /// Exclusive end offset in the source.
  final int end;

  /// Parsed value of a numeric token.
  final double? number;

  /// Letters glued to a number, lower-cased: `k`, `lakh`, `rd`, `pm`, `rs`.
  final String suffix;

  /// A trailing "/-" as in "250/-".
  final bool rupeeSlash;

  bool get isNumber => kind == TokenKind.number;
  bool get isWord => kind == TokenKind.word;
  bool get isSymbol => kind == TokenKind.symbol;
  bool get isPunct => kind == TokenKind.punct;

  bool isWordIn(Set<String> words) => isWord && words.contains(text);

  @override
  String toString() => '$kind($raw)';
}

/// Splits [source] into tokens. Grouped numbers ("2,50,000"), decimals,
/// glued suffixes ("1.5k", "3rd", "250/-") and currency symbols stay whole.
/// Pure and allocation-light: it runs on every utterance.
List<Token> tokenize(String source) {
  final pattern = cachedRegExp(
    r"(\d+(?:,\d+)*(?:\.\d+)?)(/-)?([A-Za-z]{1,8})?|([A-Za-z]+(?:['’][A-Za-z]+)*)|([₹$€£])|(\S)",
  );
  final out = <Token>[];
  var skipUntil = 0;
  for (final m in pattern.allMatches(source)) {
    if (m.start < skipUntil) continue;
    final numberText = m.group(1);
    if (numberText != null) {
      final clean = numberText.replaceAll(',', '');
      out.add(
        Token(
          kind: TokenKind.number,
          raw: m.group(0)!,
          text: clean,
          start: m.start,
          end: m.end,
          number: double.parse(clean),
          suffix: (m.group(3) ?? '').toLowerCase(),
          rupeeSlash: m.group(2) != null,
        ),
      );
      continue;
    }
    final word = m.group(4);
    if (word != null) {
      var end = m.end;
      final lower = word.toLowerCase().replaceAll('’', "'");
      // "Rs." and "INR." carry their own full stop.
      if ((lower == 'rs' || lower == 'inr') &&
          end < source.length &&
          source[end] == '.') {
        end += 1;
        skipUntil = end;
      }
      out.add(
        Token(
          kind: TokenKind.word,
          raw: source.substring(m.start, end),
          text: lower,
          start: m.start,
          end: end,
        ),
      );
      continue;
    }
    final symbol = m.group(5);
    if (symbol != null) {
      out.add(
        Token(
          kind: TokenKind.symbol,
          raw: symbol,
          text: symbol,
          start: m.start,
          end: m.end,
        ),
      );
      continue;
    }
    final punct = m.group(6)!;
    out.add(
      Token(
        kind: TokenKind.punct,
        raw: punct,
        text: punct,
        start: m.start,
        end: m.end,
      ),
    );
  }
  return out;
}
