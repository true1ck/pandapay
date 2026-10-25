import 'dart:convert';

import 'package:pandapay_domain/pandapay_domain.dart';

import '../commitments_repository.dart';
import '../past_bill_receipts.dart';
import '../pending_bills.dart';

import '../../features/sms_import/sms_text_hint.dart';
import '../local_sms_parser.dart';
import '../needs_review_repository.dart';
import '../user_cards_repository.dart';
import '../../features/sms_import/sms_background_queue.dart';
import 'financial_store.dart';
import 'sms_facts_outbox.dart';
import 'sms_intake_repository.dart';
import 'sms_rule_bundle.dart';
import 'sms_rule_exposure_outbox.dart';

/// The same capture transaction is used by inbox import, foreground delivery
/// and the Android background isolate. Upload is deliberately separate.
class SmsImportStore {
  final FinancialStore store;
  // Drain profile name into the parser for own-name self-transfer matching.
  final String? ownUserName;
  final SmsRuleBundle? downloadedRules;
  final List<SmsCandidateRuleBundle> candidateRules;
  SmsImportStore(
    this.store, {
    this.ownUserName,
    this.downloadedRules,
    this.candidateRules = const [],
  });
  void captureBatch(String namespace, List<QueuedSms> messages) {
    store.batch(() {
      final db = store.database.db;
      final cards = store
          .entities(namespace, 'cards')
          .map(UserCard.fromJson)
          .toList();
      final intake = SmsIntakeRepository(store.database);
      db.execute('SAVEPOINT sms_batch');
      try {
        for (final message in messages) {
          _capture(namespace, message, cards, intake);
        }
        db.execute('RELEASE SAVEPOINT sms_batch');
      } catch (_) {
        db.execute('ROLLBACK TO SAVEPOINT sms_batch');
        db.execute('RELEASE SAVEPOINT sms_batch');
        rethrow;
      }
    });
  }

  void capture(String namespace, QueuedSms message) {
    _capture(
      namespace,
      message,
      store.entities(namespace, 'cards').map(UserCard.fromJson).toList(),
      SmsIntakeRepository(store.database),
    );
  }

  void _capture(
    String namespace,
    QueuedSms message,
    List<UserCard> cards,
    SmsIntakeRepository intake,
  ) {
    final triage = classifySmsTriage(message.sender, message.body);
    if (triage.kind == SmsTriageKind.sensitive) return;

    final db = store.database.db;
    db.execute('SAVEPOINT sms_capture');
    try {
      final sourceKey = smsSourceKey(namespace, message.sender, message.body);
      if (intake.wasProcessed(namespace, sourceKey) ||
          store.hasReceipt(namespace, sourceKey)) {
        intake.remember(namespace, message);
        db.execute('RELEASE SAVEPOINT sms_capture');
        return;
      }

      if (triage.kind == SmsTriageKind.promotion ||
          triage.kind == SmsTriageKind.unrelated) {
        intake.recordDecision(
          namespace,
          sourceKey: sourceKey,
          decision: triage.kind == SmsTriageKind.promotion
              ? 'ignored_promotion'
              : 'ignored_unrelated',
          state: 'final',
          reasonCode: triage.reasonCode,
          receivedAt: message.receivedAt.millisecondsSinceEpoch,
          policyVersion: 'v1',
        );
        intake.forgetRaw(namespace, sourceKey);
        db.execute('RELEASE SAVEPOINT sms_capture');
        return;
      }

      final key = intake.capture(namespace, message);
      // Always evaluate the built-in/current rule set independently. A
      // candidate in shadow mode may be wrong, so its observation must never
      // become the baseline merely because it matched first.
      final baselineObservation = LocalSmsParser.parse(
        namespace: namespace,
        sender: message.sender,
        body: message.body,
        receivedAt: message.receivedAt,
        cards: cards,
        ownUserName:
            ownUserName ?? store.database.profileDisplayName(namespace),
        downloadedRules: downloadedRules,
      );
      final candidateResults =
          <
            ({
              SmsCandidateRuleBundle candidate,
              LocalSmsObservation? observation,
              bool matched,
            })
          >[];
      for (final candidate in candidateRules) {
        final candidateObservation = LocalSmsParser.parse(
          namespace: namespace,
          sender: message.sender,
          body: message.body,
          receivedAt: message.receivedAt,
          cards: cards,
          ownUserName:
              ownUserName ?? store.database.profileDisplayName(namespace),
          downloadedRules: candidate.bundle,
        );
        final matched = _isDownloadedRuleMatch(candidateObservation);
        candidateResults.add((
          candidate: candidate,
          observation: candidateObservation,
          matched: matched,
        ));
      }
      final appliedCandidate = candidateResults
          .where((result) => result.candidate.mode == 'apply' && result.matched)
          .firstOrNull;
      LocalSmsObservation? observation =
          appliedCandidate?.observation ?? baselineObservation;
      final exposureOutbox = SmsRuleExposureOutbox(store.database);
      for (final result in candidateResults) {
        final outcome = observation == null
            ? 'unresolved'
            : observation.disposition == LocalSmsDisposition.review
            ? 'review'
            : observation.disposition == LocalSmsDisposition.localIgnore
            ? 'ignored'
            : 'accepted';
        final comparison = _compareSmsObservations(
          baselineObservation,
          result.observation,
          matched: result.matched,
        );
        exposureOutbox.enqueue(
          namespace,
          candidateId: result.candidate.candidateId,
          sourceKey: key,
          stage: result.candidate.stage,
          matched: result.matched,
          applied: result.candidate.mode == 'apply' && result.matched,
          outcome: outcome,
          assignmentId: result.candidate.assignmentId,
          stageVersion: result.candidate.stageVersion,
          deltaOutcome: comparison.delta,
          baselineFamily: baselineObservation?.eventType.wireValue,
          candidateFamily: result.observation?.eventType.wireValue,
          baselineDisposition: baselineObservation?.disposition.wireValue,
          candidateDisposition: result.observation?.disposition.wireValue,
          exactFieldsEqual: comparison.exactFieldsEqual,
          factValid: comparison.factValid,
          invariantBreach: comparison.invariantBreach,
        );
      }
      if (observation != null) {
        final decision =
            observation.disposition == LocalSmsDisposition.localIgnore
            ? 'ignored_noise'
            : (observation.disposition == LocalSmsDisposition.review
                  ? 'financial_review'
                  : 'financial_auto');
        intake.recordDecision(
          namespace,
          sourceKey: key,
          decision: decision,
          state: 'final',
          reasonCode: observation.reasonCodes.isNotEmpty
              ? observation.reasonCodes.first
              : triage.reasonCode,
          receivedAt: message.receivedAt.millisecondsSinceEpoch,
          parserVersion: LocalSmsParser.version.toString(),
          bundleVersion: downloadedRules?.bundleVersion,
          policyVersion: 'v1',
        );
        store.saveObservation(namespace, key, {
          'id': key,
          'sender_bank': message.sender
              .toUpperCase()
              .replaceFirst(RegExp(r'^[A-Z0-9]{2}-'), '')
              .replaceFirst(RegExp(r'-[A-Z]$'), ''),
          'parser_version': LocalSmsParser.version,
          'received_at': message.receivedAt.toUtc().toIso8601String(),
          'account_last4': observation.accountLast4,
          'is_bank_account': observation.accountLast4 == null
              ? false
              : LocalSmsParser.isBankAccountMessage(
                  message.body,
                  message.sender,
                ),
          'card_last4': observation.cardLast4,
          'biller_name': observation.billerName,
          'cadence_hint': observation.cadenceHint,
          'balance_paise': observation.availableBalance?.paise,
          'amount_due_paise': observation.amountDue?.paise,
          'minimum_due_paise': observation.minimumDue?.paise,
          'autopay_limit_paise': observation.autopayLimit?.paise,
          'due_date': observation.dueDate?.toIso8601String(),
          'statement_date': observation.statementDate?.toIso8601String(),
          'statement_date_explicit': observation.statementDateExplicit,
          'event_type': observation.eventType.wireValue,
          'disposition': observation.disposition.wireValue,
          'reason_codes': observation.reasonCodes,
          'confidence': observation.confidence,
          if (observation.isAutopay) 'is_autopay': true,
          // Device-local only: the Bills pane shows the source message.
          // Typed facts and the legacy upload carry structured fields.
          'sample_body': message.body,
        });
        if (observation.transaction != null) {
          store.saveProvisional(namespace, observation.transaction!);
        }
        final isMandate =
            observation.reasonCodes.contains('mandate_notice') &&
            observation.cardLast4 == null;
        final isBillObligation =
            observation.eventType == LocalSmsEventType.bill &&
            observation.cardLast4 == null &&
            !isMandate;
        final now = DateTime.now();
        final startOfToday = DateTime(now.year, now.month, now.day);
        final hasDueDate = observation.dueDate != null;
        final isPastDueBill =
            hasDueDate && observation.dueDate!.isBefore(startOfToday);

        if (isMandate ||
            (!isPastDueBill &&
                observation.disposition ==
                    LocalSmsDisposition.localCommitment)) {
          final title = (observation.billerName?.trim().isNotEmpty == true)
              ? observation.billerName!.trim()
              : message.sender
                    .toUpperCase()
                    .replaceFirst(RegExp(r'^[A-Z0-9]{2}-'), '')
                    .replaceFirst(RegExp(r'-[A-Z]$'), '');
          final category = CommitmentCategory.fromText(
            '$title ${message.sender}',
          );
          final commitment = Commitment(
            id: 'commitment:$key',
            title: title,
            category: category,
            amount: observation.amountDue,
            dueOn: observation.dueDate ?? message.receivedAt,
            cadence: CommitmentCadence.values.firstWhere(
              (value) => value.name == observation.cadenceHint,
              orElse: () => switch (category) {
                CommitmentCategory.utility ||
                CommitmentCategory.telecom ||
                CommitmentCategory.loanOrEmi ||
                CommitmentCategory.rent ||
                CommitmentCategory.subscription => CommitmentCadence.monthly,
                _ => CommitmentCadence.oneTime,
              },
            ),
            source: CommitmentSource.sms,
            status: CommitmentStatus.due,
          );
          store.database.db.execute(
            'CREATE TABLE IF NOT EXISTS local_commitments (namespace TEXT NOT NULL, id TEXT NOT NULL, payload TEXT NOT NULL, PRIMARY KEY (namespace, id))',
          );
          store.database.db.execute(
            'INSERT OR REPLACE INTO local_commitments VALUES (?, ?, ?)',
            [namespace, commitment.id, jsonEncode(commitment.toJson())],
          );
        } else if (isBillObligation && isPastDueBill) {
          // Pre-filtration: An expired bill with dueDate < today is historical.
          // Archive it into PastBillReceiptRepository rather than cluttering Needs Review.
          final transactions = store
              .entities(namespace, 'transactions')
              .map(TransactionEntry.fromJson)
              .toList(growable: false);
          final linked = deriveSmsBillRows(
            observations: [
              {
                'event_type': observation.eventType.wireValue,
                'received_at': message.receivedAt.toIso8601String(),
                'sender_bank': message.sender,
                'biller_name': observation.billerName,
                'card_last4': observation.cardLast4,
                'account_last4': observation.accountLast4,
                'amount_due_paise': observation.amountDue?.paise,
                'minimum_due_paise': observation.minimumDue?.paise,
                'due_date': observation.dueDate?.toIso8601String(),
                'is_autopay': observation.isAutopay,
              },
            ],
            transactions: transactions,
            cardsLast4ById: {
              for (final card in cards)
                if (card.last4 != null) card.id: card.last4!,
            },
            now: now,
            lookbackDays: 36525,
          ).where((row) => row.state == SmsBillState.linked).firstOrNull;
          PastBillReceiptRepository(
            store.database,
            namespace: namespace,
          ).archiveBill(
            id: 'commitment:$key',
            sender: message.sender,
            merchant: observation.billerName ?? message.sender,
            amount: observation.amountDue,
            receivedAt: message.receivedAt,
            dueDate: observation.dueDate,
            cardLast4: observation.cardLast4,
            accountLast4: observation.accountLast4,
            body: message.body,
            status: linked == null
                ? PastBillReceiptStatus.historicalUnpaid
                : PastBillReceiptStatus.paidLinked,
            linkedTransactionId: linked?.linkedTxnId,
          );
        } else if (observation.eventType == LocalSmsEventType.bill &&
            observation.cardLast4 == null &&
            observation.disposition != LocalSmsDisposition.localCommitment &&
            !observation.reasonCodes.contains('mandate_notice') &&
            observation.dueDate == null &&
            observation.confidence < .85) {
          addNeedsReviewSync(
            store.database,
            namespace,
            NeedsReviewItem(
              id: 'commitment:$key',
              sender: message.sender,
              body: message.body,
              reason: observation.reasonCodes.isEmpty
                  ? 'bill_needs_confirmation'
                  : observation.reasonCodes.join(', '),
              receivedAt: message.receivedAt,
              kind: NeedsReviewKind.commitment,
            ),
          );
        }
        if (observation.eventType == LocalSmsEventType.bill &&
            observation.confidence >= .85 &&
            observation.statementDate != null) {
          final sender = message.sender.toUpperCase();
          final eligibleCards = cards
              .where((card) => !card.isArchived && card.cardType != 'debit')
              .toList();
          final isHdfcAggregator =
              RegExp(r'(?:MYTNEU|TNBPAY|TATANU)').hasMatch(sender) &&
              RegExp(
                r'\bhdfc\b[\s\S]{0,40}\bcredit\s+card\b',
                caseSensitive: false,
              ).hasMatch(message.body);
          final hdfcCards = isHdfcAggregator
              ? eligibleCards.where((candidate) {
                  final name = candidate.cardName.toLowerCase();
                  return RegExp(
                    r'\b(?:hdfc|moneyback|millennia|regalia|infinia|tata\s+neu|swiggy)\b',
                  ).hasMatch(name);
                }).toList()
              : const <UserCard>[];
          final suffixCards = eligibleCards
              .where(
                (card) =>
                    observation.cardLast4 != null &&
                    card.last4 == observation.cardLast4,
              )
              .toList();
          if (observation.dueDate != null ||
              observation.statementDate != null) {
            for (final card in eligibleCards) {
              final matchesLast4 =
                  suffixCards.length == 1 && suffixCards.single.id == card.id;
              final matchesFamily =
                  observation.cardLast4 == null &&
                  isHdfcAggregator &&
                  hdfcCards.length == 1 &&
                  hdfcCards.single.id == card.id;
              if (matchesLast4 || matchesFamily) {
                final patch = <String, dynamic>{};
                if (card.dueDay == null &&
                    card.dueDaySource != 'user' &&
                    observation.dueDate != null) {
                  patch['due_day'] = observation.dueDate!.day;
                  patch['due_day_source'] = 'sms';
                }
                if (card.statementDay == null &&
                    card.statementDaySource != 'user' &&
                    observation.statementDate != null &&
                    (!observation.isAutopay ||
                        observation.statementDateExplicit)) {
                  patch['statement_day'] = observation.statementDate!.day;
                  patch['statement_day_source'] = 'sms';
                }
                if (patch.isNotEmpty) {
                  store.patchCard(namespace, card.id, patch);
                }
              }
            }
          }
        }
        // Phase 3: bill obligations also reach the typed fact contract so
        // bill projections share one feed with
        // the balance/mandate/attempt families. INSERT OR IGNORE keeps a
        // replay dedup; the legacy observation sync is unchanged.
        if (observation.eventType == LocalSmsEventType.bill) {
          final facts = buildSmsFactsForObservation(
            body: message.body,
            observation: observation,
            receivedAt: message.receivedAt,
          );
          if (facts.isNotEmpty) {
            SmsFactsOutbox(
              store.database,
            ).enqueue(namespace, message, facts, sourceKey: key);
          }
        }
        // High-confidence non-spending classifications are terminal on the
        // device. They must not wait for the hosted parser, where they would
        // otherwise be uploaded as raw SMS and potentially reappear as
        // review items. Transaction and bill observations retain the
        // existing sync behavior until their structured server contracts
        // are added.
        if (observation.disposition == LocalSmsDisposition.localIgnore) {
          // Phase 2: a terminal local acknowledgement no longer means the
          // server never learns — recognized non-spend shapes mint typed
          // facts queued for POST /sms/facts. The raw body still never
          // leaves the device through this path.
          final facts = buildSmsFactsForObservation(
            body: message.body,
            observation: observation,
            receivedAt: message.receivedAt,
          );
          if (facts.isNotEmpty) {
            SmsFactsOutbox(
              store.database,
            ).enqueue(namespace, message, facts, sourceKey: key);
          }
          intake.acknowledge(namespace, key);
        }
        // Rich upcoming-bill reminders are the Bills pane's domain: they are
        // already persisted as observations and their typed facts were
        // queued above, so acknowledging here keeps raw bodies off the
        // wire — otherwise the hosted parser never matches them and they
        // reappear as review cards with a "Confirm mandate" CTA. Weak or
        // ambiguous bills (no due date, no amount, fragment-y biller) still
        // keep the existing sync/review behavior.
        final strongBiller =
            observation.billerName != null &&
            observation.billerName!.trim().length > 2 &&
            !_weakBillerNameRe.hasMatch(
              observation.billerName!.trim().toLowerCase(),
            );
        if ((observation.disposition == LocalSmsDisposition.localObservation ||
                observation.disposition ==
                    LocalSmsDisposition.localCommitment) &&
            (observation.eventType == LocalSmsEventType.bill ||
                observation.eventType == LocalSmsEventType.autopay) &&
            (observation.cardLast4 != null || strongBiller) &&
            (observation.amountDue != null ||
                observation.minimumDue != null ||
                observation.autopayLimit != null) &&
            observation.dueDate != null) {
          intake.acknowledge(namespace, key);
        }
        // Billing dates are selected across the captured inbox by the server.
        // A capture page is not a complete cycle, so writing the first date
        // here would lock in an older or reminder SMS before history arrives.
      } else {
        intake.recordDecision(
          namespace,
          sourceKey: key,
          decision: 'unparsed_financial',
          state: 'pending',
          reasonCode: triage.reasonCode,
          receivedAt: message.receivedAt.millisecondsSinceEpoch,
          policyVersion: 'v1',
        );
      }
      db.execute('RELEASE SAVEPOINT sms_capture');
    } catch (_) {
      db.execute('ROLLBACK TO SAVEPOINT sms_capture');
      db.execute('RELEASE SAVEPOINT sms_capture');
      rethrow;
    }
  }
}

final _weakBillerNameRe = RegExp(
  r'^(your|our|a|an|the|this|card|credit|debit|payment|bill|account|'
  r'e-?mandate|nach|si|standing|instruction)\b',
);

const _downloadedRuleMatchReasons = {
  'downloaded_rule_match',
  'downloaded_rule_balance',
  'downloaded_rule_bill',
  'downloaded_rule_mandate',
  'downloaded_rule_noise_match',
};

bool _isDownloadedRuleMatch(LocalSmsObservation? observation) =>
    observation?.reasonCodes.any(_downloadedRuleMatchReasons.contains) == true;

({String delta, bool? exactFieldsEqual, bool factValid, bool invariantBreach})
_compareSmsObservations(
  LocalSmsObservation? baseline,
  LocalSmsObservation? candidate, {
  required bool matched,
}) {
  if (baseline == null && candidate == null) {
    return (
      delta: 'unresolved',
      exactFieldsEqual: null,
      factValid: false,
      invariantBreach: false,
    );
  }
  if (candidate == null || !matched) {
    return (
      delta: baseline == null ? 'agreement_unresolved' : 'candidate_miss',
      exactFieldsEqual: false,
      factValid: false,
      invariantBreach: false,
    );
  }
  final valid = _observationHasValidFacts(candidate);
  if (baseline == null ||
      baseline.disposition == LocalSmsDisposition.localIgnore) {
    return (
      delta: candidate.disposition == LocalSmsDisposition.localIgnore
          ? 'agreement'
          : 'candidate_extra_financial',
      exactFieldsEqual:
          candidate.disposition == LocalSmsDisposition.localIgnore,
      factValid: valid,
      invariantBreach:
          candidate.disposition == LocalSmsDisposition.sync && !valid,
    );
  }
  if (baseline.eventType != candidate.eventType) {
    return (
      delta: 'wrong_family',
      exactFieldsEqual: false,
      factValid: valid,
      invariantBreach: false,
    );
  }
  if (baseline.disposition != candidate.disposition) {
    return (
      delta: 'disposition_mismatch',
      exactFieldsEqual: false,
      factValid: valid,
      invariantBreach: false,
    );
  }
  if (!_sameObservationFacts(baseline, candidate)) {
    return (
      delta: 'field_mismatch',
      exactFieldsEqual: false,
      factValid: valid,
      invariantBreach: false,
    );
  }
  return (
    delta: 'agreement',
    exactFieldsEqual: true,
    factValid: valid,
    invariantBreach: false,
  );
}

bool _observationHasValidFacts(LocalSmsObservation observation) {
  switch (observation.eventType) {
    case LocalSmsEventType.transaction:
      final transaction = observation.transaction;
      return transaction != null && transaction.amount.paise > 0;
    case LocalSmsEventType.balance:
      return observation.availableBalance != null &&
          observation.availableBalance!.paise >= 0;
    case LocalSmsEventType.bill:
      return observation.amountDue != null &&
          observation.amountDue!.paise > 0 &&
          observation.dueDate != null;
    case LocalSmsEventType.autopay:
      return observation.autopayLimit != null &&
          observation.autopayLimit!.paise > 0;
    case LocalSmsEventType.failed:
    case LocalSmsEventType.promotion:
    case LocalSmsEventType.security:
    case LocalSmsEventType.investment:
    case LocalSmsEventType.unknown:
      return true;
  }
}

bool _sameObservationFacts(LocalSmsObservation a, LocalSmsObservation b) {
  if (!_sameMoney(a.transaction?.amount, b.transaction?.amount) ||
      !_sameMoney(a.availableBalance, b.availableBalance) ||
      !_sameMoney(a.amountDue, b.amountDue) ||
      !_sameMoney(a.minimumDue, b.minimumDue) ||
      !_sameMoney(a.autopayLimit, b.autopayLimit)) {
    return false;
  }
  if (!_sameDay(a.dueDate, b.dueDate) ||
      !_sameDay(a.statementDate, b.statementDate)) {
    return false;
  }
  return _sameText(a.cardLast4, b.cardLast4) &&
      _sameText(a.accountLast4, b.accountLast4) &&
      _sameText(a.billerName, b.billerName) &&
      _sameText(a.transaction?.merchantName, b.transaction?.merchantName);
}

bool _sameMoney(Money? a, Money? b) => a?.paise == b?.paise;
bool _sameDay(DateTime? a, DateTime? b) =>
    a?.toUtc().year == b?.toUtc().year &&
    a?.toUtc().month == b?.toUtc().month &&
    a?.toUtc().day == b?.toUtc().day;
bool _sameText(String? a, String? b) =>
    a?.trim().toLowerCase() == b?.trim().toLowerCase();
