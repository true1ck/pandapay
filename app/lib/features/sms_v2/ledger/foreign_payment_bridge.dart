import 'dart:convert';

import 'package:pandapay_domain/pandapay_domain.dart' show Money;
import 'package:pandapay_domain/sms_v2.dart' as v2;

import '../../../data/foreign_money.dart';
import '../../../data/foreign_payment.dart';
import '../../../data/foreign_payments_repository.dart';
import '../../../data/local/app_database.dart';

/// Writes a `ForeignPayment` row for every v2 movement fact that states a
/// foreign amount (CCR-004), beside the INR ledger and never in it.
///
/// - INR posted with an `original`: the INR is evidenced. The row carries it as
///   the billed amount (source `sms`). When the ledger already holds the
///   transaction for the same SMS and amount the row is confirmed at once, so
///   one purchase shows once. Otherwise the server links the two by source key.
/// - A foreign-only amount (`unit` is not INR): the INR is not known. The row
///   waits for a rate-based estimate (`awaiting_rate`), or for the currency
///   when the message named none (`awaiting_amount`). It is never an INR amount
///   and never touches card, reward or cap state.
///
/// Idempotent by source key: re-processing a message never adds a row or
/// changes a row the user edited. Synchronous, so it runs in the pipeline's
/// own savepoint. Raw SMS text never enters the table or its outbox.
class ForeignPaymentBridge {
  ForeignPaymentBridge(this.database, this.namespace);

  final AppDatabase database;
  final String namespace;

  static final _sourceKey = RegExp(r'^[a-f0-9]{64}$');
  static final _uuid = RegExp(
    r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$',
    caseSensitive: false,
  );

  /// Returns the number of rows added or settled.
  int apply(
    Iterable<v2.Fact> facts, {
    required Map<String, v2.Instrument> instrumentsById,
    required Map<String, String> instrumentIdByFactId,
  }) {
    var changed = 0;
    for (final fact in facts) {
      if (fact is! v2.MovementFact || fact.evidenceOnly == true) continue;
      final payment = _paymentFor(
        fact,
        instrument: instrumentsById[instrumentIdByFactId[fact.factId]],
      );
      if (payment == null) continue;
      if (captureLocalForeignPayment(database, namespace, payment)) changed++;
    }
    if (changed > 0) {
      changed += settleAwaitingForeignPayments(database, namespace);
    }
    return changed;
  }

  ForeignPayment? _paymentFor(v2.MovementFact fact, {v2.Instrument? instrument}) {
    if (!_sourceKey.hasMatch(fact.sourceKey)) return null;
    final spend = fact.purpose == v2.MovementPurpose.purchase &&
        fact.direction == v2.Direction.debit;
    final refund = fact.direction == v2.Direction.credit &&
        (fact.purpose == v2.MovementPurpose.refund ||
            fact.purpose == v2.MovementPurpose.reversal);
    if (!spend && !refund) return null;
    final posted = fact.amount(v2.AmountRole.posted);
    final foreign = posted?.foreign;
    if (posted == null || foreign == null) return null;

    // A symbol that names no single currency keeps its amount and asks for the
    // currency; it never becomes USD by guess.
    final currency = foreign.currency == v2.smsUnknownCurrency
        ? null
        : foreign.currency;
    final exponent = v2.smsCurrencyExponent(foreign.currency);
    if (exponent == null) return null;
    final text = _decimal(foreign.minor, exponent);
    final amount = canonicalForeignAmount(text, currency);
    if (amount == null) return null;
    final known = currency != null;

    final billed = posted.isInr ? Money.fromPaise(posted.minor) : null;
    final key = fact.sourceKey;
    final tx = billed == null ? null : _ledgerTransaction(key, billed);
    // Foreign alerts are card alerts: a card the resolver could not classify
    // (the message said only "Card") is still read as a card by its digits.
    final mention = fact.instrument;
    final kind = instrument?.kind ?? mention?.kind;
    final mask = instrument?.maskDigits ?? mention?.maskDigits;
    final last4 = mask == null || mask.length < 4
        ? null
        : mask.substring(mask.length - 4);
    final account = kind == v2.InstrumentKind.bankAccount;
    final card = kind == null ||
        kind == v2.InstrumentKind.creditCard ||
        kind == v2.InstrumentKind.debitCard ||
        kind == v2.InstrumentKind.prepaidCard;
    final userCardId = card && instrument?.userCardId != null &&
            _uuid.hasMatch(instrument!.userCardId!)
        ? instrument.userCardId
        : null;
    return ForeignPayment(
      id: 'fx:$key',
      sourceKey: key,
      originalCurrency: currency,
      originalAmount: amount,
      occurredAt: fact.effectiveAt,
      merchantName: fact.counterparty?.name,
      cardLast4: card ? last4 : null,
      accountLast4: account ? last4 : null,
      userCardId: userCardId,
      categoryName: 'Other',
      valuationStatus: tx != null
          ? 'confirmed'
          : known
          ? 'awaiting_rate'
          : 'awaiting_amount',
      billedInr: billed,
      confirmationSource: billed == null ? null : 'sms',
      transactionId: tx,
      direction: refund ? 'refund' : 'spend',
      instrument: switch (kind) {
        v2.InstrumentKind.creditCard => 'credit_card',
        v2.InstrumentKind.debitCard => 'debit_card',
        v2.InstrumentKind.bankAccount => 'upi_bank',
        v2.InstrumentKind.wallet => 'wallet',
        _ => 'other',
      },
      isLocallyPending: true,
    );
  }

  /// The id of the active ledger transaction this SMS produced for exactly the
  /// billed amount, if the pipeline has already written it.
  String? _ledgerTransaction(String sourceKey, Money billed) {
    final tables = database.db.select(
      "SELECT 1 FROM sqlite_master WHERE type='table' AND name='financial_entities'",
    );
    if (tables.isEmpty) return null;
    for (final row in database.db.select(
      "SELECT payload FROM financial_entities WHERE namespace=? AND entity='transactions' AND source_key=?",
      [namespace, sourceKey],
    )) {
      final t = jsonDecode(row['payload'] as String) as Map<String, dynamic>;
      if (t['status'] == 'active' &&
          parseInrMoney(t['amount_inr']) == billed &&
          t['id'] is String) {
        return t['id'] as String;
      }
    }
    return null;
  }

  static String _decimal(int minor, int exponent) {
    if (exponent == 0) return '$minor';
    final padded = minor.toString().padLeft(exponent + 1, '0');
    final cut = padded.length - exponent;
    return '${padded.substring(0, cut)}.${padded.substring(cut)}';
  }
}
