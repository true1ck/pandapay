import 'dart:convert';

import 'package:pandapay_domain/pandapay_domain.dart';

import '../commitments_repository.dart';
import '../past_bill_receipts.dart';
import '../pending_bills.dart';
import '../sms_fact_contract.dart';
import '../sms_fact_scoring.dart';

import '../../features/sms_import/sms_text_hint.dart';
import '../local_sms_parser.dart';
import '../needs_review_repository.dart';
import '../user_cards_repository.dart';
import '../../features/sms_import/sms_background_queue.dart';
import 'auto_resolved_history_repository.dart';
import 'financial_store.dart';
import 'sms_facts_outbox.dart';
import 'sms_intake_repository.dart';
import 'sms_learning_feedback.dart';
import 'sms_rule_bundle.dart';
import 'sms_rule_bundle_store.dart';
import 'sms_rule_exposure_outbox.dart';

/// How an AI suggestion set was routed by [SmsImportStore.resolveAiSuggestions].
enum SmsAiResolutionOutcome { autoResolved, needsReview, discarded }

class SmsAiResolutionResult {
  final SmsAiResolutionOutcome outcome;
  final double score;

  /// The auto-resolved receipt id, set only for [SmsAiResolutionOutcome.autoResolved].
  final String? historyId;

  const SmsAiResolutionResult({
    required this.outcome,
    required this.score,
    this.historyId,
  });
}

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
      // One read per batch: a learned rule must not cost a query per message.
      final userCategoryRules = SmsLearningFeedback(
        store.database,
        namespace: namespace,
      ).loadRulesSync();
      final sharedCategoryRules = SmsRuleBundleStore(
        store.database,
      ).loadSharedCategoryRulesSync();
      final intake = SmsIntakeRepository(store.database);
      db.execute('SAVEPOINT sms_batch');
      try {
        for (final message in messages) {
          _capture(
            namespace,
            message,
            cards,
            intake,
            userCategoryRules,
            sharedCategoryRules,
          );
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
      SmsLearningFeedback(store.database, namespace: namespace).loadRulesSync(),
      SmsRuleBundleStore(store.database).loadSharedCategoryRulesSync(),
    );
  }

  void _capture(
    String namespace,
    QueuedSms message,
    List<UserCard> cards,
    SmsIntakeRepository intake,
    Map<String, String> userCategoryRules,
    Map<String, String> sharedCategoryRules,
  ) {
    final triage = classifySmsTriage(message.sender, message.body);
    if (triage.kind == SmsTriageKind.sensitive) return;

    final db = store.database.db;
    db.execute('SAVEPOINT sms_capture');
    try {
      final sourceKey = smsSourceKey(namespace, message.sender, message.body);
      if (store.hasReceipt(namespace, sourceKey) ||
          intake.wasProcessed(
            namespace,
            sourceKey,
            parserVersion: LocalSmsParser.version,
          )) {
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

      final key = intake.capture(
        namespace,
        message,
        parserVersion: LocalSmsParser.version,
      );
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
        userCategoryRules: userCategoryRules,
        sharedCategoryRules: sharedCategoryRules,
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
          userCategoryRules: userCategoryRules,
          sharedCategoryRules: sharedCategoryRules,
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

        if (!isPastDueBill &&
            (isMandate ||
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

  /// Triage for a completed AI result (mirrors api/src/ai_fact_scoring.js).
  ///
  /// A complete high-confidence movement/bill is filed locally and recorded
  /// in Auto-Resolved history. Uncertain, low-confidence or field-incomplete
  /// outcomes stay editable in Needs Review. Only an explicit negative
  /// tracking decision may dismiss a row.
  ///
  /// The caller owns persisting suggestions for Tier 2 (the UI contract).
  SmsAiResolutionResult resolveAiSuggestions(
    String namespace,
    NeedsReviewItem item,
    List<Map<String, dynamic>> suggestions, {
    Map<String, dynamic>? decision,
    bool? reviewRequired,
    double? serverScore,
  }) {
    if (decision != null && decision['shouldConsider'] == false) {
      final sourceKey = _cleanSourceKey(item);
      final topic = (decision['topic'] as String? ?? 'other_non_financial')
          .replaceAll('_', ' ');
      final score = serverScore != null && serverScore.isFinite
          ? serverScore
          : 0.0;
      final history = AutoResolvedHistoryEntry(
        id: 'ai:$sourceKey',
        namespace: namespace,
        sourceKey: sourceKey,
        sender: item.sender,
        resolvedKind: 'dismissed',
        title: 'AI dismissed · $topic',
        amountPaise: 0,
        sourceBody: item.body,
        occurredAt: item.receivedAt.toIso8601String(),
        confidence: score,
        autoResolvedAt: DateTime.now().millisecondsSinceEpoch,
      );
      store.batch(() {
        final db = store.database.db;
        db.execute('SAVEPOINT sms_ai_dismiss');
        try {
          AutoResolvedHistoryRepository(
            store.database,
            namespace: namespace,
          ).record(history);
          _deleteReviewRow(namespace, item.id);
          store.notifyPendingChange(namespace);
          db.execute('RELEASE SAVEPOINT sms_ai_dismiss');
        } catch (_) {
          db.execute('ROLLBACK TO SAVEPOINT sms_ai_dismiss');
          db.execute('RELEASE SAVEPOINT sms_ai_dismiss');
          rethrow;
        }
      });
      return SmsAiResolutionResult(
        outcome: SmsAiResolutionOutcome.autoResolved,
        score: score,
        historyId: history.id,
      );
    }

    final assessment = assessSmsFacts(
      suggestions,
      item.body,
      receivedAt: item.receivedAt,
    );
    final effectiveScore = serverScore != null && serverScore.isFinite
        ? serverScore
        : assessment.composite;
    final primary = assessment.primaryFact;

    if (suggestions.isEmpty || primary == null) {
      // A positive/unknown decision without usable structured fields is not a
      // safe dismissal. Preserve the original SMS for inspection/correction.
      return SmsAiResolutionResult(
        outcome: SmsAiResolutionOutcome.needsReview,
        score: effectiveScore,
      );
    }

    if (effectiveScore < kSmsReviewThreshold) {
      // Low confidence means abstain. Only an explicit shouldConsider=false
      // decision is allowed to remove a review item.
      return SmsAiResolutionResult(
        outcome: SmsAiResolutionOutcome.needsReview,
        score: effectiveScore,
      );
    }

    if (effectiveScore >= kSmsAutoResolveThreshold &&
        assessment.actionableFacts.length == 1 &&
        assessment.isComplete &&
        reviewRequired != true) {
      final resolved = _autoResolve(namespace, item, primary, effectiveScore);
      if (resolved != null) return resolved;
    }
    // Missing amounts/dates or the server's own review flag leave the row in
    // place; nothing here invents a number the message did not print.
    return SmsAiResolutionResult(
      outcome: SmsAiResolutionOutcome.needsReview,
      score: effectiveScore,
    );
  }

  SmsAiResolutionResult? _autoResolve(
    String namespace,
    NeedsReviewItem item,
    Map<String, dynamic> fact,
    double score,
  ) {
    final factType = fact['factType'] as String?;
    if (factType == null) return null;
    final payload = smsFactPayload(fact);
    final sourceKey = _cleanSourceKey(item);
    AutoResolvedHistoryEntry? history;

    store.batch(() {
      final db = store.database.db;
      db.execute('SAVEPOINT sms_ai_resolve');
      try {
        switch (factType) {
          case 'posted_movement':
          case 'bill_payment':
            history = _fileMovement(
              namespace,
              item,
              payload,
              sourceKey,
              factType,
              score,
            );
            break;
          case 'bill_obligation':
            history = _fileBill(namespace, item, payload, sourceKey, score);
            break;
          case 'mandate_lifecycle':
            history = _recordMandate(
              namespace,
              item,
              payload,
              sourceKey,
              score,
            );
            break;
          default:
            history = null;
        }
        if (history != null) {
          AutoResolvedHistoryRepository(
            store.database,
            namespace: namespace,
          ).record(history!);
          _deleteReviewRow(namespace, item.id);
          store.notifyPendingChange(namespace);
        }
        db.execute('RELEASE SAVEPOINT sms_ai_resolve');
      } catch (_) {
        db.execute('ROLLBACK TO SAVEPOINT sms_ai_resolve');
        db.execute('RELEASE SAVEPOINT sms_ai_resolve');
        rethrow;
      }
    });

    final recorded = history;
    if (recorded == null) return null;
    return SmsAiResolutionResult(
      outcome: SmsAiResolutionOutcome.autoResolved,
      score: score,
      historyId: recorded.id,
    );
  }

  AutoResolvedHistoryEntry? _fileMovement(
    String namespace,
    NeedsReviewItem item,
    Map<String, dynamic> payload,
    String sourceKey,
    String factType,
    double score,
  ) {
    final amountRupees = smsPostedAmountRupees(payload);
    if (amountRupees == null) return null;
    final amount = Money.fromPaise((amountRupees * 100).round());
    final occurredAt = _parseDate(payload['occurredAt']) ?? item.receivedAt;
    final merchant =
        _firstText([
          payload['merchant'],
          payload['transferParty'],
          payload['billerName'],
          payload['description'],
        ]) ??
        item.sender;
    final categorySlug = _categorySlug(
      payload,
      fallback: factType == 'bill_payment' ? 'bills' : null,
    );
    final instrumentWire = payload['instrument'] as String?;
    final instrument = _txnInstrument(instrumentWire);
    final entryKind = _txnEntryKind(
      payload['entryKind'],
      fallback: factType == 'bill_payment'
          ? TxnEntryKind.transfer
          : TxnEntryKind.spend,
    );
    final last4 = payload['last4'] as String?;

    UserCard? matchedCard;
    if (last4 != null &&
        (instrument == TxnInstrument.creditCard ||
            instrument == TxnInstrument.debitCard)) {
      final matches = store
          .entities(namespace, 'cards')
          .map(UserCard.fromJson)
          .where(
            (card) =>
                !card.isArchived &&
                card.last4 == last4 &&
                (instrument == TxnInstrument.debitCard
                    ? card.cardType == 'debit'
                    : card.cardType != 'debit'),
          )
          .toList();
      matchedCard = matches.length == 1 ? matches.single : null;
    }
    final accountLast4 =
        payload['accountLast4'] as String? ??
        (matchedCard == null ? last4 : null);

    store.saveTransactions(namespace, [
      TransactionEntry(
        id: 'local-ai:$sourceKey',
        sourceKey: sourceKey,
        amount: amount,
        occurredAt: occurredAt,
        merchantName: merchant,
        categoryId: categorySlug,
        categoryName: LocalSmsParser.categoryDisplayName(categorySlug),
        userCardId: matchedCard?.id,
        cardDisplayName: matchedCard?.cardName,
        cardLast4: last4,
        accountLast4: accountLast4,
        instrument: instrument,
        entryKind: entryKind,
        source: 'sms',
        status: 'active',
        rewardState: 'estimated',
      ),
    ]);

    return AutoResolvedHistoryEntry(
      id: 'ai:$sourceKey',
      namespace: namespace,
      sourceKey: sourceKey,
      sender: item.sender,
      resolvedKind: 'transaction',
      title: merchant,
      amountPaise: amount.paise,
      categorySlug: categorySlug,
      occurredAt: occurredAt.toIso8601String(),
      instrument: instrumentWire ?? instrument.wireValue,
      accountLast4: accountLast4,
      sourceBody: item.body,
      confidence: score,
      autoResolvedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  AutoResolvedHistoryEntry? _fileBill(
    String namespace,
    NeedsReviewItem item,
    Map<String, dynamic> payload,
    String sourceKey,
    double score,
  ) {
    final amountRupees = smsAmountDueRupees(payload);
    final due = _parseDate(payload['dueDate']);
    if (amountRupees == null || due == null) return null;
    final amount = Money.fromPaise((amountRupees * 100).round());
    final localDue = due.toLocal();
    final dueDay = DateTime(localDue.year, localDue.month, localDue.day);
    final now = DateTime.now();
    final startOfToday = DateTime(now.year, now.month, now.day);
    final title =
        _firstText([payload['billerName'], payload['merchant']]) ?? item.sender;

    if (!dueDay.isBefore(startOfToday)) {
      final category = CommitmentCategory.fromText('$title ${item.sender}');
      final commitment = Commitment(
        id: 'commitment:$sourceKey',
        title: title,
        category: category,
        amount: amount,
        dueOn: localDue,
        cadence: _inferCadence(category),
        source: CommitmentSource.sms,
        status: CommitmentStatus.due,
        confidence: score,
      );
      store.database.db.execute(
        'INSERT OR REPLACE INTO local_commitments VALUES (?, ?, ?)',
        [namespace, commitment.id, jsonEncode(commitment.toJson())],
      );
    } else {
      // An expired obligation is history, not a bill to pay. Archiving keeps
      // it out of the Bills pane without losing the alert.
      PastBillReceiptRepository(
        store.database,
        namespace: namespace,
      ).archiveBill(
        id: 'commitment:$sourceKey',
        sender: item.sender,
        merchant: title,
        amount: amount,
        receivedAt: item.receivedAt,
        dueDate: localDue,
        cardLast4: payload['last4'] as String?,
        accountLast4: payload['accountLast4'] as String?,
        body: item.body,
        status: PastBillReceiptStatus.historicalUnpaid,
      );
    }

    return AutoResolvedHistoryEntry(
      id: 'ai:$sourceKey',
      namespace: namespace,
      sourceKey: sourceKey,
      sender: item.sender,
      resolvedKind: 'bill',
      title: title,
      amountPaise: amount.paise,
      categorySlug: _categorySlug(payload),
      dueDate: localDue.toIso8601String(),
      occurredAt: _anchorDate(payload, item).toIso8601String(),
      instrument: payload['instrument'] as String?,
      accountLast4:
          payload['accountLast4'] as String? ?? payload['last4'] as String?,
      sourceBody: item.body,
      confidence: score,
      autoResolvedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  AutoResolvedHistoryEntry? _recordMandate(
    String namespace,
    NeedsReviewItem item,
    Map<String, dynamic> payload,
    String sourceKey,
    double score,
  ) {
    // A mandate is an authorization, never a charge: record it so the user
    // can see and undo the auto-decision, but never fabricate a bill from a
    // ceiling.
    final limit = payload['limitInr'];
    final limitPaise = limit is num && limit.isFinite && limit > 0
        ? (limit * 100).round()
        : 0;
    final title =
        _firstText([payload['serviceName'], payload['merchant']]) ??
        item.sender;
    return AutoResolvedHistoryEntry(
      id: 'ai:$sourceKey',
      namespace: namespace,
      sourceKey: sourceKey,
      sender: item.sender,
      resolvedKind: 'mandate',
      title: title,
      amountPaise: limitPaise,
      categorySlug: _categorySlug(payload),
      dueDate: payload['dueDate'] as String?,
      occurredAt: _anchorDate(payload, item).toIso8601String(),
      instrument: payload['instrument'] as String?,
      accountLast4:
          payload['accountLast4'] as String? ?? payload['last4'] as String?,
      sourceBody: item.body,
      confidence: score,
      autoResolvedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  void _deleteReviewRow(String namespace, String id) {
    final db = store.database.db;
    db.execute(
      'CREATE TABLE IF NOT EXISTS local_needs_review(namespace TEXT NOT NULL,id TEXT NOT NULL,payload TEXT NOT NULL,PRIMARY KEY(namespace,id))',
    );
    db.execute('DELETE FROM local_needs_review WHERE namespace=? AND id=?', [
      namespace,
      id,
    ]);
  }

  /// Strips the same `commitment:` prefix the UI helper does. A row that is
  /// not a 64-hex source key still needs a stable identity for replay, so the
  /// fallback is the sanitized id (never a fresh random value).
  String _cleanSourceKey(NeedsReviewItem item) {
    var key = item.id;
    if (key.startsWith('commitment:')) {
      key = key.substring('commitment:'.length);
    }
    if (RegExp(r'^[0-9a-f]{64}$').hasMatch(key)) return key;
    final sanitized = key.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '');
    if (sanitized.isNotEmpty) return sanitized;
    return 'review-${item.receivedAt.millisecondsSinceEpoch}';
  }

  String? _categorySlug(Map<String, dynamic> payload, {String? fallback}) {
    final raw = payload['category'];
    if (raw is String && smsSpendCategories.contains(raw)) return raw;
    return fallback;
  }

  DateTime? _parseDate(Object? value) =>
      value is String ? DateTime.tryParse(value) : null;

  DateTime _anchorDate(Map<String, dynamic> payload, NeedsReviewItem item) =>
      _parseDate(payload['occurredAt']) ??
      _parseDate(payload['asOfAt']) ??
      _parseDate(payload['statementDate']) ??
      _parseDate(payload['dueDate']) ??
      item.receivedAt;

  String? _firstText(List<Object?> values) {
    for (final value in values) {
      if (value is String && value.trim().isNotEmpty) return value.trim();
    }
    return null;
  }

  TxnInstrument _txnInstrument(String? wire) => switch (wire) {
    'credit_card' => TxnInstrument.creditCard,
    'debit_card' => TxnInstrument.debitCard,
    'cash' => TxnInstrument.cash,
    'upi_bank' => TxnInstrument.upiBank,
    'wallet' => TxnInstrument.wallet,
    _ => TxnInstrument.other,
  };

  TxnEntryKind _txnEntryKind(Object? wire, {required TxnEntryKind fallback}) =>
      switch (wire) {
        'spend' => TxnEntryKind.spend,
        'income' => TxnEntryKind.income,
        'investment' => TxnEntryKind.investment,
        'transfer' => TxnEntryKind.transfer,
        _ => fallback,
      };

  CommitmentCadence _inferCadence(CommitmentCategory category) =>
      switch (category) {
        CommitmentCategory.utility ||
        CommitmentCategory.telecom ||
        CommitmentCategory.loanOrEmi ||
        CommitmentCategory.rent ||
        CommitmentCategory.subscription => CommitmentCadence.monthly,
        _ => CommitmentCadence.oneTime,
      };
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
