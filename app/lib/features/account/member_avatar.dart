import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'avatar_providers.dart';
import 'user_avatar.dart';

/// Another person's avatar next to their name (Split rosters and the like).
///
/// Draws the initial straight away and swaps in the preset or photo when the
/// server returns one, at the same fixed [size], so nothing shifts when it
/// loads. People without a [profileId] (invited, not yet joined) and any
/// failure just keep the initial. [self] reuses the signed-in person's own
/// avatar instead of asking the server.
class MemberAvatar extends StatelessWidget {
  final String? profileId;
  final String name;
  final double size;
  final bool self;

  const MemberAvatar({
    super.key,
    required this.profileId,
    required this.name,
    this.size = 40,
    this.self = false,
  });

  @override
  Widget build(BuildContext context) {
    final id = profileId;
    // Screens built without a provider scope (isolated widget tests) and
    // people without an account have nothing to look up.
    final hasScope = context.getInheritedWidgetOfExactType<UncontrolledProviderScope>() != null;
    if (!hasScope || (!self && (id == null || id.isEmpty))) return _draw(null);
    return _Loaded(profileId: id ?? '', self: self, name: name, size: size);
  }

  UserAvatar _draw(AvatarState? state) => UserAvatar(
    name: name,
    preset: state?.preset,
    photo: state?.photo,
    size: size,
    radiusFactor: 0.5,
  );
}

class _Loaded extends ConsumerWidget {
  final String profileId;
  final bool self;
  final String name;
  final double size;
  const _Loaded({required this.profileId, required this.self, required this.name, required this.size});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = self
        ? ref.watch(avatarProvider).valueOrNull
        : ref.watch(memberAvatarProvider(profileId)).valueOrNull;
    return UserAvatar(
      name: name,
      preset: state?.preset,
      photo: state?.photo,
      size: size,
      radiusFactor: 0.5,
    );
  }
}

/// Whether [profileName] is worth showing under [savedName]: it exists and is a
/// different name (ignoring letter case and extra spaces).
bool profileNameDiffers(String savedName, String? profileName) {
  if (profileName == null) return false;
  String norm(String v) => v.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
  final other = norm(profileName);
  return other.isNotEmpty && other != norm(savedName);
}

/// A small "PandaPay name: X" line under the name the signed-in person saved for
/// someone. Shown only when that person's own name differs from the saved one, so
/// the saved name stays the main name and the real name is still recognisable.
/// Nothing is drawn while loading, on any failure, with no account, or without a
/// provider scope: it is a hint, never an error.
class MemberProfileNameLine extends StatelessWidget {
  final String? profileId;
  final String savedName;
  final TextStyle? style;

  const MemberProfileNameLine({
    super.key,
    required this.profileId,
    required this.savedName,
    this.style,
  });

  @override
  Widget build(BuildContext context) {
    final id = profileId;
    final hasScope = context.getInheritedWidgetOfExactType<UncontrolledProviderScope>() != null;
    if (!hasScope || id == null || id.isEmpty) return const SizedBox.shrink();
    return _ProfileNameLoaded(profileId: id, savedName: savedName, style: style);
  }
}

class _ProfileNameLoaded extends ConsumerWidget {
  final String profileId;
  final String savedName;
  final TextStyle? style;
  const _ProfileNameLoaded({required this.profileId, required this.savedName, required this.style});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name = ref.watch(memberProfileNameProvider(profileId)).valueOrNull;
    if (!profileNameDiffers(savedName, name)) return const SizedBox.shrink();
    return Text(
      'PandaPay name: $name',
      key: ValueKey('member-profile-name-$profileId'),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: style,
    );
  }
}
