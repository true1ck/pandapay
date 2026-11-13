import 'package:pandapay_domain/sms_v2.dart' as v2;
import 'package:pandapay_domain/sms_v2_ledger.dart';

import '../../../data/user_cards_repository.dart';
import 'reports.dart';

/// A card spend the card's own available limit says was probably refunded,
/// although no message ever said so.
class SuspectedRefundInfo {
  const SuspectedRefundInfo({
    required this.spendEventId,
    required this.cardLast4,
    required this.spendAmountMinor,
    required this.limitRoseByMinor,
    required this.noticedAt,
  });
  final String spendEventId;
  final String cardLast4;
  final int spendAmountMinor;
  final int limitRoseByMinor;
  final DateTime noticedAt;
}

/// Suggestions for the whole ledger, keyed by the spend's event id.
///
/// Reads only what the phone already holds: the available-limit readings that
/// card messages carry, the card's spends, and everything the messages DO
/// explain (card payments, refunds, cashback, limit increases). Cards are told
/// apart by the last four digits printed in the messages.
Map<String, SuspectedRefundInfo> suspectedRefundsFromModel(
  LedgerReadModel model,
) {
  final readings = <LimitReading>[];
  final credits = <ExplainedCredit>[];
  for (final fact in model.facts) {
    final mention = fact.instrument;
    if (mention == null || mention.kind != v2.InstrumentKind.creditCard) {
      continue;
    }
    final last4 = _last4(mention.maskDigits);
    if (last4 == null) continue;
    if (fact is v2.BalanceSnapshotFact) {
      final available = fact.amount(v2.AmountRole.availableCredit);
      if (available != null) {
        readings.add(
          LimitReading(
            instrumentId: last4,
            at: fact.asOf,
            availableMinor: available.minor,
          ),
        );
      }
    } else if (fact is v2.LimitChangeFact) {
      // A limit increase lifts the available limit by the increase.
      final limit = fact.amount(v2.AmountRole.creditLimit);
      final before = fact.previousMinor;
      if (limit != null && before != null && limit.minor > before) {
        credits.add(
          ExplainedCredit(
            instrumentId: last4,
            at: fact.occurredAt ?? fact.observedAt,
            amountMinor: limit.minor - before,
          ),
        );
      }
    }
  }

  final spends = <SpendOnCard>[];
  final refundedEventIds = <String>{};
  // The latest refund per card and amount: a spend is "already refunded" when
  // one of that amount is dated no earlier than a day before it. One map lookup
  // per spend instead of a scan of every refund per spend (R4).
  final latestRefund = <String, DateTime>{};
  for (final row in model.transactions) {
    if (row.status != 'active' || row.instrument != TxnInstrument.creditCard) {
      continue;
    }
    final last4 = _last4(row.cardLast4);
    if (last4 == null) continue;
    switch (row.entryKind) {
      case TxnEntryKind.spend:
        final eventId = row.eventId;
        if (eventId != null) {
          spends.add(
            SpendOnCard(
              instrumentId: last4,
              eventId: eventId,
              at: row.occurredAt,
              amountMinor: row.amount.paise,
            ),
          );
        }
      case TxnEntryKind.refund:
        final key = '$last4:${row.amount.paise}';
        final seen = latestRefund[key];
        if (seen == null || row.occurredAt.isAfter(seen)) {
          latestRefund[key] = row.occurredAt;
        }
        credits.add(
          ExplainedCredit(
            instrumentId: last4,
            at: row.occurredAt,
            amountMinor: row.amount.paise,
          ),
        );
      case TxnEntryKind.income || TxnEntryKind.transfer:
        // A card payment or a cashback credit: money the messages explain.
        credits.add(
          ExplainedCredit(
            instrumentId: last4,
            at: row.occurredAt,
            amountMinor: row.amount.paise,
          ),
        );
      case TxnEntryKind.investment ||
          TxnEntryKind.investmentReturn ||
          TxnEntryKind.unknown:
        break;
    }
  }
  // A spend that already has a refund of the same amount on the same card
  // (read from a message, or one the person recorded) is not a mystery.
  for (final spend in spends) {
    final refundedAt = latestRefund['${spend.instrumentId}:${spend.amountMinor}'];
    if (refundedAt != null &&
        !refundedAt.isBefore(spend.at.subtract(const Duration(days: 1)))) {
      refundedEventIds.add(spend.eventId);
    }
  }

  final found = detectSilentRefunds(
    readings: readings,
    spends: spends,
    credits: credits,
    alreadyRefundedEventIds: refundedEventIds,
  );
  return {
    for (final s in found)
      s.spendEventId: SuspectedRefundInfo(
        spendEventId: s.spendEventId,
        cardLast4: s.instrumentId,
        spendAmountMinor: s.spendAmountMinor,
        limitRoseByMinor: s.limitRoseByMinor,
        noticedAt: s.noticedAt,
      ),
  };
}

/// The last four digits in [mask], skipping any non-digit ("XX4321", "**** 4321").
/// Runs once per fact and per transaction row, so it scans characters instead of
/// compiling and running a regular expression each time (R3).
String? _last4(String? mask) {
  if (mask == null) return null;
  final found = <int>[];
  for (var i = mask.length - 1; i >= 0 && found.length < 4; i--) {
    final c = mask.codeUnitAt(i);
    if (c >= 0x30 && c <= 0x39) found.add(c);
  }
  if (found.length < 4) return null;
  return String.fromCharCodes(found.reversed);
}
