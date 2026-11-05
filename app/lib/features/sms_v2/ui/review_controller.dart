import 'dart:convert';
import 'package:flutter/material.dart';
import '../../../app/design/bamboo_components.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_category.dart';
import 'package:pandapay_domain/sms_v2_ledger.dart';
import '../../../app/providers.dart' as app;
import '../../../data/local/financial_store.dart';
import '../../../data/local/sms_intake_repository.dart';
import '../corrections/corrections_service.dart';
import '../pipeline/receipt_review.dart';
import '../pipeline/trace.dart';
import '../providers/data_providers.dart';
import '../providers/runtime_provider.dart';
import '../storage/event_store.dart';
import '../storage/fact_store.dart';
import '../storage/ledger_store.dart';
import '../storage/sync_state_store.dart';
import 'correction_form.dart';
import 'screen_parts.dart';

/// Groups always contain individual source identities. A format action applies
/// independently to each source, retaining that source's printed amount/date.
class ReviewController {
  const ReviewController({
    required this.financial,
    required this.namespace,
    required this.bundle,
    this.hasConsent = false,
  });
  final FinancialStore financial;
  final String namespace;
  final RuleBundle bundle;
  final bool hasConsent;

  void apply({
    required Iterable<LocalReviewItem> items,
    required CorrectionKind kind,
    Map<String, Object?> corrected = const {},
    bool confirm = false,
  }) {
    final db = financial.database.db;
    final service = CorrectionsService(
      financial: financial,
      namespace: namespace,
      bundle: bundle,
    );
    financial.batch(() {
      db.execute('SAVEPOINT sms_review_group');
      try {
        final sources = <String>{};
        for (final item in items) {
          final source =
              item.payload['sourceKey'] as String? ?? item.message?.id;
          if (source == null) {
            throw ArgumentError(
              'The source of this review item is unavailable',
            );
          }
          if (!sources.add(source)) continue;
          final facts = FactStore(db, namespace: namespace).forSource(source);
          final events = EventStore(db, namespace: namespace);
          var event =
              (item.payload['eventId'] is String
                  ? events.get(item.payload['eventId'] as String)
                  : null) ??
              events.findByFactIds(facts.map((f) => f.factId)).firstOrNull;
          final raw =
              item.message ??
              SmsIntakeRepository(
                financial.database,
              ).capturedById(namespace, source);
          final message = raw == null
              ? null
              : SmsMessage(
                  sender: raw.message.sender,
                  body: raw.message.body,
                  observedAt: raw.message.receivedAt.toUtc(),
                  sourceKey: source,
                );
          // The wire case remains attached to this receipt's original facts.
          // Its event can already contain newer user facts from earlier edits.
          final receipt =
              facts.whereType<MovementFact>().firstOrNull ?? facts.firstOrNull;
          final activeFacts = <String, Fact>{
            if (event != null)
              for (final leg in event.legs)
                leg.factId: ?FactStore(
                  db,
                  namespace: namespace,
                ).get(leg.factId),
          };
          final money = event == null
              ? receipt
              : moneyFactForEvent(event, activeFacts) ?? receipt;
          final patch = <String, Object?>{...corrected};
          if (patch.remove('_matchEventId') case final String matchId) {
            final target = EventStore(db, namespace: namespace).get(matchId);
            if (kind != CorrectionKind.wrongLink ||
                target == null ||
                money == null) {
              throw ArgumentError('This match is no longer available');
            }
            final rule =
                item.payload['linkRuleId']?.toString().toLowerCase() ?? '';
            final notice =
                rule.contains('receipt') || rule.contains('duplicate');
            final previous = event;
            final legs = <String, EventLeg>{
              for (final leg in target.legs) leg.factId: leg,
              for (final leg
                  in previous?.legs ??
                      [
                        EventLeg(
                          factId: money.factId,
                          role: LegRole.duplicateNotice,
                        ),
                      ])
                leg.factId: notice
                    ? EventLeg(
                        factId: leg.factId,
                        role: LegRole.duplicateNotice,
                      )
                    : leg,
            };
            if (target.linkRuleId == null &&
                target.legs.length == 1 &&
                patch['_candidateRole'] is String) {
              final leg = target.legs.single;
              legs[leg.factId] = EventLeg(
                factId: leg.factId,
                role: LegRole.fromWire(patch['_candidateRole'] as String),
              );
            }
            patch['legs'] = legs.values.map((l) => l.toJson()).toList();
            patch['eventType'] =
                (notice ? target.type : previous?.type ?? target.type).wire;
            if (previous != null && previous.eventId != target.eventId) {
              patch['_retireEventIds'] = [previous.eventId];
            }
            patch.remove('_candidateFactId');
            patch.remove('_candidateRole');
            event = target;
          }
          if (kind != CorrectionKind.notFinancial &&
              kind != CorrectionKind.missing &&
              event == null) {
            throw ArgumentError(
              'This format has no reading yet. Report it as missing, or mark it not financial.',
            );
          }
          final saved = SyncStateStore(
            db,
            namespace: namespace,
          ).get('trace:$source');
          final trace = saved == null
              ? <String, Object?>{}
              : (jsonDecode(saved) as Map).cast<String, Object?>();
          if (kind == CorrectionKind.wrongLink && !patch.containsKey('legs')) {
            patch['legs'] = event!.legs.map((l) => l.toJson()).toList();
          }
          if (kind == CorrectionKind.wrongCategory ||
              kind == CorrectionKind.preferenceOnly) {
            patch['merchantKey'] = normalizeMerchantText(
              money?.counterparty?.name ?? 'UNKNOWN',
            );
          }
          service.apply(
            SmsCorrection(
              id: const Uuid().v4(),
              sourceKey: source,
              kind: kind,
              corrected: patch,
              factIds: receipt == null ? const [] : [receipt.factId],
              eventId: event?.eventId,
              message: message,
              sharedLearningConsent: hasConsent,
              reportCase: !confirm,
              trace: DecisionTrace(
                appVersion: trace['appVersion'] as String? ?? 'unknown',
                engineVersion: trace['engineVersion'] as String? ?? 'unknown',
                bundleVersion:
                    trace['bundleVersion'] as int? ?? bundle.bundleVersion,
                outcome: trace['outcome'] as String? ?? 'matched',
                ruleId: trace['ruleId'] as String? ?? money?.provenance.ruleId,
                ruleVersion:
                    trace['ruleVersion'] as int? ??
                    money?.provenance.ruleVersion,
                facts: event == null
                    ? facts
                    : [
                        for (final leg in event.legs)
                          if (leg.role != LegRole.original &&
                              activeFacts[leg.factId] != null)
                            activeFacts[leg.factId]!,
                      ],
                event: event,
                category: event == null
                    ? null
                    : LedgerStore(
                        db,
                        namespace: namespace,
                      ).categoryDecisions()[event.eventId],
              ),
            ),
          );
        }
        for (final item in items) {
          db.execute(
            "UPDATE v2_review_items SET status='resolved' WHERE namespace=? AND review_id=?",
            [namespace, item.id],
          );
        }
        db.execute('RELEASE sms_review_group');
        financial.notifyExternalChanges(namespace, const [
          'needs_review',
          'transactions',
          'observations',
        ]);
      } catch (_) {
        db.execute('ROLLBACK TO sms_review_group');
        db.execute('RELEASE sms_review_group');
        rethrow;
      }
    });
  }
}

/// Loads the sharing opt-in even when no screen is watching it. Reading an
/// autoDispose provider nobody listens to returns "loading", not the value,
/// which silently turned every fix into a local-only fix.
Future<bool> readSharingConsent(WidgetRef ref) async {
  final keepAlive = ref.listenManual(
    app.smsSharedLearningConsentProvider,
    (_, _) {},
  );
  try {
    return await ref.read(app.smsSharedLearningConsentProvider.future) != null;
  } catch (_) {
    return false; // Offline or failed: share nothing.
  } finally {
    keepAlive.close();
  }
}

Future<ReviewController> smsReviewController(WidgetRef ref) async {
  final namespace = ref.read(app.cacheNamespaceProvider);
  final runtime = await ref.read(smsV2RuntimeProvider.future);
  final bundle = await runtime?.activeBundle();
  final cache = await ref.read(app.responseCacheProvider.future);
  final hasConsent = await readSharingConsent(ref);
  if (namespace != ref.read(app.cacheNamespaceProvider)) {
    throw StateError('Account changed');
  }
  if (bundle == null) throw StateError('No verified rules');
  return ReviewController(
    financial: cache.financialStore,
    namespace: namespace,
    bundle: bundle,
    hasConsent: hasConsent,
  );
}

/// The receipt question's answers for the signed-in account.
Future<ReceiptReviews> smsReceiptReviews(WidgetRef ref) async {
  final namespace = ref.read(app.cacheNamespaceProvider);
  final runtime = await ref.read(smsV2RuntimeProvider.future);
  final bundle = await runtime?.activeBundle();
  final cache = await ref.read(app.responseCacheProvider.future);
  if (namespace != ref.read(app.cacheNamespaceProvider)) {
    throw StateError('Account changed');
  }
  if (bundle == null) throw StateError('No verified rules');
  return ReceiptReviews(
    financial: cache.financialStore,
    namespace: namespace,
    bundle: bundle,
    clock: runtime?.clock,
  );
}

Future<void> showSmsCorrection(
  BuildContext context,
  WidgetRef ref, {
  required String sourceKey,
  String? eventId,
}) async {
  final namespace = ref.read(app.cacheNamespaceProvider);
  try {
    final cache = await ref.read(app.responseCacheProvider.future);
    if (!context.mounted || namespace != ref.read(app.cacheNamespaceProvider)) {
      return;
    }
    final message = SmsIntakeRepository(
      cache.financialStore.database,
    ).capturedById(namespace, sourceKey);
    final item = LocalReviewItem(
      id: 'report:$sourceKey',
      kind: 'event',
      payload: {'sourceKey': sourceKey, 'eventId': ?eventId},
      message: message,
    );
    final edit = await showBambooSheet<CorrectionEdit>(
      context: context,
      builder: (_) => const CorrectionForm(),
    );
    if (edit == null ||
        !context.mounted ||
        namespace != ref.read(app.cacheNamespaceProvider)) {
      return;
    }
    final controller = await smsReviewController(ref);
    controller.apply(items: [item], kind: edit.kind, corrected: edit.corrected);
    ref.invalidate(reviewItemsProvider);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Saved on this device. Your totals have been updated.'),
        ),
      );
    }
  } catch (error) {
    if (context.mounted) smsShowError(context, error);
  }
}
