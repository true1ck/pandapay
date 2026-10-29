import 'local_sms_parser.dart';
import '../features/sms_import/sms_text_hint.dart';

/// Synthetic-only envelope supplied by the native Shortcuts prototype.
/// This does not query Messages, upload a transaction, or replace the SMS parser.
class IosPrototypeCapture {
  static const marker = '[PANDAPAY_TEST]';

  final String id;
  final String sender;
  final String body;
  final DateTime capturedAt;
  final DateTime? receivedAt;

  const IosPrototypeCapture({
    required this.id,
    required this.sender,
    required this.body,
    required this.capturedAt,
    this.receivedAt,
  });

  factory IosPrototypeCapture.fromMap(Map<Object?, Object?> map) {
    final body = map['body'] as String;
    if (!body.contains(marker)) {
      throw const FormatException('Only synthetic prototype messages allowed.');
    }
    return IosPrototypeCapture(
      id: map['id'] as String,
      sender: map['sender'] as String,
      body: body,
      capturedAt: DateTime.parse(map['capturedAt'] as String),
      receivedAt: map['receivedAt'] == null
          ? null
          : DateTime.parse(map['receivedAt'] as String),
    );
  }

  LocalSmsObservation? parse() {
    final text = body.replaceAll(marker, '').trim();
    // Match Android's intake gate before invoking the shared parser. Some
    // rejected inputs can otherwise produce typed local-ignore observations.
    if (classifySmsTriage(sender, text).kind !=
        SmsTriageKind.financialCandidate) {
      return null;
    }
    return LocalSmsParser.parse(
      namespace: 'ios-shortcuts-prototype',
      sender: sender,
      body: text,
      receivedAt: receivedAt ?? capturedAt,
    );
  }
}
