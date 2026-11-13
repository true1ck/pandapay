import 'package:flutter/material.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/bamboo_components.dart';
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
  return showBambooSheet<AvatarChoice>(
    context: context,
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
    return BambooSheet(
      title: 'Choose your avatar',
      subtitle:
          'Your photo is private unless you turn on sharing in Edit profile. Others see your avatar or your initial.',
      actions: [
        _SheetButton(
          key: const Key('avatar-gallery'),
          icon: Icons.photo_library_outlined,
          label: 'Choose a photo',
          onPressed: () => Navigator.of(context).pop(const ChoosePhoto(AvatarPhotoSource.gallery)),
        ),
        _SheetButton(
          key: const Key('avatar-camera'),
          icon: Icons.photo_camera_outlined,
          label: 'Take a photo',
          onPressed: () => Navigator.of(context).pop(const ChoosePhoto(AvatarPhotoSource.camera)),
        ),
        if (hasPhoto)
          _SheetButton(
            key: const Key('avatar-remove-photo'),
            icon: Icons.delete_outline_rounded,
            label: 'Remove my photo',
            onPressed: () => Navigator.of(context).pop(const RemovePhoto()),
          ),
        if (hasPhoto || currentPreset != null)
          _SheetButton(
            key: const Key('avatar-use-initial'),
            icon: Icons.abc_rounded,
            label: 'Use my initial (${name.trim().isEmpty ? '?' : name.trim().characters.first.toUpperCase()})',
            onPressed: () => Navigator.of(context).pop(const UseInitial()),
          ),
      ],
      children: [
        _PresetCarousel(
          currentPreset: hasPhoto ? null : currentPreset,
          onPick: (id) => Navigator.of(context).pop(ChoosePreset(id)),
        ),
      ],
    );
  }
}

/// The avatars in one row, five to a page, that scrolls sideways and snaps page by
/// page. Arrows and dots show there is more. Every tile is built up front (a dozen
/// small images), so none is missing from the tree while off screen.
class _PresetCarousel extends StatefulWidget {
  final String? currentPreset;
  final ValueChanged<String> onPick;
  const _PresetCarousel({required this.currentPreset, required this.onPick});

  @override
  State<_PresetCarousel> createState() => _PresetCarouselState();
}

class _PresetCarouselState extends State<_PresetCarousel> {
  static const int _perPage = 5;
  static final int _pages = (avatarPresets.length / _perPage).ceil();

  final ScrollController _controller = ScrollController();
  double _tile = 0;
  int _page = 0;
  bool _placed = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onScroll);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_controller.hasClients || _tile == 0) return;
    final pos = _controller.position;
    final page = pos.pixels >= pos.maxScrollExtent - 1
        ? _pages - 1
        : (pos.pixels / (_tile * _perPage)).round().clamp(0, _pages - 1);
    if (page != _page) setState(() => _page = page);
  }

  void _go(int page) {
    if (!_controller.hasClients) return;
    _controller.animateTo(
      (page * _tile * _perPage).clamp(0, _controller.position.maxScrollExtent),
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        _tile = box.maxWidth / _perPage;
        if (!_placed) {
          _placed = true;
          final index = avatarPresets.indexWhere((p) => p.id == widget.currentPreset);
          if (index >= _perPage) {
            _page = index ~/ _perPage;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!_controller.hasClients) return;
              _controller.jumpTo(
                (_page * _tile * _perPage).clamp(0, _controller.position.maxScrollExtent),
              );
            });
          }
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              key: const Key('avatar-carousel'),
              height: _tile,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  SingleChildScrollView(
                    controller: _controller,
                    scrollDirection: Axis.horizontal,
                    physics: const PageScrollPhysics(),
                    child: Row(
                      children: [
                        for (final p in avatarPresets)
                          SizedBox(
                            width: _tile,
                            child: Center(child: _tileFor(p, _tile - 4)),
                          ),
                      ],
                    ),
                  ),
                  if (_page > 0)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: _Arrow(icon: Icons.chevron_left_rounded, onTap: () => _go(_page - 1)),
                    ),
                  if (_page < _pages - 1)
                    Align(
                      alignment: Alignment.centerRight,
                      child: _Arrow(icon: Icons.chevron_right_rounded, onTap: () => _go(_page + 1)),
                    ),
                ],
              ),
            ),
            const SizedBox(height: AppSpace.md),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < _pages; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    width: i == _page ? 18 : 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: i == _page ? BambooInk.slate : BambooInk.hairlineOnPaper,
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                    ),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _tileFor(AvatarPreset preset, double size) => _PresetTile(
    preset: preset,
    size: size,
    selected: widget.currentPreset == preset.id,
    onTap: () => widget.onPick(preset.id),
  );
}

class _Arrow extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _Arrow({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      width: 30,
      height: 30,
      decoration: BoxDecoration(
        color: BambooInk.paper,
        shape: BoxShape.circle,
        border: Border.all(color: BambooInk.hairlineOnPaper),
        boxShadow: [BoxShadow(color: BambooInk.slate.withValues(alpha: 0.12), blurRadius: 6)],
      ),
      child: Icon(icon, size: 20, color: BambooInk.ink900),
    ),
  );
}

class _PresetTile extends StatelessWidget {
  final AvatarPreset preset;
  final bool selected;
  final VoidCallback onTap;
  final double size;
  const _PresetTile({required this.preset, required this.selected, required this.onTap, required this.size});

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
          child: UserAvatar(name: '', preset: preset.id, size: size - 10),
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
