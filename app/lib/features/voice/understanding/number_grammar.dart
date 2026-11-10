import 'language_pack.dart';
import 'tokens.dart';

/// A run of tokens that reads as one number: "1,250", "2.5 lakh",
/// "fifteen hundred", "two and a half thousand".
class NumberSpan {
  const NumberSpan({
    required this.startToken,
    required this.endToken,
    required this.value,
    required this.fromWords,
    required this.hasMagnitude,
    this.altValue,
    this.suffix = '',
  });

  /// Inclusive index of the first token.
  final int startToken;

  /// Exclusive index after the last token.
  final int endToken;
  final double value;

  /// A second plausible reading ("two fifty" is 250 or 2.50).
  final double? altValue;

  /// At least one part was spoken as a word.
  final bool fromWords;

  /// Contains hundred, thousand, lakh, crore, million or a k/cr suffix.
  final bool hasMagnitude;

  /// Suffix glued to the digits, e.g. `rs` in "250rs".
  final String suffix;

  int get length => endToken - startToken;
  bool get ambiguous => altValue != null;

  String text(String source, List<Token> tokens) =>
      source.substring(tokens[startToken].start, tokens[endToken - 1].end);
}

enum _Prev { none, small, digits, hundred, magnitude }

/// The number that starts exactly at [index], if any. Date reading uses this
/// for "three days ago" and "last 30 days".
NumberSpan? numberAt(
  List<Token> tokens,
  int index,
  LanguagePack pack, {
  Set<int> claimed = const {},
}) => index < tokens.length && !claimed.contains(index)
    ? _parseRun(tokens, index, pack, claimed)
    : null;

/// Finds every number in [tokens] that is not in [claimed] (tokens already
/// owned by dates or times). Words and digits are read by the same small
/// grammar, so "two lakh fifty thousand" and "2.5 lakh" are handled alike.
List<NumberSpan> findNumbers(
  List<Token> tokens,
  LanguagePack pack, {
  Set<int> claimed = const {},
}) {
  final spans = <NumberSpan>[];
  var i = 0;
  while (i < tokens.length) {
    if (claimed.contains(i)) {
      i++;
      continue;
    }
    final span = _parseRun(tokens, i, pack, claimed);
    if (span == null) {
      i++;
      continue;
    }
    spans.add(span);
    i = span.endToken;
  }
  return spans;
}

NumberSpan? _parseRun(
  List<Token> tokens,
  int start,
  LanguagePack pack,
  Set<int> claimed,
) {
  var total = 0.0;
  var current = 0.0;
  var prev = _Prev.none;
  var any = false;
  var fromWords = false;
  var sawMagnitude = false;
  var sawHundred = false;
  var sawDigits = false;
  var lastSmallTens = false;
  double? pairValue;
  double? pairAlt;
  var suffixOut = '';
  var j = start;
  var end = start;

  bool free(int k) => k < tokens.length && !claimed.contains(k);
  bool isSmallWord(Token t) =>
      t.isWord &&
      (pack.numberUnits.containsKey(t.text) ||
          pack.numberTens.containsKey(t.text));
  bool isMagOrHundred(Token t) =>
      t.isWord &&
      (pack.hundredWords.contains(t.text) ||
          pack.magnitudeWords.containsKey(t.text));
  bool numberish(int k) =>
      free(k) && (tokens[k].isNumber || isSmallWord(tokens[k]));
  bool isUnderTen(Token t) => t.isWord && (pack.numberUnits[t.text] ?? 99) < 10;

  loop:
  while (free(j)) {
    final t = tokens[j];

    if (t.isNumber) {
      final suffix = t.suffix;
      if (pack.ordinalSuffixes.contains(suffix) ||
          pack.timeSuffixes.contains(suffix)) {
        break;
      }
      if (prev != _Prev.none &&
          prev != _Prev.hundred &&
          prev != _Prev.magnitude) {
        break;
      }
      final v = t.number!;
      final mag = pack.magnitudeSuffixes[suffix];
      if (mag != null) {
        total += v * mag;
        prev = _Prev.magnitude;
        sawMagnitude = true;
      } else {
        current += v;
        prev = _Prev.digits;
        sawDigits = true;
        if (pack.currencySuffixes.contains(suffix)) suffixOut = suffix;
      }
      any = true;
      end = j + 1;
      j++;
      continue;
    }

    if (t.isPunct) {
      if (t.text == '-' &&
          prev == _Prev.small &&
          free(j + 1) &&
          isSmallWord(tokens[j + 1])) {
        j++;
        continue;
      }
      break;
    }
    if (!t.isWord) break;
    final w = t.text;

    final unit = pack.numberUnits[w];
    final tens = pack.numberTens[w];
    if (unit != null || tens != null) {
      final v = (unit ?? tens!).toDouble();
      final isTens = tens != null;
      switch (prev) {
        case _Prev.none:
        case _Prev.hundred:
        case _Prev.magnitude:
          current += v;
          prev = _Prev.small;
          lastSmallTens = isTens;
        case _Prev.small:
          if (lastSmallTens && !isTens && v >= 1 && v < 10) {
            current += v; // twenty five
            lastSmallTens = false;
          } else if (!sawMagnitude &&
              !sawHundred &&
              !sawDigits &&
              current >= 1 &&
              current <= 99 &&
              v >= 10) {
            // "two fifty", "twelve fifty", "three twenty five".
            var g2 = v;
            var next = j + 1;
            if (isTens && free(next) && isUnderTen(tokens[next])) {
              final u = pack.numberUnits[tokens[next].text]!;
              if (u >= 1) {
                g2 += u;
                next++;
              }
            }
            pairValue = current * 100 + g2;
            pairAlt = current + g2 / 100;
            any = true;
            fromWords = true;
            end = next;
            break loop;
          } else {
            break loop;
          }
        case _Prev.digits:
          break loop;
      }
      any = true;
      fromWords = true;
      end = j + 1;
      j++;
      continue;
    }

    if (pack.hundredWords.contains(w)) {
      if (prev == _Prev.none) {
        current = 100;
      } else if ((prev == _Prev.small || prev == _Prev.digits) &&
          current < 100) {
        current *= 100;
      } else {
        break;
      }
      prev = _Prev.hundred;
      sawHundred = true;
      any = true;
      fromWords = true;
      end = j + 1;
      j++;
      continue;
    }

    final mult =
        pack.magnitudeWords[w] ??
        ((prev == _Prev.digits || prev == _Prev.small)
            ? pack.magnitudeSuffixes[w]
            : null);
    if (mult != null) {
      if (prev == _Prev.magnitude) break;
      total += (current == 0 ? 1 : current) * mult;
      current = 0;
      prev = _Prev.magnitude;
      sawMagnitude = true;
      any = true;
      fromWords = true;
      end = j + 1;
      j++;
      continue;
    }

    if (pack.articleWords.contains(w) &&
        prev == _Prev.none &&
        free(j + 1) &&
        isMagOrHundred(tokens[j + 1])) {
      current = 1;
      prev = _Prev.small;
      lastSmallTens = false;
      j++;
      continue;
    }

    if (pack.halfWords.contains(w) && prev == _Prev.none) {
      var k = j + 1;
      if (free(k) && pack.articleWords.contains(tokens[k].text)) k++;
      if (free(k) && isMagOrHundred(tokens[k])) {
        current = 0.5;
        prev = _Prev.small;
        lastSmallTens = false;
        j = k;
        continue;
      }
      break;
    }

    if (pack.andWords.contains(w)) {
      var k = j + 1;
      // "two and a half thousand"
      if ((prev == _Prev.small || prev == _Prev.digits) && free(k)) {
        if (pack.articleWords.contains(tokens[k].text) &&
            free(k + 1) &&
            pack.halfWords.contains(tokens[k + 1].text)) {
          current += 0.5;
          fromWords = true;
          end = k + 2;
          j = k + 2;
          prev = _Prev.small;
          lastSmallTens = false;
          continue;
        }
        if (pack.halfWords.contains(tokens[k].text)) {
          current += 0.5;
          fromWords = true;
          end = k + 1;
          j = k + 1;
          prev = _Prev.small;
          lastSmallTens = false;
          continue;
        }
      }
      // "one hundred and fifty", "one thousand and fifty"
      if ((prev == _Prev.hundred || prev == _Prev.magnitude) && numberish(k)) {
        j++;
        continue;
      }
      break;
    }

    if (pack.pointWords.contains(w) &&
        (prev == _Prev.small || prev == _Prev.digits) &&
        any) {
      final digits = StringBuffer();
      var k = j + 1;
      while (free(k)) {
        final d = tokens[k];
        if (d.isWord && isUnderTen(d)) {
          digits.write(pack.numberUnits[d.text]);
        } else if (d.isNumber &&
            d.suffix.isEmpty &&
            !d.text.contains('.') &&
            digits.isEmpty) {
          digits.write(d.text);
          k++;
          break;
        } else {
          break;
        }
        k++;
      }
      if (digits.isEmpty) break;
      current += double.parse('0.$digits');
      fromWords = true;
      end = k;
      j = k;
      prev = _Prev.small;
      lastSmallTens = false;
      continue;
    }

    break;
  }

  if (!any) return null;
  return NumberSpan(
    startToken: start,
    endToken: end,
    value: pairValue ?? (total + current),
    altValue: pairAlt,
    fromWords: fromWords,
    hasMagnitude: sawMagnitude || sawHundred,
    suffix: suffixOut,
  );
}
