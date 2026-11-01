import 'ios_device_probe_session.dart';
import 'ios_sender_probe_session.dart';
import 'local_sms_parser.dart';

/// Explicit, user-shared snapshot of the isolated probe. No auth state,
/// production store, device identifier or automatic upload is consulted.
Map<String, Object?> buildIosProbeDiagnostics({
  required String shortcut,
  required DateTime startedAt,
  required DateTime exportedAt,
  required Map<String, Object?> selection,
  required Map<Object?, Object?> nativeSnapshot,
  required IosSenderProbeSession sender,
  required IosDeviceProbeSession rangeSession,
  required IosDeviceProbeSession singleSession,
  required bool processing,
  required Map<String, Object?> errors,
  Map<String, Object?>? replayInfo,
}) {
  final live = nativeSnapshot['live'] as Map? ?? const {};
  final attempts = <Map<String, Object?>>[];
  for (final raw in live['events'] as List? ?? const []) {
    if (raw is! Map) continue;
    final body = raw['inputBody'];
    final withheld =
        raw['state'] == 'sensitive' ||
        raw['state'] == 'invalid' ||
        (body is String && LocalSmsParser.sensitive(body));
    attempts.add({
      for (final key in [
        'id',
        'handler',
        'invokedAt',
        'processedAt',
        'state',
        'missingSender',
        'missingDate',
        'bodyPresent',
        'bodyCharacters',
        'senderEvidence',
      ])
        if (raw.containsKey(key)) key: raw[key],
      if (!withheld) ...{
        for (final key in [
          'inputBody',
          'inputSender',
          'inputDate',
          'effectiveSender',
          'triageKind',
          'triageReason',
          'intakeDecision',
          'intakeReason',
          'transactionsAdded',
          'senderInferred',
          'parserOutput',
          'senderDiagnostics',
        ])
          if (raw.containsKey(key)) key: raw[key],
      },
      'content_withheld': withheld,
    });
  }
  return {
    'format': 'pandapay.sender_probe_diagnostics',
    'schema_version': 1,
    'session_started_at': startedAt.toUtc().toIso8601String(),
    'exported_at': exportedAt.toUtc().toIso8601String(),
    'parser_version': LocalSmsParser.version,
    'selected_shortcut': shortcut,
    'selection': selection,
    'processing_in_progress': processing,
    'scope': 'Isolated probe session; no main-app database or account data.',
    'receiver_label_note':
        'The legacy live tag identifies a receiver, not the automation trigger.',
    'observability':
        'Input conversion failures before the handler and the installed shortcut recipe are not observable here.',
    'expected_sender_fields': {
      'direct_person_receiver': {
        'parameter': 'sender',
        'type': 'optional IntentPerson',
        'source_property_chain': 'Message.Sender.Person',
      },
      'original_receiver': {
        'parameter': 'senderPerson',
        'type': 'optional String',
        'person_conversion': 'explicit public IntentPerson resolver v1',
      },
      'main_contract_receiver': {
        'parameter': 'sender',
        'type': 'optional String',
        'person_conversion': 'explicit public IntentPerson resolver v1',
      },
    },
    'native': {
      'range_runs': nativeSnapshot['runs'] ?? const [],
      'pending_range_inputs': _pending(nativeSnapshot['pending_records']),
      'pending_single_message_inputs': _pending(live['records']),
      'pending_range_records_at_snapshot':
          nativeSnapshot['pending_range_records'] ??
          (nativeSnapshot['records'] as List? ?? const []).length,
      'single_message_counts': live['counts'] ?? const {},
      'single_message_attempts': attempts,
      'single_message_attempt_details_limit': 30,
      'last_single_message_invoked_at': live['lastInvokedAt'],
    },
    'receiver_comparison': sender.comparison,
    'latest_single_message_input': sender.latestLiveInput,
    'latest_range_input': sender.latestHistoryInput,
    'sender_fill_summary': senderFillSummary(sender.exportJournal['records']),
    'capture_journal': sender.exportJournal,
    'body_evidence': sender.bodyEvidence.snapshot,
    'replay_info': replayInfo,
    'sessions': {
      'range_direct': _session(rangeSession),
      'single_message_direct': _session(singleSession),
      'comparison_direct': _session(sender.direct.intake),
      'body_inference_comparison_only': _session(sender.inferred.intake),
    },
    'errors': errors,
    'security_content_excluded': true,
  };
}

List<Map<String, Object?>> _pending(Object? input) => [
  for (final row in input is List ? input : const [])
    if (row is Map)
      if (row['body'] is String &&
          (row['body'] as String).length <= 20000 &&
          !LocalSmsParser.sensitive(row['body'] as String))
        {
          for (final key in [
            'id',
            'origin',
            'handler',
            'runId',
            'body',
            'sender',
            'senderEvidence',
            'senderDiagnostics',
            'receivedAt',
            'capturedAt',
            'bodyCharacters',
          ])
            if (row.containsKey(key)) key: row[key],
        }
      else
        {'id': row['id'], 'content_withheld': true},
];

Map<String, Object?> _session(IosDeviceProbeSession session) => {
  'sender_inference_enabled': session.allowSenderInference,
  'received': session.received,
  'usable_inputs': session.complete,
  'missing_sender': session.missingSender,
  'missing_date': session.missingDate,
  'security_excluded': session.sensitive,
  'invalid': session.invalid,
  'retained_messages': session.counts.captured,
  'pending_messages': session.counts.pending,
  'review_items': session.reviewCount,
  'transactions': session.transactionList,
  'observations': [
    for (final row in session.observations) {...row}..remove('sample_body'),
  ],
  'runs': {
    for (final entry in session.runs.entries)
      entry.key: {
        'handed_off': entry.value.handedOff,
        'retained_added': entry.value.retainedAdded,
        'already_retained': entry.value.existing,
        'ignored': entry.value.ignored,
        'reviewed': entry.value.reviewed,
        'transactions_added': entry.value.transactionsAdded,
        'missing_date': entry.value.missingDate,
        'invalid': entry.value.invalid,
        'security_excluded': entry.value.sensitive,
      },
  },
};

/// Counts over every exported message: how the body-based sender fill went
/// and what the shared intake then decided with that sender.
Map<String, Object?> senderFillSummary(Object? records) {
  final fill = <String, int>{}, filled = <String, int>{};
  final outcome = <String, int>{}, issuers = <String, int>{};
  var messages = 0, realSender = 0, transactions = 0;
  void add(Map<String, int> map, Object? key) =>
      map['${key ?? 'none'}'] = (map['${key ?? 'none'}'] ?? 0) + 1;
  for (final record in records is List ? records : const []) {
    if (record is! Map) continue;
    final guess = record['inferred'];
    if (guess is! Map) continue;
    messages++;
    if (record['senderPresent'] == true) realSender++;
    final details = guess['sender_fill'];
    if (details is Map) {
      add(fill, details['fill_result']);
      if (details['filled_sender'] != null) add(filled, details['filled_sender']);
      if (details['fill_result'] == 'several_issuers_named') {
        add(issuers, (details['issuers_named'] as List? ?? const []).join('+'));
      }
    }
    add(outcome, '${guess['intakeDecision']}:${guess['intakeReason']}');
    transactions += (guess['transactionsAdded'] as num? ?? 0).toInt();
  }
  return {
    'messages': messages,
    'real_sender_supplied': realSender,
    'fill_results': fill,
    'filled_senders': filled,
    'several_issuer_combinations': issuers,
    'intake_outcomes_with_fill': outcome,
    'transactions_added_with_fill': transactions,
  };
}
