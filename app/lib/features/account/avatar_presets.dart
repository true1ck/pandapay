import 'package:flutter/material.dart';

/// One of the avatars a person can pick without uploading anything. The server
/// stores only [id], so the set is fixed: every id here must be in `PRESETS` in
/// auth/src/services/userAvatar.js, or a pick is refused.
///
/// An avatar is drawn from either an [asset] (the panda illustrations the picker
/// offers) or an [icon] (the older symbol avatars, kept so anyone who already
/// picked one still sees it).
class AvatarPreset {
  final String id;
  final String label;
  final String? asset;
  final IconData? icon;
  final Color background;
  final Color foreground;

  const AvatarPreset({
    required this.id,
    required this.label,
    this.asset,
    this.icon,
    required this.background,
    this.foreground = Colors.transparent,
  }) : assert(asset != null || icon != null, 'an avatar needs an asset or an icon');
}

/// Warm paper, the same tone as the app's cards, behind every panda.
const Color _pandaTile = Color(0xFFF7F6F0);

AvatarPreset _panda(String id, String label) =>
    AvatarPreset(id: id, label: label, asset: 'assets/avatars/$id.webp', background: _pandaTile);

/// What the picker offers, in order. The art lives in `assets/avatars/{id}.webp`.
final List<AvatarPreset> avatarPresets = List.unmodifiable([
  _panda('cool', 'Cool panda'),
  _panda('coin', 'Coin panda'),
  _panda('explorer', 'Explorer panda'),
  _panda('snack', 'Bamboo snack panda'),
  _panda('verified', 'Laptop panda'),
  _panda('party', 'Party panda'),
  _panda('phone', 'Phone panda'),
  _panda('sleepy', 'Sleepy panda'),
  _panda('hero', 'Hero panda'),
  _panda('shopper', 'Shopper panda'),
  _panda('secure', 'Secure panda'),
  _panda('music', 'Music panda'),
]);

/// The symbol avatars from before. Not offered any more, but still drawn, so
/// nobody who picked one is left with a blank avatar. `panda` was the paw: it now
/// shows the party panda.
final List<AvatarPreset> legacyAvatarPresets = List.unmodifiable([
  _panda('panda', 'Panda').withArt('party'),
  const AvatarPreset(id: 'bamboo', label: 'Bamboo', icon: Icons.eco_rounded, background: Color(0xFF1F6B4A), foreground: Color(0xFFE4F2CF)),
  const AvatarPreset(id: 'sun', label: 'Sunrise', icon: Icons.wb_sunny_rounded, background: Color(0xFFF2B33D), foreground: Color(0xFF3A2A06)),
  const AvatarPreset(id: 'wave', label: 'Wave', icon: Icons.water_drop_rounded, background: Color(0xFF2B7BB9), foreground: Color(0xFFEAF5FD)),
  const AvatarPreset(id: 'berry', label: 'Berry', icon: Icons.favorite_rounded, background: Color(0xFFB8325A), foreground: Color(0xFFFFE9F0)),
  const AvatarPreset(id: 'forest', label: 'Forest', icon: Icons.park_rounded, background: Color(0xFF2F5D3A), foreground: Color(0xFFD9F0C2)),
  const AvatarPreset(id: 'dusk', label: 'Dusk', icon: Icons.star_rounded, background: Color(0xFF6A4BA8), foreground: Color(0xFFF1EAFF)),
  const AvatarPreset(id: 'night', label: 'Night', icon: Icons.nightlight_round, background: Color(0xFF262B33), foreground: Color(0xFFAEB8C2)),
]);

extension on AvatarPreset {
  /// The same avatar id drawn with another panda's art.
  AvatarPreset withArt(String artId) =>
      AvatarPreset(id: id, label: label, asset: 'assets/avatars/$artId.webp', background: background);
}

AvatarPreset? avatarPresetFor(String? id) {
  if (id == null) return null;
  for (final preset in avatarPresets) {
    if (preset.id == id) return preset;
  }
  for (final preset in legacyAvatarPresets) {
    if (preset.id == id) return preset;
  }
  return null;
}
