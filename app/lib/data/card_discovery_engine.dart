import 'package:pandapay_domain/pandapay_domain.dart';
import 'user_cards_repository.dart' show CardDiscoveryResult, DiscoveredCard;

/// On-device card discovery engine that identifies card products from bank
/// SMS and email text by matching against the card catalogue.
///
/// Mirrors api/src/card_discovery.js to ensure exact parity between
/// on-device/offline discovery and backend discovery.
class LocalCardDiscoveryEngine {
  static const Set<String> stopwords = {
    'card',
    'cards',
    'credit',
    'debit',
    'bank',
    'the',
    'a',
    'an',
    'of',
    'and',
    'ltd',
    'limited',
    'india',
    'indian',
    'pvt',
    'co',
    'inr',
    'rs',
  };

  /// Normalise for comparison: casefold, collapse whitespace, and drop
  /// punctuation.
  static String normalise(String text) {
    return text
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9 ]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  /// Significant tokens of a card/issuer name (after stopwords).
  static List<String> significantTokens(String name) {
    return normalise(name)
        .split(' ')
        .where((t) => t.length > 1 && !stopwords.contains(t))
        .toList();
  }

  /// Extracts last-4 digits mentioned in the text (e.g., "ending 4568", "XX4568", "****4568").
  static List<String> extractLast4(String text) {
    final hits = <String>{};
    final re = RegExp(
      r'(?:ending|ending\s+with|xx+|\*{2,}|\.{3,})\s*(\d{4})\b',
      caseSensitive: false,
    );
    for (final match in re.allMatches(text)) {
      final val = match.group(1);
      if (val != null && val.isNotEmpty) hits.add(val);
    }
    return hits.toList();
  }

  /// Scan one message for cards from [catalogue].
  static List<DiscoveredCard> discoverInMessage({
    String? subject,
    String? body,
    String? sender,
    required List<CardProduct> catalogue,
  }) {
    final combined = [subject, body, sender].where((s) => s != null && s.isNotEmpty).join(' ');
    final haystack = normalise(combined);
    if (haystack.isEmpty) return const [];

    final haystackWords = Set<String>.from(haystack.split(' '));
    final results = <DiscoveredCard>[];

    for (final card in catalogue) {
      final nameTokens = significantTokens(card.name);
      if (nameTokens.isEmpty) continue;

      final matchedNameTokens = nameTokens.where((t) => haystackWords.contains(t)).toList();
      final fullName = normalise(card.name);
      final exact = fullName.isNotEmpty && haystack.contains(fullName);

      final issuerTokens = significantTokens(card.issuerName ?? '');
      final issuerHit = issuerTokens.isNotEmpty && issuerTokens.every((t) => haystack.contains(t));

      final distinguishing = matchedNameTokens.where((t) => !issuerTokens.contains(t)).toList();
      if (!exact && !(issuerHit && distinguishing.isNotEmpty)) continue;

      final evidence = exact
          ? [card.name]
          : [if (card.issuerName != null) card.issuerName!, ...distinguishing];

      final score = exact
          ? 1.0
          : 0.5 + 0.5 * (distinguishing.length / (nameTokens.length - issuerTokens.length).clamp(1, 999));

      results.add(
        DiscoveredCard(
          cardProductId: card.id,
          name: card.name,
          score: score,
          evidence: evidence,
          last4: extractLast4(combined),
          messageCount: 1,
          sources: const ['sms'],
        ),
      );
    }

    results.sort((a, b) {
      final cmp = b.score.compareTo(a.score);
      return cmp != 0 ? cmp : a.name.compareTo(b.name);
    });
    return results;
  }

  /// Fold multiple messages into one consolidated suggestion list.
  static CardDiscoveryResult discoverAcrossMessages({
    required List<String> smsBodies,
    required List<CardProduct> catalogue,
  }) {
    final byCard = <String, DiscoveredCard>{};

    for (final body in smsBodies) {
      final hits = discoverInMessage(body: body, catalogue: catalogue);
      final last4s = extractLast4(body);

      for (final hit in hits) {
        final existing = byCard[hit.cardProductId];
        if (existing != null) {
          final mergedEvidence = List<String>.from(existing.evidence);
          for (final e in hit.evidence) {
            if (!mergedEvidence.contains(e)) mergedEvidence.add(e);
          }
          final mergedLast4 = List<String>.from(existing.last4);
          for (final l in last4s) {
            if (!mergedLast4.contains(l)) mergedLast4.add(l);
          }
          byCard[hit.cardProductId] = DiscoveredCard(
            cardProductId: hit.cardProductId,
            name: hit.name,
            score: hit.score > existing.score ? hit.score : existing.score,
            evidence: mergedEvidence,
            last4: mergedLast4,
            messageCount: existing.messageCount + 1,
            sources: existing.sources,
          );
        } else {
          byCard[hit.cardProductId] = DiscoveredCard(
            cardProductId: hit.cardProductId,
            name: hit.name,
            score: hit.score,
            evidence: hit.evidence,
            last4: last4s,
            messageCount: 1,
            sources: const ['sms'],
          );
        }
      }
    }

    final suggestions = byCard.values.toList()
      ..sort((a, b) {
        final cmpScore = b.score.compareTo(a.score);
        if (cmpScore != 0) return cmpScore;
        final cmpCount = b.messageCount.compareTo(a.messageCount);
        if (cmpCount != 0) return cmpCount;
        return a.name.compareTo(b.name);
      });

    return CardDiscoveryResult(
      suggestions: suggestions,
      emailsScanned: 0,
      smsScanned: smsBodies.length,
    );
  }
}
