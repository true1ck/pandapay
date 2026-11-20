import 'dart:convert';

import 'sync_state_store.dart';

/// Device-only links from a shared, redacted format to this account's original
/// format hashes. Neither raw text nor original hashes enter the upload queue.
class TemplateOriginStore {
  const TemplateOriginStore(this.state);
  final SyncStateStore state;

  /// Original wordings (local hashes) remembered per shared layout. A draft is applied here to exactly these
  /// wordings, one private copy of its rule each, so a layout whose wording varies with the shop or the person
  /// (one bank template, hundreds of shops) needs one entry per variant. It was 32, and every variant after the
  /// 32nd stayed unread by its own draft for good.
  ///
  /// 128: each entry is one more private copy of the rule in the overlay (about 0.14 ms to build on a desktop, so 128
  /// copies of 20 layouts is about 0.4 s once, per change of a draft, off the sync path thanks to the overlay cache)
  /// and 67 bytes in the stored record (at most 8.6 KB, written only when a new wording is first seen). A layout
  /// that needs more than 128 wordings is a rule for the shared bundle, not a private draft; wordings beyond the
  /// bound are not remembered and the message is not looked at again.
  static const maxOrigins = 128;
  static final _hash = RegExp(r'^[a-f0-9]{64}$');
  static final _brand = RegExp(r'^[A-Z0-9]{1,32}$');

  /// Whether the origin of [remoteHash] already holds [localHash] or has room for it.
  bool hasRoomFor(String remoteHash, String localHash) {
    final previous = get(remoteHash);
    return previous == null ||
        previous.localHashes.contains(localHash) ||
        previous.localHashes.length < maxOrigins;
  }

  /// [senderBrand] is the brand the layout is filed under (the shape the server takes: letters and digits).
  /// [localBrand] is the brand this phone reads the messages under, when it differs (`SBI-UPI` is filed as
  /// `SBIUPI`); the private copy of a draft must carry that one to match.
  bool remember({
    required String remoteHash,
    required String localHash,
    required String senderBrand,
    String? localBrand,
  }) {
    if (!_hash.hasMatch(remoteHash) ||
        !_hash.hasMatch(localHash) ||
        !_brand.hasMatch(senderBrand)) {
      return false;
    }
    final previous = get(remoteHash);
    if (previous != null && previous.senderBrand != senderBrand) return false;
    final hashes = {...?previous?.localHashes};
    if (!hashes.contains(localHash) && hashes.length >= maxOrigins) {
      return false;
    }
    final brands = {
      ...?previous?.localBrands.skip(1),
      if (localBrand != null && localBrand != senderBrand && localBrand.isNotEmpty && localBrand.length <= 40)
        localBrand,
    };
    final isNew = !hashes.contains(localHash);
    // Nothing to write: a pass that sees a known wording again leaves the stored record (and so everything keyed on
    // it) exactly as it was.
    if (previous != null && !isNew && brands.length == previous.localBrands.length - 1) return true;
    hashes.add(localHash);
    state.put(
      'template:origins:$remoteHash',
      jsonEncode({
        'senderBrand': senderBrand,
        'localHashes': hashes.toList()..sort(),
        if (brands.isNotEmpty) 'localBrands': brands.toList()..sort(),
      }),
    );
    return true;
  }

  ({String senderBrand, List<String> localHashes, List<String> localBrands})? get(String remoteHash) {
    if (!_hash.hasMatch(remoteHash)) return null;
    final raw = state.get('template:origins:$remoteHash');
    return raw == null ? null : parse(raw);
  }

  /// Reads a stored origin record; null when it is damaged. [localBrands] always holds the layout's own brand and any
  /// other header the messages were read under.
  ({String senderBrand, List<String> localHashes, List<String> localBrands})? parse(String raw) {
    try {
      final value = jsonDecode(raw) as Map;
      final brand = value['senderBrand'] as String;
      final hashes = (value['localHashes'] as List).cast<String>();
      final extra = ((value['localBrands'] as List?) ?? const []).cast<String>();
      if (!_brand.hasMatch(brand) ||
          hashes.isEmpty ||
          hashes.length > maxOrigins ||
          extra.length > 8 ||
          hashes.any((hash) => !_hash.hasMatch(hash))) {
        return null;
      }
      return (
        senderBrand: brand,
        localHashes: hashes.toSet().toList()..sort(),
        localBrands: [brand, ...extra.where((b) => b != brand)],
      );
    } catch (_) {
      return null;
    }
  }
}
