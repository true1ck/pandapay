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

  /// Messages from a saved contact (sender arrives as a name). Counted only;
  /// the shared triage ignores them like texts from a phone number.
  final int personal;

  const IosShortcutSmsBatch._({
    required this.messages,
    required this.sourceRows,
    required this.total,
    required this.sensitive,
    required this.invalid,
    required this.incomplete,
    required this.missingSender,
    required this.missingDate,
    this.personal = 0,
  });

  /// Shortcuts formats numbers for display ("+91 74111 47986"). Remove the
  /// spacing so the shared phone-number rules recognise them.
  static String normalizeSender(String sender) {
    final trimmed = sender.trim();
    if (RegExp(r'^\+?[\d\s\-().]+$').hasMatch(trimmed) &&
        RegExp(r'\d').allMatches(trimmed).length >= 7) {
      return trimmed.replaceAll(RegExp(r'[\s\-().]'), '');
    }
    return trimmed;
  }

  static final _filterTag = RegExp(
    r'\s*\((?:smsft(?:_fi|_rm|_or)?|smsfp)\)\s*$',
    caseSensitive: false,
  );

  /// Strip the iOS annotation for classification only. Keep the raw
  /// sender on QueuedSms for source identity and the rule engine.
  static String senderForTriage(String sender) =>
      sender.replaceFirst(_filterTag, '');

  /// True for a contact name ("Sujay", "Mom Work"). Bank and company headers
  /// look like "SBICRD-S", "JioBal-S", "VM-HDFCBK" or "HDFCBK"; numbers and
  /// emails are addresses, not names. iOS cannot save an alphanumeric bank
  /// header as a contact, so a name always stands for a phone or email.
  static bool looksLikeContactName(String sender) {
    final s = senderForTriage(sender).trim();
    if (s.isEmpty || !RegExp(r'[A-Za-z]').hasMatch(s) || s.contains('@')) {
      return false;
    }
    final header = RegExp(
      r'^(?:[A-Za-z]{2}-)?[A-Za-z0-9]{2,11}(?:-[A-Za-z])?$',
    );
    if (!header.hasMatch(s)) return true;
    // A bare word with lowercase and no route suffix is a name, not a header.
    return RegExp(r'[a-z]').hasMatch(s) &&
        !RegExp(r'-[A-Za-z]$').hasMatch(s) &&
        !RegExp(r'^[A-Za-z]{2}-').hasMatch(s);
  }

  /// Banks and card issuers, checked first. More specific entries (SBI Card)
  /// come before the broader issuer (SBI) and claim their words, so one
  /// message naming "SBI Card" is not read as two issuers.
  static final List<(RegExp, String)> _issuers = [
    (RegExp(r'\bsbi\s*(?:credit\s*|cr\.?\s*)?card'), 'VM-SBICRD'),
    (RegExp(r'\b(?:sbi|state bank of india)\b'), 'VM-SBIINB'),
    (RegExp(r'\bhdfc\b'), 'VM-HDFCBK'),
    (RegExp(r'\bicici\b'), 'VM-ICICIB'),
    (RegExp(r'\baxis\b'), 'VM-AXISBK'),
    (RegExp(r'\bkotak\b'), 'VM-KOTAKB'),
    (RegExp(r'\b(?:bob|bank of baroda)\b'), 'VM-BOBTXN'),
    (RegExp(r'\b(?:pnb|punjab national)\b'), 'VM-PNBSMS'),
    (RegExp(r'\bindusind\b'), 'VM-INDBNK'),
    (RegExp(r'\bidfc\b'), 'VM-IDFCFB'),
    (RegExp(r'\byes\s*bank\b'), 'VM-YESBNK'),
    (RegExp(r'\bcanara\b'), 'VM-CANBNK'),
    (RegExp(r'\bunion bank\b'), 'VM-UBINBK'),
    (RegExp(r'\bfederal bank\b'), 'VM-FEDBNK'),
    (RegExp(r'\brbl\b'), 'VM-RBLBNK'),
    (RegExp(r'\bau (?:small finance )?bank\b'), 'VM-AUBANK'),
    (RegExp(r'\bone\s*card\b'), 'VM-ONECRD'),
  ];

  /// Payment apps are used only when no bank or card issuer is named: a bank
  /// alert often mentions the app ("via PhonePe") but the bank sent it.
  static final List<(RegExp, String)> _paymentApps = [
    (RegExp(r'\bphone\s*pe\b'), 'VM-PHONPE'),
    (RegExp(r'\bpaytm\b'), 'VM-PAYTMB'),
  ];

  /// Every sender [inferSenderFromBody] can return.
  static final Set<String> fillableSenders = {
    for (final (_, sender) in [..._issuers, ..._paymentApps]) sender,
  };

  static Set<String> _named(String text, List<(RegExp, String)> table) {
    var remaining = text;
    final found = <String>{};
    for (final (pattern, sender) in table) {
      if (pattern.hasMatch(remaining)) {
        found.add(sender);
        remaining = remaining.replaceAll(pattern, ' ');
      }
    }
    return found;
  }

  /// Fills a missing sender only when the body names exactly one issuer.
  /// Returns null when no issuer, or more than one, is named; the message
  /// then stays in review instead of getting a guessed bank.
  static String? inferSenderFromBody(String body) =>
      senderFillDetails(body)['filled_sender'] as String?;

  /// What the fill saw in the body and why it chose (or refused) a sender.
  static Map<String, Object?> senderFillDetails(String body) {
    final text = body.toLowerCase();
    final issuers = _named(text, _issuers);
    final apps = _named(text, _paymentApps);
    final (String? filled, String result) = switch ((issuers.length, apps.length)) {
      (1, _) => (issuers.single, 'filled_from_issuer'),
      (> 1, _) => (null, 'several_issuers_named'),
      (0, 1) => (apps.single, 'filled_from_payment_app'),
      (0, > 1) => (null, 'several_payment_apps_named'),
      _ => (null, 'no_issuer_named'),
    };
    return {
      'issuers_named': issuers.toList(),
      'payment_apps_named': apps.toList(),
      'filled_sender': filled,
      'fill_result': result,
    };
  }

  factory IosShortcutSmsBatch.fromRows(
    List<Map<Object?, Object?>> rows, {
    bool allowSenderInference = true,
  }) {
    if (rows.length > 2000) {
      throw ArgumentError('Import at most 2000 Shortcut messages per batch.');
    }
    final accepted = <QueuedSms>[];
    final sourceRows = <Map<Object?, Object?>>[];
    var sensitive = 0, invalid = 0, incomplete = 0;
    var missingSender = 0, missingDate = 0, personal = 0;
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
      var inferred = false;
      if (senderValid) {
        // Every row must reach the shared intake: native acknowledgement
        // expects one result per message. Contact names are classified as
        // personal by the shared triage, the same outcome Android gives a
        // phone-number sender.
        effectiveSender = normalizeSender(sender);
        if (looksLikeContactName(effectiveSender)) personal++;
      } else {
        missingSender++;
        final guess = allowSenderInference ? inferSenderFromBody(body) : null;
        inferred = guess != null;
        effectiveSender = guess ?? '';
      }

      // QueuedSms requires a receive date. Quarantine incomplete input rather
      // than substituting a body date or import time as original delivery.
      if (!dateValid) {
        missingDate++;
        incomplete++;
        continue;
      }

      sourceRows.add(
        Map.unmodifiable({
          ...row,
          'senderInferred': inferred,
          if (inferred) 'inferredSender': effectiveSender,
        }),
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
      personal: personal,
    );
  }
}
