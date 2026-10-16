import 'package:pandapay_domain/pandapay_domain.dart';

import 'user_cards_repository.dart' show DiscoveredCard, UserCard;

/// Marks suggestions that already describe a physical card in the wallet and
/// keeps known catalogue cards visible even when the current scan did not
/// return a matching message for them.
///
/// The API historically filtered only by catalogue product id. That is not
/// enough for SMS-only matches: an alert such as "HDFC card ending 8708"
/// can produce a generic HDFC placeholder while the wallet already contains
/// the named HDFC card ending 8708. Matching issuer + suffix (and respecting
/// credit/debit when both are known) prevents the duplicate-card flow without
/// hiding a different product that happens to share a suffix.
List<DiscoveredCard> filterOwnedCardSuggestions({
  required Iterable<DiscoveredCard> suggestions,
  required Iterable<UserCard> ownedCards,
  required Iterable<CardProduct> catalogue,
}) {
  final productsById = <String, CardProduct>{
    for (final product in catalogue) product.id: product,
  };
  final ownedPhysical = ownedCards
      .where((card) => card.last4 != null && card.last4!.trim().isNotEmpty)
      .map((card) {
        final product = productsById[card.cardProductId];
        return _OwnedPhysicalCard(
          issuer: _normalise(product?.issuerName ?? ''),
          last4: _normaliseLast4(card.last4),
          cardType: card.cardType ?? product?.cardType,
          cardName: card.cardName,
        );
      })
      .where((card) => card.issuer.isNotEmpty && card.last4 != null)
      .toList();

  final ownedPhysicalMatches = <int, _OwnedPhysicalCard>{};
  final ownedSuffixesWithKnownIssuer = <String>{};

  for (var index = 0; index < suggestions.length; index++) {
    final suggestion = suggestions.elementAt(index);
    final issuer = _normalise(suggestion.issuerName ?? '');
    if (issuer.isEmpty || suggestion.last4.isEmpty) continue;
    for (final owned in ownedPhysical) {
      final matches = suggestion.last4.any((last4) {
        final normalizedLast4 = _normaliseLast4(last4);
        return normalizedLast4 != null &&
            owned.issuer == issuer &&
            owned.last4 == normalizedLast4 &&
            (suggestion.cardType == null ||
                owned.cardType == null ||
                suggestion.cardType == owned.cardType);
      });
      if (matches) {
        ownedPhysicalMatches[index] = owned;
        for (final last4 in suggestion.last4) {
          final normalizedLast4 = _normaliseLast4(last4);
          if (normalizedLast4 != null) {
            ownedSuffixesWithKnownIssuer.add(normalizedLast4);
          }
        }
        break;
      }
    }
  }

  final filtered = suggestions
      .toList()
      .asMap()
      .entries
      .where((entry) {
        final suggestion = entry.value;
        // If this scan has already produced an issuer-specific, wallet-owned
        // match for a suffix, drop the parallel issuer-less placeholder. Keep an
        // issuer-less suffix when it is the only evidence, because another bank
        // can legitimately share the same last four digits.
        final issuerless = _normalise(suggestion.issuerName ?? '').isEmpty;
        final duplicateGeneric =
            issuerless &&
            suggestion.last4.any((last4) {
              final normalizedLast4 = _normaliseLast4(last4);
              return normalizedLast4 != null &&
                  ownedSuffixesWithKnownIssuer.contains(normalizedLast4);
            });
        return !duplicateGeneric;
      })
      .map((entry) {
        final suggestion = entry.value;
        final exactProduct = ownedCards
            .where((card) => card.cardProductId == suggestion.cardProductId)
            .firstOrNull;
        if (exactProduct != null) {
          return suggestion.copyWith(
            name: exactProduct.cardName,
            isAlreadyOwned: true,
          );
        }
        final physicalMatch = ownedPhysicalMatches[entry.key];
        return physicalMatch == null
            ? suggestion
            : suggestion.copyWith(
                name: physicalMatch.cardName,
                isAlreadyOwned: true,
              );
      })
      .toList();

  // Discovery is evidence from this scan, not the source of truth for the
  // wallet. A provider can omit an older/issuer-specific SMS match while the
  // card is still validly owned. Keep that known card on this screen so it is
  // visibly accounted for and cannot look like an addable duplicate.
  final representedPhysicalKeys = <String>{};
  for (final suggestion in filtered) {
    final issuer = _normalise(suggestion.issuerName ?? '');
    if (issuer.isEmpty) continue;
    for (final last4 in suggestion.last4) {
      final normalizedLast4 = _normaliseLast4(last4);
      if (normalizedLast4 != null) {
        representedPhysicalKeys.add('$issuer|$normalizedLast4');
      }
    }
  }

  final knownWalletRows = <DiscoveredCard>[];
  final representedProductIds = filtered
      .map((suggestion) => suggestion.cardProductId)
      .toSet();
  final appendedProductIds = <String>{};
  for (final owned in ownedCards) {
    if (representedProductIds.contains(owned.cardProductId) ||
        appendedProductIds.contains(owned.cardProductId)) {
      continue;
    }
    final product = productsById[owned.cardProductId];
    if (product == null) continue;

    final issuer = _normalise(product.issuerName ?? '');
    final last4 = _normaliseLast4(owned.last4);
    if (last4 != null && representedPhysicalKeys.contains('$issuer|$last4')) {
      continue;
    }

    appendedProductIds.add(owned.cardProductId);
    knownWalletRows.add(
      DiscoveredCard(
        cardProductId: product.id,
        name: owned.cardName.isEmpty ? product.name : owned.cardName,
        score: 1,
        evidence: const ['Already in your wallet'],
        last4: last4 == null ? const [] : [last4],
        messageCount: 0,
        sources: const ['wallet'],
        issuerName: product.issuerName,
        cardType: owned.cardType ?? product.cardType,
        isAlreadyOwned: true,
      ),
    );
  }

  return [...filtered, ...knownWalletRows];
}

class _OwnedPhysicalCard {
  final String issuer;
  final String? last4;
  final String? cardType;
  final String cardName;

  const _OwnedPhysicalCard({
    required this.issuer,
    required this.last4,
    required this.cardType,
    required this.cardName,
  });
}

String _normalise(String value) => value
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

String? _normaliseLast4(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}
