import '../../data/local_sms_parser.dart';
import 'sms_background_queue.dart';

/// Validates the iOS acquisition boundary. Accepted messages are the exact
/// QueuedSms values consumed by Android's SmsImportStore and upload worker.
class IosShortcutSmsBatch {
  final List<QueuedSms> messages;
  final List<Map<Object?, Object?>> sourceRows;
  final int total;
  final int sensitive;
  final int invalid;
  final int incomplete;
  final int missingSender;
  final int missingDate;

  const IosShortcutSmsBatch._({
    required this.messages,
    required this.sourceRows,
    required this.total,
    required this.sensitive,
    required this.invalid,
    required this.incomplete,
    required this.missingSender,
    required this.missingDate,
  });

  static String _inferSender(String body) {
    final lower = body.toLowerCase();
    if (lower.contains('hdfc')) return 'VM-HDFCBK';
    if (lower.contains('icici')) return 'VM-ICICIB';
    if (lower.contains('sbi') || lower.contains('state bank')) {
      return 'VM-SBIINB';
    }
    if (lower.contains('axis')) return 'VM-AXISBK';
    if (lower.contains('kotak')) return 'VM-KOTAKB';
    if (lower.contains('bob') || lower.contains('bank of baroda')) {
      return 'VM-BOBTXN';
    }
    if (lower.contains('pnb') || lower.contains('punjab national')) {
      return 'VM-PNBSMS';
    }
    if (lower.contains('indusind')) return 'VM-INDBNK';
    if (lower.contains('idfc')) return 'VM-IDFCFB';
    if (lower.contains('yes bank') || lower.contains('yesbank')) {
      return 'VM-YESBNK';
    }
    if (lower.contains('canara')) return 'VM-CANBNK';
    if (lower.contains('union bank')) return 'VM-UBINBK';
    if (lower.contains('federal bank')) return 'VM-FEDBNK';
    if (lower.contains('rbl')) return 'VM-RBLBNK';
    if (lower.contains('onecard')) return 'VM-ONECRD';
    return 'VM-BANK';
  }

  factory IosShortcutSmsBatch.fromRows(List<Map<Object?, Object?>> rows) {
    if (rows.length > 2000) {
      throw ArgumentError('Import at most 2000 Shortcut messages per batch.');
    }
    final accepted = <QueuedSms>[];
    final sourceRows = <Map<Object?, Object?>>[];
    var sensitive = 0, invalid = 0, incomplete = 0;
    var missingSender = 0, missingDate = 0;
    for (final row in rows) {
      final body = row['body'];
      if (body is! String || body.trim().isEmpty || body.length > 20000) {
        invalid++;
        continue;
      }
      final nativeCharacters = row['bodyCharacters'];
      if (nativeCharacters != null && nativeCharacters != body.length) {
        invalid++;
        continue;
      }
      if (LocalSmsParser.sensitive(body)) {
        sensitive++;
        continue;
      }
      final sender = row['sender'];
      final evidence = row['senderEvidence'];
      final senderValid =
          sender is String &&
          sender.trim().isNotEmpty &&
          (evidence == null ||
              evidence == 'text' ||
              evidence == 'handle' ||
              evidence == 'name');
      final rawDate = row['receivedAt'];
      final date = rawDate is String ? DateTime.tryParse(rawDate) : null;
      final dateValid =
          date != null &&
          rawDate is String &&
          RegExp(r'(?:Z|[+-]\d{2}:?\d{2})$').hasMatch(rawDate);

      String effectiveSender;
      if (senderValid) {
        effectiveSender = sender.trim();
      } else {
        effectiveSender = _inferSender(body);
        missingSender++;
      }

      // QueuedSms requires a receive date. Quarantine incomplete input rather
      // than substituting a body date or import time as original delivery.
      if (!dateValid) {
        missingDate++;
        incomplete++;
        continue;
      }

      sourceRows.add(
        Map.unmodifiable({...row, 'senderInferred': !senderValid}),
      );
      accepted.add(
        QueuedSms(sender: effectiveSender, body: body, receivedAt: date),
      );
    }
    return IosShortcutSmsBatch._(
      messages: List.unmodifiable(accepted),
      sourceRows: List.unmodifiable(sourceRows),
      total: rows.length,
      sensitive: sensitive,
      invalid: invalid,
      incomplete: incomplete,
      missingSender: missingSender,
      missingDate: missingDate,
    );
  }
}
