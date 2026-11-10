/// Turns an accepted [SolverDecision] into the same contract facts a rule would
/// emit, so everything downstream (linker, ledger, bills, subscriptions, review)
/// treats a solver reading exactly like a rule reading.
///
/// The provenance names engine `rules` and a rule id `SOLVER-<READ>`: the
/// contract has no separate solver engine, and the rule id is what the review
/// screen, the learning loop and the audit trail key on.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../contract/enums.dart';
import '../contract/fact.dart';
import '../contract/json_util.dart';
import '../contract/validate.dart';
import 'evidence_solver.dart';

/// What a solver reading became.
class SolverFactResult {
  const SolverFactResult(
    this.facts, {
    required this.ignored,
    required this.ruleId,
  });

  /// One or more valid facts.
  final List<Fact> facts;

  /// True when the only fact is an `info` fact (the message is not financial),
  /// which the engine reports as `ignored`.
  final bool ignored;
  final String ruleId;
}

const _istOffset = Duration(hours: 5, minutes: 30);

/// Largest confidence a solver fact carries: below any specific rule.
const double kSolverMaxConfidence = 0.9;

class SolverFacts {
  const SolverFacts._();

  static String ruleIdFor(SolverDecision d) => 'SOLVER-${_slug(d)}';

  static String _slug(SolverDecision d) {
    switch (d.read) {
      case SolverRead.debit:
        return 'DEBIT';
      case SolverRead.credit:
        return 'CREDIT';
      case SolverRead.cardPayment:
        return 'CARD-PAYMENT';
      case SolverRead.ownTransfer:
        return 'OWN-TRANSFER';
      case SolverRead.walletTopup:
        return 'WALLET-TOPUP';
      case SolverRead.investment:
        return 'INVESTMENT';
      case SolverRead.billDue:
        return 'BILL-DUE';
      case SolverRead.billReceipt:
        return 'BILL-RECEIPT';
      case SolverRead.scheduled:
        return 'UPCOMING';
      case SolverRead.mandate:
        return 'MANDATE';
      case SolverRead.redemption:
        return 'REDEMPTION';
      case SolverRead.holdRelease:
        return 'HOLD-RELEASE';
      case SolverRead.requestPending:
        return 'REQUEST-PENDING';
      case SolverRead.balance:
        return 'BALANCE';
      case SolverRead.failed:
        return 'FAILED';
      case SolverRead.promo:
        return 'PROMO';
      case SolverRead.info:
        return 'INFO';
      case SolverRead.unclear:
        return 'UNCLEAR';
    }
  }

  /// Builds the facts for [d], or null when the reading cannot be written as a
  /// valid fact (the caller then treats the message as unresolved, never guessing).
  ///
  /// [issuerSlug] is the sender's issuer when the bundle knows it.
  static SolverFactResult? build(
    SolverDecision d, {
    required String sourceKey,
    required DateTime observedAt,
    required String? issuerSlug,
    required int packVersion,
    required int bundleVersion,
    required String engineVersion,
    required String appVersion,
    void Function(List<Map<String, Object?>> facts)? refine,
    bool forceAccept = false,
    double? confidenceCap,
    String? ruleIdOverride,
  }) {
    // [forceAccept] writes a reading the solver itself was unsure of, once history
    // has confirmed the missing piece; [confidenceCap] then keeps it below the
    // review bar so a person is asked.
    if (!d.accepted && !forceAccept) return null;
    final ruleId = ruleIdOverride ?? ruleIdFor(d);

    Map<String, Object?>? instrument({String? kindOverride}) {
      final kind = kindOverride ?? d.instrumentKind;
      final mask = d.mask != null && d.mask!.length >= 2 ? d.mask : null;
      if (kind == null && mask == null && issuerSlug == null) return null;
      if (kind == null && mask == null) return null;
      return {
        'kind': kind,
        'issuerSlug': issuerSlug,
        'maskDigits': mask,
        'maskLength': null,
        'productName': null,
        'raw': null,
      };
    }

    Map<String, Object?>? counterparty() {
      final name = d.party;
      if (name == null || name.trim().isEmpty) return null;
      return {
        'name': d.partyIsVpa ? null : name,
        'vpa': d.partyIsVpa ? name : null,
        'kind': null,
        'accountMask': null,
      };
    }

    Map<String, Object?> envelope(
      String factType,
      int index, {
      required Map<String, Object?> attrs,
      List<Map<String, Object?>> amounts = const [],
      Map<String, Object?>? instrumentJson,
      Map<String, Object?>? counterpartyJson,
      Map<String, String> references = const {},
      DateTime? occurredAt,
    }) {
      return {
        'contractVersion': Fact.contractVersion,
        'factId': sha256
            .convert(utf8.encode('$sourceKey|$ruleId|$index'))
            .toString(),
        'sourceKey': sourceKey,
        'factType': factType,
        'observedAt': formatUtc(observedAt),
        'occurredAt': occurredAt == null ? null : formatUtc(occurredAt),
        'instrument': instrumentJson,
        'counterparty': counterpartyJson,
        'amounts': amounts,
        'references': references,
        'attrs': attrs,
        'provenance': {
          'engine': 'rules',
          'ruleId': ruleId,
          'ruleVersion': packVersion,
          'bundleVersion': bundleVersion,
          'engineVersion': engineVersion,
          'appVersion': appVersion,
        },
        'evidence': <Object?>[],
        'confidence': [
          d.score,
          kSolverMaxConfidence,
          ?confidenceCap,
        ].reduce((a, b) => a < b ? a : b),
      };
    }

    Map<String, Object?> posted(int minor, {String role = 'posted'}) {
      final out = <String, Object?>{
        'role': role,
        'minor': minor,
        'unit': 'INR',
      };
      if (d.originalMinor != null &&
          d.originalUnit != null &&
          role == 'posted') {
        out['original'] = {
          'minor': d.originalMinor,
          'currency': d.originalUnit,
        };
      }
      return out;
    }

    bool validPurpose(String? p) =>
        p != null && MovementPurpose.values.any((e) => e.wire == p);

    // A purpose word can sit near the amount without describing the movement
    // ("... EMI 2025-26" in the narration of a credit). Only purposes that make
    // sense for the direction are used; anything else falls back to the default.
    const creditPurposes = {
      'salary',
      'interest',
      'refund',
      'cashback',
      'reversal',
      'dividend',
      'p2p',
      'card_payment',
      'wallet_topup',
      'investment',
      'unknown',
    };
    const debitPurposes = {
      'purchase',
      'p2p',
      'atm',
      'fee',
      'emi',
      'card_payment',
      'wallet_topup',
      'investment',
      'bill_payment',
      'tax',
      'transfer',
      'unknown',
    };
    String? purposeFor(bool debit, String? p) =>
        p != null && (debit ? debitPurposes : creditPurposes).contains(p)
        ? p
        : null;
    String rail(String? fallback) => d.rail ?? fallback ?? 'unknown';

    final facts = <Map<String, Object?>>[];
    var ignored = false;

    switch (d.read) {
      case SolverRead.debit:
      case SolverRead.credit:
        final minor = d.minor;
        final debit = d.debitDirection;
        if (minor == null || debit == null || d.unit != 'INR') return null;
        final r = rail(d.instrumentKind == 'wallet' ? 'wallet' : null);
        var purpose = purposeFor(
          debit,
          validPurpose(d.purpose) ? d.purpose : null,
        );
        // A credit with no stated reason is money in (a transfer, a loan paid
        // out, a wallet credit). Marking it unknown would hide it from the books.
        purpose ??= debit ? 'purchase' : 'p2p';
        facts.add(
          envelope(
            'movement',
            0,
            attrs: {
              'direction': debit ? 'debit' : 'credit',
              'purpose': purpose,
              'rail': purpose == 'atm' ? 'cash' : r,
              if (d.mandateRef != null) 'mandateRef': d.mandateRef,
            },
            amounts: [posted(minor)],
            instrumentJson: instrument(),
            counterpartyJson: counterparty(),
            references: {if (d.mandateRef != null) 'umrn': d.mandateRef!},
          ),
        );
        if (d.recurring && debit && d.mandatePurpose == 'subscription') {
          facts.add(_mandate(envelope, 1, d, phase: 'created'));
        }
      case SolverRead.billReceipt:
        final minor = d.minor;
        if (minor == null || d.unit != 'INR') return null;
        final purpose = d.mandatePurpose == 'subscription' || d.recurring
            ? 'purchase'
            : (d.purpose == 'emi' ? 'emi' : 'bill_payment');
        facts.add(
          envelope(
            'movement',
            0,
            attrs: {
              'direction': 'debit',
              'purpose': purpose,
              'rail': rail(null),
              if (d.mandateRef != null) 'mandateRef': d.mandateRef,
              'evidenceOnly': true,
            },
            amounts: [posted(minor)],
            instrumentJson: instrument(),
            counterpartyJson:
                counterparty() ??
                (d.billerName == null && d.consumerRef == null
                    ? null
                    : {
                        // The consumer number rides in the name ("<biller> <number>"),
                        // the way biller-side scheduled-payment notices print it, so
                        // a payment and its bill share one key (the contract has no
                        // field for it).
                        'name': [
                          d.billerName,
                          d.consumerRef,
                        ].whereType<String>().join(' '),
                        'vpa': null,
                        'kind': null,
                        'accountMask': null,
                      }),
          ),
        );
        if (d.recurring && d.mandatePurpose == 'subscription') {
          facts.add(_mandate(envelope, 1, d, phase: 'created'));
        }
      case SolverRead.cardPayment:
        final minor = d.minor;
        final debit = d.debitDirection;
        if (minor == null || debit == null || d.unit != 'INR') return null;
        // The card side is a credit leg on the card; the funding side a debit on the bank.
        final kind = debit
            ? d.instrumentKind
            : (d.instrumentKind ?? 'credit_card');
        facts.add(
          envelope(
            'movement',
            0,
            attrs: {
              'direction': debit ? 'debit' : 'credit',
              'purpose': 'card_payment',
              'rail': rail(null),
            },
            amounts: [posted(minor)],
            instrumentJson: instrument(
              kindOverride: debit ? kind : 'credit_card',
            ),
          ),
        );
      case SolverRead.ownTransfer:
        final minor = d.minor;
        if (minor == null || d.debitDirection != true || d.unit != 'INR') {
          return null;
        }
        final own = d.ownMasks;
        facts.add(
          envelope(
            'movement',
            0,
            attrs: {
              'direction': 'debit',
              'purpose': 'transfer',
              'rail': rail(null),
            },
            amounts: [posted(minor)],
            instrumentJson: own.isNotEmpty
                ? {
                    'kind': 'bank_account',
                    'issuerSlug': issuerSlug,
                    'maskDigits': own.first,
                    'maskLength': null,
                    'productName': null,
                    'raw': null,
                  }
                : instrument(),
            counterpartyJson: {
              'name': null,
              'vpa': null,
              'kind': 'own',
              'accountMask': own.length > 1 ? own[1] : null,
            },
          ),
        );
      case SolverRead.walletTopup:
        final minor = d.minor;
        if (minor == null || d.unit != 'INR') return null;
        facts.add(
          envelope(
            'movement',
            0,
            attrs: {
              'direction': 'credit',
              'purpose': 'wallet_topup',
              'rail': 'wallet',
            },
            amounts: [posted(minor)],
            instrumentJson: {
              'kind': 'wallet',
              'issuerSlug': issuerSlug,
              'maskDigits': null,
              'maskLength': null,
              'productName': null,
              'raw': null,
            },
          ),
        );
      case SolverRead.investment:
        final minor = d.minor;
        if (minor == null || d.unit != 'INR') return null;
        facts.add(
          envelope(
            'movement',
            0,
            attrs: {
              'direction': 'debit',
              'purpose': 'investment',
              'rail': rail(null),
              if (d.evidenceOnly) 'evidenceOnly': true,
            },
            amounts: [posted(minor)],
            instrumentJson: instrument(),
            counterpartyJson: counterparty(),
          ),
        );
      case SolverRead.billDue:
        final minor = d.minor;
        final due = d.dueDate;
        if (minor == null || due == null || d.unit != 'INR') return null;
        facts.add(
          envelope(
            'bill_due',
            0,
            attrs: {
              'dueDate': due.iso,
              if (d.statementDate != null)
                'statementDate': d.statementDate!.iso,
              if (d.billerName != null) 'billerName': d.billerName,
            },
            amounts: [
              {'role': 'due_total', 'minor': minor, 'unit': 'INR'},
              if (d.dueMinorMinimum != null)
                {
                  'role': 'due_minimum',
                  'minor': d.dueMinorMinimum,
                  'unit': 'INR',
                },
            ],
            instrumentJson: instrument(),
          ),
        );
      case SolverRead.scheduled:
        final minor = d.minor;
        final debit = d.debitDirection ?? true;
        if (minor == null || d.unit != 'INR') return null;
        var purpose = purposeFor(
          debit,
          validPurpose(d.purpose) ? d.purpose : null,
        );
        // An upcoming credit with no stated reason ("will be credited") is not
        // assumed to be a refund.
        purpose ??= debit ? 'purchase' : 'unknown';
        facts.add(
          envelope(
            'attempt',
            0,
            attrs: {
              'status': 'scheduled',
              'direction': debit ? 'debit' : 'credit',
              'purpose': purpose,
              if (d.scheduledDate != null)
                'dueAt': formatUtc(
                  d.scheduledDate!.utcMidnight.subtract(_istOffset),
                ),
            },
            amounts: [posted(minor, role: 'scheduled')],
            instrumentJson: instrument(),
            counterpartyJson: counterparty(),
          ),
        );
      case SolverRead.failed:
        final minor = d.minor;
        if (minor == null || d.unit != 'INR') {
          facts.add(_info('service', envelope, 0));
          ignored = true;
          break;
        }
        var purpose = d.purpose;
        if (!validPurpose(purpose)) purpose = null;
        facts.add(
          envelope(
            'attempt',
            0,
            attrs: {
              'status': d.attemptStatus ?? 'failed',
              'direction': 'debit',
              'purpose': purpose ?? 'purchase',
            },
            amounts: [posted(minor)],
            instrumentJson: instrument(),
          ),
        );
      case SolverRead.redemption:
        final minor = d.minor;
        if (minor == null || d.unit != 'INR') return null;
        // Activity only: a transfer is shown but never counted as spending or income.
        facts.add(
          envelope(
            'movement',
            0,
            attrs: {'direction': 'debit', 'purpose': 'transfer', 'rail': 'wallet'},
            amounts: [posted(minor)],
            instrumentJson: instrument(),
            counterpartyJson: {
              'name': null,
              'vpa': null,
              'kind': 'own',
              'accountMask': null,
            },
          ),
        );
      case SolverRead.holdRelease:
        final minor = d.minor;
        if (minor == null || d.unit != 'INR') return null;
        final holdPurpose = const {'ipo_asba', 'upi_mandate_block', 'preauth', 'lien', 'other'}.contains(d.purpose)
            ? d.purpose
            : 'other';
        facts.add(
          envelope(
            'hold',
            0,
            attrs: {'phase': 'released', 'purpose': holdPurpose},
            amounts: [
              {'role': 'released', 'minor': minor, 'unit': 'INR'},
            ],
            instrumentJson: instrument(),
          ),
        );
      case SolverRead.requestPending:
        final minor = d.minor;
        if (minor == null || d.unit != 'INR') return null;
        var pendingPurpose = d.purpose;
        if (!validPurpose(pendingPurpose)) pendingPurpose = null;
        facts.add(
          envelope(
            'attempt',
            0,
            attrs: {
              'status': 'pending',
              'direction': 'debit',
              'purpose': pendingPurpose ?? 'purchase',
            },
            amounts: [posted(minor)],
            instrumentJson: instrument(),
          ),
        );
      case SolverRead.mandate:
        facts.add(_mandate(envelope, 0, d, phase: d.mandatePhase ?? 'created'));
      case SolverRead.balance:
        final minor = d.minor;
        if (minor == null ||
            d.unit != 'INR' ||
            (d.mask == null && d.instrumentKind == null)) {
          facts.add(_info('service', envelope, 0));
          ignored = true;
        } else {
          facts.add(
            envelope(
              'balance_snapshot',
              0,
              attrs: {'asOf': formatUtc(observedAt)},
              amounts: [
                {'role': 'available_balance', 'minor': minor, 'unit': 'INR'},
              ],
              instrumentJson: instrument(),
            ),
          );
        }
      case SolverRead.promo:
        facts.add(_info('promotion', envelope, 0));
        ignored = true;
      case SolverRead.info:
        final security = d.reasons.any((r) => r.startsWith('security wording'));
        facts.add(_info(security ? 'security' : 'other', envelope, 0));
        ignored = true;
      case SolverRead.unclear:
        return null;
    }

    if (refine != null && !ignored) refine(facts);

    final out = <Fact>[];
    for (final json in facts) {
      if (!validateFactJson(json).ok) return null;
      try {
        out.add(Fact.fromJson(json));
      } on Object {
        return null;
      }
    }
    return SolverFactResult(out, ignored: ignored, ruleId: ruleId);
  }

  static Map<String, Object?> _info(
    String category,
    Map<String, Object?> Function(
      String,
      int, {
      required Map<String, Object?> attrs,
      List<Map<String, Object?>> amounts,
      Map<String, Object?>? instrumentJson,
      Map<String, Object?>? counterpartyJson,
      Map<String, String> references,
      DateTime? occurredAt,
    })
    envelope,
    int index,
  ) => envelope('info', index, attrs: {'category': category});

  static Map<String, Object?> _mandate(
    Map<String, Object?> Function(
      String,
      int, {
      required Map<String, Object?> attrs,
      List<Map<String, Object?>> amounts,
      Map<String, Object?>? instrumentJson,
      Map<String, Object?>? counterpartyJson,
      Map<String, String> references,
      DateTime? occurredAt,
    })
    envelope,
    int index,
    SolverDecision d, {
    required String phase,
  }) {
    final merchant = d.party ?? d.billerName;
    final amount =
        d.minor != null && d.unit == 'INR' && d.read == SolverRead.mandate
        ? [
            {'role': 'ceiling', 'minor': d.minor, 'unit': 'INR'},
          ]
        : <Map<String, Object?>>[];
    return envelope(
      'mandate',
      index,
      attrs: {
        'phase': phase,
        if (d.frequency != null) 'frequency': d.frequency,
        if (merchant != null && merchant.trim().isNotEmpty)
          'merchantName': merchant,
        if (d.oneTime != null) 'oneTime': d.oneTime,
        if (d.mandatePurpose != null) 'mandatePurpose': d.mandatePurpose,
      },
      amounts: amount,
      // The mandate's own reference, so a later charge that quotes it joins this mandate.
      references: {if (d.mandateRef != null) 'umrn': d.mandateRef!},
    );
  }
}
