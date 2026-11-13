import 'package:flutter/material.dart';

import '../../app/design/app_theme.dart';

/// One of the avatars a person can pick without uploading anything. The server
/// stores only [id], so the set is fixed: it must match `PRESETS` in
/// auth/src/services/userAvatar.js, or a pick is refused.
class AvatarPreset {
  final String id;
  final String label;
  final IconData icon;
  final Color background;
  final Color foreground;

  const AvatarPreset({
    required this.id,
    required this.label,
    required this.icon,
    required this.background,
    required this.foreground,
  });
}

const List<AvatarPreset> avatarPresets = [
  AvatarPreset(id: 'panda', label: 'Panda', icon: Icons.pets_rounded, background: BambooInk.slate, foreground: BambooInk.lime),
  AvatarPreset(id: 'bamboo', label: 'Bamboo', icon: Icons.eco_rounded, background: Color(0xFF1F6B4A), foreground: Color(0xFFE4F2CF)),
  AvatarPreset(id: 'sun', label: 'Sunrise', icon: Icons.wb_sunny_rounded, background: Color(0xFFF2B33D), foreground: Color(0xFF3A2A06)),
  AvatarPreset(id: 'wave', label: 'Wave', icon: Icons.water_drop_rounded, background: Color(0xFF2B7BB9), foreground: Color(0xFFEAF5FD)),
  AvatarPreset(id: 'berry', label: 'Berry', icon: Icons.favorite_rounded, background: Color(0xFFB8325A), foreground: Color(0xFFFFE9F0)),
  AvatarPreset(id: 'forest', label: 'Forest', icon: Icons.park_rounded, background: Color(0xFF2F5D3A), foreground: Color(0xFFD9F0C2)),
  AvatarPreset(id: 'dusk', label: 'Dusk', icon: Icons.star_rounded, background: Color(0xFF6A4BA8), foreground: Color(0xFFF1EAFF)),
  AvatarPreset(id: 'night', label: 'Night', icon: Icons.nightlight_round, background: Color(0xFF262B33), foreground: Color(0xFFAEB8C2)),
];

AvatarPreset? avatarPresetFor(String? id) {
  if (id == null) return null;
  for (final preset in avatarPresets) {
    if (preset.id == id) return preset;
  }
  return null;
}
