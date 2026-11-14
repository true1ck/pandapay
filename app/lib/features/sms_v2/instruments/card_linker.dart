import 'package:pandapay_domain/pandapay_domain.dart' show CardProduct;
import 'package:pandapay_domain/sms_v2.dart' show Instrument, InstrumentKind;

import '../../../data/card_discovery_engine.dart' show LocalCardDiscoveryEngine;
import '../../../data/user_cards_repository.dart' show DiscoveredCard, UserCard;
import '../storage/instrument_store.dart';
import 'card_pairing.dart';
import 'issuer_slugs.dart';

/// What happened when a confirmed card was linked to the wallet.
sealed class CardLinkResult {
  const CardLinkResult();
}

/// Exactly one `user_cards` row matched; [instrument] now carries its id.
final class CardLinked extends CardLinkResult {
  const CardLinked(this.instrument, this.userCard);
  final Instrument instrument;
  final UserCard userCard;
}

/// No single wallet card matched. WP-15 opens the add-card flow prefilled with
/// [issuerSlug] and [maskDigits], offering [suggestions] (at most 3).
final class CardNeedsProduct extends CardLinkResult {
  const CardNeedsProduct({
    required this.instrument,
    required this.issuerSlug,
    required this.maskDigits,
    required this.suggestions,
  });
  final Instrument instrument;
  final String issuerSlug;
  final String? maskDigits;
  final List<DiscoveredCard> suggestions;
}

/// The instrument already has a `userCardId`; nothing to do.
final class CardAlreadyLinked extends CardLinkResult {
  const CardAlreadyLinked(this.instrument);
  final Instrument instrument;
}

/// Links a credit card the user confirmed to the wallet card it is, so the
/// rewards engine keeps reading `user_cards` unchanged.
class InstrumentCardLinker {
  InstrumentCardLinker({
    required this.store,
    required this.issuerSlugOf,
    required this.catalogue,
    this.maxSuggestions = 3,
  });

  final InstrumentStore store;

  /// A wallet card's issuer slug (see `cardIssuerSlugFromCatalogue`).
  final String? Function(UserCard) issuerSlugOf;
  final List<CardProduct> catalogue;
  final int maxSuggestions;

  /// Links [card] (a confirmed credit card without a `userCardId`).
  ///
  /// If exactly one row of [userCards] has the same issuer and last 4 digits,
  /// and no other instrument already uses it, the instrument is linked and
  /// saved. So is the one wallet card that has no last 4 when it is the only
  /// card this issuer could be (see [CardPairing]). Otherwise returns [CardNeedsProduct] with up to [maxSuggestions]
  /// catalogue products read from [smsBodies] (the card's own messages; they
  /// stay on the phone) through the existing discovery engine, which is only
  /// called, never changed.
  CardLinkResult link(
    Instrument card, {
    required List<UserCard> userCards,
    List<String> smsBodies = const [],
  }) {
    if (card.userCardId != null) return CardAlreadyLinked(card);
    final digits = card.maskDigits;
    final last4 = _last4(digits);

    if (last4 != null) {
      final matches = [
        for (final u in userCards)
          if (!u.isArchived &&
              u.last4 == last4 &&
              issuerSlugOf(u) == card.issuerSlug &&
              _free(u, card))
            u,
      ];
      if (matches.length == 1) {
        final linked = card.copyWith(userCardId: matches.single.id);
        store.upsert(linked);
        return CardLinked(linked, matches.single);
      }
    }

    // No wallet card ends in these digits. A wallet card added without its
    // last 4 can still be the one, when nothing else could be: it is then the
    // issuer's only such card and this is the only found card it could be.
    final paired = CardPairing(
      instruments: store.list(),
      wallet: userCards,
      issuerSlugOf: issuerSlugOf,
    ).cardForInstrument(card);
    if (paired != null) {
      final linked = card.copyWith(userCardId: paired.id);
      store.upsert(linked);
      return CardLinked(linked, paired);
    }
    return CardNeedsProduct(
      instrument: card,
      issuerSlug: card.issuerSlug,
      maskDigits: digits,
      suggestions: _suggest(card, smsBodies),
    );
  }

  static String? _last4(String? mask) =>
      mask == null || mask.length < 4 ? null : mask.substring(mask.length - 4);

  /// A wallet card not already tied to another instrument.
  bool _free(UserCard u, Instrument card) {
    final owner = store.findByUserCardId(u.id);
    return owner == null || owner.instrumentId == card.instrumentId;
  }

  List<DiscoveredCard> _suggest(Instrument card, List<String> smsBodies) {
    if (smsBodies.isEmpty || catalogue.isEmpty) return const [];
    final found = LocalCardDiscoveryEngine.discoverAcrossMessages(
      smsBodies: smsBodies,
      catalogue: catalogue,
      isSms: true,
    );
    final issuerById = <String, String?>{
      for (final p in catalogue) p.id: p.issuerName,
    };
    final wantCredit = card.kind == InstrumentKind.creditCard;
    final last4 = _last4(card.maskDigits);
    final fits =
        [
          for (final s in found.suggestions)
            if (!s.isPlaceholder &&
                !s.isAlreadyOwned &&
                (s.cardType == null ||
                    (s.cardType == 'credit') == wantCredit) &&
                v2IssuerSlugFromName(
                      s.issuerName ?? issuerById[s.cardProductId],
                    ) ==
                    card.issuerSlug &&
                (last4 == null || s.last4.isEmpty || s.last4.contains(last4)))
              s,
        ]..sort((a, b) {
          final c = b.score.compareTo(a.score);
          return c != 0 ? c : a.name.compareTo(b.name);
        });
    return fits.take(maxSuggestions).toList();
  }
}
