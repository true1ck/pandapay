import '../contract/rule_bundle.dart';

/// Result of [normalizeSenderBrand].
class NormalizedSender {
  const NormalizedSender({required this.brand, this.iosFilter});

  /// Canonical brand: upper case, no operator prefix or suffix, aliases
  /// resolved through `bundle.senders`.
  final String brand;

  /// The iOS filter tag without parentheses (`smsft_fi`), or null.
  final String? iosFilter;
}

final RegExp _iosFilterTag = RegExp(r'\s*\(([^)]*)\)\s*$');
final RegExp _operatorPrefix = RegExp(r'^[A-Z]{2}-');
final RegExp _operatorSuffix = RegExp(r'-[STPG]$');

/// Normalises a raw sender (`VM-HDFCBK-S`, `AD-SBIUPI (smsft_fi)`) to a brand.
/// This is the only implementation in the codebase.
///
/// [senders] are the bundle's sender entries; a brand that matches an alias
/// becomes the entry's own brand.
NormalizedSender normalizeSenderBrand(String sender, [Iterable<SenderEntry> senders = const []]) {
  var s = sender.trim().toUpperCase();
  String? filter;
  final tag = _iosFilterTag.firstMatch(s);
  if (tag != null) {
    final raw = tag.group(1)!.trim().toLowerCase();
    filter = raw.isEmpty ? null : raw;
    s = s.substring(0, tag.start);
  }
  s = s.trim().replaceFirst(_operatorPrefix, '').replaceFirst(_operatorSuffix, '');
  return NormalizedSender(brand: resolveBrandAlias(s, senders), iosFilter: filter);
}

/// Resolves [brand] through the aliases of [senders].
String resolveBrandAlias(String brand, Iterable<SenderEntry> senders) {
  for (final e in senders) {
    if (e.brand == brand) return brand;
  }
  for (final e in senders) {
    for (final a in e.aliases) {
      if (a.toUpperCase() == brand) return e.brand;
    }
  }
  return brand;
}
