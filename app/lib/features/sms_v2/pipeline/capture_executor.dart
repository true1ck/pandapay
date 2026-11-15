import 'package:pandapay_domain/sms_v2.dart';

import '../../../data/local/financial_store.dart';
import '../../../data/local/sms_import_store.dart';
import '../../sms_import/sms_background_queue.dart';
import '../category/category_snapshot.dart';
import '../personal/personal_rule_store.dart';
import '../storage/provisional_store.dart';
import '../../../data/user_cards_repository.dart' show UserCard;
import '../instruments/card_transaction_relinker.dart';
import '../instruments/instrument_seeder.dart';
import '../instruments/unlinked_card_healer.dart';
import '../storage/instrument_store.dart';
import 'sms_v2_pipeline.dart';

/// One slice of a chunk that shares a backfill flag. History (`backfill`) goes
/// first, then live messages, exactly as the synchronous loop always did.
class CaptureGroup {
  const CaptureGroup({required this.backfill, required this.messages});
  final bool backfill;
  final List<QueuedSms> messages;
}

/// One chunk of at most 200 messages, as plain data. The shared bundle is the
/// verified, un-overlaid bundle; each executor builds the account's provisional
/// overlay itself, once per [session] (one session per `SmsV2Runtime.capture`).
class CaptureChunkRequest {
  const CaptureChunkRequest({
    required this.namespace,
    required this.appVersion,
    required this.categoryIdBySlug,
    required this.session,
    required this.shared,
    required this.groups,
    required this.ownerNames,
    this.healCards = false,
    this.walletCards,
    this.cardIssuerSlugs = const {},
    this.onCommitted,
    this.debugFault,
  });

  final String namespace;
  final String appVersion;
  final Map<String, String> categoryIdBySlug;
  final int session;
  final RuleBundle shared;
  final List<CaptureGroup> groups;
  final List<String> ownerNames;

  /// Also link the card movements that were saved with no card to the wallet
  /// card they name ([UnlinkedCardHealer]), after the groups. Plain data like
  /// the rest, so the whole walk runs in the worker isolate, off the UI thread.
  final bool healCards;

  /// The wallet cards (their stored JSON) to link to the cards the messages
  /// found, before the groups are captured: seeding the instruments, then
  /// writing each wallet card onto the transactions saved before it was linked.
  /// That is O(the card's history), so it runs here, in the worker, and never on
  /// the UI isolate. [cardIssuerSlugs] maps a wallet card id to its issuer slug
  /// (the catalogue is not sent); a card with none is skipped, as before.
  final List<Map<String, Object?>>? walletCards;
  final Map<String, String?> cardIssuerSlugs;

  /// Called on the calling isolate with the entity names a worker committed
  /// (including for a chunk whose caller already timed out), so the live
  /// `FinancialStore` can bump its revision streams. Never called in-process,
  /// where the store itself already notified.
  final void Function(Set<String> changedEntities)? onCommitted;

  /// Test hook honoured only in debug/test builds (`assert`): `throw`, `exit`
  /// or `stall`.
  final String? debugFault;
}

/// Runs the CPU/SQL-heavy part of SMS capture. Completing normally means every
/// message of the request was captured, processed and acknowledged; any error
/// means the caller must treat the messages as still pending.
abstract class CaptureExecutor {
  Future<void> run(CaptureChunkRequest request);
  Future<void> close();
}

void _direct(void Function() work) => work();

/// The one capture loop body. [InProcessCaptureExecutor] and the worker isolate
/// both call it, so the isolate cannot change results, ordering, dedup or
/// acknowledge semantics. [transact] wraps each group's database work.
void runCaptureChunk({
  required FinancialStore financial,
  required String namespace,
  required RuleBundle bundle,
  required String overlayRevision,
  required RuleEngine engine,
  required PersonalRuleStore personalRules,
  required String appVersion,
  required Map<String, String> categoryIdBySlug,
  required List<CaptureGroup> groups,
  required List<String> ownerNames,
  bool healCards = false,
  List<Map<String, Object?>>? walletCards,
  Map<String, String?> cardIssuerSlugs = const {},
  void Function(void Function() work) transact = _direct,
}) {
  if (walletCards != null) {
    // Never stops a message from being captured; the next run retries it.
    try {
      transact(
        () => seedAndRelinkWalletCards(
          financial,
          namespace,
          walletCards,
          cardIssuerSlugs,
        ),
      );
    } catch (_) {}
  }
  final categories = CategorySnapshot.load(
    financial.database,
    namespace: namespace,
    aliases: bundle.merchantAliases,
  );
  final pipeline = SmsV2Pipeline(
    financial: financial,
    namespace: namespace,
    bundle: bundle,
    appVersion: appVersion,
    userRules: categories.userRules,
    confirmedHistory: categories.confirmedHistory,
    categoryIdBySlug: categoryIdBySlug,
    engine: engine,
    revision: '$overlayRevision:personal:${personalRules.revision}',
    ownerNames: ownerNames,
  );
  for (final group in groups) {
    if (group.messages.isEmpty) continue;
    transact(
      () => SmsImportStore(
        financial,
        v2Pipeline: pipeline,
        v2Backfill: group.backfill,
      ).captureBatch(namespace, group.messages),
    );
  }
  if (healCards) {
    // One short transaction per step (at most 50 facts), so a writer on the
    // other connection never waits long and a failure loses at most one step.
    final healer = UnlinkedCardHealer(financial, namespace: namespace);
    HealCursor? cursor;
    do {
      HealCursor? next;
      transact(() => next = healer.step(after: cursor).next);
      cursor = next;
    } while (cursor != null);
  }
}

/// Links each wallet card to the card the messages found and gives that card the
/// transactions saved before it was linked (see [CardTransactionRelinker]).
/// Idempotent; the heavy part is bounded by the linked cards' own history.
void seedAndRelinkWalletCards(
  FinancialStore financial,
  String namespace,
  List<Map<String, Object?>> walletCards,
  Map<String, String?> cardIssuerSlugs,
) {
  final seeded = InstrumentSeeder(
    InstrumentStore(financial.database.db, namespace: namespace),
  ).seed(
    cards: [for (final c in walletCards) UserCard.fromJson(c)],
    issuerSlugOf: (card) => cardIssuerSlugs[card.id],
    bankAccounts: const [],
  );
  final relinker = CardTransactionRelinker(financial, namespace: namespace);
  relinker.moveFacts(seeded.merged);
  relinker.relinkAll(seeded.linked);
  relinker.repairOnce();
}

/// Synchronous path on the caller's own connection: in-memory databases (every
/// test) and the fallback when the worker cannot start.
class InProcessCaptureExecutor implements CaptureExecutor {
  InProcessCaptureExecutor({
    required this.financial,
    required this.namespace,
    required this.engine,
    required this.personalRules,
  });

  final FinancialStore financial;
  final String namespace;
  final RuleEngine engine;
  final PersonalRuleStore personalRules;
  int? _session;
  ({RuleBundle bundle, String revision})? _overlay;

  @override
  Future<void> run(CaptureChunkRequest request) async {
    if (request.namespace != namespace) {
      throw ArgumentError('SMS capture account mismatch');
    }
    if (_session != request.session || _overlay == null) {
      _overlay = ProvisionalStore(personalRules.state).overlay(request.shared);
      _session = request.session;
    }
    final overlay = _overlay!;
    runCaptureChunk(
      financial: financial,
      namespace: namespace,
      bundle: overlay.bundle,
      overlayRevision: overlay.revision,
      engine: engine,
      personalRules: personalRules,
      appVersion: request.appVersion,
      categoryIdBySlug: request.categoryIdBySlug,
      groups: request.groups,
      ownerNames: request.ownerNames,
      healCards: request.healCards,
      walletCards: request.walletCards,
      cardIssuerSlugs: request.cardIssuerSlugs,
    );
    await Future<void>.delayed(
      Duration.zero,
    ); // perf-ok: in-memory/fallback path only, one bounded 200-message chunk per yield; file-backed databases use the worker isolate
  }

  @override
  Future<void> close() async {}
}

/// Raised only when the worker never accepted the chunk (it could not start or
/// is closed), so falling back to the in-process path cannot double-process.
class CaptureWorkerUnavailable implements Exception {
  const CaptureWorkerUnavailable(this.reason);
  final String reason;
  @override
  String toString() => 'SMS capture worker unavailable: $reason';
}

/// Prefers [primary] (the worker); when it cannot start, this and later chunks
/// run on [fallback] so capture degrades to the old behaviour instead of
/// stopping. Job errors are never retried on the fallback.
class FallbackCaptureExecutor implements CaptureExecutor {
  FallbackCaptureExecutor({required this.primary, required this.fallback});
  final CaptureExecutor primary;
  final CaptureExecutor fallback;
  bool _degraded = false;

  @override
  Future<void> run(CaptureChunkRequest request) async {
    if (!_degraded) {
      try {
        return await primary.run(request);
      } on CaptureWorkerUnavailable {
        _degraded = true;
      }
    }
    return fallback.run(request);
  }

  @override
  Future<void> close() async {
    await primary.close();
    await fallback.close();
  }
}
