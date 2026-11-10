import 'package:pandapay_domain/pandapay_domain.dart' show Money;
import 'package:pandapay_domain/sms_v2.dart'
    show Instrument, InstrumentKind, InstrumentStatus;

import '../../../data/local/financial_store.dart' show bankDisplayLabel;
import '../../../data/user_cards_repository.dart' show BankAccountSummary;
import 'issuer_slugs.dart';

/// A balance the user typed in, kept in `manual_bank_balances`. The key is
/// `<bank code>:<last 4>`, as `FinancialStore.manualBankBalances` returns it.
typedef ManualBalances = Map<String, ({Money balance, DateTime updatedAt})>;

/// The accounts Home and the account screens show, built from the instrument
/// registry. It returns today's [BankAccountSummary], with the same fields
/// the local store fills in, so those screens render unchanged.
///
/// - Only `bank_account` instruments the user has confirmed. Auto-detection
///   can be wrong (a counterparty's account, a UPI handle), so a detected
///   account waits on "Accounts and cards we found" and is not listed here.
/// - `accountLast4` is the last 4 digits of the mask. A 2 or 3 digit mask has
///   no last 4 and is left out.
/// - `issuerSlug` and `issuerShortName` use today's bank code and label
///   (`indusind` is shown as it is today, `indus`).
/// - Newest `lastSeenAt` first, as the local store orders its accounts.
/// - A balance the user typed in ([manualBalances]) replaces the SMS balance
///   and sets `isBalanceManuallySet`, exactly as the current projection does.
///   An account with a manual balance and no instrument is added, as today.
/// True when [account] is really a card: another instrument of the same bank
/// is a credit card ending in the same digits. A message about a credit card
/// (rewards, limit, statement) can be read as a bank account, and one number
/// cannot be both, so the card wins and the "account" is not listed.
bool isShadowedByCard(Instrument account, Iterable<Instrument> instruments) =>
    shadowingCard(account, instruments) != null;

/// The credit card that [account] collides with (same bank, same last 4), or
/// null. The user settles the collision once on "Accounts and cards we
/// found"; either answer archives one side, so the collision is then gone.
Instrument? shadowingCard(Instrument account, Iterable<Instrument> instruments) {
  final mask = account.maskDigits;
  if (account.kind != InstrumentKind.bankAccount || mask == null) return null;
  String last4(String m) => m.length > 4 ? m.substring(m.length - 4) : m;
  for (final c in instruments) {
    if (c.kind == InstrumentKind.creditCard &&
        c.status != InstrumentStatus.rejected &&
        c.status != InstrumentStatus.archived &&
        c.issuerSlug == account.issuerSlug &&
        c.maskDigits != null &&
        last4(c.maskDigits!) == last4(mask)) {
      return c;
    }
  }
  return null;
}

List<BankAccountSummary> bankAccountSummariesFromInstruments(
  Iterable<Instrument> instruments, {
  ManualBalances manualBalances = const {},
}) {
  final all = instruments.toList();
  final rows =
      [
        for (final i in all)
          if (i.kind == InstrumentKind.bankAccount &&
              !isShadowedByCard(i, all) &&
              i.status == InstrumentStatus.confirmed &&
              i.maskDigits != null &&
              i.maskDigits!.length >= 4)
            i,
      ]..sort((a, b) {
        final c = b.lastSeenAt.compareTo(a.lastSeenAt);
        return c != 0 ? c : a.instrumentId.compareTo(b.instrumentId);
      });

  final summaries = <BankAccountSummary>[];
  final known = <String>{};
  for (final i in rows) {
    final mask = i.maskDigits!;
    final last4 = mask.substring(mask.length - 4);
    final code = legacyBankCodeFromV2Slug(i.issuerSlug);
    final key = '$code:$last4';
    if (!known.add(key)) continue; // two masks ending alike: show the newest
    final balance = i.availableMinor == null
        ? null
        : Money.fromPaise(i.availableMinor!);
    final manual = manualBalances[key];
    summaries.add(
      BankAccountSummary(
        accountLast4: last4,
        issuerSlug: code,
        issuerShortName: bankDisplayLabel(code),
        availableBalance: manual?.balance ?? balance,
        latestBalanceSmsAt: i.availableAt,
        latestSmsAt: i.lastSeenAt,
        smsCount: i.evidenceCount,
        isBalanceManuallySet: manual != null,
        manualBalanceUpdatedAt: manual?.updatedAt,
      ),
    );
  }
  for (final m in manualBalances.entries) {
    if (known.contains(m.key)) continue;
    final code = m.key.split(':').first;
    summaries.add(
      BankAccountSummary(
        accountLast4: m.key.split(':').last,
        issuerSlug: code,
        issuerShortName: bankDisplayLabel(code),
        availableBalance: m.value.balance,
        latestBalanceSmsAt: null,
        latestSmsAt: null,
        smsCount: 0,
        isBalanceManuallySet: true,
        manualBalanceUpdatedAt: m.value.updatedAt,
      ),
    );
  }
  return summaries;
}
