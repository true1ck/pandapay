import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:pandapay_domain/sms_v2.dart' show ContractException;
import 'package:sqlite3/sqlite3.dart' show SqliteException;

import '../storage/sync_state_store.dart';

/// Coarse reason a sync run failed. Never carries an exception message, a URL,
/// a status text or anything else the failure might contain.
enum SyncErrorReason { network, timeout, server, storage, data, other }

/// Aggregate release counters for the go/no-go metrics (Lane N).
///
/// Counts only: sync runs and failures by coarse reason, history-migration
/// started/completed/failed and bundle download failures. No message content,
/// no ids. Counts live in the account's `v2_sync_state` rows (durable across app
/// restarts) under `metrics:d:<UTC day>:<counter>`, and are uploaded in closed-day
/// batches no more than once a day.
///
/// Everything here is off unless the user has given the sharing consent other v2
/// telemetry requires: nothing is counted without it, and counts already stored are
/// deleted when it is found withdrawn. Nothing in this class may ever affect the
/// user: every public method swallows its own failures.
class ClientMetrics {
  ClientMetrics({
    required this.state,
    required this.hasConsent,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final SyncStateStore state;
  final Future<bool> Function() hasConsent;
  final DateTime Function() _clock;

  static const syncAttempts = 'sync_attempts';
  static const migrationStarted = 'migration_started';
  static const migrationCompleted = 'migration_completed';
  static const migrationFailed = 'migration_failed';
  static const bundleDownloadFailures = 'bundle_download_failures';
  static String syncErrorCounter(SyncErrorReason reason) =>
      'sync_errors_${reason.name}';

  /// The only names that are ever stored or sent (the server enforces the same list).
  static final Set<String> counterNames = {
    syncAttempts,
    for (final reason in SyncErrorReason.values) syncErrorCounter(reason),
    migrationStarted,
    migrationCompleted,
    migrationFailed,
    bundleDownloadFailures,
  };

  static const _prefix = 'metrics:d:';
  static const _lastSentKey = 'metrics:last-sent';
  static const _lastTryKey = 'metrics:last-try';
  static const _maxStored = 100000;
  static const _maxSent = 10000;
  static const _maxDaysBack = 7;
  static const _maxDaysPerUpload = 3;
  static const _retryAfterFailure = Duration(hours: 1);
  static const _interval = Duration(hours: 24);

  /// Whether an error is the account-switch fence rather than a real failure.
  static bool _isAccountChange(Object error) =>
      error is StateError && error.message.contains('account changed');

  static SyncErrorReason classify(Object error) {
    if (error is TimeoutException) return SyncErrorReason.timeout;
    if (error is SocketException ||
        error is http.ClientException ||
        error is TlsException) {
      return SyncErrorReason.network;
    }
    if (error is HttpException) return SyncErrorReason.server;
    if (error is SqliteException) return SyncErrorReason.storage;
    if (error is FormatException ||
        error is ContractException ||
        error is TypeError ||
        error is ArgumentError) {
      return SyncErrorReason.data;
    }
    return SyncErrorReason.other;
  }

  /// Runs one sync, counting the attempt and, if it throws, the coarse reason.
  /// The original outcome is always passed through unchanged.
  Future<void> measureSync(Future<void> Function() run) async {
    try {
      await run();
    } catch (error) {
      if (!_isAccountChange(error)) {
        await _add({
          syncAttempts: 1,
          syncErrorCounter(classify(error)): 1,
        });
      }
      rethrow;
    }
    await _add({syncAttempts: 1});
  }

  /// Runs the history replay, counting started, then completed or failed.
  Future<T> measureMigration<T>(Future<T> Function() run) async {
    await _add({migrationStarted: 1});
    try {
      final result = await run();
      await _add({migrationCompleted: 1});
      return result;
    } catch (error) {
      if (!_isAccountChange(error)) await _add({migrationFailed: 1});
      rethrow;
    }
  }

  Future<void> bundleDownloadFailed() => _add({bundleDownloadFailures: 1});

  String _day(DateTime at) => at.toUtc().toIso8601String().substring(0, 10);

  Future<void> _add(Map<String, int> counts) async {
    try {
      if (!await hasConsent()) return;
      final day = _day(_clock());
      for (final entry in counts.entries) {
        if (!counterNames.contains(entry.key)) continue;
        final key = '$_prefix$day:${entry.key}';
        final current = int.tryParse(state.get(key) ?? '') ?? 0;
        final next = current + entry.value;
        state.put(key, '${next > _maxStored ? _maxStored : next}');
      }
    } catch (_) {
      // A counter that cannot be written is simply not counted.
    }
  }

  Map<String, Map<String, int>> _stored() {
    final rows = state.db.select(
      'SELECT key,value FROM v2_sync_state WHERE namespace=? AND key LIKE ?',
      [state.namespace, '$_prefix%'],
    );
    final days = <String, Map<String, int>>{};
    for (final row in rows) {
      final rest = (row['key'] as String).substring(_prefix.length);
      final split = rest.indexOf(':');
      if (split != 10) continue;
      final name = rest.substring(split + 1);
      final count = int.tryParse(row['value'] as String);
      if (!counterNames.contains(name) || count == null || count < 1) continue;
      (days[rest.substring(0, split)] ??= {})[name] = count;
    }
    return days;
  }

  void _deleteDay(String day) => state.db.execute(
    'DELETE FROM v2_sync_state WHERE namespace=? AND key LIKE ?',
    [state.namespace, '$_prefix$day:%'],
  );

  void _purge() => state.db.execute(
    'DELETE FROM v2_sync_state WHERE namespace=? AND key LIKE ?',
    [state.namespace, '$_prefix%'],
  );

  /// Uploads closed days, oldest first, at most once every 24 hours (a failed
  /// attempt is retried after an hour). Without sharing consent nothing is sent
  /// and stored counts are deleted. Never throws.
  Future<void> upload({
    required http.Client client,
    required Uri baseUri,
    required Future<Map<String, String>> Function() headers,
    required String appVersion,
    required bool Function() accountIsCurrent,
  }) async {
    try {
      if (!accountIsCurrent()) return;
      if (!await hasConsent()) {
        if (accountIsCurrent()) _purge();
        return;
      }
      final now = _clock();
      final lastSent = DateTime.tryParse(state.get(_lastSentKey) ?? '');
      if (lastSent != null && now.difference(lastSent) < _interval) return;
      final lastTry = DateTime.tryParse(state.get(_lastTryKey) ?? '');
      if (lastTry != null && now.difference(lastTry) < _retryAfterFailure) {
        return;
      }
      final today = _day(now);
      final oldest = _day(now.subtract(const Duration(days: _maxDaysBack)));
      final stored = _stored();
      // Counts too old for the server to accept are dropped.
      for (final day in stored.keys.where((d) => d.compareTo(oldest) < 0)) {
        _deleteDay(day);
      }
      final pending =
          stored.keys
              .where((d) => d.compareTo(oldest) >= 0 && d.compareTo(today) < 0)
              .toList()
            ..sort();
      if (pending.isEmpty) return;
      state.put(_lastTryKey, now.toUtc().toIso8601String());
      final version = RegExp(r'^[0-9A-Za-z][0-9A-Za-z._+-]{0,31}$')
              .hasMatch(appVersion)
          ? appVersion
          : 'unknown';
      var sentAny = false;
      for (final day in pending.take(_maxDaysPerUpload)) {
        final counters = {
          for (final entry in stored[day]!.entries)
            entry.key: entry.value > _maxSent ? _maxSent : entry.value,
        };
        final authHeaders = await headers();
        if (!accountIsCurrent()) return;
        final response = await client
            .post(
              baseUri.resolve('/sms/v2/client-metrics'),
              headers: {...authHeaders, 'Content-Type': 'application/json'},
              body: jsonEncode({
                'day': day,
                'appVersion': version,
                'counters': counters,
              }),
            )
            .timeout(const Duration(seconds: 30));
        if (!accountIsCurrent()) return;
        if (response.statusCode == 202 || response.statusCode == 400) {
          // 202: stored, a duplicate, or refused for consent. 400: this day can
          // never be accepted. Either way the day is finished.
          _deleteDay(day);
          sentAny = sentAny || response.statusCode == 202;
        } else {
          break;
        }
      }
      if (sentAny) state.put(_lastSentKey, now.toUtc().toIso8601String());
    } catch (_) {
      // Failing to report must never reach the user; counts stay for a retry.
    }
  }
}
