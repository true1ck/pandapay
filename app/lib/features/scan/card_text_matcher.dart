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
  const CardMatch({
    required this.product,
    required this.confidence,
    required this.reason,
    this.overlap = 0.0,
    this.hits = 0,
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
String? extractLastFourDigits(String text) {
  final matches = RegExp(
    r'\d{4}',
  ).allMatches(text.replaceAll(RegExp(r'[\s-]'), ' '));
  final groups = matches.map((m) => m.group(0)!).toList();
  if (groups.isEmpty) return null;
  return groups.last;
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
  final canonical = s.replaceAllMapped(
    RegExp(r'\bneu\s*card\s*\+', caseSensitive: false),
    (_) => 'neu plus',
  ).replaceAllMapped(
    RegExp(r'\bcash\s*back\b', caseSensitive: false),
    (_) => 'cashback',
  ).replaceAllMapped(
    RegExp(r'\bca(?:sh|sih)\s+b[^a-z0-9\s]*ck\b', caseSensitive: false),
    (_) => 'cashback',
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
    candidates.add(wordList[i] + (i + 1 < wordList.length ? wordList[i + 1] : ''));
    if (i + 2 < wordList.length) {
      candidates.add(wordList[i] + wordList[i + 1] + wordList[i + 2]);
    }
  }

  final maxDistance = token.length >= 7 ? 3 : 2;
  return candidates.any((candidate) {
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
  ).split(' ').where((t) => t.length >= 2 && !ignoreWords.contains(t)).toList();
  if (tokens.isEmpty) {
    return (overlap: 0.0, hits: 0);
  }
  final hits = tokens.where((t) => _fuzzyTokenMatch(normalizedText, t)).length;
  return (overlap: hits / tokens.length, hits: hits);
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

/// Matches [extracted] against [catalogue], returning candidates sorted
/// best-first. Confidence bands (deliberately conservative — see file doc):
/// - `high`: network detected AND token overlap >= 0.75
/// - `medium`: at least two product-name tokens and token overlap >= 0.5
///   (network match optional boost)
/// - `low`: a weak multi-token name hit, or network-only match with no name hit
/// - cards below all thresholds are omitted entirely, not returned as `none`
List<CardMatch> matchCardText(
  ExtractedCardText extracted,
  List<CardProduct> catalogue,
) {
  final normalizedText = _normalize(extracted.rawText);
  final network = detectNetworkFromText(extracted.rawText);

  final results = <CardMatch>[];
  for (final product in catalogue) {
    final score = _tokenOverlapScore(normalizedText, product.name);
    final overlap = score.overlap;
    final hits = score.hits;
    final identityHits = _identityTokenHits(normalizedText, product.name);
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
    } else if (hits >= 2 && overlap >= 0.75) {
      confidence = networkMatches
          ? MatchConfidence.high
          : MatchConfidence.medium;
      reasonParts.add('name match ${(overlap * 100).round()}%');
    } else if (hits >= 2 && overlap >= 0.5) {
      confidence = MatchConfidence.medium;
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
      ),
    );
  }

  results.sort((a, b) {
    final confCmp = b.confidence.index.compareTo(a.confidence.index);
    if (confCmp != 0) return confCmp;
    final overlapCmp = b.overlap.compareTo(a.overlap);
    if (overlapCmp != 0) return overlapCmp;
    return b.hits.compareTo(a.hits);
  });
  return results;
}
