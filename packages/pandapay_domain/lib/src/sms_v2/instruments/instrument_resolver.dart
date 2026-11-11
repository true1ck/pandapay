import 'dart:math';

import '../contract/enums.dart';
import '../contract/instrument.dart';
import '../contract/interfaces.dart';
import '../contract/rule_bundle.dart';
import '../contract/types.dart';

/// Why a mention was sent to review instead of resolving.
enum InstrumentReviewReason {
  /// Two or more instruments fit the mention.
  ambiguous,

  /// The matching instrument was rejected by the user.
  rejected,

  /// The mention names an issuer and a mask but no kind, and no instrument
  /// fits. A kind is needed to create one.
  kindUnknown,
}

/// Why a mention produced no instrument and needs no review either.
enum InstrumentNotCreatedReason {
  /// The mention has no issuer.
  noIssuer,

  /// A bank account, card or loan without a mask, and no single instrument of
  /// that issuer and kind to attach it to.
  noIdentity,

  /// Neither a mask nor a kind: nothing to identify.
  emptyMention,

  /// A UPI-app sender never creates a bank account from a mask alone. The
  /// digits in such a message belong to the counterparty.
  upiAppMask,

  /// A wallet with `walletSpendVisibility: partial` (Amazon Pay) is wallet
  /// activity only, so it never becomes an instrument by itself.
  partialWallet,
}

/// What the resolver decided for one mention.
sealed class InstrumentOutcome {
  const InstrumentOutcome();
}

/// The mention maps to [resolution].instrument, which is new when
/// [InstrumentResolution.created] is true. A new instrument is `detected` and
/// not yet stored; the caller stores it.
final class InstrumentResolved extends InstrumentOutcome {
  const InstrumentResolved(this.resolution);
  final InstrumentResolution resolution;
}

/// Nothing was created. A person should look at this mention.
final class InstrumentReviewNeeded extends InstrumentOutcome {
  const InstrumentReviewNeeded(this.reason, {this.candidates = const []});
  final InstrumentReviewReason reason;
  final List<Instrument> candidates;
}

/// Nothing was created and nothing needs review: the message simply does not
/// say enough to name one of the user's instruments.
final class InstrumentNotCreated extends InstrumentOutcome {
  const InstrumentNotCreated(this.reason);
  final InstrumentNotCreatedReason reason;
}

/// Thrown by [DefaultInstrumentResolver.resolve] (the frozen interface method,
/// which can only return a resolution) when the mention did not resolve. Call
/// [DefaultInstrumentResolver.resolveDetailed] to get the outcome without it.
class InstrumentNotResolvedException implements Exception {
  const InstrumentNotResolvedException(this.outcome);
  final InstrumentOutcome outcome;

  @override
  String toString() => 'InstrumentNotResolvedException($outcome)';
}

/// Kinds that have no printed mask. One instrument per issuer and kind is
/// enough to identify them.
const Set<InstrumentKind> maskFreeKinds = {
  InstrumentKind.wallet,
  InstrumentKind.broker,
  InstrumentKind.payLater,
};

/// Sender brands that are UPI apps rather than the issuer of the account.
/// The contract's `issuerKind` has no `upi_app` value, so the resolver takes
/// the set from here (or from its constructor). A brand that contains `UPI`
/// counts too.
const Set<String> defaultUpiAppSenderBrands = {
  'SBIUPI',
  'PHONPE',
  'GPAY',
  'GOOGPAY',
  'BHIM',
  'BHIMUP',
  'NPCIUP',
  'AMAZUP',
};

/// The default [InstrumentResolver]. Matching order (Contracts, Instrument):
///
/// 1. Exact key match: kind, issuer, mask digits.
/// 2. No kind in the mention: the one instrument with that issuer and mask.
/// 3. No mask in the mention: the one instrument with that issuer and kind.
/// 4. Otherwise create a new `detected` instrument.
///
/// Never merges across issuers. A card and an account with the same digits
/// stay separate because their kind differs. Identity never uses
/// `maskLength` (the engine fills it with the number of printed digits, which
/// is not the length of the card number), and never uses the sender id: one
/// account can write from several sender ids.
class DefaultInstrumentResolver implements InstrumentResolver {
  DefaultInstrumentResolver({
    String Function()? idGenerator,
    String Function(String issuerSlug)? issuerLabel,
    Set<String> upiAppSenderBrands = defaultUpiAppSenderBrands,
    Set<String> partialWalletIssuers = const {},
  }) : _newId = idGenerator ?? generateUuidV4,
       _issuerLabel = issuerLabel ?? defaultIssuerLabel,
       _upiBrands = upiAppSenderBrands,
       _partialWallets = partialWalletIssuers;

  /// A resolver that reads the wallet visibility of each issuer from the
  /// bundle's `senders`.
  factory DefaultInstrumentResolver.fromBundle(
    RuleBundle bundle, {
    String Function()? idGenerator,
    String Function(String issuerSlug)? issuerLabel,
  }) => DefaultInstrumentResolver(
    idGenerator: idGenerator,
    issuerLabel: issuerLabel,
    partialWalletIssuers: {
      for (final s in bundle.senders)
        if (s.issuerSlug != null && s.walletSpendVisibility == WalletSpendVisibility.partial)
          s.issuerSlug!,
    },
  );

  final String Function() _newId;
  final String Function(String) _issuerLabel;
  final Set<String> _upiBrands;
  final Set<String> _partialWallets;

  /// The frozen interface method. Returns the resolution, or throws
  /// [InstrumentNotResolvedException] when the mention needs review or names
  /// nothing. Use [resolveDetailed] to branch on the outcome.
  @override
  InstrumentResolution resolve(
    InstrumentMention mention,
    Iterable<Instrument> known, {
    required String profileId,
    required DateTime observedAt,
  }) {
    final outcome = resolveDetailed(mention, known, profileId: profileId, observedAt: observedAt);
    if (outcome is InstrumentResolved) return outcome.resolution;
    throw InstrumentNotResolvedException(outcome);
  }

  /// Resolves [mention] against [known] (the instruments of [profileId]).
  ///
  /// [senderBrand] is the normalised sender brand. It becomes an alias on a
  /// new instrument and feeds the UPI-app rule; it is never part of identity.
  ///
  /// [createWithoutMask] lets a credit card with NO printed number become an
  /// instrument when nothing of that issuer and kind exists yet. Pass it only
  /// for a fact that proves money moved on the card (a spend, a refund, a
  /// payment receipt): the card is then the source of that money, and some
  /// issuers (for example a co-branded card app) never print a number in any
  /// message. A mask that was printed but is unusable never counts as "no mask"
  /// (it may be a reference number), and accounts, debit cards, prepaid cards
  /// and loans are never created without a number: a bank has many of them and
  /// a message that omits the number cannot say which.
  ///
  /// [adoptNumberlessCard] lets a message that prints a number complete a card
  /// that has none. Pass false for a payment receipt: issuers print the card
  /// ACCOUNT number there (see `cardPaymentMayCreateCard`), which is not the
  /// number on the card, and stamping it on the card would split it in two when
  /// the first spend alert arrives.
  InstrumentOutcome resolveDetailed(
    InstrumentMention mention,
    Iterable<Instrument> known, {
    required String profileId,
    required DateTime observedAt,
    String? senderBrand,
    bool createWithoutMask = false,
    bool adoptNumberlessCard = true,
  }) {
    final issuer = mention.issuerSlug;
    if (issuer == null || issuer.isEmpty) {
      // A notice that gives only a number ("transferred to your account
      // XXXX1234", sent by the payer's bank) names no issuer. It can only point
      // at an account the user already has; it never creates one.
      final only = instrumentByNumberOnly(mention.kind, mention.maskDigits, known);
      return only == null
          ? const InstrumentNotCreated(InstrumentNotCreatedReason.noIssuer)
          : InstrumentResolved(InstrumentResolution(instrument: only, created: false));
    }
    final kind = mention.kind;
    final mask = _cleanMask(mention.maskDigits);
    if (kind == null && mask == null) {
      return const InstrumentNotCreated(InstrumentNotCreatedReason.emptyMention);
    }
    final sameIssuer = [
      for (final i in known)
        if (i.issuerSlug == issuer) i,
    ];

    // 1. Exact key match, then the same number printed longer or shorter
    //    (SBI prints XXXXX728648 in one message and X8648 in another).
    if (kind != null && mask != null) {
      final exact = sameIssuer.where((i) => i.kind == kind && i.maskDigits == mask).toList();
      if (exact.isNotEmpty) return _pick(exact);
      final sameNumber = sameIssuer.where((i) => i.kind == kind && _sameNumberEnding(i.maskDigits, mask)).toList();
      if (sameNumber.isNotEmpty) return _pick(sameNumber);
      // A numbered message after a card that never had a number: one card.
      final numberless = adoptNumberlessCard ? _numberlessCardToAdopt(sameIssuer, kind, mention) : null;
      if (numberless != null) {
        return InstrumentResolved(
          InstrumentResolution(instrument: _withNumber(numberless, issuer, mask, mention), created: false),
        );
      }
    }
    // 2. No kind: the one instrument with that issuer and mask.
    if (kind == null) {
      final byMask = sameIssuer.where((i) => i.maskDigits == mask || _sameNumberEnding(i.maskDigits, mask)).toList();
      if (byMask.isNotEmpty) return _pick(byMask);
    }
    // 3. No mask: the one instrument with that issuer and kind. When a wallet
    //    was first seen without a number and later with one, the numbered one is
    //    the real instrument.
    if (mask == null) {
      final byKind = sameIssuer.where((i) => i.kind == kind).toList();
      final numbered = byKind.where((i) => i.maskDigits != null).toList();
      if (byKind.length > 1 && numbered.length == 1) return _pick(numbered);
      if (byKind.isNotEmpty) return _pick(byKind);
    }

    // 4. Create.
    if (kind == null) {
      // Issuer and mask but no kind, and nothing fits: we cannot pick a kind.
      return const InstrumentReviewNeeded(InstrumentReviewReason.kindUnknown);
    }
    if (mask == null && !maskFreeKinds.contains(kind)) {
      final nothingPrinted = mention.maskDigits == null;
      if (!(createWithoutMask && nothingPrinted && kind == InstrumentKind.creditCard)) {
        return const InstrumentNotCreated(InstrumentNotCreatedReason.noIdentity);
      }
    }
    if (kind == InstrumentKind.bankAccount && _isUpiApp(senderBrand)) {
      return const InstrumentNotCreated(InstrumentNotCreatedReason.upiAppMask);
    }
    if (kind == InstrumentKind.wallet && _partialWallets.contains(issuer)) {
      return const InstrumentNotCreated(InstrumentNotCreatedReason.partialWallet);
    }
    return InstrumentResolved(
      InstrumentResolution(
        instrument: _create(mention, kind, issuer, mask, observedAt, senderBrand),
        created: true,
      ),
    );
  }

  /// A rejected instrument is not a candidate: the user said it is not theirs.
  /// Among the others the match must be unique; when every candidate was
  /// rejected the mention belongs to something the user turned away.
  InstrumentOutcome _pick(List<Instrument> candidates) {
    final live = [
      for (final i in candidates)
        if (i.status != InstrumentStatus.rejected) i,
    ];
    if (live.isEmpty) {
      return InstrumentReviewNeeded(InstrumentReviewReason.rejected, candidates: candidates);
    }
    if (live.length > 1) {
      return InstrumentReviewNeeded(InstrumentReviewReason.ambiguous, candidates: live);
    }
    return InstrumentResolved(InstrumentResolution(instrument: live.single, created: false));
  }

  /// The credit card that [mention] (which prints a number) is most likely the
  /// same card as: the issuer's ONLY card, when it has no number, was found from
  /// messages (not linked by the user from the catalogue), is not rejected, and
  /// does not name a different product. Null otherwise: two cards, a catalogue
  /// card or a different product are other cards, never merged by a guess.
  Instrument? _numberlessCardToAdopt(
    List<Instrument> sameIssuer,
    InstrumentKind kind,
    InstrumentMention mention,
  ) {
    if (kind != InstrumentKind.creditCard) return null;
    final cards = [
      for (final i in sameIssuer)
        if (i.kind == kind) i,
    ];
    if (cards.length != 1) return null;
    final only = cards.single;
    if (only.maskDigits != null ||
        only.userCardId != null ||
        only.status == InstrumentStatus.rejected ||
        !_productsCompatible(only.aliases.productNames, mention.productName)) {
      return null;
    }
    return only;
  }

  /// [numberless] with the number [mask] now known. The name stays as the user
  /// left it; a name the app made (issuer and kind) gains the number.
  Instrument _withNumber(Instrument numberless, String issuer, String mask, InstrumentMention mention) {
    final length = mention.maskLength;
    final fullLength = (length != null && length > mask.length && length <= 32) ? length : null;
    final autoName = defaultDisplayName(_issuerLabel(issuer), numberless.kind, null);
    final product = mention.productName?.trim();
    final products = numberless.aliases.productNames;
    return numberless.copyWith(
      maskDigits: mask,
      maskLength: fullLength,
      displayName: numberless.displayName == autoName
          ? defaultDisplayName(_issuerLabel(issuer), numberless.kind, mask)
          : null,
      aliases: product == null || product.isEmpty || products.any((p) => p.toLowerCase() == product.toLowerCase())
          ? null
          : InstrumentAliases(
              senders: numberless.aliases.senders,
              vpas: numberless.aliases.vpas,
              productNames: [...products, product],
            ),
    );
  }

  /// True when either side names no product, or one product name contains the
  /// other ("Scapia" and "Scapia Federal Visa"). Two different products of one
  /// issuer are two cards.
  static bool _productsCompatible(List<String> known, String? incoming) {
    final b = incoming?.trim().toLowerCase();
    if (b == null || b.isEmpty || known.isEmpty) return true;
    return known.any((a) {
      final x = a.trim().toLowerCase();
      return x.isEmpty || x.contains(b) || b.contains(x);
    });
  }

  bool _isUpiApp(String? brand) {
    if (brand == null) return false;
    final b = brand.toUpperCase();
    return _upiBrands.contains(b) || b.contains('UPI');
  }

  Instrument _create(
    InstrumentMention mention,
    InstrumentKind kind,
    String issuer,
    String? mask,
    DateTime observedAt,
    String? senderBrand,
  ) {
    final product = mention.productName?.trim();
    final brand = senderBrand?.trim();
    // `maskLength` is the full printed length when known. The engine reports
    // the number of printed digits, which equals the stored mask: keep it only
    // when it says more than the mask already does.
    final length = mention.maskLength;
    final fullLength = (length != null && mask != null && length > mask.length && length <= 32)
        ? length
        : null;
    return Instrument(
      instrumentId: _newId(),
      kind: kind,
      issuerSlug: issuer,
      maskDigits: mask,
      maskLength: fullLength,
      displayName: defaultDisplayName(_issuerLabel(issuer), kind, mask),
      status: InstrumentStatus.detected,
      aliases: InstrumentAliases(
        senders: [if (brand != null && brand.isNotEmpty) brand],
        productNames: [if (product != null && product.isNotEmpty) product],
      ),
      firstSeenAt: observedAt.toUtc(),
      lastSeenAt: observedAt.toUtc(),
      evidenceCount: 0,
    );
  }

  /// True when two different masks are one number printed to different
  /// lengths: both have at least four digits and one ends with the other.
  static bool _sameNumberEnding(String? a, String? b) {
    if (a == null || b == null || a == b) return false;
    if (a.length < 4 || b.length < 4) return false;
    return a.endsWith(b) || b.endsWith(a);
  }

  /// The mask when it is 2 to 6 digits, else null.
  static String? _cleanMask(String? mask) {
    if (mask == null) return null;
    return RegExp(r'^\d{2,6}$').hasMatch(mask) ? mask : null;
  }
}

/// The one instrument of [kind] whose number [maskDigits] ends, across issuers,
/// for a mention that names no issuer. Null when the number or kind is missing,
/// when nothing matches, and when two or more do: a number printed without a
/// bank is evidence for an account the user has, never a reason to pick between
/// two of them. Instruments the user rejected are not candidates.
Instrument? instrumentByNumberOnly(
  InstrumentKind? kind,
  String? maskDigits,
  Iterable<Instrument> known,
) {
  final mask = DefaultInstrumentResolver._cleanMask(maskDigits);
  if (kind == null || mask == null) return null;
  final matches = [
    for (final i in known)
      if (i.kind == kind &&
          i.status != InstrumentStatus.rejected &&
          i.maskDigits != null &&
          (i.maskDigits == mask || DefaultInstrumentResolver._sameNumberEnding(i.maskDigits, mask)))
        i,
  ];
  return matches.length == 1 ? matches.single : null;
}

/// The instrument of [kind] whose number [maskDigits] ends, across issuers, that
/// the user REJECTED. Used when a notice names an account by its number alone and
/// no live account matches ([instrumentByNumberOnly] is null): if every match is
/// rejected the notice belongs to something the user said is not theirs, and its
/// money must stay hidden instead of falling into "an account we cannot name".
Instrument? rejectedByNumberOnly(
  InstrumentKind? kind,
  String? maskDigits,
  Iterable<Instrument> known,
) {
  final mask = DefaultInstrumentResolver._cleanMask(maskDigits);
  if (kind == null || mask == null) return null;
  for (final i in known) {
    if (i.kind == kind &&
        i.status == InstrumentStatus.rejected &&
        i.maskDigits != null &&
        (i.maskDigits == mask || DefaultInstrumentResolver._sameNumberEnding(i.maskDigits, mask))) {
      return i;
    }
  }
  return null;
}

/// Issuer plus kind plus `••` plus digits, for example `HDFC Bank credit card ••5678`.
String defaultDisplayName(String issuerLabel, InstrumentKind kind, String? maskDigits) {
  final base = '$issuerLabel ${kindLabel(kind)}';
  return maskDigits == null ? base : '$base ••$maskDigits';
}

/// Plain-language name of a kind, lower case.
String kindLabel(InstrumentKind kind) => switch (kind) {
  InstrumentKind.bankAccount => 'account',
  InstrumentKind.creditCard => 'credit card',
  InstrumentKind.debitCard => 'debit card',
  InstrumentKind.prepaidCard => 'prepaid card',
  InstrumentKind.wallet => 'wallet',
  InstrumentKind.broker => 'broker account',
  InstrumentKind.loan => 'loan',
  InstrumentKind.payLater => 'pay later',
};

/// Upper case for short slugs (`hdfc` becomes `HDFC`), else title case with
/// underscores as spaces (`indusind` becomes `Indusind`).
String defaultIssuerLabel(String slug) {
  if (slug.length <= 4) return slug.toUpperCase();
  return slug
      .split('_')
      .where((p) => p.isNotEmpty)
      .map((p) => p[0].toUpperCase() + p.substring(1))
      .join(' ');
}

/// A random UUID v4 string.
String generateUuidV4([Random? random]) {
  final r = random ?? Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  String hex(int from, int to) =>
      b.sublist(from, to).map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
}
