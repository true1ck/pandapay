import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:pandapay_domain/sms_v2.dart';

import '../../../data/local/financial_store.dart';
import '../../../data/local/sms_import_store.dart';
import '../../../data/local/sms_intake_repository.dart';
import '../../sms_import/sms_background_queue.dart';
import '../../sms_import/sms_text_hint.dart';
import '../category/category_snapshot.dart';
import '../storage/bundle_store.dart';
import '../storage/outbox_store.dart';
import '../storage/schema.dart';
import '../storage/sync_state_store.dart';
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
    this.categoryIdBySlug = const {},
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now {
    SmsV2Schema.ensure(financial.database.db);
  }

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
  final RuleEngine _engine = RuleEngine();
  late final _state = SyncStateStore(
    financial.database.db,
    namespace: namespace,
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

  Future<void> capture(List<QueuedSms> messages, {bool? backfill}) async {
    final bundle = await _loadBundle();
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
        clock().difference(previous) < const Duration(hours: 6))
      return;
    final current = await _loadBundle();
    _checkAccount();
    final response = await client
        .get(
          baseUri
              .resolve('/sms/v2/rules')
              .replace(queryParameters: {'since': '${current.bundleVersion}'}),
          headers: await headers(),
        )
        .timeout(const Duration(seconds: 30));
    _checkAccount();
    if (response.statusCode != 200 && response.statusCode != 304) return;
    if (response.statusCode == 200) {
      // HTTP may return gzip to clients that do not decompress automatically.
      final raw = response.headers['content-encoding'] == 'gzip'
          ? utf8.decode(gzip.decode(response.bodyBytes))
          : response.body;
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
    operation = _sync().whenComplete(() {
      if (identical(_running, operation)) _running = null;
    });
    return _running = operation;
  }

  Future<void> _sync() async {
    _checkAccount();
    await _loadBundle();
    try {
      await _refreshRules();
    } catch (_) {
      /* Retain the verified cache. */
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
    await _upload.drain();
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
  }
}
