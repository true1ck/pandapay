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
    'alert',
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
    return normalise(
      name,
    ).split(' ').where((t) => t.length > 1 && !stopwords.contains(t)).toList();
  }

  /// A bank-account reference and its trailing digits — "A/c XX1797",
  /// "Account No. XXXX 1772", "AC ...1234". Those digits are an *account*
  /// suffix, never a card number, so they must not be read as a card's
  /// last-4 (doing so let debit/UPI alerts masquerade as card alerts).
  /// Mirrors ACCOUNT_NUMBER_SPAN in api/src/card_discovery.js.
  static final RegExp _accountNumberSpan = RegExp(
    r'\b(?:a/c|ac|acct|account)\b(?:\s*(?:no\.?|number|#|ending(?:\s+(?:in|with))?))?\s*[:\-]?\s*[x*.•]*\s*\d{3,}'
    r'|\bbank\s+[x*•]+\s*\d{3,}'
    r'|\b(?:aadhaar|aadhar|uidai|pan|gstin)\b\s*[:\-]?\s*[x*.•]*\s*\d{3,}',
    caseSensitive: false,
  );

  /// Extracts last-4 digits mentioned in the text (e.g., "ending 4568", "XX4568", "****4568").
  /// Account-number spans ("A/c XX1797") are stripped first — see
  /// [_accountNumberSpan].
  static List<String> extractLast4(String text) {
    final cleaned = text.replaceAll(_accountNumberSpan, ' ');
    final hits = <String>{};
    final re = RegExp(
      r'(?:ending\s+in|ending\s+with|ending|no\.?\s*x+|xx+|\*{2,}|\.{3,}|\b(?:x+|dc))\s*(\d{4})\b',
      caseSensitive: false,
    );
    for (final match in re.allMatches(cleaned)) {
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
    'apply now',
    'apply today',
    'pre-approved',
    'pre approved',
    'preapproved',
    'lifetime free',
    'ltf',
    'no joining fee',
    'no annual fee',
    'joining fee waived',
    'annual fee waived',
    'exclusive offer',
    'special offer',
    'limited period',
    'limited time',
    'click here',
    'hurry',
    't&c apply',
    't & c apply',
    'tnc apply',
    'offer ends',
    'offer valid',
    'get it now',
    'avail now',
    'you are eligible',
    "you're eligible",
    'you re eligible',
    'eligible for',
    'now eligible',
    'congratulations',
    'know more',
    'unlock',
    'upgrade to',
    'upgrade your',
    '0% interest',
    'no cost emi',
    'emi offer',
    'instant loan',
    'personal loan',
    'redeem now',
    'points expiring',
    'expiring soon',
    'bit.ly',
    'tinyurl',
    'http://',
    'https://',
    'www.',
  ];

  /// Transaction / statement markers — the SMS shapes a card the user
  /// actually holds produces. Mirrors TXN_MARKERS in card_discovery.js.
  static const List<String> txnMarkers = [
    'spent',
    'debited',
    'credited',
    'charged',
    'txn',
    'transaction',
    'purchase of',
    'purchase at',
    ' paid ',
    'used at',
    'used for',
    'withdrawn',
    'payment of',
    'payment received',
    'received on your',
    'avl bal',
    'available balance',
    'avl. bal',
    'avl lmt',
    'available limit',
    'outstanding',
    'statement',
    'amount due',
    'due date',
    'min amt due',
    'total amount due',
    'e-statement',
    'autopay',
    'auto pay',
    'auto-pay',
    'has been credited',
    'has been debited',
  ];

  static bool looksPromotionalSms(String text) {
    final lower = text.toLowerCase();
    return promoMarkers.any(lower.contains);
  }

  static bool looksTransactionalSms(String text) {
    final lower = text.toLowerCase();
    return txnMarkers.any(lower.contains);
  }

  /// Account / debit-card alert markers. Account-only alerts must not become
  /// physical-card suggestions, while explicit debit-card alerts are kept as
  /// debit suggestions. Mirrors DEBIT_ACCOUNT_MARKERS in api/src/card_discovery.js.
  static const List<String> debitAccountMarkers = [
    'debit card',
    'a/c',
    'ac no',
    'acct',
    'account no',
    'from a/c',
    'to a/c',
    'savings a/c',
    'salary a/c',
    'imps',
    'neft',
    'atm',
    'upi/',
    'by upi',
    'vpa',
    'withdrawn from',
    'withdrawn rs',
    'block dc',
    ' dc ',
    'account ending',
    'deducted from',
    'deposited in',
  ];

  /// Credit-card-specific markers. Their presence overrides the debit filter
  /// above. Mirrors CREDIT_CARD_MARKERS in api/src/card_discovery.js.
  static const List<String> creditCardMarkers = [
    'credit card',
    'avl lmt',
    'available limit',
    'avl. limit',
    'credit limit',
    'outstanding',
    'statement',
    'min amt due',
    'minimum amount due',
    'total amount due',
    'amount due',
    'cc bill',
    'card bill',
    'block cc',
    ' cc ',
    'card ending with',
    'available credit',
  ];

  static bool looksDebitAccountSms(String text) {
    final lower = text.toLowerCase();
    return debitAccountMarkers.any(lower.contains);
  }

  static bool looksCreditCardSms(String text) {
    final lower = text.toLowerCase();
    return creditCardMarkers.any(lower.contains);
  }

  /// True when the message identifies a physical debit card, not a bank
  /// account. ATM/cash-withdrawal alerts are debit-card evidence too.
  static bool looksDebitCardSms(String text) {
    final lower = text.toLowerCase();
    return RegExp(r'\bdebit\s+card\b').hasMatch(lower) ||
        RegExp(
          r'\b(?:atm|cash\s+withdrawal|withdrawn\s+from\s+(?:your\s+)?(?:bank\s+)?card)\b',
        ).hasMatch(lower) ||
        RegExp(r'\bblock\s+dc\b').hasMatch(lower);
  }

  /// Scan one message for cards from [catalogue].
  static List<DiscoveredCard> discoverInMessage({
    String? subject,
    String? body,
    String? sender,
    required List<CardProduct> catalogue,
  }) {
    final combined = [
      subject,
      body,
      sender,
    ].where((s) => s != null && s.isNotEmpty).join(' ');
    final haystack = normalise(combined);
    if (haystack.isEmpty) return const [];

    final messageIsDebit = looksDebitCardSms(combined);
    final messageIsCredit = looksCreditCardSms(combined);

    final haystackWords = Set<String>.from(haystack.split(' '));
    final results = <DiscoveredCard>[];

    // Some issuers put only the product mark in the alert (for example
    // "MoneyBack+ xx8708" or "Flipkart card ending 7105") and keep the bank
    // name in the sender/header. A product token is safe without the issuer
    // only when it uniquely identifies one catalogue row; family words such
    // as Tata/Neu remain ambiguous and still require the issuer.
    final productTokenOwners = <String, Set<String>>{};
    for (final candidate in catalogue) {
      for (final token in significantTokens(candidate.name)) {
        productTokenOwners
            .putIfAbsent(token, () => <String>{})
            .add(candidate.id);
      }
    }

    for (final card in catalogue) {
      if (card.cardType == 'debit' && messageIsCredit && !messageIsDebit) {
        continue;
      }
      if (card.cardType == 'credit' && messageIsDebit && !messageIsCredit) {
        continue;
      }
      final nameTokens = significantTokens(card.name);

      final fullName = normalise(card.name);
      final exact = fullName.isNotEmpty && haystack.contains(fullName);

      if (nameTokens.isEmpty && !exact) continue;

      final matchedNameTokens = nameTokens
          .where((t) => haystackWords.contains(t))
          .toList();

      final issuerTokens = significantTokens(card.issuerName ?? '');
      final issuerHit =
          issuerTokens.isNotEmpty &&
          issuerTokens.every((t) => haystack.contains(t));

      final distinguishing = matchedNameTokens
          .where((t) => !issuerTokens.contains(t))
          .toList();
      final words = haystack.split(' ');
      final uniqueProductToken = distinguishing.any((token) {
        if (productTokenOwners[token]?.length != 1) return false;
        // A merchant name such as "Amazon" must not identify the Amazon Pay
        // card. Product-only evidence must sit next to card language or a
        // masked suffix ("MoneyBack+ card" / "MoneyBack+ xx8708").
        final tokenIndexes = <int>[];
        for (var i = 0; i < words.length; i++) {
          if (words[i] == token) tokenIndexes.add(i);
        }
        for (final index in tokenIndexes) {
          for (var distance = 1; distance <= 3; distance++) {
            final nextIndex = index + distance;
            if (nextIndex >= words.length) break;
            final next = words[nextIndex];
            if (next == 'card' ||
                next == 'ending' ||
                RegExp(r'^x{2,}\d{4}$').hasMatch(next)) {
              return true;
            }
          }
        }
        return false;
      });
      if (!exact &&
          !(issuerHit && distinguishing.isNotEmpty) &&
          !uniqueProductToken) {
        continue;
      }

      final evidence = exact
          ? [card.name]
          : [if (card.issuerName != null) card.issuerName!, ...distinguishing];

      // 2.0 for a verbatim product name (it stands alone as SMS evidence);
      // otherwise how much of the distinguishing part of the name we saw, in
      // (0.5, 1.0]. Ties are broken by messageCount downstream.
      final score = exact
          ? 2.0
          : 0.5 +
                0.5 *
                    (distinguishing.length /
                        (nameTokens.length - issuerTokens.length).clamp(
                          1,
                          999,
                        ));

      results.add(
        DiscoveredCard(
          cardProductId: card.id,
          name: card.name,
          score: score,
          evidence: evidence,
          last4: extractLast4(combined),
          messageCount: 1,
          sources: const ['sms'],
          issuerName: card.issuerName,
          cardType:
              card.cardType ??
              (messageIsDebit
                  ? 'debit'
                  : messageIsCredit
                  ? 'credit'
                  : null),
        ),
      );
    }

    results.sort((a, b) {
      final cmp = b.score.compareTo(a.score);
      return cmp != 0 ? cmp : a.name.compareTo(b.name);
    });
    return results;
  }

  /// A suffix is not globally unique, but issuer + suffix + instrument type
  /// is the best physical-card identity available in an SMS. Once one named
  /// catalogue product wins that identity, do not present sibling products
  /// for the same card. Exact product evidence beats a weaker hint.
  static List<DiscoveredCard> _consolidateNamedPhysicalCards({
    required Iterable<DiscoveredCard> suggestions,
    required List<CardProduct> catalogue,
  }) {
    final productsById = <String, CardProduct>{
      for (final product in catalogue) product.id: product,
    };
    String? issuerFor(DiscoveredCard suggestion) =>
        suggestion.issuerName ??
        productsById[suggestion.cardProductId]?.issuerName;
    String typeFor(DiscoveredCard suggestion) =>
        suggestion.cardType ??
        productsById[suggestion.cardProductId]?.cardType ??
        'unknown';
    List<String> keysFor(DiscoveredCard suggestion) {
      if (suggestion.isPlaceholder) return const [];
      final issuer = normalise(issuerFor(suggestion) ?? '');
      if (issuer.isEmpty || suggestion.last4.isEmpty) return const [];
      final type = normalise(typeFor(suggestion));
      return suggestion.last4.map((last4) => '$issuer|$type|$last4').toList();
    }

    bool stronger(DiscoveredCard candidate, DiscoveredCard incumbent) =>
        candidate.score > incumbent.score ||
        (candidate.score == incumbent.score &&
            candidate.messageCount > incumbent.messageCount) ||
        (candidate.score == incumbent.score &&
            candidate.messageCount == incumbent.messageCount &&
            candidate.evidence.length > incumbent.evidence.length);

    final winners = <String, DiscoveredCard>{};
    for (final suggestion in suggestions) {
      for (final key in keysFor(suggestion)) {
        final incumbent = winners[key];
        if (incumbent == null || stronger(suggestion, incumbent)) {
          winners[key] = suggestion;
        }
      }
    }

    return suggestions.expand((suggestion) {
      final keys = keysFor(suggestion);
      if (keys.isEmpty) return [suggestion];
      final issuer = normalise(issuerFor(suggestion) ?? '');
      final type = normalise(typeFor(suggestion));
      final keptLast4 = suggestion.last4
          .where(
            (last4) =>
                winners['$issuer|$type|$last4']?.cardProductId ==
                suggestion.cardProductId,
          )
          .toList();
      if (keptLast4.isEmpty) return const <DiscoveredCard>[];
      if (keptLast4.length == suggestion.last4.length) return [suggestion];
      return [
        DiscoveredCard(
          cardProductId: suggestion.cardProductId,
          name: suggestion.name,
          score: suggestion.score,
          evidence: suggestion.evidence,
          last4: keptLast4,
          messageCount: suggestion.messageCount,
          sources: suggestion.sources,
          isPlaceholder: suggestion.isPlaceholder,
          issuerName: suggestion.issuerName,
          cardType: suggestion.cardType,
          creditLimit: suggestion.creditLimit,
          isAlreadyOwned: suggestion.isAlreadyOwned,
        ),
      ];
    }).toList();
  }

  /// Fold multiple messages into one consolidated suggestion list.
  /// [isSms] applies the stricter SMS-only gating (promo/transaction markers,
  /// a mandatory masked card number in the same message, confident matches
  /// only, family-ambiguity suppression, and the issuer placeholder
  /// fallback). The email path passes `false`: forwarded/fetched mail is
  /// already sender-verified upstream, so a plain statement line is trusted
  /// and partial issuer+token matches are kept. SMS and email are meant to
  /// widen each other's coverage, so email must not inherit SMS's filters.
  /// Mirrors the `isSms` parameter of `discoverCardsAcrossMessages` in
  /// api/src/card_discovery.js.
  static CardDiscoveryResult discoverAcrossMessages({
    required List<String> smsBodies,
    required List<CardProduct> catalogue,
    bool isSms = false,
  }) {
    final byCard = <String, DiscoveredCard>{};

    final issuers = catalogue
        .map((c) => c.issuerName)
        .whereType<String>()
        .where((s) => s.isNotEmpty)
        .toSet();

    // Pre-pass: an issuer + last-4 that appears in ANY debit/account alert is
    // "poisoned" — no issuer placeholder is offered for it even if another,
    // wordless message ("Rs 500 on card ending 1234") would otherwise seed
    // one. One "…debited from A/c …1234 via UPI" is enough. Keyed
    // "<normalised issuer>|<last4>" ('' last4 = the issuer with no number).
    final debitPoisoned = <String>{};
    final debitCardPoisoned = <String>{};
    if (isSms) {
      for (final body in smsBodies) {
        final explicitDebitCard =
            looksDebitCardSms(body) && !looksCreditCardSms(body);
        if (explicitDebitCard) {
          final low = normalise(body);
          final l4s = extractLast4(body);
          for (final issuer in issuers) {
            if (!low.contains(normalise(issuer))) continue;
            final ni = normalise(issuer);
            debitCardPoisoned.add('$ni|');
            for (final l in l4s) {
              debitCardPoisoned.add('$ni|$l');
            }
          }
        }
        final accountOnly =
            looksDebitAccountSms(body) &&
            !looksCreditCardSms(body) &&
            !looksDebitCardSms(body);
        if (!accountOnly) continue;
        final low = normalise(body);
        final l4s = extractLast4(body);
        for (final issuer in issuers) {
          if (!low.contains(normalise(issuer))) continue;
          final ni = normalise(issuer);
          debitPoisoned.add('$ni|');
          for (final l in l4s) {
            debitPoisoned.add('$ni|$l');
          }
        }
      }
    }

    for (final body in smsBodies) {
      // SMS only: a card match is believable only when it rides on a real
      // transaction/statement alert, never a marketing blast that names the
      // bank's whole product line. Email is sender-verified upstream.
      if (isSms &&
          (looksPromotionalSms(body) || !looksTransactionalSms(body))) {
        continue;
      }

      final last4s = extractLast4(body);

      // SMS only: a masked card number in the SAME message is required. A real
      // spend/statement alert always carries "card ending 1234"; a marketing
      // blast that merely spells a card's name does not. Email statements
      // frequently omit any masked number, so this gate would drop them.
      if (isSms && last4s.isEmpty) continue;

      final hits = discoverInMessage(body: body, catalogue: catalogue);

      // SMS only: trust CONFIDENT matches (score >= 1.0). Email keeps partial
      // issuer+token matches so a card SMS never saw can still be surfaced.
      final confidentHits = isSms
          ? hits.where((h) => h.score >= 1.0).toList()
          : hits;

      if (confidentHits.isNotEmpty) {
        final maxScore = confidentHits.fold<double>(
          0,
          (max, h) => h.score > max ? h.score : max,
        );
        var topHits = confidentHits.where((h) => h.score == maxScore).toList();

        // A message that names a card *family* without pinning one product
        // ("...Tata Neu Infinity...", matching both the HDFC and SBI row
        // equally) is ambiguous — surface nothing. Two catalogue rows that are
        // really the same card described twice (same issuer + distinguishing
        // tokens) are NOT ambiguous.
        if (isSms && topHits.length > 1 && maxScore < 2) {
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
              isPlaceholder: existing.isPlaceholder,
              issuerName: existing.issuerName ?? hit.issuerName,
              cardType: existing.cardType ?? hit.cardType,
              creditLimit: existing.creditLimit ?? hit.creditLimit,
              isAlreadyOwned: existing.isAlreadyOwned,
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
              issuerName: hit.issuerName,
              cardType: hit.cardType,
            );
          }
        }
      } else if (isSms) {
        // A bank-account/UPI alert has no physical card to rank. An explicit
        // debit-card alert is different: preserve it as a debit suggestion.
        final explicitDebitCard =
            looksDebitCardSms(body) && !looksCreditCardSms(body);
        if (looksDebitAccountSms(body) &&
            !looksCreditCardSms(body) &&
            !explicitDebitCard) {
          continue;
        }
        final placeholderType = explicitDebitCard ? 'debit' : 'credit';
        final placeholderLabel = explicitDebitCard
            ? 'Debit card'
            : 'Credit card';

        // No exact match. Fallback to generating Placeholder cards based on Issuer.
        final haystack = normalise(body);
        final matchingIssuers = issuers
            .where((issuer) => haystack.contains(normalise(issuer)))
            .toList();

        // Some bank alerts identify only "your credit card XX9080". We
        // cannot infer the catalogue product, but we can preserve the suffix
        // as a generic placeholder for the user to choose from.
        if (matchingIssuers.isEmpty && last4s.isNotEmpty) {
          for (final l4 in last4s) {
            final placeholderId = explicitDebitCard
                ? 'placeholder_debit_card_$l4'
                : 'placeholder_card_$l4';
            final existing = byCard[placeholderId];
            if (existing != null) {
              byCard[placeholderId] = DiscoveredCard(
                cardProductId: existing.cardProductId,
                name: existing.name,
                score: existing.score,
                evidence: existing.evidence,
                last4: existing.last4,
                messageCount: existing.messageCount + 1,
                sources: const ['sms'],
                isPlaceholder: true,
                cardType: placeholderType,
              );
            } else {
              byCard[placeholderId] = DiscoveredCard(
                cardProductId: placeholderId,
                name: '$placeholderLabel ending in $l4',
                score: 0.1,
                evidence: ['Transaction matched card ending in $l4'],
                last4: [l4],
                messageCount: 1,
                sources: const ['sms'],
                isPlaceholder: true,
                cardType: placeholderType,
              );
            }
          }
        }

        for (final issuer in matchingIssuers) {
          final normIssuer = normalise(issuer);
          final l4sToUse = last4s.isEmpty ? [''] : last4s;
          for (final l4 in l4sToUse) {
            // Skip a card this issuer was seen debiting an account for.
            if (!explicitDebitCard &&
                (debitPoisoned.contains('$normIssuer|$l4') ||
                    debitCardPoisoned.contains('$normIssuer|$l4'))) {
              continue;
            }
            final placeholderId = explicitDebitCard
                ? 'placeholder_debit_${normIssuer}_$l4'
                : 'placeholder_${normIssuer}_$l4';
            final existing = byCard[placeholderId];

            if (existing != null) {
              byCard[placeholderId] = DiscoveredCard(
                cardProductId: existing.cardProductId,
                name: existing.name,
                score: existing.score,
                evidence: existing.evidence,
                last4: existing.last4,
                messageCount: existing.messageCount + 1,
                sources: const ['sms'],
                isPlaceholder: true,
                issuerName: issuer,
                cardType: placeholderType,
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
                cardType: placeholderType,
              );
            }
          }
        }
      }
    }

    // Reconcile placeholders against the real, named cards. A placeholder
    // that shares an issuer + last-4 with a confident match is that same
    // card discovered a second way; its "pick from catalogue" prompt would
    // ask the user to identify a card we already identified. Drop it.
    final issuerById = <String, String>{
      for (final c in catalogue)
        if (c.issuerName != null && c.issuerName!.isNotEmpty)
          c.id: c.issuerName!,
    };
    final realKeys = <String>{};
    for (final s in byCard.values) {
      if (s.isPlaceholder) continue;
      final iss = normalise(issuerById[s.cardProductId] ?? '');
      for (final l in s.last4) {
        realKeys.add('$iss|$l');
      }
    }
    byCard.removeWhere(
      (_, s) =>
          s.isPlaceholder &&
          s.last4.any(
            (l) => realKeys.contains('${normalise(s.issuerName ?? '')}|$l'),
          ),
    );

    final suggestions =
        _consolidateNamedPhysicalCards(
          suggestions: byCard.values,
          catalogue: catalogue,
        ).toList()..sort((a, b) {
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
