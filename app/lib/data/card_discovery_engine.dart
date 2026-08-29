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
    // Generic financial/transaction terms that shouldn't trigger matches on their own:
    'purchase',
    'mobile',
    'upi',
    'rupay',
    'visa',
    'mastercard',
    'premium',
    'rewards',
    'smart',
    'cashback',
    'save',
    'plus',
    'infinity',
    'wholesale',
    'online',
    'statement',
    'payment',
    'txn',
    'transaction',
    'spent',
    'debited',
    'credited',
    'account',
    'acct',
    'alert'
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

  /// Marketing / promotional SMS markers. A bank's own marketing blast
  /// names its card products in full ("Apply now for the Tata Neu Infinity
  /// HDFC Bank Credit Card") and, unfiltered, seeds the wallet with every
  /// card the bank sells. SMS discovery ignores these outright.
  /// Mirrors PROMO_MARKERS in api/src/card_discovery.js.
  static const List<String> promoMarkers = [
    'apply now', 'apply today', 'pre-approved', 'pre approved', 'preapproved',
    'lifetime free', 'ltf', 'no joining fee', 'no annual fee',
    'joining fee waived', 'annual fee waived', 'exclusive offer',
    'special offer', 'limited period', 'limited time', 'click here', 'hurry',
    't&c apply', 't & c apply', 'tnc apply', 'offer ends', 'offer valid',
    'get it now', 'avail now', 'you are eligible', "you're eligible",
    'you re eligible', 'eligible for', 'now eligible', 'congratulations',
    'know more', 'unlock', 'upgrade to', 'upgrade your', '0% interest',
    'no cost emi', 'emi offer', 'instant loan', 'personal loan', 'redeem now',
    'points expiring', 'expiring soon', 'bit.ly', 'tinyurl', 'http://',
    'https://', 'www.',
  ];

  /// Transaction / statement markers — the SMS shapes a card the user
  /// actually holds produces. Mirrors TXN_MARKERS in card_discovery.js.
  static const List<String> txnMarkers = [
    'spent', 'debited', 'credited', 'charged', 'txn', 'transaction',
    'purchase of', 'purchase at', ' paid ', 'used at', 'used for', 'withdrawn',
    'payment of', 'payment received', 'received on your', 'avl bal',
    'available balance', 'avl. bal', 'avl lmt', 'available limit',
    'outstanding', 'statement', 'amount due', 'due date', 'min amt due',
    'total amount due', 'e-statement', 'autopay', 'auto pay', 'auto-pay',
    'has been credited', 'has been debited',
  ];

  static bool looksPromotionalSms(String text) {
    final lower = text.toLowerCase();
    return promoMarkers.any(lower.contains);
  }

  static bool looksTransactionalSms(String text) {
    final lower = text.toLowerCase();
    return txnMarkers.any(lower.contains);
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
      
      final fullName = normalise(card.name);
      final exact = fullName.isNotEmpty && haystack.contains(fullName);

      if (nameTokens.isEmpty && !exact) continue;

      final matchedNameTokens = nameTokens.where((t) => haystackWords.contains(t)).toList();

      final issuerTokens = significantTokens(card.issuerName ?? '');
      final issuerHit = issuerTokens.isNotEmpty && issuerTokens.every((t) => haystack.contains(t));

      final distinguishing = matchedNameTokens.where((t) => !issuerTokens.contains(t)).toList();
      if (!exact && !(issuerHit && distinguishing.isNotEmpty)) continue;

      final evidence = exact
          ? [card.name]
          : [if (card.issuerName != null) card.issuerName!, ...distinguishing];

      // 2.0 for a verbatim product name (it stands alone as SMS evidence);
      // otherwise how much of the distinguishing part of the name we saw, in
      // (0.5, 1.0]. Ties are broken by messageCount downstream.
      final score = exact
          ? 2.0
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
    
    final issuers = catalogue
        .map((c) => c.issuerName)
        .whereType<String>()
        .where((s) => s.isNotEmpty)
        .toSet();

    for (final body in smsBodies) {
      // A card match is believable only when it rides on a real
      // transaction/statement alert, never a marketing blast that names the
      // bank's whole product line.
      if (looksPromotionalSms(body) || !looksTransactionalSms(body)) continue;

      final last4s = extractLast4(body);

      // SMS discovery: a masked card number in the SAME message is required. A
      // real spend/statement alert always carries "card ending 1234"; a
      // marketing blast that merely spells a card's name does not. This is the
      // single strongest signal separating a genuine alert from noise.
      if (last4s.isEmpty) continue;

      final hits = discoverInMessage(body: body, catalogue: catalogue);

      // Only trust CONFIDENT matches from SMS (score >= 1.0).
      final confidentHits = hits.where((h) => h.score >= 1.0).toList();

      if (confidentHits.isNotEmpty) {
        final maxScore = confidentHits.fold<double>(0, (max, h) => h.score > max ? h.score : max);
        var topHits = confidentHits.where((h) => h.score == maxScore).toList();

        // A message that names a card *family* without pinning one product
        // ("...Tata Neu Infinity...", matching both the HDFC and SBI row
        // equally) is ambiguous — surface nothing. Two catalogue rows that are
        // really the same card described twice (same issuer + distinguishing
        // tokens) are NOT ambiguous.
        if (topHits.length > 1 && maxScore < 2) {
          String signature(DiscoveredCard h) {
            final rest = h.evidence.skip(1).toList()..sort();
            return '${normalise(h.evidence.isEmpty ? '' : h.evidence.first)}|${rest.join(',')}';
          }
          final distinct = topHits.map(signature).toSet();
          if (distinct.length > 1) continue;
          topHits = [topHits.first];
        }

        for (final hit in topHits) {
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
      } else {
        // No exact match. Fallback to generating Placeholder cards based on Issuer.
        final haystack = normalise(body);
        for (final issuer in issuers) {
          final normIssuer = normalise(issuer);
          if (haystack.contains(normIssuer)) {
            final l4sToUse = last4s.isEmpty ? [''] : last4s;
            for (final l4 in l4sToUse) {
              final placeholderId = 'placeholder_${normIssuer}_$l4';
              final existing = byCard[placeholderId];
              
              if (existing != null) {
                byCard[placeholderId] = DiscoveredCard(
                  cardProductId: existing.cardProductId,
                  name: existing.name,
                  score: 0.1,
                  evidence: existing.evidence,
                  last4: existing.last4,
                  messageCount: existing.messageCount + 1,
                  sources: const ['sms'],
                  isPlaceholder: true,
                  issuerName: issuer,
                );
              } else {
                final nameSuffix = l4.isNotEmpty ? ' ending in $l4' : '';
                byCard[placeholderId] = DiscoveredCard(
                  cardProductId: placeholderId,
                  name: '$issuer Card$nameSuffix',
                  score: 0.1,
                  evidence: ['Transaction matched $issuer'],
                  last4: l4.isNotEmpty ? [l4] : const [],
                  messageCount: 1,
                  sources: const ['sms'],
                  isPlaceholder: true,
                  issuerName: issuer,
                );
              }
            }
          }
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
