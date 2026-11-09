/// Checks a typed Indian mobile number the same way the server does, so an
/// obviously wrong entry gets a message before a round trip. The server is still
/// the authority.
///
/// Accepts `9876543210`, `98765 43210`, `+91 98765 43210`, `09876543210` and
/// `919876543210`. Returns the ten digits, or null when it is not a valid number.
String? indianMobileDigits(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty || !RegExp(r'^\+?[\d\s().-]+$').hasMatch(trimmed)) {
    return null;
  }
  var digits = trimmed.replaceAll(RegExp(r'\D'), '');
  if (trimmed.startsWith('+')) {
    if (!digits.startsWith('91')) return null;
    digits = digits.substring(2);
  } else if (digits.startsWith('00') && digits.length > 2) {
    digits = digits.substring(2);
    if (!digits.startsWith('91')) return null;
    digits = digits.substring(2);
  } else if (digits.length == 12 && digits.startsWith('91')) {
    digits = digits.substring(2);
  } else if (digits.length == 11 && digits.startsWith('0')) {
    digits = digits.substring(1);
  }
  if (!RegExp(r'^[6-9]\d{9}$').hasMatch(digits)) return null;
  if (RegExp(r'^(\d)\1+$').hasMatch(digits)) return null;
  return digits;
}

/// The message to show next to the field, or null when the number looks fine.
String? indianMobileError(String raw) {
  if (raw.trim().isEmpty) return 'Enter your mobile number.';
  if (indianMobileDigits(raw) == null) {
    return 'Enter a valid 10-digit Indian mobile number.';
  }
  return null;
}
