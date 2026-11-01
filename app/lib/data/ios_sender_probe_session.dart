import 'dart:convert';

import '../features/sms_import/ios_shortcut_sms.dart';
import 'ios_live_probe_session.dart';
import 'local/app_database.dart';
import 'local_sms_parser.dart';
import 'ios_body_evidence_session.dart';

/// Two disposable comparison databases. Neither is the main app database or
/// an upload owner. Guessed senders never become evidence in the direct branch.
class IosSenderProbeSession {
  final bodyEvidence = IosBodyEvidenceSession();
  final IosLiveProbeSession direct;
  final IosLiveProbeSession inferred;
  final int limit;
  final int exportLimit, exportByteLimit;
  final _events = <Map<String, Object?>>[];
  final _journal = <Map<String, Object?>>[];
  int _journalBytes = 0, _exportOmitted = 0;
  final _seen = <String>{};
  Map<String, Object?>? _latestLiveInput, _latestHistoryInput, _referenceLive;
  final _matchingHistory = <String, Map<String, Object?>>{};
  String? _comparisonRun;
  bool _comparisonComplete = false;

  IosSenderProbeSession({
    this.limit = 30,
    this.exportLimit = 5000,
    this.exportByteLimit = 16 * 1024 * 1024,
    IosLiveProbeSession? directSession,
    IosLiveProbeSession? inferredSession,
  }) : direct =
           directSession ??
           IosLiveProbeSession(
             openInMemoryForTesting(),
             allowSenderInference: false,
           ),
       inferred =
           inferredSession ??
           IosLiveProbeSession(
             openInMemoryForTesting(),
             allowSenderInference: true,
           );

  List<Map<String, Object?>> get events => List.unmodifiable(_events.reversed);
  Map<String, Object?> get exportJournal => {
    'records': List.of(_journal),
    'record_count': _journal.length,
    'omitted_records': _exportOmitted,
    'complete': _exportOmitted == 0,
    'record_limit': exportLimit,
    'byte_limit': exportByteLimit,
    'recorded_bytes': _journalBytes,
    'security_content_excluded': true,
    'coverage':
        'Processed inputs; pending native inputs are exported separately.',
  };
  Map<String, Object?>? get latestLiveInput => _latestLiveInput;
  Map<String, Object?>? get latestHistoryInput => _latestHistoryInput;

  void beginHistoryComparison(String runId, {bool useLatestReference = true}) {
    _comparisonRun = runId;
    _referenceLive = useLatestReference ? _latestLiveInput : null;
    _matchingHistory.clear();
    _comparisonComplete = false;
  }

  void completeHistoryComparison(String runId) {
    if (_comparisonRun == runId) _comparisonComplete = true;
  }

  Map<String, Object?> get comparison => {
    'status': _comparisonRun == null
        ? 'not_started'
        : _referenceLive == null
        ? 'no_live_reference'
        : _matchingHistory.length > 1
        ? 'ambiguous_text'
        : _matchingHistory.isEmpty
        ? (_comparisonComplete ? 'no_matching_text' : 'waiting_for_history')
        : _matchingHistory.values.single['senderPresent'] != true
        ? 'history_missing_sender'
        : _matchingHistory.values.single['capturedSender'] ==
              _referenceLive!['capturedSender']
        ? 'same_sender'
        : 'different_sender',
    'live': _referenceLive,
    'history': _matchingHistory.length == 1
        ? _matchingHistory.values.single
        : null,
    'completed': _comparisonComplete,
  };

  Map<String, Object?> _input(Map<Object?, Object?> row) {
    final diagnostics = row['senderDiagnostics'];
    final fields = diagnostics is Map ? diagnostics : const {};
    final supplied = directRow(row)['sender'] as String?;
    return {
      'origin': row['origin'] ?? 'history',
      'receiver': fields['action'] ?? 'existing_single_message',
      'run_id': row['runId'],
      'captured_at': row['capturedAt'],
      'input_mode': row['inputMode'] ?? 'native_handoff',
      'body_characters': row['bodyCharacters'],
      'message_body': row['body'],
      'original_receive_date': row['receivedAt'],
      'sender_shortcuts_type': fields['shortcuts_type'],
      'sender_text': fields.containsKey('text')
          ? fields['text']
          : row['senderEvidence'] == 'text'
          ? row['sender']
          : null,
      'sender_person': fields['person'],
      'sender_conversion': fields['conversion'] ?? 'not_reported',
      'sender_parameter_state': fields['parameter_state'] ?? 'not_reported',
      'native_sender_value': row['sender'],
      'sender_parameter':
          fields['parameter_id'] ??
          (row['handler'] == 'person_sender'
              ? 'senderPerson (String)'
              : 'Not reported'),
      'native_sender_runtime_type':
          row['sender']?.runtimeType.toString() ?? 'null',
      'native_sender_evidence': row['senderEvidence'] ?? 'text',
      'senderPresent': supplied?.trim().isNotEmpty == true,
      'capturedSender': supplied?.trim().isNotEmpty == true ? supplied : null,
    };
  }

  void _observe(Map<Object?, Object?> row) {
    final body = row['body'];
    if (row['id'] is! String ||
        body is! String ||
        body.trim().isEmpty ||
        body.length > 20000 ||
        LocalSmsParser.sensitive(body)) {
      return;
    }
    final input = _input(row);
    if (row['origin'] == 'live') {
      _latestLiveInput = input;
      // "live" is a legacy receiver tag, not acquisition evidence. The
      // original single-message action can be called inside the same loop.
      if (_comparisonRun != null && _referenceLive == null) {
        _referenceLive = input;
      }
    } else {
      _latestHistoryInput = input;
      if (row['runId'] == _comparisonRun &&
          _referenceLive != null &&
          body == _referenceLive!['message_body'] &&
          _matchingHistory.length < 2) {
        _matchingHistory[row['id'] as String] = input;
      }
    }
  }

  /// A supplied display name is visible in raw diagnostics, but does not
  /// establish the original address for the strict comparison.
  static Map<Object?, Object?> directRow(Map<Object?, Object?> row) {
    final diagnostics = row['senderDiagnostics'];
    final person = diagnostics is Map ? diagnostics['person'] : null;
    final nativeSender = row['sender'];
    final handle = person is Map ? person['handle'] : null;
    final name = person is Map ? person['name'] : null;
    final nameOnlyText =
        person is Map &&
        person['present'] == true &&
        (handle is! String || handle.trim().isEmpty) &&
        name is String &&
        name.trim().isNotEmpty &&
        nativeSender is String &&
        nativeSender.trim() == name.trim();
    return {
      ...row,
      if (nativeSender is! String ||
          row['senderEvidence'] == 'name' ||
          nameOnlyText) ...{
        'sender': '',
        'senderEvidence': 'missing',
      },
    };
  }

  void process(List<Map<Object?, Object?>> rows) {
    bodyEvidence.process(rows.map(directRow).toList());
    // Keep the receiver reference independent of the recent-30 display.
    // The export journal records every processed non-sensitive input until
    // its stated capacity. Ambiguous text never supplies a sender.
    for (final row in rows) {
      _observe(row);
    }
    for (final row in rows) {
      final id = row['id'];
      final body = row['body'];
      if (id is! String ||
          body is! String ||
          body.trim().isEmpty ||
          body.length > 20000 ||
          LocalSmsParser.sensitive(body) ||
          _seen.contains(id)) {
        continue;
      }
      final input = {...directRow(row), 'origin': 'live'};
      final actual = direct.process([input]).single;
      final guess = inferred.process([
        {...input, 'sender': '', 'senderEvidence': 'missing'},
      ]).single;
      final failed =
          actual['outcome'] == 'processing_error' ||
          guess['outcome'] == 'processing_error';
      if (!failed) _seen.add(id);
      final inputJson = _input(row);
      final event = <String, Object?>{
        'id': id,
        'origin': row['origin'] ?? 'history',
        'receivedAt': row['receivedAt'],
        'processing_complete': !failed,
        'senderPresent':
            (actual['effectiveSender'] as String? ?? '').isNotEmpty,
        'input': inputJson,
        'direct': _output(actual),
        'inferred': {
          'inference_basis': 'body_text_only',
          ..._output(guess),
          'sender_fill': IosShortcutSmsBatch.senderFillDetails(body),
        },
      };
      _events.removeWhere((previous) => previous['id'] == id);
      _events.add(event);
      final bytes = utf8.encode(jsonEncode(event)).length;
      if (_journal.length < exportLimit &&
          _journalBytes + bytes <= exportByteLimit) {
        _journal.add(event);
        _journalBytes += bytes;
      } else {
        _exportOmitted++;
      }
      if (_events.length > limit) _events.removeAt(0);
    }
  }

  Map<String, Object?> _output(Map<String, Object?> result) {
    final output = {...result}..remove('id');
    if (output['parserOutput'] case final String json) {
      try {
        output['parserOutput'] = jsonDecode(json);
      } on FormatException {
        // Already contains a safe display message from the diagnostic adapter.
      }
    }
    return output;
  }

  void dispose() {
    direct.dispose();
    inferred.dispose();
  }
}
