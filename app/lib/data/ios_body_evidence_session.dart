import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../features/sms_import/ios_shortcut_sms.dart';
import 'user_cards_repository.dart';

/// Extraction previews, not financial postings. An absent sender stays absent;
/// no fabricated bank header is needed to run the shared body parser.
class IosBodyEvidenceSession {
  final List<UserCard> cards;
  final int limit;
  final _records = <String, Map<String, Object?>>{};
  final _seen = <String>{};
  int omitted = 0;
  IosBodyEvidenceSession({this.cards = const [], this.limit = 5000});

  List<Map<String, Object?>> get records =>
      List.unmodifiable(_records.values.toList().reversed);
  Map<String, Object?> get snapshot => {
    'mode': 'inputs_without_fabricated_sender',
    'posting_state': 'preview_only',
    'unique_message_inputs': _records.length,
    'transaction_candidates': _records.values
        .where((r) => r['kind'] == 'transaction_candidate')
        .length,
    'payment_requests': _records.values
        .where((r) => r['kind'] == 'payment_request')
        .length,
    'omitted_inputs': omitted,
    'records': records,
  };

  void process(List<Map<Object?, Object?>> rows) {
    for (final row in rows) {
      final id = row['id'];
      if (id is! String || _seen.contains(id)) continue;
      final batch = IosShortcutSmsBatch.fromRows([
        row,
      ], allowSenderInference: false);
      if (batch.messages.isEmpty) continue;
      final message = batch.messages.single;
      final key = sha256
          .convert(
            utf8.encode(
              jsonEncode([
                message.body,
                message.receivedAt.toUtc().toIso8601String(),
              ]),
            ),
          )
          .toString();
      _seen.add(id);
      if (!_records.containsKey(key) && _records.length >= limit) {
        omitted++;
        continue;
      }
      final previous = _records[key];
      final sources = <Map<String, Object?>>[
        ...?((previous?['receiver_inputs'] as List?)
            ?.cast<Map<String, Object?>>()),
        {
          'transport_id': id,
          'receiver':
              (row['senderDiagnostics'] as Map?)?['action'] ??
              'existing_single_message',
          'supplied_sender': message.sender.isEmpty ? null : message.sender,
          'input_mode': row['inputMode'] ?? 'native_handoff',
        },
      ];
      final senders = sources
          .map((r) => r['supplied_sender'])
          .whereType<String>()
          .toSet();
      final supplied = senders.length == 1 ? senders.single : '';
      final request = RegExp(
        r'^(.{1,160}?)\s+has\s+requested\s+(?:money|payment)\s+from\s+you\b',
        caseSensitive: false,
      ).firstMatch(message.body.trim());
      final issuer = RegExp(
        r'\bon\s+(?:your\s+)?([A-Za-z][A-Za-z &]{1,40}?)\s+(?:credit|debit)\s+card\b',
        caseSensitive: false,
      ).firstMatch(message.body)?.group(1)?.trim();
      final app = RegExp(
        r'\b(PhonePe|Google Pay|GPay|Paytm|BHIM|Amazon Pay)\b',
        caseSensitive: false,
      ).firstMatch(message.body)?.group(1);
      final amountText = RegExp(
        r'(?:\brs\.?|\binr|₹)\s*:?\s*([\d,]+(?:\.\d{1,2})?)',
        caseSensitive: false,
      ).firstMatch(message.body)?.group(1);
      final amount = double.tryParse(amountText?.replaceAll(',', '') ?? '');
      _records[key] = {
        'message_input_key': key,
        'message_body': message.body,
        'original_receive_date': message.receivedAt.toUtc().toIso8601String(),
        'captured_sender': supplied.isEmpty ? null : supplied,
        'sender_status': senders.length > 1
            ? 'conflicting_inputs'
            : supplied.isEmpty
            ? 'unavailable'
            : 'supplied',
        'issuer_named_in_body': issuer,
        'payment_app_named_in_body': app,
        'kind': request != null
            ? 'payment_request'
            : 'non_transaction_observation',
        'posting_state': 'not_posted',
        'facts_basis': supplied.isEmpty
            ? 'message_body_and_receive_date'
            : 'message_body_and_supplied_sender',
        'transaction_facts': null,
        if (request != null)
          'request_facts': {
            'requester': request.group(1)?.trim(),
            'requested_amount_inr': amount?.isFinite == true ? amount : null,
            'payment_app': app,
            'completion_confirmed': false,
            'spending_added': 0,
          },
        'receiver_inputs': sources,
      };
    }
  }

  /// Re-evaluate only original input fields, never a prior guess or parser
  /// output. A diagnostic file is data, not a list of actions to execute.
  static List<Map<Object?, Object?>> inputsFromExport(String json) {
    if (utf8.encode(json).length > 32 * 1024 * 1024) {
      throw const FormatException('Report too large');
    }
    final report = jsonDecode(json);
    if (report is! Map ||
        report['format'] != 'pandapay.sender_probe_diagnostics' ||
        report['schema_version'] != 1) {
      throw const FormatException('Unsupported probe report');
    }
    final records = (report['capture_journal'] as Map?)?['records'];
    if (records is! List || records.length > 5000) {
      throw const FormatException('Invalid capture journal');
    }
    final replayId = sha256.convert(utf8.encode(json)).toString();
    return [
      for (var index = 0; index < records.length; index++)
        if (records[index] is Map && records[index]['input'] is Map)
          _replayRow(records[index]['input'] as Map, '$replayId:$index'),
    ];
  }

  static Map<Object?, Object?> _replayRow(Map input, String recordId) => {
    'id': 'replay:$recordId',
    'runId': input['run_id'] ?? 'export_replay',
    'origin': input['origin'],
    'inputMode': 'diagnostic_file_replay',
    'body': input['message_body'],
    'sender': input['native_sender_value'],
    'senderEvidence': input['native_sender_evidence'],
    'receivedAt': input['original_receive_date'],
    'capturedAt': input['captured_at'],
    'senderDiagnostics': {
      'action': input['receiver'],
      'text': input['sender_text'],
      'person': input['sender_person'],
      'shortcuts_type': input['sender_shortcuts_type'],
    },
  };
}
