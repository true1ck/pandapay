import '../personal/personal_rule_engine.dart';
import '../personal/personal_rule_store.dart';
import '../migration/legacy_replay.dart';
import '../migration/history_update.dart';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/pandapay_domain.dart' show CardProduct;

import '../../../data/local/financial_store.dart';
import '../../../data/local/sms_import_store.dart';
import '../../../data/user_cards_repository.dart';
import '../instruments/instrument_seeder.dart';
import '../storage/instrument_store.dart';
import '../ledger/card_state_adapter.dart';
import '../../../data/local/sms_intake_repository.dart';
import '../../sms_import/sms_background_queue.dart';
import '../../sms_import/sms_text_hint.dart';
import '../category/category_snapshot.dart';
import '../storage/bundle_store.dart';
import '../storage/outbox_store.dart';
import '../storage/schema.dart';
import '../storage/sync_state_store.dart';
import '../storage/provisional_store.dart';
import '../storage/stats_store.dart';
import '../sync/template_upload.dart';
import '../sync/stats_upload.dart';
import '../telemetry/client_metrics.dart';
import '../sync/corrections_sync.dart';
import '../sync/facts_upload.dart';
import '../sync/sync_pull.dart';
import 'sms_v2_pipeline.dart';

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
    required this.headers,
    required this.verify,
    required this.loadShippedBundle,
    required this.accountIsCurrent,
    this.hasSharingConsent = _noConsent,
    this.catalogue = const [],
    this.cardRepository,

    this.categoryIdBySlug = const {},
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now {
    SmsV2Schema.ensure(financial.database.db);
  }

  static Future<bool> _noConsent() async => false;
  final Future<bool> Function() hasSharingConsent;
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
  final Map<String, String> categoryIdBySlug;
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

  Future<void> capture(List<QueuedSms> messages, {bool? backfill}) async {
    final shared = await _loadBundle();
    final overlay = ProvisionalStore(_state).overlay(shared);
    final bundle = overlay.bundle;
    final instrumentStore = InstrumentStore(
      financial.database.db,
      namespace: namespace,
    );
    InstrumentSeeder(instrumentStore).seed(
      cards: financial
          .entities(namespace, 'cards')
          .map(UserCard.fromJson)
          .toList(),
      issuerSlugOf: cardIssuerSlugFromCatalogue(catalogue),
      bankAccounts: const [],
    );
    for (var start = 0; start < messages.length; start += 200) {
      _checkAccount();
      final chunk = messages.sublist(
        start,
        (start + 200).clamp(0, messages.length),
      );
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
        engine: _engine,
        revision: _revision(overlay.revision),
      );
      for (final history in [true, false]) {
        final selected = chunk
            .where(
              (message) =>
                  (backfill ??
                      message.receivedAt.isBefore(
                        clock().subtract(const Duration(days: 1)),
                      )) ==
                  history,
            )
            .toList();
        if (selected.isEmpty) continue;
        SmsImportStore(
          financial,
          v2Pipeline: pipeline,
          v2Backfill: history,
        ).captureBatch(namespace, selected);
      }
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> _refreshRules() async {
    final previous = DateTime.tryParse(_state.get('rules:last-check') ?? '');
    if (previous != null &&
        clock().difference(previous) < const Duration(hours: 6)) {
      return;
    }
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

  Future<void> sync() {
    final running = _running;
    if (running != null) return running;
    late final Future<void> operation;
    operation = _syncAndReport().whenComplete(() {
      if (identical(_running, operation)) _running = null;
    });
    return _running = operation;
  }

  Future<void> _syncAndReport() async {
    try {
      await _metrics.measureSync(_sync);
    } finally {
      await _metrics.upload(
        client: client,
        baseUri: baseUri,
        headers: headers,
        appVersion: appVersion,
        accountIsCurrent: accountIsCurrent,
      );
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
    try {
      await _refreshRules();
    } catch (_) {
      /* Retain the verified cache. */
      await _metrics.bundleDownloadFailed();
    }
    _checkAccount();
    final replay = migration(await activeBundle());
    if (_bundle!.rules.isNotEmpty &&
        replay.hasLegacyHistory &&
        replay.savedReport() == null) {
      await _metrics.measureMigration(() => replay.run());
    }
    _checkAccount();
    final intake = SmsIntakeRepository(financial.database);
    while (accountIsCurrent()) {
      final pending = intake.pending(namespace, limit: 200);
      if (pending.isEmpty) break;
      for (final entry in pending) {
        if (classifySmsTriage(entry.message.sender, entry.message.body).kind ==
            SmsTriageKind.sensitive) {
          intake.forgetRaw(namespace, entry.id);
        }
      }
      await capture(pending.map((entry) => entry.message).toList());
    }
    await _applyCardState();
    await _upload.drain();
    await CorrectionsSync(
      queue: OutboxStore(financial.database.db, namespace: namespace),
      client: client,
      baseUri: baseUri,
      headers: headers,
      accountIsCurrent: accountIsCurrent,
      clock: clock,
    ).drain();
    await TemplateUpload(
      intake: intake,
      queue: OutboxStore(financial.database.db, namespace: namespace),
      client: client,
      baseUri: baseUri,
      headers: headers,
      hasConsent: hasSharingConsent,
      accountIsCurrent: accountIsCurrent,
      clock: clock,
    ).drain();
    await StatsUpload(
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
    );
    _checkAccount();
    await SyncPull(
      financial: financial,
      namespace: namespace,
      client: client,
      baseUri: baseUri,
      headers: headers,
      bundle: _bundle!,
      categoryIdBySlug: categoryIdBySlug,
      accountIsCurrent: accountIsCurrent,
    ).pull();
    final available = int.tryParse(_state.get('rules:latest') ?? '') ?? 0;
    if (available > _bundle!.bundleVersion) {
      _state.put('rules:last-check', DateTime.utc(1970).toIso8601String());
      await _refreshRules();
    }
    final active = ProvisionalStore(_state).overlay(_bundle!);
    final previousRevision = _state.get('pipeline:revision');
    if (previousRevision != _revision(active.revision)) {
      final unknown = financial.database.db.select(
        "SELECT source_key FROM sms_source_decisions WHERE namespace=? AND policy_version='v2' AND decision='unknown'",
        [namespace],
      );
      for (var offset = 0; offset < unknown.length; offset += 200) {
        _checkAccount();
        final rows = unknown.skip(offset).take(200);
        final messages = <QueuedSms>[
          for (final row in rows)
            if (intake.capturedById(namespace, row['source_key'] as String)
                case final entry?)
              entry.message,
        ];
        if (messages.isNotEmpty) await capture(messages, backfill: true);
      }
      _state.put('pipeline:revision', _revision(active.revision));
    }
  }
}
