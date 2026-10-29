import 'dart:convert';

import 'ios_device_probe_session.dart';
import '../features/sms_import/ios_shortcut_sms.dart';
import '../features/sms_import/sms_text_hint.dart';
import 'local/app_database.dart';
import 'local/sms_intake_repository.dart';

/// Live intake has its own disposable DB so history/self-check traffic cannot
/// inflate its results. Successful outcomes survive acknowledgement retries.
class IosLiveProbeSession {
  final IosDeviceProbeSession intake;
  final void Function(List<Map<Object?, Object?>>) _capture;
  final _outcomes = <String, Map<String, Object?>>{};
  IosLiveProbeSession(
    AppDatabase database, {
    void Function(List<Map<Object?, Object?>>)? capture,
  }) : this.withIntake(IosDeviceProbeSession(database), capture: capture);
  IosLiveProbeSession.withIntake(
    this.intake, {
    void Function(List<Map<Object?, Object?>>)? capture,
  }) : _capture = capture ?? intake.accept;

  List<Map<String, Object?>> process(List<Map<Object?, Object?>> rows) => [
    for (final row in rows)
      if (row['origin'] == 'live' && row['id'] is String) _process(row),
  ];

  Map<String, Object?> _process(Map<Object?, Object?> row) {
    final id = row['id'] as String;
    if (_outcomes[id] case final outcome?) return outcome;
    try {
      final beforeRetained = intake.counts.captured;
      final beforeInvalid = intake.invalid;
      final beforeSensitive = intake.sensitive;
      final beforeDate = intake.missingDate;
      final beforeSender = intake.missingSender;
      final beforeExisting = intake.runs['live']?.existing ?? 0;
      final beforeTransactions = intake.transactions;
      final batch = IosShortcutSmsBatch.fromRows([row]);
      _capture([
        {...row, 'runId': 'live'},
      ]);
      final outcome = intake.invalid > beforeInvalid
          ? 'rejected_invalid'
          : intake.sensitive > beforeSensitive
          ? 'rejected_sensitive'
          : intake.missingDate > beforeDate
          ? 'rejected_missing_date'
          : intake.counts.captured > beforeRetained
          ? 'retained_new'
          : (intake.runs['live']?.existing ?? 0) > beforeExisting
          ? 'retained_existing'
          : 'ignored';
      final diagnostic = <String, Object?>{};
      if (batch.messages.isNotEmpty) {
        final message = batch.messages.single;
        final triage = classifySmsTriage(message.sender, message.body);
        final key = smsSourceKey(
          IosDeviceProbeSession.namespace,
          message.sender,
          message.body,
        );
        final decision = SmsIntakeRepository(
          intake.database,
        ).decision(IosDeviceProbeSession.namespace, key);
        diagnostic.addAll({
          'effectiveSender': message.sender,
          'triageKind': triage.kind.name,
          'triageReason': triage.reasonCode,
          if (decision != null) 'intakeDecision': decision.decision,
          if (decision != null) 'intakeReason': decision.reasonCode,
          'transactionsAdded': intake.transactions - beforeTransactions,
        });
        final matching = intake.transactionList
            .where(
              (transaction) =>
                  intake.sourceKeysForTransaction(transaction).contains(key),
            )
            .toList();
        if (matching.isNotEmpty) {
          try {
            diagnostic['parserOutput'] = const JsonEncoder.withIndent(
              '  ',
            ).convert(matching);
          } on JsonUnsupportedObjectError {
            diagnostic['parserOutput'] =
                'Transaction output could not be displayed.';
          }
        }
      }
      return _outcomes[id] = {
        'id': id,
        'outcome': outcome,
        ...diagnostic,
        'senderInferred':
            intake.missingSender > beforeSender && batch.messages.isNotEmpty,
      };
    } catch (_) {
      // Do not acknowledge or cache failure. No exception/raw payload is logged.
      return {'id': id, 'outcome': 'processing_error'};
    }
  }

  void dispose() => intake.dispose();
}
