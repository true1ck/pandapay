import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_ledger.dart';
import 'package:pandapay_domain/sms_v2_template.dart';

import '../../../data/local/financial_store.dart';
import '../../../data/local/sms_learning_feedback.dart';
import '../category/category_snapshot.dart';
import '../category/user_category_rules.dart';
import '../ledger/projection_writer.dart';
import '../pipeline/trace.dart';
import '../storage/event_store.dart';
import '../storage/fact_store.dart';
import '../storage/instrument_store.dart';
import '../storage/ledger_store.dart';
import '../storage/outbox_store.dart';

/// A device-local correction. [corrected] uses contract field names such as
/// amountMinor, occurredAt, merchantName, instrumentId, category, or legs.
class SmsCorrection {
  const SmsCorrection({
    required this.id,
    required this.sourceKey,
    required this.kind,
    required this.corrected,
    required this.trace,
    this.factIds = const [],
    this.eventId,
    this.message,
    this.extractedMaskCorrect = true,
    this.sharedLearningConsent = false,
  });

  final String id, sourceKey;
  final CorrectionKind kind;
  final Map<String, Object?> corrected;
  final DecisionTrace trace;
  final List<String> factIds;
  final String? eventId;
  final SmsMessage? message;
  final bool extractedMaskCorrect, sharedLearningConsent;
}

/// Applies the local effect and queues its review case in the same savepoint.
class CorrectionsService {
  CorrectionsService({
    required this.financial,
    required this.namespace,
    required this.bundle,
    this.categoryIdBySlug = const {},
  });

  final FinancialStore financial;
  final String namespace;
  final RuleBundle bundle;
  final Map<String, String> categoryIdBySlug;
  late final _db = financial.database.db;
  late final _facts = FactStore(_db, namespace: namespace);
  late final _events = EventStore(_db, namespace: namespace);
  late final _ledger = LedgerStore(_db, namespace: namespace);
  late final _outbox = OutboxStore(_db, namespace: namespace);

  void apply(SmsCorrection correction) {
    if (correction.id.isEmpty) {
      throw ArgumentError('Correction id is required');
    }
    final localId = 'correction:${correction.id}';
    if (_db.select(
      'SELECT 1 FROM v2_review_items WHERE namespace=? AND review_id=?',
      [namespace, localId],
    ).isNotEmpty) {
      return;
    }
    final originalFacts = {
      for (final id in correction.factIds)
        id:
            _facts.get(id) ??
            (throw ArgumentError('Fact is not in this account')),
    };
    if (originalFacts.values.any(
      (fact) => fact.sourceKey != correction.sourceKey,
    )) {
      throw ArgumentError('Fact source mismatch');
    }
    var event = correction.eventId == null
        ? null
        : _events.get(correction.eventId!);
    if (correction.eventId != null && event == null) {
      throw ArgumentError('Event is not in this account');
    }
    final stage = correction.trace.stage(
      correction.kind,
      extractedMaskCorrect: correction.extractedMaskCorrect,
    );
    financial.batch(() {
      _db.execute('SAVEPOINT sms_v2_correction');
      try {
        final corrected = correction.corrected;
        final locked = <String, CategoryDecision>{};
        if (correction.kind == CorrectionKind.wrongCategory ||
            correction.kind == CorrectionKind.preferenceOnly) {
          final slug = corrected['category'] as String;
          final key = corrected['merchantKey'] as String;
          UserCategoryRules(
            financial.database,
            namespace: namespace,
          ).saveChoice(merchantKey: key, slug: slug);
          if (event != null) {
            locked[event!.eventId] = CategoryDecision(
              slug: slug,
              source: CategorySource.user,
              confidence: 1,
            );
          }
        } else if (correction.kind == CorrectionKind.notFinancial) {
          final message = correction.message;
          if (message == null || message.sourceKey != correction.sourceKey) {
            throw ArgumentError(
              'The original message is required for an ignore rule',
            );
          }
          SmsLearningFeedback(
            financial.database,
            namespace: namespace,
          ).recordFalseTransactionRule(
            sender: message.sender,
            body: message.body,
          );
          if (event != null) event = event!.copyWith(type: EventType.unknown);
        } else if (correction.kind == CorrectionKind.duplicate) {
          if (event == null) throw ArgumentError('An event is required');
          event = event!.copyWith(type: EventType.unknown);
        } else if (correction.kind == CorrectionKind.wrongInstrument) {
          if (originalFacts.isEmpty) {
            throw ArgumentError('A source fact is required');
          }
          final instrumentId = corrected['instrumentId'] as String;
          final target = InstrumentStore(
            _db,
            namespace: namespace,
          ).get(instrumentId);
          if (target == null || target.status == InstrumentStatus.rejected) {
            throw ArgumentError('Instrument is not in this account');
          }
          for (final fact in originalFacts.values) {
            _db.execute(
              'UPDATE v2_facts SET instrument_id=? WHERE namespace=? AND fact_id=?',
              [instrumentId, namespace, fact.factId],
            );
          }
        } else if (correction.kind == CorrectionKind.wrongLink) {
          if (event == null) throw ArgumentError('An event is required');
          final legs = [
            for (final json in corrected['legs'] as List)
              EventLeg.fromJson((json as Map).cast<String, Object?>()),
          ];
          if (legs.isEmpty ||
              legs.any((leg) => _facts.get(leg.factId) == null)) {
            throw ArgumentError('All linked facts must be in this account');
          }
          event = event!.copyWith(legs: legs);
        } else if (correction.kind != CorrectionKind.missing) {
          if (event == null || originalFacts.length != 1) {
            throw ArgumentError('One source fact and event are required');
          }
          final original = originalFacts.values.single;
          final json = original.toJson();
          final id = sha256
              .convert(utf8.encode('user|${correction.id}|${original.factId}'))
              .toString();
          final source = 'correction:${correction.id}';
          final patch = <String, Object?>{
            ...json,
            'factId': id,
            'sourceKey': source,
            'provenance': {
              ...original.provenance.toJson(),
              'engine': 'user',
              'ruleId': 'USER-CORRECTION',
              'ruleVersion': 1,
            },
            if (correction.kind == CorrectionKind.wrongDate)
              'occurredAt': corrected['occurredAt'],
            if (correction.kind == CorrectionKind.wrongMerchant)
              'counterparty': <String, Object?>{
                ...?original.counterparty?.toJson(),
                'name': corrected['merchantName'],
              },
          };
          if (correction.kind == CorrectionKind.wrongAmount) {
            final amount = corrected['amountMinor'];
            if (amount is! int || amount <= 0) {
              throw ArgumentError('Positive paise required');
            }
            final role =
                corrected['amountRole'] as String? ??
                original.amounts
                    .where((value) => value.role == AmountRole.posted)
                    .firstOrNull
                    ?.role
                    .wire ??
                original.amounts.firstOrNull?.role.wire;
            if (role == null ||
                !original.amounts.any((value) => value.role.wire == role)) {
              throw ArgumentError('A printed amount role is required');
            }
            patch['amounts'] = [
              for (final value in original.amounts)
                {
                  ...value.toJson(),
                  if (value.role.wire == role) 'minor': amount,
                },
            ];
          }
          final replacement = Fact.fromJson(patch);
          _facts.insert(replacement);
          _outbox.enqueue('source', source, {
            'sourceKey': source,
            'senderBrand': correction.message == null
                ? 'USER'
                : normalizeSenderBrand(correction.message!.sender).brand,
            'observedAt': replacement.observedAt.toUtc().toIso8601String(),
            'bodyHash': sha256.convert(utf8.encode(source)).toString(),
            'facts': [
              {
                ...replacement.toJson(),
                'evidence': <Object?>[],
                if (replacement.instrument != null)
                  'instrument': {
                    ...replacement.instrument!.toJson(),
                    'raw': null,
                  },
              },
            ],
          });
          event = event!.copyWith(
            legs: [
              for (final leg in event!.legs)
                if (leg.factId == original.factId) ...[
                  if (leg.factId == event!.eventId)
                    EventLeg(factId: leg.factId, role: LegRole.original),
                  EventLeg(factId: replacement.factId, role: leg.role),
                ] else
                  leg,
            ],
            amountMinor: correction.kind == CorrectionKind.wrongAmount
                ? corrected['amountMinor'] as int
                : null,
            occurredAt: correction.kind == CorrectionKind.wrongDate
                ? replacement.effectiveAt
                : null,
            type: correction.kind == CorrectionKind.wrongKind
                ? EventType.fromWire(corrected['eventType'] as String)
                : null,
          );
        }
        if (event != null) {
          event = event!.copyWith(status: EventStatus.userConfirmed);
          final check = event!.validate();
          if (!check.ok) throw ContractException(check.errors);
          event = _events.upsert(event!, fromUser: true);
          final affected = <String, Event>{
            event!.eventId: event!,
            for (final related in _events.findByFactIds(correction.factIds))
              if (related.eventId != event!.eventId) related.eventId: related,
          };
          final previousEntries = [
            for (final related in affected.values)
              ..._ledger.forEvent(related.eventId),
          ];
          for (final saved in _ledger.categoryDecisions().entries) {
            if (saved.value.source == CategorySource.user) {
              locked.putIfAbsent(saved.key, () => saved.value);
            }
          }
          final allFacts = {
            for (final fact in _facts.since(DateTime.utc(1900)))
              fact.factId: fact,
          };
          final instruments = {
            for (final value in InstrumentStore(
              _db,
              namespace: namespace,
            ).list())
              value.instrumentId: value,
          };
          final categories = CategorySnapshot.load(
            financial.database,
            namespace: namespace,
            aliases: bundle.merchantAliases,
          );
          final snapshot = LedgerSnapshot.project(
            events: affected.values,
            factsById: allFacts,
            instrumentsById: instruments,
            bundle: bundle,
            lockedCategories: locked,
            instrumentIdByFactId: _facts.instrumentIdsSince(DateTime.utc(1900)),
            userRules: categories.userRules,
            confirmedHistory: categories.confirmedHistory,
          );
          ProjectionWriter(financial, _ledger).write(
            snapshot,
            factsById: allFacts,
            instrumentsById: instruments,
            categoryIdBySlug: categoryIdBySlug,
            instrumentIdByFactId: _facts.instrumentIdsSince(DateTime.utc(1900)),
          );
          final retainedIds = snapshot.entries
              .map((entry) => entry.entryId)
              .toSet();
          for (final previous in previousEntries) {
            if (!retainedIds.contains(previous.entryId)) {
              _db.execute('DELETE FROM v2_outbox WHERE namespace=? AND id=?', [
                namespace,
                'ledger:${previous.entryId}',
              ]);
            }
          }
          for (final changed in affected.values) {
            _outbox.enqueue('event', changed.eventId, changed.toJson());
          }
          for (final entry in snapshot.entries) {
            _outbox.enqueue('ledger', entry.entryId, entry.toJson());
          }
        }
        _db.execute(
          'INSERT INTO v2_review_items(namespace,review_id,kind,payload,status) VALUES(?,?,?,?,?)',
          [
            namespace,
            localId,
            'correction',
            jsonEncode({
              'kind': correction.kind.wire,
              'trace': correction.trace.toJson(),
              'corrected': correction.corrected,
            }),
            'pending',
          ],
        );
        if (stage != null) _queueCase(correction, stage);
        _db.execute('RELEASE sms_v2_correction');
        financial.notifyExternalChanges(namespace, const [
          'transactions',
          'observations',
        ]);
      } catch (_) {
        _db.execute('ROLLBACK TO sms_v2_correction');
        _db.execute('RELEASE sms_v2_correction');
        rethrow;
      }
    });
  }

  void _queueCase(SmsCorrection correction, String stage) {
    final payload = <String, Object?>{
      'sourceKey': correction.sourceKey,
      'factIds': correction.factIds,
      if (correction.eventId != null) 'eventId': correction.eventId,
      'correctionKind': correction.kind.wire,
      'corrected': <String, Object?>{},
      'trace': correction.trace.compact(stage),
    };
    if (correction.sharedLearningConsent && correction.message != null) {
      final message = correction.message!;
      final redacted = redactSms(
        sender: message.sender,
        body: message.body,
        observedAt: message.observedAt,
        options: SmsRedactionOptions(salt: correction.id),
      );
      final skeleton = smsSkeleton(redacted.body);
      final brand = smsTemplateBrand(redacted.sender);
      payload['redactedTemplate'] = skeleton;
      payload['corrected'] = {
        // Only categorical values enter shared review automatically. Corrected
        // amounts, dates and names stay on-device until an admin makes a
        // reviewed synthetic example for code-fix export.
        if (correction.corrected['category'] case final String category)
          'category': category,
        '_template': {
          'senderBrand': brand,
          'hash': smsTemplateHash(brand, skeleton),
          'observedAt': redacted.observedAt.toUtc().toIso8601String(),
        },
      };
    }
    _outbox.enqueue('correction', correction.id, payload);
  }
}
