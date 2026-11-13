import 'package:flutter/material.dart';

import '../../app/design/app_theme.dart';
import 'avatar_presets.dart';
import 'avatar_providers.dart';
import 'user_avatar.dart';

/// What the person chose in [showAvatarPickerSheet].
sealed class AvatarChoice {
  const AvatarChoice();
}

/// A preset avatar. Choosing one replaces any photo.
class ChoosePreset extends AvatarChoice {
  final String id;
  const ChoosePreset(this.id);
}

/// Go back to the initial letter: no preset and no photo.
class UseInitial extends AvatarChoice {
  const UseInitial();
}

class ChoosePhoto extends AvatarChoice {
  final AvatarPhotoSource source;
  const ChoosePhoto(this.source);
}

class RemovePhoto extends AvatarChoice {
  const RemovePhoto();
}

/// The avatar menu: the preset avatars, plus a photo from the gallery or camera.
Future<AvatarChoice?> showAvatarPickerSheet(
  BuildContext context, {
  required String name,
  required String? currentPreset,
  required bool hasPhoto,
}) {
  return showModalBottomSheet<AvatarChoice>(
    context: context,
    isScrollControlled: true,
    backgroundColor: BambooInk.paper,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (_) => _AvatarPickerSheet(name: name, currentPreset: currentPreset, hasPhoto: hasPhoto),
  );
}

class _AvatarPickerSheet extends StatelessWidget {
  final String name;
  final String? currentPreset;
  final bool hasPhoto;
  const _AvatarPickerSheet({required this.name, required this.currentPreset, required this.hasPhoto});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, AppSpace.lg, 20, AppSpace.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: BambooInk.hairlineOnPaper,
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                ),
              ),
            ),
            const SizedBox(height: AppSpace.lg),
            Text('Choose your avatar', style: BambooFonts.heading(20, color: BambooInk.ink900)),
            const SizedBox(height: AppSpace.xs),
            Text(
              'Your photo is private unless you turn on sharing in Edit profile. Others see your avatar or your initial.',
              style: BambooFonts.ui(13, color: BambooInk.ink500, height: 1.5),
            ),
            const SizedBox(height: AppSpace.lg),
            _PresetCarousel(
              currentPreset: hasPhoto ? null : currentPreset,
              onPick: (id) => Navigator.of(context).pop(ChoosePreset(id)),
            ),
            const SizedBox(height: AppSpace.xl),
            _SheetButton(
              key: const Key('avatar-gallery'),
              icon: Icons.photo_library_outlined,
              label: 'Choose a photo',
              onPressed: () => Navigator.of(context).pop(const ChoosePhoto(AvatarPhotoSource.gallery)),
            ),
            const SizedBox(height: AppSpace.sm),
            _SheetButton(
              key: const Key('avatar-camera'),
              icon: Icons.photo_camera_outlined,
              label: 'Take a photo',
              onPressed: () => Navigator.of(context).pop(const ChoosePhoto(AvatarPhotoSource.camera)),
            ),
            if (hasPhoto) ...[
              const SizedBox(height: AppSpace.sm),
              _SheetButton(
                key: const Key('avatar-remove-photo'),
                icon: Icons.delete_outline_rounded,
                label: 'Remove my photo',
                onPressed: () => Navigator.of(context).pop(const RemovePhoto()),
              ),
            ],
            if (hasPhoto || currentPreset != null) ...[
              const SizedBox(height: AppSpace.sm),
              _SheetButton(
                key: const Key('avatar-use-initial'),
                icon: Icons.abc_rounded,
                label: 'Use my initial (${name.trim().isEmpty ? '?' : name.trim().characters.first.toUpperCase()})',
                onPressed: () => Navigator.of(context).pop(const UseInitial()),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The avatars in two rows that scroll sideways together. The next column peeks in
/// at the edge so it is obvious there are more, and it opens already scrolled to the
/// person's current avatar. Every tile is built up front (a couple of dozen, each a
/// single emoji), so none is missing from the tree while off screen.
class _PresetCarousel extends StatefulWidget {
  final String? currentPreset;
  final ValueChanged<String> onPick;
  const _PresetCarousel({required this.currentPreset, required this.onPick});

  @override
  State<_PresetCarousel> createState() => _PresetCarouselState();
}

class _PresetCarouselState extends State<_PresetCarousel> {
  static const double _tile = 68; // avatar 58 + 3 padding + 2 border, each side
  static const double _gap = 12;
  static const double _rowGap = 12;

  late final ScrollController _controller;

  @override
  void initState() {
    super.initState();
    final index = avatarPresets.indexWhere((p) => p.id == widget.currentPreset);
    // Two avatars per column. Put the chosen one's column second from the left so a
    // neighbour is visible on each side.
    final column = index < 0 ? 0 : index ~/ 2;
    final offset = (column - 1) * (_tile + _gap);
    _controller = ScrollController(initialScrollOffset: offset < 0 ? 0 : offset);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final columns = <Widget>[];
    for (var i = 0; i < avatarPresets.length; i += 2) {
      if (columns.isNotEmpty) columns.add(const SizedBox(width: _gap));
      columns.add(
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _tileFor(avatarPresets[i]),
            if (i + 1 < avatarPresets.length) ...[
              const SizedBox(height: _rowGap),
              _tileFor(avatarPresets[i + 1]),
            ],
          ],
        ),
      );
    }
    return SizedBox(
      key: const Key('avatar-carousel'),
      height: _tile * 2 + _rowGap + 4,
      child: SingleChildScrollView(
        controller: _controller,
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: columns),
      ),
    );
  }

  Widget _tileFor(AvatarPreset preset) => _PresetTile(
    preset: preset,
    selected: widget.currentPreset == preset.id,
    onTap: () => widget.onPick(preset.id),
  );
}

class _PresetTile extends StatelessWidget {
  final AvatarPreset preset;
  final bool selected;
  final VoidCallback onTap;
  const _PresetTile({required this.preset, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: '${preset.label} avatar',
      child: GestureDetector(
        key: Key('avatar-preset-${preset.id}'),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: selected ? BambooInk.slate : Colors.transparent,
              width: 2,
            ),
          ),
          child: UserAvatar(name: '', preset: preset.id, size: 58),
        ),
      ),
    );
  }
}

/// A full-width button. It sits in a Column, never a Row or ListTile.trailing:
/// the app-wide button theme forces full width.
class _SheetButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  const _SheetButton({super.key, required this.icon, required this.label, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 20),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: BambooInk.ink900,
        backgroundColor: BambooInk.paperMuted,
        minimumSize: const Size.fromHeight(48),
        side: const BorderSide(color: BambooInk.hairlineOnPaper),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: BambooFonts.ui(14, weight: FontWeight.w700),
      ),
    );
  }
}
