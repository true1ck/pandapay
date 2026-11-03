import 'package:pandapay_domain/pandapay_domain.dart' show CardProduct;
import 'package:pandapay_domain/sms_v2.dart'
    show
        CreditLimitSource,
        Instrument,
        InstrumentAliases,
        InstrumentKind,
        InstrumentStatus,
        defaultDisplayName,
        defaultIssuerLabel,
        generateUuidV4;

import '../../../data/local/financial_store.dart'
    show bankDisplayLabel, canonicalBankSender;
import '../../../data/user_cards_repository.dart'
    show BankAccountSummary, UserCard;
import '../storage/instrument_store.dart';
import 'issuer_slugs.dart';

/// What a seeding run did. Running it again on the same input reports zero
/// created and zero updated.
class SeedReport {
  const SeedReport({
    this.cardsCreated = 0,
    this.cardsUpdated = 0,
    this.accountsCreated = 0,
    this.accountsUpdated = 0,
    this.skipped = const [],
  });

  final int cardsCreated;
  final int cardsUpdated;
  final int accountsCreated;
  final int accountsUpdated;

  /// Rows that could not become instruments, each with the reason.
  final List<String> skipped;

  int get created => cardsCreated + accountsCreated;
  int get updated => cardsUpdated + accountsUpdated;

  @override
  String toString() =>
      'SeedReport(cards +$cardsCreated ~$cardsUpdated, accounts +$accountsCreated ~$accountsUpdated, skipped ${skipped.length})';
}

final RegExp _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);
final RegExp _mask = RegExp(r'^\d{2,6}$');
final RegExp _last4Digits = RegExp(r'^\d{4}$');

/// Builds the function that turns a `user_cards` row into its issuer slug,
/// through the card catalogue (`UserCard.cardProductId` to `CardProduct.issuerName`).
String? Function(UserCard) cardIssuerSlugFromCatalogue(
  Iterable<CardProduct> catalogue,
) {
  final issuerByProduct = <String, String?>{
    for (final p in catalogue) p.id: p.issuerName,
  };
  return (card) => v2IssuerSlugFromName(issuerByProduct[card.cardProductId]);
}

/// Turns what the app already knows into stored instruments: every
/// `user_cards` row and every detected bank account. WP-16 calls it once at
/// migration. It is idempotent: a second run with the same input changes
/// nothing, so nothing is marked dirty twice.
class InstrumentSeeder {
  InstrumentSeeder(
    this.store, {
    String Function()? idGenerator,
    DateTime Function()? clock,
  }) : _newId = idGenerator ?? generateUuidV4,
       _clock = clock ?? DateTime.now;

  final InstrumentStore store;
  final String Function() _newId;
  final DateTime Function() _clock;

  /// Seeds [cards] and [bankAccounts].
  ///
  /// [issuerSlugOf] gives a card's issuer slug (see
  /// [cardIssuerSlugFromCatalogue]); a card it cannot name is skipped. A card
  /// whose id is not a UUID is skipped too, because the contract's
  /// `userCardId` must be one.
  SeedReport seed({
    required List<UserCard> cards,
    required String? Function(UserCard) issuerSlugOf,
    required List<BankAccountSummary> bankAccounts,
  }) {
    final now = _clock().toUtc();
    var cardsCreated = 0,
        cardsUpdated = 0,
        accountsCreated = 0,
        accountsUpdated = 0;
    final skipped = <String>[];

    for (final card in cards) {
      if (!_uuid.hasMatch(card.id)) {
        skipped.add('card ${card.id}: id is not a UUID');
        continue;
      }
      final issuer = issuerSlugOf(card);
      if (issuer == null) {
        skipped.add('card ${card.id}: issuer unknown');
        continue;
      }
      switch (_seedCard(card, issuer, now)) {
        case _Change.created:
          cardsCreated++;
        case _Change.updated:
          cardsUpdated++;
        case _Change.none:
          break;
      }
    }

    for (final account in bankAccounts) {
      final issuer = _accountIssuer(account);
      final last4 = account.accountLast4;
      if (issuer == null ||
          _looksNonDeposit(account, issuer) ||
          !_last4Digits.hasMatch(last4)) {
        skipped.add('account $last4: not a bank account the user owns');
        continue;
      }
      switch (_seedAccount(account, issuer, now)) {
        case _Change.created:
          accountsCreated++;
        case _Change.updated:
          accountsUpdated++;
        case _Change.none:
          break;
      }
    }

    return SeedReport(
      cardsCreated: cardsCreated,
      cardsUpdated: cardsUpdated,
      accountsCreated: accountsCreated,
      accountsUpdated: accountsUpdated,
      skipped: skipped,
    );
  }

  // ------------------------------------------------------------------ cards

  _Change _seedCard(UserCard card, String issuer, DateTime now) {
    final kind = switch (card.cardType) {
      'debit' => InstrumentKind.debitCard,
      'prepaid' => InstrumentKind.prepaidCard,
      _ => InstrumentKind.creditCard,
    };
    final last4 = card.last4;
    final mask = last4 != null && _mask.hasMatch(last4) ? last4 : null;

    // Already seeded, or already detected from SMS under the same key.
    var existing = store.findByUserCardId(card.id);
    existing ??= mask == null ? null : store.findByKey(kind, issuer, mask);
    if (existing != null &&
        existing.userCardId != null &&
        existing.userCardId != card.id) {
      // The key belongs to another user card: keep both, this one by id only.
      existing = null;
    }

    final seededAt = card.openedOn?.toUtc() ?? now;
    final limit = card.creditLimit;
    final points = card.pointsBalance;
    final productName = card.cardName.trim();

    if (existing == null) {
      // The key may be taken by another user card's instrument (same issuer
      // and last 4): the store forbids two, so this one is kept without a mask.
      final clash = mask == null ? null : store.findByKey(kind, issuer, mask);
      final instrument = Instrument(
        instrumentId: _newId(),
        kind: kind,
        issuerSlug: issuer,
        maskDigits: clash == null ? mask : null,
        displayName: _cardName(card, issuer, kind, mask),
        status: InstrumentStatus.confirmed,
        userCardId: card.id,
        aliases: InstrumentAliases(
          productNames: [if (productName.isNotEmpty) productName],
        ),
        creditLimitMinor: limit?.paise,
        creditLimitSource: limit == null ? null : CreditLimitSource.user,
        creditLimitAt: limit == null ? null : now,
        pointsBalance: points?.round(),
        firstSeenAt: seededAt,
        lastSeenAt: seededAt,
        evidenceCount: 0,
      );
      store.upsert(instrument);
      return _Change.created;
    }

    // Link or refresh the instrument we already have. Only fields the seed
    // owns change, so a second run finds nothing to do.
    final names = existing.aliases.productNames;
    var next = existing.copyWith(
      userCardId: existing.userCardId ?? card.id,
      status: existing.status == InstrumentStatus.detected
          ? InstrumentStatus.confirmed
          : existing.status,
      aliases: productName.isEmpty || names.contains(productName)
          ? null
          : InstrumentAliases(
              senders: existing.aliases.senders,
              vpas: existing.aliases.vpas,
              productNames: [...names, productName],
            ),
    );
    if (limit != null && existing.creditLimitMinor == null) {
      next = next.copyWith(
        creditLimitMinor: limit.paise,
        creditLimitSource: CreditLimitSource.user,
        creditLimitAt: now,
      );
    }
    if (points != null && existing.pointsBalance == null) {
      next = next.copyWith(pointsBalance: points.round());
    }
    if (_sameInstrument(next, existing)) return _Change.none;
    store.upsert(next);
    return _Change.updated;
  }

  String _cardName(
    UserCard card,
    String issuer,
    InstrumentKind kind,
    String? mask,
  ) {
    final nick = card.nickname?.trim();
    if (nick != null && nick.isNotEmpty) return nick;
    final name = card.cardName.trim();
    if (name.isNotEmpty) return mask == null ? name : '$name ••$mask';
    return defaultDisplayName(defaultIssuerLabel(issuer), kind, mask);
  }

  // --------------------------------------------------------------- accounts

  String? _accountIssuer(BankAccountSummary a) {
    final raw = a.issuerSlug ?? a.issuerShortName ?? a.issuerName;
    if (raw == null || raw.trim().isEmpty) return null;
    final code = canonicalBankSender(raw);
    if (code == 'unknown') return null;
    return v2IssuerSlugFromLegacyCode(code);
  }

  /// UPI platforms and lenders quote someone else's account; today's Home
  /// drops them, so the seed does too.
  bool _looksNonDeposit(BankAccountSummary a, String issuer) =>
      RegExp(r'upi|axio').hasMatch(
        [
          a.issuerSlug,
          a.issuerShortName,
          a.issuerName,
          issuer,
        ].whereType<String>().join(' ').toLowerCase(),
      );

  _Change _seedAccount(BankAccountSummary a, String issuer, DateTime now) {
    final manual = a.isBalanceManuallySet;
    final balance = a.availableBalance;
    final balanceAt = manual ? a.manualBalanceUpdatedAt : a.latestBalanceSmsAt;
    final seen =
        a.latestSmsAt?.toUtc() ?? a.manualBalanceUpdatedAt?.toUtc() ?? now;

    final existing = store.findByKey(
      InstrumentKind.bankAccount,
      issuer,
      a.accountLast4,
    );
    if (existing == null) {
      store.upsert(
        Instrument(
          instrumentId: _newId(),
          kind: InstrumentKind.bankAccount,
          issuerSlug: issuer,
          maskDigits: a.accountLast4,
          displayName: defaultDisplayName(
            bankDisplayLabel(legacyBankCodeFromV2Slug(issuer)),
            InstrumentKind.bankAccount,
            a.accountLast4,
          ),
          status: manual
              ? InstrumentStatus.confirmed
              : InstrumentStatus.detected,
          firstSeenAt: seen,
          lastSeenAt: seen,
          evidenceCount: a.smsCount,
          availableMinor: balance?.paise,
          availableAt: balance == null ? null : (balanceAt?.toUtc() ?? seen),
        ),
      );
      return _Change.created;
    }

    // Already stored (seeded before, or detected from SMS). A manual balance
    // confirms it and fills a missing balance; nothing else is overwritten.
    var next = existing;
    if (manual && existing.status == InstrumentStatus.detected) {
      next = next.copyWith(status: InstrumentStatus.confirmed);
    }
    if (balance != null && existing.availableMinor == null) {
      next = next.copyWith(
        availableMinor: balance.paise,
        availableAt: balanceAt?.toUtc() ?? seen,
      );
    }
    if (_sameInstrument(next, existing)) return _Change.none;
    store.upsert(next);
    return _Change.updated;
  }

  bool _sameInstrument(Instrument a, Instrument b) =>
      a.toJson().toString() == b.toJson().toString();
}

enum _Change { created, updated, none }
