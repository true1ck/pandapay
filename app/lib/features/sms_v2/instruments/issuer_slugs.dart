import '../../../data/local/financial_store.dart' show canonicalBankSender;

/// Today's canonical bank codes that differ from the v2 `issuerSlug` in
/// `rules/sms/v2/senders`.
const Map<String, String> _legacyToV2 = {
  'indus': 'indusind',
  'aubank': 'au',
  'scb': 'sc',
};

final Map<String, String> _v2ToLegacy = {
  for (final e in _legacyToV2.entries) e.value: e.key,
};

/// Issuer names (as the card catalogue spells them) that
/// [canonicalBankSender] does not reduce to the v2 slug.
const Map<String, String> _issuerNameAliases = {
  'american express': 'amex',
  'amex': 'amex',
  'state bank of india': 'sbi',
  'bank of baroda': 'bob',
  'bank of india': 'boi',
  'punjab national bank': 'pnb',
  'standard chartered': 'sc',
  'au small finance bank': 'au',
  'idfc first bank': 'idfc',
  'idfc first': 'idfc',
  'indusind bank': 'indusind',
  'canara bank': 'canara',
  'union bank of india': 'union',
  'kotak mahindra bank': 'kotak',
  'federal bank': 'federal',
};

String _plainSlug(String text) => text
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
    .replaceAll(RegExp(r'^_+|_+$'), '');

/// The v2 `issuerSlug` for today's bank code (`canonicalBankSender` output):
/// `indus` becomes `indusind`, the rest are unchanged.
String v2IssuerSlugFromLegacyCode(String code) => _legacyToV2[code] ?? code;

/// Today's bank code for a v2 `issuerSlug`, so the adapter can return the same
/// `issuerSlug` and display label the current Home screen shows.
String legacyBankCodeFromV2Slug(String slug) => _v2ToLegacy[slug] ?? slug;

/// The v2 `issuerSlug` for an issuer name or sender token as written in the
/// card catalogue or a `BankAccountSummary`. Null when it names nothing.
String? v2IssuerSlugFromName(String? name) {
  final text = name?.trim();
  if (text == null || text.isEmpty) return null;
  final alias = _issuerNameAliases[text.toLowerCase()];
  if (alias != null) return alias;
  final code = canonicalBankSender(text);
  if (code == 'unknown') return null;
  final slug = _legacyToV2[code] ?? code;
  // A name no bank code recognises ("Some Co-op Bank") keeps its plain slug.
  final plain = _plainSlug(slug);
  return plain.isEmpty ? null : plain;
}
