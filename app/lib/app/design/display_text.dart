/// Converts catalogue and enum identifiers into readable product copy.
///
/// Storage/API values stay snake_case; only strings that cross into the UI
/// should use this helper. Natural-language labels are returned unchanged so
/// issuer-provided descriptions keep their original wording.
String humanizeIdentifier(String? value, {String fallback = '—'}) {
  final raw = value?.trim();
  if (raw == null || raw.isEmpty) return fallback;

  final hasIdentifierShape =
      raw.contains('_') ||
      raw.contains('-') ||
      (!raw.contains(' ') && RegExp(r'[a-z0-9][A-Z]').hasMatch(raw));
  if (!hasIdentifierShape) return raw;

  final spaced = raw
      .replaceAllMapped(RegExp(r'([a-z0-9])([A-Z])'), (m) => '${m[1]} ${m[2]}')
      .replaceAll(RegExp(r'[_-]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  const overrides = <String, String>{
    'api': 'API',
    'hdfc': 'HDFC',
    'icici': 'ICICI',
    'pnb': 'PNB',
    'rupay': 'RuPay',
    'sms': 'SMS',
    'upi': 'UPI',
    'visa': 'Visa',
  };
  const lowerCaseJoiners = {'and', 'or', 'of', 'on', 'per', 'to', 'in'};
  final words = spaced.split(' ');
  return [
    for (var i = 0; i < words.length; i++)
      overrides[words[i].toLowerCase()] ??
          (i > 0 && lowerCaseJoiners.contains(words[i].toLowerCase())
              ? words[i].toLowerCase()
              : _titleCaseWord(words[i])),
  ].join(' ');
}

String _titleCaseWord(String word) {
  if (word.isEmpty) return word;
  return '${word[0].toUpperCase()}${word.substring(1).toLowerCase()}';
}
