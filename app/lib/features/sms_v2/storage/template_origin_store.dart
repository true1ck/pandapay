import 'dart:convert';

import 'sync_state_store.dart';

/// Device-only links from a shared, redacted format to this account's original
/// format hashes. Neither raw text nor original hashes enter the upload queue.
class TemplateOriginStore {
  const TemplateOriginStore(this.state);
  final SyncStateStore state;

  static const maxOrigins = 32;
  static final _hash = RegExp(r'^[a-f0-9]{64}$');
  static final _brand = RegExp(r'^[A-Z0-9]{1,32}$');

  bool remember({
    required String remoteHash,
    required String localHash,
    required String senderBrand,
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
    hashes.add(localHash);
    state.put(
      'template:origins:$remoteHash',
      jsonEncode({
        'senderBrand': senderBrand,
        'localHashes': hashes.toList()..sort(),
      }),
    );
    return true;
  }

  ({String senderBrand, List<String> localHashes})? get(String remoteHash) {
    if (!_hash.hasMatch(remoteHash)) return null;
    final raw = state.get('template:origins:$remoteHash');
    if (raw == null) return null;
    try {
      final value = jsonDecode(raw) as Map;
      final brand = value['senderBrand'] as String;
      final hashes = (value['localHashes'] as List).cast<String>();
      if (!_brand.hasMatch(brand) ||
          hashes.isEmpty ||
          hashes.length > maxOrigins ||
          hashes.any((hash) => !_hash.hasMatch(hash))) {
        return null;
      }
      return (senderBrand: brand, localHashes: hashes.toSet().toList()..sort());
    } catch (_) {
      return null;
    }
  }
}
