import 'catalogue_repository.dart' show SpendCategory;

/// High-confidence MCC-to-PandaPay category hints for merchant QR codes.
///
/// A QR MCC is stronger evidence than a merchant-name substring, but it is
/// not available for every QR and some providers use broad/general codes.
/// Therefore this intentionally returns null for unknown or ambiguous MCCs;
/// the server-side merchant resolver remains the final fallback.
String? categorySlugForUpiMcc(String? rawMcc) {
  final mcc = int.tryParse(rawMcc ?? '');
  if (mcc == null) return null;

  return switch (mcc) {
    5541 || 5542 => 'fuel',
    5411 || 5422 || 5441 || 5451 || 5462 || 5499 => 'groceries',
    5812 || 5813 || 5814 => 'dining',
    4111 || 4121 || 4131 || 4789 || 7011 => 'travel',
    4812 || 4814 || 4899 || 4900 => 'bills',
    5912 ||
    8011 ||
    8021 ||
    8031 ||
    8041 ||
    8042 ||
    8043 ||
    8049 ||
    8050 ||
    8062 ||
    8099 => 'health',
    5815 ||
    5816 ||
    5817 ||
    5818 ||
    7832 ||
    7922 ||
    7929 ||
    7932 ||
    7933 ||
    7941 ||
    7991 ||
    7993 ||
    7994 ||
    7995 ||
    7996 ||
    7997 ||
    7998 ||
    7999 => 'entertainment',
    8211 || 8220 || 8241 || 8244 || 8249 || 8299 => 'education',
    6300 => 'insurance',
    5311 ||
    5399 ||
    5611 ||
    5621 ||
    5631 ||
    5641 ||
    5651 ||
    5661 ||
    5691 ||
    5699 ||
    5732 ||
    5734 ||
    5940 ||
    5941 ||
    5942 ||
    5943 ||
    5944 ||
    5945 ||
    5946 ||
    5947 ||
    5948 ||
    5949 ||
    5999 => 'online',
    _ => null,
  };
}

String? categoryIdForUpiMcc(String? rawMcc, List<SpendCategory> categories) {
  final slug = categorySlugForUpiMcc(rawMcc);
  if (slug == null) return null;
  return categories.where((category) => category.slug == slug).firstOrNull?.id;
}

extension on Iterable<SpendCategory> {
  SpendCategory? get firstOrNull => isEmpty ? null : first;
}
