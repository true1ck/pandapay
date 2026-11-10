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
  s = s.trim();
  final hadPrefix = _operatorPrefix.hasMatch(s);
  s = s.replaceFirst(_operatorPrefix, '');
  final hadSuffix = _operatorSuffix.hasMatch(s);
  s = s.replaceFirst(_operatorSuffix, '');
  var brand = resolveBrandAlias(s, senders);
  if (!_isRegistered(brand, senders)) {
    brand = _registeredWithoutDashes(s, hadPrefix, hadSuffix, senders) ?? brand;
  }
  return NormalizedSender(brand: brand, iosFilter: filter);
}

bool _isRegistered(String brand, Iterable<SenderEntry> senders) {
  for (final e in senders) {
    if (e.brand == brand) return true;
    for (final a in e.aliases) {
      if (a.toUpperCase() == brand) return true;
    }
  }
  return false;
}

/// Some phones, backups and apps hand over the header without its dashes
/// (`VASDCCBKS` for `VA-SDCCBK-S`, `VMSDPTCS` for `VM-SDPTCS`). The operator
/// prefix is two letters and the suffix one of S, T, P, G, but without the
/// dashes a registry-free guess would cut real brands. So the cut is only taken
/// when what is left is a brand (or alias) the bundle already knows, and only
/// the affix that was not already removed. An unknown header stays as it is.
String? _registeredWithoutDashes(
  String s,
  bool hadPrefix,
  bool hadSuffix,
  Iterable<SenderEntry> senders,
) {
  if (senders.isEmpty) return null;
  final canPrefix = !hadPrefix && s.length >= 6;
  final canSuffix = !hadSuffix && s.length >= 5 && 'STPG'.contains(s[s.length - 1]);
  final candidates = <String>[
    if (canPrefix && canSuffix) s.substring(2, s.length - 1),
    if (canPrefix) s.substring(2),
    if (canSuffix) s.substring(0, s.length - 1),
  ];
  for (final c in candidates) {
    if (c.length >= 4 && _isRegistered(c, senders)) return resolveBrandAlias(c, senders);
  }
  return null;
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
