import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../app/design/app_theme.dart';
import 'avatar_presets.dart';

/// A person's avatar. In order of preference: their photo, their chosen preset,
/// then the first letter of their name (what everyone had before avatars).
class UserAvatar extends StatelessWidget {
  final String name;
  final String? preset;
  final Uint8List? photo;
  final double size;

  /// Corner radius as a fraction of [size]; the app's tiles are rounded squares.
  final double radiusFactor;

  const UserAvatar({
    super.key,
    required this.name,
    this.preset,
    this.photo,
    this.size = 56,
    this.radiusFactor = 0.32,
  });

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(size * radiusFactor);
    final chosen = avatarPresetFor(preset);
    final initial = name.trim().isEmpty ? '?' : name.trim().characters.first.toUpperCase();

    final Widget content;
    Color background = BambooInk.lime;
    if (photo != null) {
      content = Image.memory(
        photo!,
        width: size,
        height: size,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        // A corrupt photo must never break the screen: fall back to the letter.
        errorBuilder: (_, _, _) => _letter(initial),
      );
    } else if (chosen != null) {
      background = chosen.background;
      final asset = chosen.asset;
      content = asset != null
          ? Image.asset(
              asset,
              width: size,
              height: size,
              fit: BoxFit.cover,
              // Decode at the size it is drawn, not the 384 px the art ships at:
              // lists of friends would otherwise hold a full image each.
              cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).round(),
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => _letter(initial),
            )
          : Icon(chosen.icon, size: size * 0.5, color: chosen.foreground);
    } else {
      content = _letter(initial);
    }

    return Semantics(
      label: 'Avatar for ${name.trim().isEmpty ? 'your account' : name.trim()}',
      image: true,
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(color: background, borderRadius: radius),
        child: content,
      ),
    );
  }

  Widget _letter(String initial) => Text(
    initial,
    style: BambooFonts.heading(size * 0.4, weight: FontWeight.w800, color: BambooInk.slate),
  );
}
