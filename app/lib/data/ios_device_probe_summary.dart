import '../features/sms_import/sms_text_hint.dart';
import 'local_sms_parser.dart';

/// Only parsed fields survive this conversion. Raw input is not stored here.
class IosDeviceProbeSummary {
  final String id;
  final String event;
  final String? amount;
  final String? merchant;
  final DateTime? originalDate;
  final bool senderKnown;

  const IosDeviceProbeSummary({
    required this.id,
    required this.event,
    this.amount,
    this.merchant,
    this.originalDate,
    required this.senderKnown,
  });

  factory IosDeviceProbeSummary.fromMap(Map<Object?, Object?> row) {
    final sender = row['sender'] as String? ?? '';
    final body = row['body'] as String;
    final original = DateTime.tryParse(row['receivedAt'] as String? ?? '');
    final captured = DateTime.parse(row['capturedAt'] as String);
    final candidate =
        classifySmsTriage(sender, body).kind ==
        SmsTriageKind.financialCandidate;
    final parsed = candidate
        ? LocalSmsParser.parse(
            namespace: 'isolated-ios-device-probe',
            sender: sender,
            body: body,
            receivedAt: original ?? captured,
          )
        : null;
    final needsReview = parsed?.eventType == LocalSmsEventType.unknown;
    final draft = needsReview
        ? LocalSmsParser.reviewDraft(
            namespace: 'isolated-ios-device-probe',
            sender: sender,
            body: body,
            receivedAt: original ?? captured,
          )
        : null;
    final money =
        parsed?.transaction?.amount ?? parsed?.amountDue ?? parsed?.amount ?? draft?.amount;
    return IosDeviceProbeSummary(
      id: row['id'] as String,
      event: parsed?.eventType.wireValue ?? 'ignored',
      amount: money?.format(),
      merchant: parsed?.transaction?.merchantName ?? parsed?.billerName ?? draft?.merchantName,
      originalDate: original,
      senderKnown: sender.trim().isNotEmpty,
    );
  }
}
