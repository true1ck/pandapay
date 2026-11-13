import 'dart:convert';

import 'package:http/http.dart' as http;

import '../storage/outbox_store.dart';

/// A correction is uploaded after fact/event sync, so the server can verify
/// account ownership of the referenced facts. Retries retain its stable ID.
///
/// What happens when the server refuses a correction:
/// * It could not find the facts or the event it names: they are sent again
///   (see [requeue]) and the correction is tried again after a growing wait,
///   up to [maxFactsNotFoundRefusals] times in all. Only then does the
///   correction stay on this phone only. A correction is never given up for
///   want of a connection: while the facts it names are still waiting to
///   upload (even in a back-off) it is not sent at all.
/// * It did not accept the shared template: the correction is tried once
///   more without the template.
/// * Any other refusal that retrying cannot change: the correction stays on
///   this phone only.
/// * The server is busy, the network is down or the sign-in is stale: it is
///   retried later with a growing wait.
/// A correction that stays on the phone is taken out of the queue, so it no
/// longer blocks the ones behind it, and its review row records why.
class CorrectionsSync {
  CorrectionsSync({
    required this.queue,
    required this.client,
    required this.baseUri,
    required this.headers,
    required this.accountIsCurrent,
    this.requeue,
    this.sharingGranted,
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now;

  final OutboxStore queue;
  final http.Client client;
  final Uri baseUri;
  final Future<Map<String, String>> Function() headers;
  final bool Function() accountIsCurrent;

  /// Puts the facts, event and ledger entries of a source back in the upload
  /// queue. Optional: without it a correction the server cannot match stays
  /// on this phone after the first refusal.
  final void Function(String sourceKey, String? eventId)? requeue;
  final DateTime Function() clock;

  /// Whether sharing with the community is agreed RIGHT NOW. Read just before
  /// every send: a correction queued while it was agreed must not carry its
  /// share-only parts after a withdrawal. Null = not asked (kept as queued).
  final Future<bool> Function()? sharingGranted;
  Future<int>? _running;

  /// A refusal marker kept inside the queued payload; never sent. It counts
  /// the "facts not found" refusals so far (older builds stored `true`: one).
  static const _resentKey = '_resent';
  static const _noTemplateKey = '_templateDropped';

  /// Stop waiting for a source's facts after this many failed uploads of them,
  /// so a source the server refuses for good cannot hold a correction forever.
  static const _waitAttempts = 6;

  /// The server may say "facts not found" this many times for one correction
  /// (each after the facts were sent again) before it is kept on the phone.
  static const maxFactsNotFoundRefusals = 4;

  /// Waits after the first, second and third such refusal.
  static const _factsNotFoundWaits = [
    Duration(minutes: 1),
    Duration(minutes: 5),
    Duration(minutes: 30),
  ];

  static const _factsMissing = {
    'correction_facts_not_found',
    'correction_event_not_found',
  };
  static const _templateRefused = {
    'redacted_template_invalid',
    'template_hash_mismatch',
  };

  Future<int> drain() =>
      _running ??= _drain().whenComplete(() => _running = null);

  Future<int> _drain() async {
    var sent = 0;
    // Corrections that wait for their facts are looked at again next pass.
    final waiting = <String>{};
    // Bounds one pass, however many corrections are queued.
    var handled = 0;
    while (accountIsCurrent() && handled < 50) {
      final pending = queue
          .due(clock(), limit: 500)
          .where(
            (record) =>
                record.kind == 'correction' && !waiting.contains(record.id),
          )
          .firstOrNull;
      if (pending == null) return sent;
      handled++;
      final payload = pending.json;
      if (_waitsForUpload(payload)) {
        waiting.add(pending.id);
        continue;
      }
      try {
        final requestHeaders = await headers();
        final shareOk = sharingGranted == null || await sharingGranted!();
        if (!accountIsCurrent()) return sent;
        final response = await client
            .post(
              baseUri.resolve('/sms/v2/corrections'),
              headers: {...requestHeaders, 'Content-Type': 'application/json'},
              body: jsonEncode(_wire(payload, shareOk)),
            )
            .timeout(const Duration(seconds: 30));
        if (!accountIsCurrent()) return sent;
        if (response.statusCode != 200) {
          switch (_afterRefusal(pending, payload, response)) {
            case _Next.later:
              queue.retry(pending, clock());
              return sent;
            case _Next.again || _Next.parked:
              continue;
          }
        }
        final decoded = jsonDecode(response.body);
        if (decoded is! Map ||
            decoded.length != 1 ||
            decoded['caseId'] is! String ||
            (decoded['caseId'] as String).isEmpty) {
          throw const FormatException('Invalid correction response');
        }
        final caseId = decoded['caseId'] as String;
        queue.db.execute('SAVEPOINT sms_v2_correction_ack');
        try {
          if (queue.acknowledge(pending)) {
            queue.db.execute(
              'UPDATE v2_review_items SET payload=json_set(payload,\'\$.caseId\',?),status=\'open\' '
              'WHERE namespace=? AND review_id=?',
              [caseId, queue.namespace, pending.id],
            );
            sent++;
          }
          queue.db.execute('RELEASE sms_v2_correction_ack');
        } catch (_) {
          queue.db.execute('ROLLBACK TO sms_v2_correction_ack');
          queue.db.execute('RELEASE sms_v2_correction_ack');
          rethrow;
        }
      } catch (_) {
        queue.retry(pending, clock());
        return sent;
      }
    }
    return sent;
  }

  /// What the server receives: the payload without the phone's own markers.
  /// Without current consent the share-only parts (template, shared
  /// category / shop) are dropped; the case itself is still sent.
  Map<String, Object?> _wire(Map<String, Object?> payload, bool shareOk) => {
    for (final entry in payload.entries)
      if (entry.key != _resentKey &&
          entry.key != _noTemplateKey &&
          (shareOk || entry.key != 'redactedTemplate'))
        entry.key: shareOk || entry.key != 'corrected'
            ? entry.value
            : <String, Object?>{},
  };

  /// True while the source or the event the correction names is still waiting
  /// in the upload queue: the server cannot match a correction to facts it has
  /// not received. A record that has failed [_waitAttempts] times no longer
  /// holds it, backoff or not (WP-C9: a network failure never counts an
  /// attempt, so attempts > 0 means the server itself refused it; its backoff
  /// keeps re-arming and must not hold the correction for ever). Below that,
  /// a waiting record (even in a back-off: the phone may only have been
  /// offline) still holds it, so it is not sent before its facts (Q-09).
  bool _waitsForUpload(Map<String, Object?> payload) {
    final ids = [
      if (payload['sourceKey'] is String) 'source:${payload['sourceKey']}',
      if (payload['eventId'] is String) 'event:${payload['eventId']}',
    ];
    if (ids.isEmpty) return false;
    final rows = queue.db.select(
      'SELECT attempts, next_attempt_at FROM v2_outbox WHERE namespace=? AND id IN (${List.filled(ids.length, '?').join(',')})',
      [queue.namespace, ...ids],
    );
    return rows.any((row) => (row['attempts'] as int) < _waitAttempts);
  }

  String? _reason(http.Response response) {
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map && decoded['error'] is String) {
        return decoded['error'] as String;
      }
    } catch (_) {}
    return null;
  }

  _Next _afterRefusal(
    OutboxRecord pending,
    Map<String, Object?> payload,
    http.Response response,
  ) {
    final status = response.statusCode;
    // Busy server, rate limit, stale sign-in, App Check, timeouts and server
    // faults pass with time; so does anything that is not a plain refusal.
    if (status != 400 && status != 404 && status != 410 && status != 413) {
      return _Next.later;
    }
    // A refusal without the server's own error code (a proxy page, a cut-off
    // body) is not a verdict on this correction: try again later.
    final reason = _reason(response);
    if (reason == null) return _Next.later;
    if (_factsMissing.contains(reason) && requeue != null) {
      final refusals =
          switch (payload[_resentKey]) {
            final int count => count,
            true => 1,
            _ => 0,
          } +
          1;
      if (refusals >= maxFactsNotFoundRefusals) return _park(pending, reason);
      final sourceKey = payload['sourceKey'];
      if (sourceKey is! String) return _park(pending, reason);
      requeue!(sourceKey, payload['eventId'] as String?);
      queue.enqueue('correction', pending.id.substring('correction:'.length), {
        ...payload,
        _resentKey: refusals,
      });
      queue.deferUntil(
        pending.id,
        clock().add(_factsNotFoundWaits[refusals - 1]),
      );
      return _Next.again;
    }
    if (_templateRefused.contains(reason) &&
        payload[_noTemplateKey] != true &&
        (payload.containsKey('redactedTemplate') ||
            (payload['corrected'] as Map?)?.containsKey('_template') == true)) {
      final corrected = {
        for (final entry
            in ((payload['corrected'] as Map?) ?? const {}).entries)
          if (entry.key != '_template') entry.key as String: entry.value,
      };
      queue.enqueue('correction', pending.id.substring('correction:'.length), {
        for (final entry in payload.entries)
          if (entry.key != 'redactedTemplate') entry.key: entry.value,
        'corrected': corrected,
        _noTemplateKey: true,
      });
      return _Next.again;
    }
    return _park(pending, reason);
  }

  /// Takes a refused correction out of the queue. The change itself stays on
  /// the phone; the review row says it was not sent, and why.
  _Next _park(OutboxRecord pending, String reason) {
    queue.db.execute('SAVEPOINT sms_v2_correction_park');
    try {
      if (queue.acknowledge(pending)) {
        queue.db.execute(
          'UPDATE v2_review_items SET status=\'resolved\',payload=json_set(payload,\'\$.notSent\',?) '
          'WHERE namespace=? AND review_id=?',
          [reason, queue.namespace, pending.id],
        );
      }
      queue.db.execute('RELEASE sms_v2_correction_park');
    } catch (_) {
      queue.db.execute('ROLLBACK TO sms_v2_correction_park');
      queue.db.execute('RELEASE sms_v2_correction_park');
      rethrow;
    }
    return _Next.parked;
  }

  /// Apply the owner-scoped status rows delivered by the normal sync response.
  /// This participates in the puller's existing transaction.
  void applyStatuses(List<Map<String, Object?>> statuses) {
    for (final status in statuses) {
      final caseId = status['caseId'];
      if (caseId is! String ||
          !['open', 'decided'].contains(status['status'])) {
        throw const FormatException('Invalid correction status');
      }
      queue.db.execute(
        "UPDATE v2_review_items SET status=?,payload=json_set(payload,'\$.serverStatus',json(?)) "
        "WHERE namespace=? AND kind='correction' AND json_extract(payload,'\$.caseId')=?",
        [status['status'], jsonEncode(status), queue.namespace, caseId],
      );
    }
  }
}

enum _Next { later, again, parked }
