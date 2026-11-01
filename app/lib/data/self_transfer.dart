import 'dart:convert';

String selfTransferSender(String sender) {
  final family = sender
      .trim()
      .toLowerCase()
      .replaceFirst(RegExp(r'^[a-z0-9]{2}-'), '')
      .replaceFirst(RegExp(r'-[a-z]$'), '');
  return const {
        'hdfcbk': 'hdfc',
        'canbnk': 'canara',
        'canbk': 'canara',
        'kotakb': 'kotak',
        'icicib': 'icici',
        'unionb': 'union',
        'axisbnk': 'axis',
        'axisb': 'axis',
        'sbibnk': 'sbi',
        'sbibk': 'sbi',
        'idbibk': 'idbi',
        'yesbnk': 'yes',
        'yesbank': 'yes',
        'ucob': 'uco',
        'eqt': 'equitas',
        'pytm': 'paytm',
      }[family] ??
      family;
}

class SelfTransferDestination {
  final String accountLast4;
  final String bank;
  const SelfTransferDestination({
    required this.accountLast4,
    required this.bank,
  });
  String get label =>
      'Self-transfer to ${selfTransferBankLabel(bank)} •$accountLast4';
  Map<String, dynamic> toJson() => {'accountLast4': accountLast4, 'bank': bank};
}

String selfTransferBankLabel(String bank) =>
    const {
      'slcbnk': 'Slice',
      'hdfc': 'HDFC Bank',
      'canara': 'Canara Bank',
      'kotak': 'Kotak Bank',
      'union': 'Union Bank',
      'axis': 'Axis Bank',
      'icici': 'ICICI Bank',
      'sbi': 'SBI',
      'idbi': 'IDBI Bank',
      'yes': 'Yes Bank',
      'equitas': 'Equitas Bank',
      'paytm': 'Paytm Bank',
    }[bank] ??
    bank.toUpperCase();

/// Only the source account and exact beneficiary define the relationship.
/// Amounts, dates and references must not join two separate payments together.
String? selfTransferKey(String sender, String body) {
  final source = RegExp(
    r'\bfrom\b[^\n]*?\b(?:a/c|account)\s*(?:(?:no\.?|number)\s*)?'
    r'(?:(?:ending|last\s*4)\s*(?:with|in)?\s*)?[*xX. -]*(\d{4})\b',
    caseSensitive: false,
  ).firstMatch(body);
  if (source == null) return null;
  final after = body.substring(source.end);
  final recipient = RegExp(
    r'\bto\s+([A-Za-z][A-Za-z0-9 .&\x27/-]{1,100}?)(?=\s+\b(?:on|ref(?:erence)?|refno|txn|not\s+you|call|sms\s+block|via|upi|bal(?:ance)?|available|avl)\b|\s+[*xX-]*\d{4}\b|[.,;]|$)',
    caseSensitive: false,
  ).firstMatch(after)?.group(1);
  if (recipient == null || sender.trim().isEmpty) return null;
  return jsonEncode([
    selfTransferSender(sender),
    source.group(1),
    recipient.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase(),
  ]);
}

/// The server sync snapshot already contains the normalized identity, so it
/// can be converted to the same local key without retaining SMS text.
String selfTransferIdentityKey({
  required String sourceSender,
  required String sourceAccountLast4,
  required String party,
}) => jsonEncode([
  selfTransferSender(sourceSender),
  sourceAccountLast4,
  party.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase(),
]);
