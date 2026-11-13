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
  final cardRefunds = <TransactionEntry>[];
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
        cardRefunds.add(row);
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
    for (final refund in cardRefunds) {
      if (_last4(refund.cardLast4) == spend.instrumentId &&
          refund.amount.paise == spend.amountMinor &&
          !refund.occurredAt.isBefore(
            spend.at.subtract(const Duration(days: 1)),
          )) {
        refundedEventIds.add(spend.eventId);
      }
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

String? _last4(String? mask) {
  if (mask == null) return null;
  final digits = mask.replaceAll(RegExp(r'\D'), '');
  if (digits.length < 4) return null;
  return digits.substring(digits.length - 4);
}
