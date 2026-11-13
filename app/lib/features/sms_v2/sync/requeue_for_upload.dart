import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:pandapay_domain/sms_v2.dart';

import '../../../data/local/sms_intake_repository.dart';
import '../storage/event_store.dart';
import '../storage/fact_store.dart';
import '../storage/ledger_store.dart';
import '../storage/outbox_store.dart';

/// Puts a source's facts, the event built on them and that event's ledger
/// entries back in the upload queue.
///
/// For when the server says it does not know something this phone already
/// uploaded (a restored or replaced server database, or an upload that was
/// lost). Sending the same records again is safe: the server treats an
/// identical record as a duplicate.
///
/// The entries start over (no attempts, no wait) even when they are byte for
/// byte what is already queued: a source that waited out a back-off while the
/// phone was offline has to go now, since the caller is a correction that is
/// held back until it has gone (Q-09).
///
/// Returns how many queue entries were written.
int requeueForUpload({
  required OutboxStore queue,
  required SmsIntakeRepository intake,
  required String sourceKey,
  required String Function(String sender) brandOf,
  String? eventId,
}) {
  final db = queue.db;
  final namespace = queue.namespace;
  final facts = FactStore(db, namespace: namespace);
  final event = eventId == null
      ? null
      : EventStore(db, namespace: namespace).get(eventId);
  // The event can stand on facts from several sources: the SMS itself and the
  // replacement facts that earlier edits created.
  final sources = <String>{sourceKey};
  if (event != null) {
    for (final leg in event.legs) {
      final fact = facts.get(leg.factId);
      if (fact != null) sources.add(fact.sourceKey);
    }
  }
  var written = 0;
  for (final source in sources) {
    // Facts that only inform never leave the phone.
    final uploadable = [
      for (final fact in facts.forSource(source))
        if (fact.factType != FactType.info) fact,
    ];
    if (uploadable.isEmpty) continue;
    final captured = intake.capturedById(namespace, source)?.message;
    queue.enqueue('source', source, {
      'sourceKey': source,
      'senderBrand': captured == null ? 'USER' : brandOf(captured.sender),
      'observedAt': (captured?.receivedAt ?? uploadable.first.observedAt)
          .toUtc()
          .toIso8601String(),
      'bodyHash': sha256
          .convert(utf8.encode(captured?.body ?? source))
          .toString(),
      'facts': [
        for (final fact in uploadable)
          {
            ...fact.toJson(),
            'evidence': <Object?>[],
            if (fact.instrument != null)
              'instrument': {...fact.instrument!.toJson(), 'raw': null},
          },
      ],
    }, restart: true);
    written++;
  }
  if (event != null) {
    queue.enqueue('event', event.eventId, event.toJson(), restart: true);
    written++;
    for (final entry in LedgerStore(
      db,
      namespace: namespace,
    ).forEvent(event.eventId)) {
      queue.enqueue('ledger', entry.entryId, entry.toJson(), restart: true);
      written++;
    }
  }
  return written;
}
