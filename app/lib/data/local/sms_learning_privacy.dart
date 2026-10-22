/// Redacts optional learning evidence before it enters a durable outbox or
/// leaves the device. Typed facts and source-key hashes remain useful even
/// when the provider does not need the example text.
String? redactSmsLearningText(String? value) {
  if (value == null || value.trim().isEmpty) return null;
  var text = value.trim();
  text = text.replaceAll(RegExp(r'https?://\S+', caseSensitive: false), '[URL]');
  text = text.replaceAll(RegExp(r'\b[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}\b'), '[EMAIL]');
  text = text.replaceAll(RegExp(r'(?<!\d)(?:\+?\d[\d\s().-]{7,}\d)(?!\d)'), '[PHONE]');
  // Keep only the last four digits when a message contains a long account,
  // card, reference, or identifier value. Short money amounts are left intact
  // because corrections may need to distinguish total vs minimum due.
  text = text.replaceAllMapped(RegExp(r'(?<!\d)\d{8,}(?!\d)'), (match) {
    final digits = match.group(0)!;
    return 'XXXX${digits.substring(digits.length - 4)}';
  });
  return text.length <= 1200 ? text : '${text.substring(0, 1200)}…';
}
