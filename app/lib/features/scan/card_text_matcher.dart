import 'package:flutter/foundation.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

/// UA-4 (Chunk 30): pure-Dart matching/parsing logic for camera/QR card
/// scanning — no camera, no plugin, no platform channel in this file. Kept
/// separate from the camera wiring (`card_scanner.dart`) specifically so
/// this half is unit-testable without a device, per the task's scope split.
///
/// Deliberately narrow: this is NOT card-recognition ML. It extracts a
/// plausible last-4 digit group and a network keyword from whatever raw text
/// a text-recognition plugin handed back, then fuzzy-matches the recognized
/// text (issuer/product name fragments) against the already-fetched
/// `card_products` catalogue. If nothing clears a confidence floor, it
/// returns no confident match — callers must fall back to the manual
/// catalogue picker rather than guess. Same "never fabricate a capability"
/// rule as AD-4.3's heuristic (not LLM) extraction.

/// How sure the matcher is about a candidate. `low` should never be
/// auto-selected by a caller — it exists so the UI can still show "did you
/// mean X?" alongside the raw extracted text.
enum MatchConfidence { none, low, medium, high }

/// What a text-recognition pass (OCR) or QR/barcode scan handed back, before
/// any interpretation. `rawText` is the full recognized block (OCR) or
/// decoded payload (QR/barcode) — always kept around so the UI can show it
/// verbatim when confidence is too low to guess.
class ExtractedCardText {
  final String rawText;
  const ExtractedCardText(this.rawText);
}

/// The result of matching extracted text against one catalogue entry.
class CardMatch {
  final CardProduct product;
  final MatchConfidence confidence;
  final String reason;
  final double overlap;
  final int hits;

  /// Number of matched tokens that identify the product rather than only its
  /// issuer. Used to rank candidates when OCR also picked up shared words
  /// such as "bank" or "credit card".
  final int productHits;
  const CardMatch({
    required this.product,
    required this.confidence,
    required this.reason,
    this.overlap = 0.0,
    this.hits = 0,
    this.productHits = 0,
  });
}

/// Card networks scanning cares about, plus the raw synonyms printed on
/// physical cards (mixed case/spacing) that map to each `CardNetwork`.
const Map<CardNetwork, List<String>> _networkSynonyms = {
  CardNetwork.visa: ['visa'],
  CardNetwork.mastercard: ['mastercard', 'master card'],
  CardNetwork.rupay: ['rupay'],
  CardNetwork.amex: ['amex', 'american express'],
  CardNetwork.diners: ['diners', 'diners club'],
};

// These words describe a network or a broad tier, but do not identify a
// catalogue product on their own. A low-resolution photo can easily preserve
// only "RuPay Platinum" while losing the small Tata/HDFC/SBI wordmark.
const _genericCardWords = {
  'visa',
  'mastercard',
  'rupay',
  'amex',
  'diners',
  'platinum',
  'gold',
  'classic',
  'signature',
  'select',
};

const _allGenericWords = {
  ..._genericCardWords,
  'card',
  'credit',
  'debit',
  'bank',
  'prepaid',
  'creditcard',
  'debitcard',
  'bankcard',
};

/// Finds a network keyword anywhere in [text] (case-insensitive). Returns
/// null if none of the known synonyms appear — a scan of a card whose
/// network logo OCR'd as garbage should not silently default to one.
CardNetwork? detectNetworkFromText(String text) {
  final lower = text.toLowerCase();
  for (final entry in _networkSynonyms.entries) {
    for (final synonym in entry.value) {
      if (lower.contains(synonym)) return entry.key;
    }
  }
  return null;
}

/// Extracts groups of 4+ consecutive digits (allowing spaces/dashes between
/// 4-digit blocks, as printed on most cards) and returns the *last* group
/// found — physical cards print the full PAN, and the last 4 digits are
/// what's actually useful for identification (and all that's safe to keep:
/// this never stores a full card number, only whatever the last recognized
/// digit group is).
/// Validates whether [digits] passes the Luhn checksum (mod 10 algorithm).
///
/// Bank card numbers (13-19 digits) follow the Luhn algorithm, allowing
/// genuine card numbers to be prioritized over helplines and random digit
/// strings.
bool _passesLuhn(String digits) {
  if (digits.length < 13 || digits.length > 19) return false;
  var sum = 0;
  var alternate = false;
  for (var i = digits.length - 1; i >= 0; i--) {
    final code = digits.codeUnitAt(i);
    if (code < 48 || code > 57) return false;
    var n = code - 48;
    if (alternate) {
      n *= 2;
      if (n > 9) {
        n -= 9;
      }
    }
    sum += n;
    alternate = !alternate;
  }
  return sum % 10 == 0;
}

@visibleForTesting
bool passesLuhn(String digits) => _passesLuhn(digits);

/// Returns true if [digits] begins with a known toll-free or helpline prefix
/// (e.g. 1800, 1860, or with country/trunk prefix 91/0).
bool _isHelplineDigits(String digits) {
  return digits.startsWith('1800') ||
      digits.startsWith('1860') ||
      digits.startsWith('1900') ||
      digits.startsWith('911800') ||
      digits.startsWith('911860') ||
      digits.startsWith('911900') ||
      digits.startsWith('01800') ||
      digits.startsWith('01860');
}

/// Identifies whether a 4-digit [group] within [text] is likely part of an
/// expiry date (e.g. `VALID THRU 2029`, `EXP 05/29`), a customer care helpline
/// (e.g. `1800 209 5577`), or a postal code, rather than a card PAN suffix.
bool _isLikelyExpiryOrHelpline(String group, String text) {
  if (group.length != 4) return false;

  // Helplines almost universally start with 1800, 1860, or 1900 in India
  if (group == '1800' || group == '1860' || group == '1900') {
    return true;
  }

  final groupInt = int.tryParse(group);
  final isYear = groupInt != null && groupInt >= 2020 && groupInt <= 2045;
  final month = int.tryParse(group.substring(0, 2)) ?? 0;
  final year = int.tryParse(group.substring(2, 4)) ?? 0;
  final isMmYy = (month >= 1 && month <= 12) && (year >= 20 && year <= 45);

  final lowerText = text.toLowerCase();

  // If group is MMYY (e.g. 1228) and text contains 12/28 or 12-28
  if (isMmYy) {
    final slashForm = '${group.substring(0, 2)}/${group.substring(2, 4)}';
    final dashForm = '${group.substring(0, 2)}-${group.substring(2, 4)}';
    if (lowerText.contains(slashForm) || lowerText.contains(dashForm)) {
      if (lowerText.contains('valid') ||
          lowerText.contains('thru') ||
          lowerText.contains('exp') ||
          lowerText.contains('good')) {
        return true;
      }
    }
  }

  // Find standalone occurrences of group
  final groupPattern = RegExp(r'(?<!\d)' + RegExp.escape(group) + r'(?!\d)');
  final matches = groupPattern.allMatches(text).toList();
  if (matches.isEmpty) {
    // If not found standalone, but it is an expiry year/date and text has expiry labels
    if (isYear &&
        (lowerText.contains('valid') ||
            lowerText.contains('thru') ||
            lowerText.contains('exp'))) {
      return true;
    }
    return false;
  }

  for (final match in matches) {
    final start = match.start;
    final end = match.end;

    // Line containing match
    final lineStart = text.lastIndexOf('\n', start) == -1
        ? 0
        : text.lastIndexOf('\n', start) + 1;
    final lineEnd =
        text.indexOf('\n', end) == -1 ? text.length : text.indexOf('\n', end);
    final line = text.substring(lineStart, lineEnd).toLowerCase();

    // Check if on the same line or in immediate proximity (20 chars) to helpline indicators
    final helplineKeywords = RegExp(
      r'(?:1800|1860|1900|toll[\s-]?free|helpline|customer[\s-]?care|customercare)',
    );
    if (helplineKeywords.hasMatch(line)) {
      return true;
    }

    final immediateBefore = text.substring(
      (start - 20).clamp(0, text.length),
      start,
    ).toLowerCase();
    if (immediateBefore.contains('1800') ||
        immediateBefore.contains('1860') ||
        immediateBefore.contains('1900') ||
        immediateBefore.contains('toll free') ||
        immediateBefore.contains('helpline')) {
      return true;
    }

    // Expiry checks for this occurrence
    if (isYear || isMmYy) {
      final expiryKeywords = RegExp(
        r'(?:valid|thru|exp|expiry|expires|good|date|member|since)',
      );
      if (expiryKeywords.hasMatch(line) ||
          expiryKeywords.hasMatch(immediateBefore)) {
        return true;
      }

      // Check for slashes adjacent to the digits
      final charBefore = start > 0 ? text[start - 1] : '';
      final charAfter = end < text.length ? text[end] : '';
      if (charBefore == '/' || charAfter == '/') {
        return true;
      }

      if (isYear &&
          (lowerText.contains('valid') ||
              lowerText.contains('thru') ||
              lowerText.contains('exp'))) {
        return true;
      }
    }
  }

  return false;
}

@visibleForTesting
bool isLikelyExpiryOrHelpline(String group, String text) =>
    _isLikelyExpiryOrHelpline(group, text);

/// Extracts the last 4 digits of a card number from recognized OCR [text].
///
/// Priority ladder:
/// 1. Luhn-passing PAN candidates (13-19 digits).
/// 2. Any 13-19 digit candidate (if none pass Luhn, e.g. OCR noise or mock card).
/// 3. Masked card patterns (e.g. `•••• •••• •••• 8908`, `**** 8908`, `xxxx 8908`).
/// 4. Safe filtered standalone 4-digit candidates (excluding helplines, expiry dates, pincodes).
String? extractLastFourDigits(String text) {
  // Priority 1 & 2: PAN-shaped run of 13 to 19 digits.
  // Allows up to 3 spaces, newlines, dashes, or dots between digits to tolerate
  // ML Kit OCR spacing/newline artifacts across 4-digit blocks.
  final panMatches = RegExp(
    r'(?<!\d)(?:\d[\s\-\.\r\n]{0,3}){12,18}\d(?!\d)',
  ).allMatches(text).toList();

  final luhnCandidates = <String>[];
  final nonLuhnCandidates = <String>[];

  for (final match in panMatches.reversed) {
    final digits = match.group(0)!.replaceAll(RegExp(r'\D'), '');
    if (digits.length >= 13 && digits.length <= 19) {
      if (_passesLuhn(digits)) {
        luhnCandidates.add(digits);
      } else if (!_isHelplineDigits(digits)) {
        nonLuhnCandidates.add(digits);
      }
    }
  }

  // 1. Prioritize Luhn-passing PAN candidate first
  if (luhnCandidates.isNotEmpty) {
    final digits = luhnCandidates.first;
    return digits.substring(digits.length - 4);
  }

  // 2. Any 13-19 digit candidate (if none passed Luhn)
  if (nonLuhnCandidates.isNotEmpty) {
    final digits = nonLuhnCandidates.first;
    return digits.substring(digits.length - 4);
  }

  // 3. Masked card pattern (e.g. •••• •••• •••• 8908, **** 8908, xxxx 8908)
  final maskedMatches = RegExp(
    r'(?:[•●∙・·\*\.xX]{2,4}[\s\-\.]*)+(\d{4})(?!\d)|'
    r'(?:card|account|acct)?\s*ending\s+(?:in|with)?\s*[:\s]*(?:[•●∙・·\*\.xX]{2,4}[\s\-\.]*)*(\d{4})(?!\d)',
    caseSensitive: false,
  ).allMatches(text).toList();

  for (final match in maskedMatches.reversed) {
    final group = match.group(1) ?? match.group(2);
    if (group != null && !_isLikelyExpiryOrHelpline(group, text)) {
      return group;
    }
  }

  // 4. Safe filtered standalone 4-digit candidate
  final fourDigitMatches = RegExp(
    r'(?<!\d)\d{4}(?!\d)',
  ).allMatches(text).toList();

  for (final match in fourDigitMatches.reversed) {
    final group = match.group(0)!;
    if (!_isLikelyExpiryOrHelpline(group, text)) {
      return group;
    }
  }

  return null;
}

/// Masks any run of 3+ digits in [text], replacing each digit with `•`.
///
/// The physical-card OCR path (UA-4, extended) reads whatever text is
/// printed on the front of the card — and on most Indian debit/credit
/// cards, that includes the embossed or printed card number. The matcher
/// only ever needs issuer/product NAME text; nothing about matching
/// requires the digits, so nothing that displays extracted text to a user
/// (or would ever log it) should show them unmasked. 3 digits, not 4, is
/// the threshold deliberately — a 2-digit expiry month/year fragment is
/// harmless, but a 3-digit CVV-length run is exactly the kind of thing that
/// must never render on screen even partially.
///
/// Unlike `redactSmsShape` (api/src/sms_parser.js), which also collapses
/// letters, this keeps letters as-is: the whole point of showing extracted
/// text at all (when it exists to show) is letting a user see *why* a
/// match failed, and an issuer name is exactly the part that's safe and
/// useful to show.
String redactDigitRuns(String text) {
  return text.replaceAllMapped(
    RegExp(r'\d{3,}'),
    (m) => '•' * m.group(0)!.length,
  );
}

/// Normalizes text for fuzzy comparison: lowercase, strip anything that
/// isn't a letter/digit/space, collapse whitespace.
String _normalize(String s) {
  // The physical Tata Neu Plus artwork prints the product mark as
  // “NEUCARD+”. OCR commonly returns that as one token, so canonicalize the
  // visible plus marker into the catalogue's separate “Neu Plus” token before
  // punctuation is stripped. This lets the matcher distinguish Plus from
  // Infinity instead of treating both as the same Tata Neu family.
  //
  // The Infinity artwork uses “NEUCARD∞”, and OCR often returns the symbol
  // either as the Unicode infinity glyph or as a near-brand spelling such as
  // “Tata Neo”. Canonicalize only the Tata-branded form: a global neo -> neu
  // rewrite would turn a real Axis Bank Neo card into a false Tata match.
  var canonical = s.replaceAll('∞', ' infinity ');
  canonical = canonical.replaceAllMapped(
    RegExp(r'\bneu\s*card\s*\+', caseSensitive: false),
    (_) => 'neu plus',
  );
  canonical = canonical.replaceAllMapped(
    RegExp(r'\btata\s+neo(?:\s*card)?\b', caseSensitive: false),
    (_) => 'tata neu',
  );
  canonical = canonical.replaceAllMapped(
    RegExp(r'\bstate\s+bank\s+of\s+india\b', caseSensitive: false),
    (_) => 'sbi',
  );
  canonical = canonical.replaceAllMapped(
    RegExp(r'\bcash\s*back\b', caseSensitive: false),
    (_) => 'cashback',
  );
  canonical = canonical.replaceAllMapped(
    RegExp(r'\bca(?:sh|sih)\s+b[^a-z0-9\s]*ck\b', caseSensitive: false),
    (_) => 'cashback',
  );
  canonical = canonical.replaceAllMapped(
    RegExp(r'\bmy\s*zone\b|\bmyzone\b', caseSensitive: false),
    (_) => 'my zone',
  );
  canonical = canonical.replaceAllMapped(
    RegExp(r'\bsimply\s*click\b|\bsimplyclick\b', caseSensitive: false),
    (_) => 'simply click',
  );
  canonical = canonical.replaceAllMapped(
    RegExp(r'\bsimply\s*save\b|\bsimplysave\b', caseSensitive: false),
    (_) => 'simply save',
  );
  return canonical
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

/// OCR can turn a printed token into a near-spelling (`CASIH`) or split it
/// into short fragments (`B<CK`). Keep fuzzy matching deliberately local and
/// conservative: only product-name tokens of four or more characters are
/// eligible, and the token still needs to be reasonably close to one OCR word
/// or a short run of adjacent OCR fragments.
bool _fuzzyTokenMatch(String normalizedText, String token) {
  if (normalizedText.contains(token)) return true;
  if (token.length < 4) return false;

  final words = normalizedText.split(' ').where((word) => word.isNotEmpty);
  final candidates = <String>{...words};
  final wordList = words.toList();
  for (var i = 0; i < wordList.length; i++) {
    candidates.add(
      wordList[i] + (i + 1 < wordList.length ? wordList[i + 1] : ''),
    );
    if (i + 2 < wordList.length) {
      candidates.add(wordList[i] + wordList[i + 1] + wordList[i + 2]);
    }
  }

  final maxDistance = token.length >= 8 ? 2 : 1;
  return candidates.any((candidate) {
    if (_allGenericWords.contains(candidate) && candidate != token) {
      return false;
    }
    if (candidate.length < token.length - maxDistance ||
        candidate.length > token.length + maxDistance) {
      return false;
    }
    return _levenshteinDistance(candidate, token) <= maxDistance;
  });
}

int _levenshteinDistance(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;

  var previous = List<int>.generate(b.length + 1, (i) => i);
  for (var i = 0; i < a.length; i++) {
    final current = List<int>.filled(b.length + 1, 0)..[0] = i + 1;
    for (var j = 0; j < b.length; j++) {
      final substitutionCost = a[i] == b[j] ? 0 : 1;
      current[j + 1] = [
        current[j] + 1,
        previous[j + 1] + 1,
        previous[j] + substitutionCost,
      ].reduce((x, y) => x < y ? x : y);
    }
    previous = current;
  }
  return previous[b.length];
}

String _searchableProductName(CardProduct product) {
  final issuer = product.issuerName?.trim();
  final name = product.name.trim();
  if (issuer != null &&
      issuer.isNotEmpty &&
      name.toLowerCase().contains(issuer.toLowerCase())) {
    return name;
  }
  return [issuer, name].whereType<String>().where((value) => value.trim().isNotEmpty).join(' ');
}

/// Very small token-overlap fuzzy score: fraction of the catalogue product
/// name's tokens (e.g. "hdfc", "millennia") that appear as substrings
/// anywhere in the normalized extracted text. Deliberately simple — no
/// edit-distance/library dependency — because OCR'd card text is short and
/// mostly-correct issuer/product names, not free-form prose. 0.0-1.0.
({double overlap, int hits}) _tokenOverlapScore(
  String normalizedText,
  String productName,
) {
  final ignoreWords = {'credit', 'card', 'debit', 'prepaid'};
  final tokens = _normalize(
    productName,
  ).split(' ').where((t) => t.length >= 2 && !ignoreWords.contains(t)).toSet().toList();
  if (tokens.isEmpty) {
    return (overlap: 0.0, hits: 0);
  }
  final hits = tokens.where((t) => _fuzzyTokenMatch(normalizedText, t)).length;
  return (overlap: hits / tokens.length, hits: hits);
}

bool _hasRawExactProductToken(
  String rawText,
  String productName,
  String issuerName,
) {
  // Fuzzy OCR corrections are useful for finding the right candidate, but a
  // fully fuzzy match is not enough for the highest confidence band. Keep
  // the raw text (before Tata/Cashback aliases are canonicalised) as the
  // evidence check so a visibly noisy read remains a user-verifiable medium
  // match rather than looking certain.
  var raw = rawText
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  raw = raw
      .replaceAll(RegExp(r'\bmyzone\b'), 'my zone')
      .replaceAll(RegExp(r'\bsimplyclick\b'), 'simply click')
      .replaceAll(RegExp(r'\bsimplysave\b'), 'simply save');

  final issuerTokens = _normalize(
    issuerName,
  ).split(' ').where((t) => t.isNotEmpty).toSet();
  var tokens = _normalize(productName)
      .split(' ')
      .where(
        (t) =>
            t.length >= 2 &&
            !_genericCardWords.contains(t) &&
            !{'credit', 'card', 'debit', 'prepaid'}.contains(t) &&
            !issuerTokens.contains(t),
      )
      .toList();
  // When the catalogue row has no separate issuer field, the first name
  // token is commonly the issuer (for example, "SBI Cashback"). It must not
  // turn a noisy read of the issuer into high-confidence product evidence.
  if (issuerTokens.isEmpty && tokens.length > 1) {
    tokens = tokens.skip(1).toList();
  }
  final hasDirectMatch = tokens.any(
    (token) =>
        RegExp(r'(^|\s)' + RegExp.escape(token) + r'($|\s)').hasMatch(raw),
  );
  if (hasDirectMatch) return true;

  for (var i = 0; i < tokens.length - 1; i++) {
    final compound = tokens[i] + tokens[i + 1];
    if (RegExp(r'(^|\s)' + RegExp.escape(compound) + r'($|\s)').hasMatch(raw)) {
      return true;
    }
  }
  return false;
}

int _identityTokenHits(String normalizedText, String productName) {
  final ignoreWords = {'credit', 'card', 'debit', 'prepaid'};
  final tokens = _normalize(productName)
      .split(' ')
      .where(
        (t) =>
            t.length >= 2 &&
            !ignoreWords.contains(t) &&
            !_genericCardWords.contains(t),
      )
      .toSet();
  return tokens.where((t) => _fuzzyTokenMatch(normalizedText, t)).length;
}

/// Returns how many product-specific tokens (name tokens NOT in the issuer
/// name) match in [normalizedText]. An issuer-only match (e.g. only "sbi")
/// means every card from that issuer would score the same — result is arbitrary.
int _productSpecificHits(
  String normalizedText,
  String issuerName,
  String searchableName,
) {
  final ignoreWords = {'credit', 'card', 'debit', 'prepaid'};
  final issuerTokens = _normalize(
    issuerName,
  ).split(' ').where((t) => t.isNotEmpty).toSet();
  final tokens = _normalize(searchableName)
      .split(' ')
      .where(
        (t) =>
            t.length >= 2 &&
            !ignoreWords.contains(t) &&
            !_genericCardWords.contains(t) &&
            !issuerTokens.contains(t),
      )
      .toSet();
  return tokens.where((t) => _fuzzyTokenMatch(normalizedText, t)).length;
}

/// Matches [extracted] against [catalogue], returning candidates sorted
/// best-first. Confidence bands (deliberately conservative — see file doc):
/// - `high`: explicit product-name evidence with token overlap >= 0.75;
///   a network match is a useful confirmation but is not required because
///   many real catalogue rows do not have a readable network logo
/// - `medium`: at least two product-name tokens and token overlap >= 0.5
///   (network match optional boost)
/// - `low`: a weak multi-token name hit, or network-only match with no name hit
/// - cards below all thresholds are omitted entirely, not returned as `none`
Set<String> _extractProductTokens(CardProduct product) {
  final ignoreWords = {'credit', 'card', 'debit', 'prepaid'};
  final issuerTokens = _normalize(
    product.issuerName ?? '',
  ).split(' ').where((t) => t.isNotEmpty).toSet();
  return _normalize(product.name)
      .split(' ')
      .where(
        (t) =>
            t.length >= 2 &&
            !ignoreWords.contains(t) &&
            !_genericCardWords.contains(t) &&
            !issuerTokens.contains(t),
      )
      .toSet();
}

bool _hasSubVariantPhraseEvidence(
  CardProduct subVariant,
  Set<String> baseTokens,
  Set<String> extraTokens,
  String normalizedText,
) {
  final subTokens = _normalize(subVariant.name)
      .split(' ')
      .where((t) => t.isNotEmpty && !_allGenericWords.contains(t))
      .toList();
  if (subTokens.length >= 2) {
    final phrase = subTokens.join(' ');
    if (normalizedText.contains(phrase)) return true;
  }
  final words = normalizedText.split(' ').where((w) => w.isNotEmpty).toList();
  for (var i = 0; i < words.length - 1; i++) {
    final w1 = words[i];
    final w2 = words[i + 1];
    if ((baseTokens.contains(w1) && extraTokens.contains(w2)) ||
        (extraTokens.contains(w1) && baseTokens.contains(w2))) {
      return true;
    }
  }
  return false;
}

int _compareSubVariants(CardMatch a, CardMatch b, String normalizedText) {
  final tokensA = _extractProductTokens(a.product);
  final tokensB = _extractProductTokens(b.product);
  if (tokensA.isEmpty || tokensB.isEmpty || tokensA.length == tokensB.length) {
    return 0;
  }

  if (tokensB.length > tokensA.length && tokensB.containsAll(tokensA)) {
    final extraTokens = tokensB.difference(tokensA);
    final hasEvidence = _hasSubVariantPhraseEvidence(
      b.product,
      tokensA,
      extraTokens,
      normalizedText,
    );
    if (!hasEvidence) return -1;
  }

  if (tokensA.length > tokensB.length && tokensA.containsAll(tokensB)) {
    final extraTokens = tokensA.difference(tokensB);
    final hasEvidence = _hasSubVariantPhraseEvidence(
      a.product,
      tokensB,
      extraTokens,
      normalizedText,
    );
    if (!hasEvidence) return 1;
  }

  return 0;
}

List<CardMatch> matchCardText(
  ExtractedCardText extracted,
  List<CardProduct> catalogue,
) {
  final normalizedText = _normalize(extracted.rawText);
  final network = detectNetworkFromText(extracted.rawText);

  final results = <CardMatch>[];
  for (final product in catalogue) {
    final searchableName = _searchableProductName(product);
    final issuerName = product.issuerName ?? '';
    final score = _tokenOverlapScore(normalizedText, searchableName);
    final overlap = score.overlap;
    final hits = score.hits;
    final identityHits = _identityTokenHits(normalizedText, searchableName);
    final productHits = _productSpecificHits(
      normalizedText,
      issuerName,
      searchableName,
    );
    final hasRawExactProductToken = _hasRawExactProductToken(
      extracted.rawText,
      searchableName,
      issuerName,
    );
    final networkMatches = network != null && network == product.network;

    MatchConfidence confidence;
    final reasonParts = <String>[];
    // A one-token match is not card identification. Generic catalogue names
    // such as "Platinum Credit Card" would otherwise win whenever OCR picks
    // up the word "platinum" from card art or nearby text. Keep those as
    // network-only low-confidence suggestions at most; the result panel does
    // not show low-confidence candidates as detected cards.
    if (identityHits == 0) {
      // Network/tier-only labels (for example "RuPay Platinum") are not
      // sufficient to identify a product. Keep the row diagnostic-only.
      if (networkMatches) {
        confidence = MatchConfidence.low;
        reasonParts.add('network/tier text only (${product.network.name})');
      } else {
        continue;
      }
    } else if (productHits == 0) {
      // Only issuer tokens matched — every card from this issuer scores the
      // same, so the top result is arbitrary. Downgrade to low/skip.
      if (networkMatches) {
        confidence = MatchConfidence.low;
        reasonParts.add('issuer match only (${product.network.name})');
      } else {
        continue;
      }
    } else if (hits >= 2 && overlap >= 0.75 && hasRawExactProductToken) {
      // The printed product name is stronger evidence than a logo that ML Kit
      // may miss or that the catalogue may not know (47 live catalogue rows
      // currently have an unknown network). Requiring the network here made
      // otherwise exact card-name scans show as only "possible matches".
      confidence = MatchConfidence.high;
      reasonParts.add('name match ${(overlap * 100).round()}%');
    } else if (hits >= 2 && overlap >= 0.75) {
      confidence = MatchConfidence.medium;
      reasonParts.add('fuzzy name match ${(overlap * 100).round()}%');
    } else if (hits >= 2 && overlap >= 0.5) {
      // Require network confirmation for medium on a partial match — without
      // it the 50% bar is too easy to hit with overlapping issuer tokens.
      confidence = networkMatches
          ? MatchConfidence.medium
          : MatchConfidence.low;
      reasonParts.add('partial name match ${(overlap * 100).round()}%');
    } else if (hits >= 2 && overlap >= 0.25) {
      confidence = MatchConfidence.low;
      reasonParts.add('weak name match ${(overlap * 100).round()}%');
    } else if (networkMatches) {
      confidence = MatchConfidence.low;
      reasonParts.add('network match only (${product.network.name})');
    } else {
      continue;
    }
    if (networkMatches && !reasonParts.first.startsWith('network')) {
      reasonParts.add('network match (${product.network.name})');
    }

    results.add(
      CardMatch(
        product: product,
        confidence: confidence,
        reason: reasonParts.join(', '),
        overlap: overlap,
        hits: hits,
        productHits: productHits,
      ),
    );
  }

  results.sort((a, b) {
    final confCmp = b.confidence.index.compareTo(a.confidence.index);
    if (confCmp != 0) return confCmp;
    final overlapCmp = b.overlap.compareTo(a.overlap);
    if (overlapCmp != 0) return overlapCmp;
    final subVariantCmp = _compareSubVariants(a, b, normalizedText);
    if (subVariantCmp != 0) return subVariantCmp;
    final productHitsCmp = b.productHits.compareTo(a.productHits);
    if (productHitsCmp != 0) return productHitsCmp;
    return b.hits.compareTo(a.hits);
  });
  return results;
}
