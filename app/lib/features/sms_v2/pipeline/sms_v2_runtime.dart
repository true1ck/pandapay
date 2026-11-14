import '../personal/personal_rule_engine.dart';
import '../personal/owner_identity_store.dart';
import '../personal/personal_rule_store.dart';
import '../migration/legacy_replay.dart';
import '../migration/history_update.dart';
import '../migration/history_category_recheck.dart';
import 'package:crypto/crypto.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/pandapay_domain.dart' show CardProduct;

import '../../../data/local/financial_store.dart';
import '../../../data/connectivity/server_backoff.dart';
import '../../../data/local_first/command_outbox.dart';
import '../../../data/user_cards_repository.dart';
import '../instruments/card_transaction_relinker.dart';
import '../instruments/instrument_seeder.dart';
import 'ai_withdrawal.dart';
import '../storage/event_store.dart';
import '../storage/fact_store.dart';
import '../storage/instrument_store.dart';
import '../ledger/card_state_adapter.dart';
import '../../../data/local/sms_intake_repository.dart';
import '../../sms_import/sms_background_queue.dart';
import '../../sms_import/sms_text_hint.dart';
import '../storage/bundle_store.dart';
import '../storage/outbox_store.dart';
import '../storage/schema.dart';
import '../storage/subscription_store.dart';
import '../storage/sync_state_store.dart';
import '../storage/provisional_store.dart';
import '../storage/stats_store.dart';
import '../sync/learning_signals.dart';
import '../sync/sharing_consent_mirror.dart';
import '../sync/template_upload.dart';
import '../sync/stats_upload.dart';
import '../telemetry/client_metrics.dart';
import '../sync/corrections_sync.dart';
import '../similar/fact_keys.dart';
import '../sync/requeue_for_upload.dart';
import '../sync/facts_upload.dart';
import '../sync/sync_pull.dart';
import 'capture_executor.dart';
import 'capture_worker.dart';
import 'receipt_review.dart';
import 'owner_recheck.dart';
import 'salary_recheck.dart';
import 'rules_refresh.dart';

/// One foreground account owner. Capture is available offline, and the
/// lifecycle provider admits network work at start, resume and foreground ticks.
class SmsV2Runtime {
  SmsV2Runtime({
    required this.financial,
    required this.namespace,
    required this.client,
    required this.baseUri,
    required this.deviceId,
    required this.appVersion,
    required Future<Map<String, String>> Function() headers,
    required this.verify,
    required this.loadShippedBundle,
    required this.accountIsCurrent,
    this.hasSharingConsent = _noConsent,
    this.ownerNames = _noOwnerNames,
    this.catalogue = const [],
    this.cardRepository,

    this.categoryIdBySlug = const {},
    this.autoApplyResort = false,
    this.captureExecutor,
    this.isOffline = _neverOffline,
    Duration headersTimeout = defaultHeadersTimeout,
    DateTime Function()? clock,
  }) : headers = _bounded(headers, headersTimeout),
       clock = clock ?? DateTime.now {
    SmsV2Schema.ensure(financial.database.db);
  }

  /// How long acquiring request headers (the App Check token) may take before
  /// the request is abandoned. Without a bound a black-holed network held every
  /// network step of a sync for as long as the platform took to give up (C-04).
  static const defaultHeadersTimeout = Duration(seconds: 8);

  static Future<Map<String, String>> Function() _bounded(
    Future<Map<String, String>> Function() headers,
    Duration limit,
  ) => () => headers().timeout(limit);

  static bool _neverOffline() => false;

  /// True while the phone knows it has no connection. Network steps of a sync
  /// are skipped then; reading messages never waits on the network.
  final bool Function() isOffline;

  static Future<bool> _noConsent() async => false;
  static List<String> _noOwnerNames() => const [];
  final Future<bool> Function() hasSharingConsent;

  /// The account owner's names, read when messages are captured.
  final List<String> Function() ownerNames;
  final List<CardProduct> catalogue;
  final UserCardsRepository? cardRepository;
  final FinancialStore financial;
  final String namespace;
  final http.Client client;
  final Uri baseUri;
  final String deviceId;
  final String appVersion;
  final Future<Map<String, String>> Function() headers;
  final Future<RuleBundle?> Function(String) verify;
  final Future<String> Function() loadShippedBundle;
  final bool Function() accountIsCurrent;
  final CaptureExecutor? captureExecutor;
  final Map<String, String> categoryIdBySlug;

  /// Whether a new rule set re-sorts spends without being asked. Off: the
  /// refresh sheet shows what would move and waits for a tap.
  final bool autoApplyResort;
  final DateTime Function() clock;
  late final PersonalRuleStore _personalRules = PersonalRuleStore(_state);
  late final RuleEngine _engine = PersonalRuleEngine(
    store: _personalRules,
    instruments: InstrumentStore(financial.database.db, namespace: namespace),
  );
  String _revision(String shared) =>
      '$shared:personal:${_personalRules.revision}';
  LegacyReplay migration(RuleBundle bundle) => LegacyReplay(
    financial: financial,
    namespace: namespace,
    bundle: bundle,
    appVersion: appVersion,
    catalogue: catalogue,
    categoryIdBySlug: categoryIdBySlug,
    accountIsCurrent: accountIsCurrent,
    engine: _engine,
  );
  Future<ReplayReport> migrationDryRun() async =>
      migration(await activeBundle()).dryRun();
  Future<HistoryUpdate> historyUpdate(DateTime from, DateTime to) async {
    _checkAccount();
    return HistoryUpdate(
      financial: financial,
      namespace: namespace,
      bundle: await activeBundle(),
      appVersion: appVersion,
      from: from,
      to: to,
      accountIsCurrent: accountIsCurrent,
      categoryIdBySlug: categoryIdBySlug,
      catalogue: catalogue,
      engine: _engine,
    );
  }

  late final _state = SyncStateStore(
    financial.database.db,
    namespace: namespace,
  );
  // Lane N: aggregate counters only, and only with the sharing consent.
  late final _metrics = ClientMetrics(
    state: _state,
    hasConsent: hasSharingConsent,
    clock: clock,
  );
  late final _bundles = BundleStore(
    financial.database.db,
    verify: verify,
    clock: clock,
  );
  late final _upload = FactsUpload(
    queue: OutboxStore(financial.database.db, namespace: namespace),
    client: client,
    baseUri: baseUri,
    deviceId: deviceId,
    appVersion: appVersion,
    headers: headers,
    clock: clock,
    accountIsCurrent: accountIsCurrent,
  );
  String? _shipped;
  RuleBundle? _bundle;
  Future<void>? _running;

  void _checkAccount() {
    if (!accountIsCurrent()) throw StateError('SMS account changed');
  }

  Future<RuleBundle> _loadBundle() async {
    final shipped = _shipped ??= await loadShippedBundle();
    _checkAccount();
    return _bundle ??= await _bundles.load(shippedJson: shipped);
  }

  Future<RuleBundle> activeBundle() async =>
      ProvisionalStore(_state).overlay(await _loadBundle()).bundle;

  static int _captureSessions = 0;

  /// In-memory databases (every test) and the fallback run capture
  /// synchronously on this isolate; a file-backed database captures in the
  /// shared worker isolate with its own connection (R1, R9).
  late final CaptureExecutor _executor = captureExecutor ?? _defaultExecutor();

  CaptureExecutor _defaultExecutor() {
    final inProcess = InProcessCaptureExecutor(
      financial: financial,
      namespace: namespace,
      engine: _engine,
      personalRules: _personalRules,
    );
    if (financial.database.filePath == null) return inProcess;
    return FallbackCaptureExecutor(
      primary: PooledCaptureExecutor(financial.database),
      fallback: inProcess,
    );
  }

  /// Captures [messages] in chunks of 200. Returns normally only when every
  /// chunk was captured, processed and acknowledged; any error leaves the
  /// failed chunk's messages pending in `sms_intake` for the next sync.
  Future<void> capture(List<QueuedSms> messages, {bool? backfill}) async {
    final shared = await _loadBundle();
    final instrumentStore = InstrumentStore(
      financial.database.db,
      namespace: namespace,
    );
    final seeded = InstrumentSeeder(instrumentStore).seed(
      cards: financial
          .entities(namespace, 'cards')
          .map(UserCard.fromJson)
          .toList(),
      issuerSlugOf: cardIssuerSlugFromCatalogue(catalogue),
      bankAccounts: const [],
    );
    _relinkCardTransactions(seeded.linked);
    final session = ++_captureSessions;
    for (var start = 0; start < messages.length; start += 200) {
      _checkAccount();
      final chunk = messages.sublist(
        start,
        (start + 200).clamp(0, messages.length),
      );
      final historyBefore = clock().subtract(const Duration(days: 1));
      final groups = [
        for (final history in [true, false])
          CaptureGroup(
            backfill: history,
            messages: [
              for (final message in chunk)
                if ((backfill ?? message.receivedAt.isBefore(historyBefore)) ==
                    history)
                  message,
            ],
          ),
      ];
      await _executor.run(
        CaptureChunkRequest(
          namespace: namespace,
          appVersion: appVersion,
          categoryIdBySlug: categoryIdBySlug,
          session: session,
          shared: shared,
          groups: groups,
          ownerNames: ownerNames(),
          onCommitted: (entities) =>
              financial.notifyExternalChanges(namespace, entities),
        ),
      );
    }
    _markFamilyPayees();
    // A history import marked the saved subscription rows dirty instead of
    // re-deriving them per chunk. Tell the readers once, now that it is over.
    if (SubscriptionStore(financial.database.db, namespace: namespace)
        .isDirty) {
      financial.notifyExternalChanges(namespace, const ['subscriptions']);
    }
  }

  /// Writes the wallet card onto the transactions saved before their card was
  /// linked: the cards linked by this run's seeding, and once per account every
  /// card an older build linked without doing so. Never stops a message from
  /// being captured; a failure is retried by the next capture (the one-time
  /// pass only records itself when it finished).
  void _relinkCardTransactions(List<Instrument> linked) {
    try {
      final relinker = CardTransactionRelinker(financial, namespace: namespace);
      relinker.relinkAll(linked);
      relinker.repairOnce();
    } catch (_) {}
  }

  /// Marks as family the person payees whose names strongly look like the
  /// owner's family ([OwnerIdentityStore.autoFamily]), then asks the next sync
  /// to read their earlier payments again. Reads only the facts since the last
  /// pass (a week's overlap for late messages); does nothing with no owner name.
  void _markFamilyPayees() {
    try {
      if (!ownerNames().any((e) => !e.contains(':'))) return;
      final db = financial.database.db;
      final from = (DateTime.tryParse(_state.get('family:scanned') ?? '') ??
              DateTime.utc(1900))
          .subtract(const Duration(days: 7));
      final moves = FactStore(db, namespace: namespace).movementsSince(from);
      if (moves.isEmpty) return;
      _state.put(
        'family:scanned',
        moves.map((m) => m.observedAt).reduce((a, b) => a.isAfter(b) ? a : b)
            .toUtc()
            .toIso8601String(),
      );
      final names = {
        for (final m in moves)
          if (m.counterparty?.kind == CounterpartyKind.person &&
              m.counterparty?.name != null)
            m.counterparty!.name!,
      };
      final marked = OwnerIdentityStore(db, namespace: namespace).autoFamily(
        names,
        profileName: financial.database.profileDisplayName(namespace),
      );
      if (marked > 0) requestOwnerRecheck();
    } catch (_) {
      // A guess about family never stops a message from being captured.
    }
  }

  /// The shared rules are asked for at most once every [_rulesCheckEvery]
  /// unless the server says a newer set exists, or [force] is set (the person
  /// pressed "Refresh rules").
  static const _rulesCheckEvery = Duration(hours: 6);

  Future<void> _refreshRules({bool force = false}) async {
    final previous = DateTime.tryParse(_state.get('rules:last-check') ?? '');
    if (!force &&
        previous != null &&
        clock().difference(previous) < _rulesCheckEvery) {
      return;
    }
    // The server asked every client to wait: do not add a request to the pile.
    if (!force && ServerBackoff.process.isPaused) return;
    final current = await _loadBundle();
    _checkAccount();
    final response = await client
        .get(
          baseUri
              .resolve('/sms/v2/rules')
              .replace(
                queryParameters: {
                  'since':
                      current.expiresAt.isBefore(
                        clock().add(const Duration(days: 1)),
                      )
                      ? '0'
                      : '${current.bundleVersion}',
                },
              ),
          headers: await headers(),
        )
        .timeout(const Duration(seconds: 30));
    _checkAccount();
    if (response.statusCode == 429) {
      // A read limit is per endpoint (it said how long, often half an hour):
      // ask again after that, not on every sync.
      final wait =
          ServerBackoff.parseRetryAfter(
            response.headers['retry-after'],
            clock(),
          ) ??
          const Duration(minutes: 15);
      final shift = _rulesCheckEvery - wait;
      _state.put(
        'rules:last-check',
        clock().subtract(shift.isNegative ? Duration.zero : shift)
            .toUtc()
            .toIso8601String(),
      );
    }
    if (response.statusCode != 200 && response.statusCode != 304) {
      await _metrics.bundleDownloadFailed();
      _state.put(
        'rules:stale',
        response.statusCode == 403
            ? 'entitlement_or_attestation'
            : 'download_failed',
      );
      return;
    }
    _state.put('rules:stale', '');
    if (response.statusCode == 200) {
      // HTTP may return gzip to clients that do not decompress automatically.
      final bytes = response.bodyBytes;
      final raw = bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b
          ? utf8.decode(gzip.decode(bytes))
          : utf8.decode(bytes);
      if (await _bundles.install(raw)) {
        _bundle = await _bundles.load(shippedJson: _shipped!);
      }
    }
    _state.put('rules:last-check', clock().toUtc().toIso8601String());
  }

  /// True while a sync / migration pass is in flight. Read by the
  /// notification sweep so it never announces a half-finished import.
  bool get isBusy => _running != null;

  /// Messages captured on the phone but not yet read through the pipeline.
  int get pendingIntake =>
      SmsIntakeRepository(financial.database).counts(namespace).pending;

  Future<void> sync() {
    final running = _running;
    if (running != null) return running;
    late final Future<void> operation;
    operation = _syncAndReport().whenComplete(() {
      if (identical(_running, operation)) _running = null;
    });
    return _running = operation;
  }

  /// Makes every upload that was waiting out a back-off due again. Called when
  /// the connection returns: the waits were set while the phone had no network
  /// and say nothing about the server (Q-08).
  void resetUploadBackoff() {
    OutboxStore(financial.database.db, namespace: namespace).resetBackoff();
  }

  Future<void> _syncAndReport() async {
    try {
      await _metrics.measureSync(_sync);
    } finally {
      if (!isOffline()) {
        await _metrics.upload(
          client: client,
          baseUri: baseUri,
          headers: headers,
          appVersion: appVersion,
          accountIsCurrent: accountIsCurrent,
        );
      }
    }
  }

  /// Writes the shop and rule keys of facts stored before those columns
  /// existed, a little on each pass so no pass is held up: at most about a
  /// fifth of a second, 500 facts at a time.
  void _keyFacts() {
    final db = financial.database.db;
    final watch = Stopwatch()..start();
    try {
      while (watch.elapsedMilliseconds < 200 &&
          FactKeys.backfill(db, namespace) > 0) {}
    } catch (_) {
      // The keys only speed up "similar transactions"; sync never waits on them.
    }
  }

  Future<void> _applyCardState() async {
    final repository = cardRepository;
    if (repository == null) return;
    final cards = {
      for (final json in financial.entities(namespace, 'cards'))
        (json['id'] as String): UserCard.fromJson(json),
    };
    final instruments = InstrumentStore(
      financial.database.db,
      namespace: namespace,
    ).list();
    for (final instrument in instruments) {
      if (!accountIsCurrent()) return;
      final current = cards[instrument.userCardId];
      if (current == null) continue;
      final key = 'card:last-applied:${current.id}';
      final raw = _state.get(key);
      final previous = raw == null
          ? null
          : Instrument.fromJson(
              (jsonDecode(raw) as Map).cast<String, Object?>(),
            );
      try {
        if (await CardStateAdapter(
          repository,
          commands: CommandOutbox(financial.database, namespace: namespace),
          store: financial,
          namespace: namespace,
        ).apply(instrument, current, lastApplied: previous)) {
          _checkAccount();
          _state.put(key, jsonEncode(instrument.toJson()));
        }
      } catch (_) {
        // The next foreground pass retries learned card state independently.
      }
    }
  }

  Future<void> _sync() async {
    _checkAccount();
    await _loadBundle();
    // Reading the messages already on the phone comes first and never waits on
    // the network: the rules refresh and the request headers (App Check) can
    // take as long as the platform needs to give up on a dead connection.
    final intake = SmsIntakeRepository(financial.database);
    Set<String>? previousBatch;
    while (accountIsCurrent()) {
      final pending = intake.pending(namespace, limit: 200);
      if (pending.isEmpty) break;
      // A pass that leaves the very same messages pending can never finish
      // them; stop and retry on the next sync instead of spinning on the UI
      // thread.
      final batch = {for (final entry in pending) entry.id};
      if (previousBatch != null &&
          previousBatch.length == batch.length &&
          previousBatch.containsAll(batch)) {
        break;
      }
      previousBatch = batch;
      for (final entry in pending) {
        if (classifySmsTriage(entry.message.sender, entry.message.body).kind ==
            SmsTriageKind.sensitive) {
          intake.forgetRaw(namespace, entry.id);
        }
      }
      await capture(pending.map((entry) => entry.message).toList());
    }
    if (accountIsCurrent()) {
      // Every captured message is processed: now ask about receipts that never
      // got a funding debit (current month only; older ones are skipped).
      try {
        ReceiptReviews(
          financial: financial,
          namespace: namespace,
          bundle: await activeBundle(),
          clock: clock,
          categoryIdBySlug: categoryIdBySlug,
        ).sweep();
      } catch (_) {
        // The next sync pass retries; a failed question never blocks sync.
      }
    }
    Object? firstError;
    StackTrace? firstStack;
    // One step failing (a refused upload, no connection) must not stop the
    // ones after it: fetching the rules and re-sorting are mostly local work.
    // The first failure is still raised at the end, so it is counted and the
    // next pass tries again.
    Future<void> guarded(Future<void> Function() step) async {
      try {
        await step();
      } catch (error, stack) {
        if (!accountIsCurrent()) rethrow;
        firstError ??= error;
        firstStack ??= stack;
      }
    }

    // The steps below that talk to the server are skipped while the phone
    // knows it has no connection; nothing is lost, they run on the next pass.
    Future<void> networked(Future<void> Function() step) async {
      if (isOffline()) return;
      await guarded(step);
    }

    if (!isOffline()) {
      try {
        await _refreshRules();
      } catch (_) {
        /* Retain the verified cache. */
        await _metrics.bundleDownloadFailed();
      }
      _checkAccount();
      await _applyCardState();
    }
    _keyFacts();
    await networked(() => _upload.drain());
    final senders = (await activeBundle()).senders;
    final correctionQueue = OutboxStore(
      financial.database.db,
      namespace: namespace,
    );
    await networked(
      () => CorrectionsSync(
        queue: correctionQueue,
        client: client,
        baseUri: baseUri,
        headers: headers,
        accountIsCurrent: accountIsCurrent,
        // Consent is re-read at send time; the mirror is cleared by every
        // server answer that is not a grant and by a withdrawal.
        sharingGranted: () => SmsSharedLearningConsentMirror.isGranted(namespace),
        requeue: (sourceKey, eventId) => requeueForUpload(
          queue: correctionQueue,
          intake: intake,
          sourceKey: sourceKey,
          eventId: eventId,
          brandOf: (sender) => uploadBrandOfSender(sender, senders),
        ),
        clock: clock,
      ).drain(),
    );
    await networked(
      () => TemplateUpload(
        intake: intake,
        queue: OutboxStore(financial.database.db, namespace: namespace),
        client: client,
        baseUri: baseUri,
        headers: headers,
        hasConsent: hasSharingConsent,
        accountIsCurrent: accountIsCurrent,
        clock: clock,
      ).drain(),
    );
    await networked(
      () => LearningSignalUpload(
        intake: intake,
        queue: OutboxStore(financial.database.db, namespace: namespace),
        client: client,
        baseUri: baseUri,
        headers: headers,
        hasConsent: hasSharingConsent,
        accountIsCurrent: accountIsCurrent,
        taxonomyVersion: () => _bundle!.taxonomyVersion,
        clock: clock,
      ).drain(),
    );
    await networked(
      () =>
          StatsUpload(
            stats: StatsStore(financial.database.db, namespace: namespace),
            state: _state,
            client: client,
            baseUri: baseUri,
            headers: headers,
            accountIsCurrent: accountIsCurrent,
          ).send(
            clock(),
            appVersion: appVersion,
            bundleVersion: _bundle!.bundleVersion,
          ),
    );
    _checkAccount();
    await networked(
      () => SyncPull(
        financial: financial,
        namespace: namespace,
        client: client,
        baseUri: baseUri,
        headers: headers,
        bundle: _bundle!,
        categoryIdBySlug: categoryIdBySlug,
        accountIsCurrent: accountIsCurrent,
      ).pull(),
    );
    await networked(() async {
      final available = int.tryParse(_state.get('rules:latest') ?? '') ?? 0;
      if (available > _bundle!.bundleVersion) {
        _state.put('rules:last-check', DateTime.utc(1970).toIso8601String());
        await _refreshRules();
      }
    });
    await guarded(_withdrawRejectedAiReadings);
    await guarded(_recheckIfRequested);
    final active = ProvisionalStore(_state).overlay(_bundle!);
    final previousRevision = _state.get('pipeline:revision');
    if (previousRevision != _revision(active.revision)) {
      await guarded(() async {
        await _rereadUnknown();
        _state.put('pipeline:revision', _revision(active.revision));
      });
    }
    final salaryMarker = '${_revision(active.revision)}:salary-payer-1';
    if (_state.get('salary:payer-recheck') != salaryMarker) {
      await guarded(() async {
        await _rereadPayerlessSalary();
        _state.put('salary:payer-recheck', salaryMarker);
      });
    }
    // The same for a spend read by a fallback rule that a newer rule can now
    // name ("Unknown merchant"). Its own marker, for the same reason.
    final payeeMarker = '${_revision(active.revision)}:payee-1';
    if (_state.get('payee:recheck') != payeeMarker) {
      await guarded(() async {
        await _rereadPayerless(payeeless: true);
        _state.put('payee:recheck', payeeMarker);
      });
    }
    // A person asked to see what a re-sort would move before it moves
    // anything, so ordinary sync leaves categories alone. The refresh sheet
    // shows the preview and applies it on a tap. [autoApplyResort] set to true
    // has each new rule set re-sort spends on its own again.
    if (autoApplyResort) {
      await guarded(() => _refreshAutomaticCategories());
    }
    final failure = firstError;
    if (failure != null) Error.throwWithStackTrace(failure, firstStack!);
  }

  /// Reads every message still marked "unknown" again with the rules now in
  /// force, 200 at a time. Returns how many were read again.
  Future<int> _rereadUnknown() async {
    final intake = SmsIntakeRepository(financial.database);
    final unknown = financial.database.db.select(
      "SELECT DISTINCT source_key FROM ("
      "SELECT source_key FROM sms_source_decisions WHERE namespace=? AND policy_version='v2' AND decision='unknown' "
      "UNION "
      "SELECT json_extract(payload, '\$.sourceKey') AS source_key FROM v2_review_items WHERE namespace=? AND kind='template' AND status='open'"
      ") WHERE source_key IS NOT NULL",
      [namespace, namespace],
    );
    var read = 0;
    for (var offset = 0; offset < unknown.length; offset += 200) {
      _checkAccount();
      final rows = unknown.skip(offset).take(200);
      final messages = <QueuedSms>[
        for (final row in rows)
          if (intake.capturedById(namespace, row['source_key'] as String)
              case final entry?)
            entry.message,
      ];
      if (messages.isNotEmpty) {
        await capture(messages, backfill: true);
        read += messages.length;
      }
    }
    return read;
  }

  Future<int> _rereadPayerlessSalary() => _rereadPayerless(payeeless: false);

  /// [payeeless] reads again spends and transfers that a fallback rule read
  /// without a payee; otherwise the salary credits without an employer.
  Future<int> _rereadPayerless({required bool payeeless}) async {
    _checkAccount();
    final active = await activeBundle();
    final recheck = payeeless
        ? SalaryRecheck.payeeless(
            financial: financial,
            namespace: namespace,
            bundle: active,
            categoryIdBySlug: categoryIdBySlug,
          )
        : SalaryRecheck(
            financial: financial,
            namespace: namespace,
            bundle: active,
            categoryIdBySlug: categoryIdBySlug,
          );
    final sources = recheck.sourcesToRecheck();
    if (sources.isEmpty) return 0;
    final intake = SmsIntakeRepository(financial.database);
    final taken = AiWithdrawal(
      financial: financial,
      namespace: namespace,
      bundle: active,
      categoryIdBySlug: categoryIdBySlug,
    ).withdraw(sources);
    final messages = <QueuedSms>[
      for (final source in taken)
        if (intake.capturedById(namespace, source) case final entry?)
          entry.message,
    ];
    if (messages.isNotEmpty) await capture(messages, backfill: true);
    return taken.length;
  }

  /// Asks the next sync to read again the messages whose reading depends on who
  /// the account owner is (their name, or a payee they marked). [revert] also
  /// re-reads own transfers whose name no longer matches (a name was removed).
  void requestOwnerRecheck({bool revert = false}) {
    final pending = _state.get('owner:recheck');
    _state.put('owner:recheck', revert || pending == 'revert' ? 'revert' : '1');
  }

  Future<void> _recheckIfRequested() async {
    final flag = _state.get('owner:recheck');
    if (flag == null || flag.isEmpty) return;
    await _recheckOwnTransfers(revertUnmatched: flag == 'revert');
    _state.put('owner:recheck', '');
  }

  /// Reads again every earlier message whose reading changes with the owner's
  /// identity, now. Serialized with sync. Returns how many messages were read
  /// again.
  Future<int> recheckOwnTransfers({bool revertUnmatched = false}) async {
    final running = _running;
    if (running != null) {
      try {
        await running;
      } catch (_) {}
    }
    final done = Completer<void>();
    final marker = done.future;
    _running = marker;
    try {
      final n = await _recheckOwnTransfers(revertUnmatched: revertUnmatched);
      _state.put('owner:recheck', '');
      return n;
    } finally {
      done.complete();
      if (identical(_running, marker)) _running = null;
    }
  }

  Future<int> _recheckOwnTransfers({required bool revertUnmatched}) async {
    _checkAccount();
    final active = await activeBundle();
    final identity = OwnerIdentity.fromEntries(ownerNames());
    final sources = OwnerRecheck(
      financial: financial,
      namespace: namespace,
      bundle: active,
      categoryIdBySlug: categoryIdBySlug,
    ).sourcesToRecheck(identity, revertUnmatched: revertUnmatched);
    if (sources.isEmpty) return 0;
    final intake = SmsIntakeRepository(financial.database);
    final taken = AiWithdrawal(
      financial: financial,
      namespace: namespace,
      bundle: active,
      categoryIdBySlug: categoryIdBySlug,
    ).withdraw(sources);
    final messages = <QueuedSms>[
      for (final source in taken)
        if (intake.capturedById(namespace, source) case final entry?)
          entry.message,
    ];
    if (messages.isNotEmpty) await capture(messages, backfill: true);
    return taken.length;
  }

  /// Once the server says a layout's AI rule was rejected (or could not be
  /// made), what that rule read leaves the ledger and the messages are read
  /// again without it, so they return to a plain Needs review item.
  Future<void> _withdrawRejectedAiReadings() async {
    final withdrawal = AiWithdrawal(
      financial: financial,
      namespace: namespace,
      bundle: _bundle!,
      categoryIdBySlug: categoryIdBySlug,
    );
    final sources = <String>[
      for (final hash in withdrawal.rejectedTemplates())
        ...withdrawal.sourcesRead(hash),
    ];
    if (sources.isEmpty) return;
    _checkAccount();
    withdrawal.withdraw(sources);
    final intake = SmsIntakeRepository(financial.database);
    final messages = <QueuedSms>[
      for (final source in sources)
        if (intake.capturedById(namespace, source) case final entry?)
          entry.message,
    ];
    if (messages.isNotEmpty) await capture(messages, backfill: true);
  }

  static String _categoryRevision(RuleBundle shared) => sha256
      .convert(
        utf8.encode(
          canonicalJson({
            'categoryRules': [
              for (final rule in shared.categoryRules) rule.toJson(),
            ],
            'merchantAliases': [
              for (final alias in shared.merchantAliases) alias.toJson(),
            ],
            'taxonomy': shared.taxonomyVersion,
          }),
        ),
      )
      .toString();

  /// What a re-sort would do, worked out on a copy: nothing on the phone
  /// changes. Spends still waiting to be sent are not touched either way.
  Future<HistoryCategoryReport> _previewAutomaticCategories() async {
    final shared = _bundle;
    if (shared == null) throw StateError('No rules loaded');
    return HistoryCategoryRecheck.automaticChoices(
      financial: financial,
      namespace: namespace,
      bundle: shared,
      accountIsCurrent: accountIsCurrent,
      categoryIdBySlug: categoryIdBySlug,
      now: clock(),
    ).preview(restart: true);
  }

  /// The tap on "Apply" in the refresh sheet: puts rule-chosen spends in their
  /// new category on this phone, then tells the account. A spend the person set
  /// or confirmed is never touched.
  Future<RulesRefreshReport> applyResort() async {
    final running = _running;
    if (running != null) {
      try {
        await running;
      } catch (_) {}
    }
    final done = Completer<void>();
    final marker = done.future;
    _running = marker;
    try {
      _checkAccount();
      await _loadBundle();
      String? resortProblem;
      var report = const HistoryCategoryReport({
        'changed': 0,
        'preservedUser': 0,
        'awaitingSync': 0,
        'processed': 0,
        'total': 0,
      });
      try {
        report = await _refreshAutomaticCategories(force: true) ?? report;
      } catch (error) {
        _checkAccount();
        resortProblem = RulesRefreshReport.resortProblemFor(
          HistoryCategoryRecheck.failureReason(error),
        );
      }
      String? sendProblem;
      try {
        await _upload.drain(settleRefused: true);
      } catch (_) {
        _checkAccount();
        sendProblem = RulesRefreshReport.sendProblemText;
      }
      return RulesRefreshReport(
        versionBefore: _bundle!.bundleVersion,
        versionAfter: _bundle!.bundleVersion,
        ruleCount: _bundle!.rules.length,
        sendProblem: sendProblem,
        resorted: report.changed,
        keptYours: report.preservedUser,
        waitingToSend: report.awaitingSync,
        resortSkipped: report.failed,
        resortSkippedWhy: report.failedWhy,
        refusedForGood:
            int.tryParse(_state.get(FactsUpload.refusedKey) ?? '') ?? 0,
        refusedWhy: _refusedWhy(),
        resortProblem: resortProblem,
        applied: true,
        finishedAt: clock(),
      );
    } finally {
      done.complete();
      if (identical(_running, marker)) _running = null;
    }
  }

  /// Once, on the build that learned to find the record the server cannot
  /// take: sends again the messages the server never accepted (their facts are
  /// not marked as received and nothing is waiting to send them), with the
  /// spend built on them. Anything it still cannot take is set aside again,
  /// this time with the reason written down. Returns how many it queued.
  int _resendSetAside() {
    const marker = 'upload:resent-set-aside-v1';
    if (_state.get(marker) != null) return 0;
    final db = financial.database.db;
    final sources = [
      for (final row in db.select(
        "SELECT DISTINCT source_key FROM v2_facts WHERE namespace=? AND uploaded_at IS NULL AND fact_type!='info' "
        "AND source_key NOT IN (SELECT substr(id,8) FROM v2_outbox WHERE namespace=? AND kind='source') LIMIT 2000",
        [namespace, namespace],
      ))
        row['source_key'] as String,
    ];
    final queue = OutboxStore(db, namespace: namespace);
    final intake = SmsIntakeRepository(financial.database);
    final facts = FactStore(db, namespace: namespace);
    final events = EventStore(db, namespace: namespace);
    var queued = 0;
    for (final source in sources) {
      _checkAccount();
      final linked = events.findByFactIds([
        for (final fact in facts.forSource(source)) fact.factId,
      ]);
      for (final eventId in linked.isEmpty
          ? <String?>[null]
          : [for (final event in linked) event.eventId]) {
        queued += requeueForUpload(
          queue: queue,
          intake: intake,
          sourceKey: source,
          eventId: eventId,
          brandOf: (sender) => uploadBrandOfSender(sender, _bundle?.senders ?? const []),
        );
      }
    }
    _state.put(marker, clock().toUtc().toIso8601String());
    return queued;
  }

  Map<String, int> _refusedWhy() {
    try {
      return {
        for (final entry
            in (jsonDecode(_state.get(FactsUpload.refusedReasonsKey) ?? '{}')
                    as Map)
                .entries)
          '${entry.key}': (entry.value as num).toInt(),
      };
    } catch (_) {
      return const {};
    }
  }

  /// A new shared rule set can categorise shops that earlier sat in "Other".
  /// Once per rule-set revision, spends whose category the rules chose are
  /// worked out again; a category the person set or confirmed is never touched.
  /// [force] (the "Refresh rules" button) looks at every such spend again even
  /// when this rule set was already applied. Returns null when there was
  /// nothing to do.
  Future<HistoryCategoryReport?> _refreshAutomaticCategories({
    bool force = false,
  }) async {
    final shared = _bundle;
    if (shared == null || !accountIsCurrent()) return null;
    final revision = _categoryRevision(shared);
    if (!force && _state.get('pipeline:category-revision') == revision) {
      return null;
    }
    try {
      final report = await HistoryCategoryRecheck.automaticChoices(
        financial: financial,
        namespace: namespace,
        bundle: shared,
        accountIsCurrent: accountIsCurrent,
        categoryIdBySlug: categoryIdBySlug,
        now: clock(),
      ).run(chunkSize: 50, shouldContinue: accountIsCurrent, restart: force);
      // Money still waiting for the server, or a spend that could not be looked
      // at, is picked up on a later pass.
      if (report.complete && report.awaitingSync == 0 && report.failed == 0) {
        _state.put('pipeline:category-revision', revision);
      }
      return report;
    } catch (error) {
      if (force) rethrow;
      // A failed pass never blocks sync; the next sync tries again.
      return null;
    }
  }

  /// The "Refresh rules" button: gets the newest shared rules now (ignoring
  /// the six-hour wait), sends what is waiting, reads unrecognised messages
  /// again and puts rule-chosen spends in their right category. It never stops
  /// at the first problem, and says what happened in words.
  Future<RulesRefreshReport> refreshRulesAndReanalyze() async {
    final running = _running;
    if (running != null) {
      try {
        await running;
      } catch (_) {}
    }
    final done = Completer<void>();
    final marker = done.future;
    _running = marker;
    try {
      return await _refreshNow();
    } finally {
      done.complete();
      if (identical(_running, marker)) _running = null;
    }
  }

  Future<RulesRefreshReport> _refreshNow() async {
    _checkAccount();
    await _loadBundle();
    final before = _bundle!.bundleVersion;
    String? rulesProblem, sendProblem, rereadProblem, resortProblem;

    // 1. The newest shared rules, right now.
    try {
      await _refreshRules(force: true);
      final stale = _state.get('rules:stale') ?? '';
      if (stale.isNotEmpty) {
        rulesProblem = RulesRefreshReport.rulesProblemFor(stale);
      }
    } catch (_) {
      _checkAccount();
      rulesProblem = RulesRefreshReport.rulesProblemFor(null);
    }
    _checkAccount();

    // 2. Send what is waiting, so nothing blocks the re-sort below.
    Future<void> send() async {
      try {
        await _upload.drain(settleRefused: true);
      } catch (_) {
        _checkAccount();
        sendProblem = RulesRefreshReport.sendProblemText;
      }
    }

    try {
      _resendSetAside();
    } catch (_) {
      _checkAccount();
    }
    await send();

    // 3. Messages that were not recognised, with the rules now in force.
    var reread = 0;
    var rereadSkipped = false;
    try {
      final active = ProvisionalStore(_state).overlay(_bundle!);
      if (_state.get('pipeline:revision') == _revision(active.revision)) {
        // Same rules as the last read: reading again would find nothing new.
        rereadSkipped = true;
      } else {
        reread = await _rereadUnknown();
        _state.put('pipeline:revision', _revision(active.revision));
      }
    } catch (_) {
      _checkAccount();
      rereadProblem =
          'Could not read the earlier messages again. They are unchanged.';
    }
    SmsIntakeRepository(financial.database); // makes sure its tables exist
    final stillUnknown =
        financial.database.db.select(
              "SELECT count(*) AS n FROM sms_source_decisions WHERE namespace=? AND policy_version='v2' AND decision='unknown'",
              [namespace],
            ).first['n']
            as int;

    // 4. Rule-chosen categories, every one looked at again on this phone, on a
    // copy. Nothing moves until the person taps Apply in the sheet.
    var report = const HistoryCategoryReport({
      'changed': 0,
      'preservedUser': 0,
      'awaitingSync': 0,
      'processed': 0,
      'total': 0,
    });
    // This rule set was already applied (or had nothing to move): skip the look.
    final categoryRevision = _categoryRevision(_bundle!);
    final alreadySorted =
        _state.get('pipeline:category-revision') == categoryRevision;
    try {
      if (!alreadySorted) {
        report = await _previewAutomaticCategories();
        if (report.awaitingSync > 0) {
          await send();
          report = await _previewAutomaticCategories();
        }
        if (report.complete &&
            report.changed == 0 &&
            report.awaitingSync == 0 &&
            report.failed == 0) {
          _state.put('pipeline:category-revision', categoryRevision);
        }
      }
    } catch (error) {
      _checkAccount();
      resortProblem = RulesRefreshReport.resortProblemFor(
        HistoryCategoryRecheck.failureReason(error),
      );
    }

    // 5. Tell the account about the new categories.
    await send();
    _state.put('rules:last-refresh', clock().toUtc().toIso8601String());
    return RulesRefreshReport(
      versionBefore: before,
      versionAfter: _bundle!.bundleVersion,
      ruleCount: _bundle!.rules.length,
      rulesProblem: rulesProblem,
      sendProblem: sendProblem,
      rereadMessages: reread,
      stillUnrecognised: stillUnknown,
      rereadProblem: rereadProblem,
      resortWouldMove: report.changed,
      keptYours: report.preservedUser,
      waitingToSend: report.awaitingSync,
      resortSkipped: report.failed,
      resortSkippedWhy: report.failedWhy,
      refusedForGood:
          int.tryParse(_state.get(FactsUpload.refusedKey) ?? '') ?? 0,
      refusedWhy: _refusedWhy(),
      resortProblem: resortProblem,
      upToDate:
          alreadySorted &&
          rereadSkipped &&
          before == _bundle!.bundleVersion &&
          rulesProblem == null &&
          resortProblem == null,
      finishedAt: clock(),
    );
  }
}
