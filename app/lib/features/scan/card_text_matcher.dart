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
  const CardMatch({required this.product, required this.confidence, required this.reason});
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
  final matches = RegExp(r'\d{4}').allMatches(text.replaceAll(RegExp(r'[\s-]'), ' '));
  final groups = matches.map((m) => m.group(0)!).toList();
  if (groups.isEmpty) return null;
  return groups.last;
}

/// Normalizes text for fuzzy comparison: lowercase, strip anything that
/// isn't a letter/digit/space, collapse whitespace.
String _normalize(String s) {
  return s
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

/// Very small token-overlap fuzzy score: fraction of the catalogue product
/// name's tokens (e.g. "hdfc", "millennia") that appear as substrings
/// anywhere in the normalized extracted text. Deliberately simple — no
/// edit-distance/library dependency — because OCR'd card text is short and
/// mostly-correct issuer/product names, not free-form prose. 0.0-1.0.
double _tokenOverlapScore(String normalizedText, String productName) {
  final tokens = _normalize(productName).split(' ').where((t) => t.length >= 2).toList();
  if (tokens.isEmpty) return 0.0;
  final hits = tokens.where((t) => normalizedText.contains(t)).length;
  return hits / tokens.length;
}

/// Matches [extracted] against [catalogue], returning candidates sorted
/// best-first. Confidence bands (deliberately conservative — see file doc):
/// - `high`: network detected AND token overlap >= 0.75
/// - `medium`: token overlap >= 0.5 (network match optional boost)
/// - `low`: token overlap >= 0.25, or network-only match with no name hit
/// - cards below all thresholds are omitted entirely, not returned as `none`
List<CardMatch> matchCardText(ExtractedCardText extracted, List<CardProduct> catalogue) {
  final normalizedText = _normalize(extracted.rawText);
  final network = detectNetworkFromText(extracted.rawText);

  final results = <CardMatch>[];
  for (final product in catalogue) {
    final overlap = _tokenOverlapScore(normalizedText, product.name);
    final networkMatches = network != null && network == product.network;

    MatchConfidence confidence;
    final reasonParts = <String>[];
    if (overlap >= 0.75) {
      confidence = networkMatches ? MatchConfidence.high : MatchConfidence.medium;
      reasonParts.add('name match ${(overlap * 100).round()}%');
    } else if (overlap >= 0.5) {
      confidence = MatchConfidence.medium;
      reasonParts.add('partial name match ${(overlap * 100).round()}%');
    } else if (overlap >= 0.25) {
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

    results.add(CardMatch(product: product, confidence: confidence, reason: reasonParts.join(', ')));
  }

  results.sort((a, b) => b.confidence.index.compareTo(a.confidence.index));
  return results;
}
