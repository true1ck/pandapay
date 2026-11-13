import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../account/account_local_first.dart';
import '../../data/account_name_api.dart';
import '../../data/api_exception.dart';
import '../settings/feedback_support_screen.dart';
import '../settings/phone_change_screen.dart';
import 'avatar_photo_processor.dart';
import 'avatar_picker_sheet.dart';
import 'avatar_providers.dart';
import 'user_avatar.dart';

/// Edit profile: the name, the phone number, and the sign-in email (read-only).
///
/// - Name saves directly; it is not a credential.
/// - Phone is added or changed through [PhoneChangeScreen], which confirms with a
///   code sent to the sign-in email. The number is not shown as verified or not:
///   phone-ownership verification is a later feature.
/// - Email is the account's identity (sign-in codes, recovery, later billing), so
///   it can't be edited here. Support moves it after confirming from the old
///   address.
class EditProfileScreen extends ConsumerStatefulWidget {
  const EditProfileScreen({super.key});

  @override
  ConsumerState<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends ConsumerState<EditProfileScreen> {
  final _nameController = TextEditingController();
  bool _seeded = false;
  bool _saving = false;
  bool _avatarBusy = false;
  bool _sharingBusy = false;
  bool? _sharingOverride;
  String? _error;
  String _savedName = '';

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _seed(String name) {
    if (_seeded) return;
    _seeded = true;
    _savedName = name;
    _nameController.text = name;
  }

  bool get _dirty =>
      AccountNameApi.clean(_nameController.text) != AccountNameApi.clean(_savedName);

  Future<void> _saveName() async {
    final problem = AccountNameApi.problemWith(_nameController.text);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    final api = ref.read(accountNameApiProvider);
    if (api == null) return;
    FocusScope.of(context).unfocus();
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final name = AccountNameApi.clean(_nameController.text);
      Map<String, dynamic>? profile;
      final result = await sendOrQueue(
        ref,
        kind: AccountCommand.profileName,
        target: 'profile_name',
        payload: {'name': name},
        live: () async => profile = await api.save(name),
      );
      if (result == AccountWrite.sent) {
        await ref.read(profileSnapshotWriterProvider)(profile!);
      } else {
        // Saved offline: show the new name everywhere at once (profile cache
        // and the display-name column); the server write is queued.
        final current = ref.read(profileProvider).valueOrNull ?? const {};
        await ref.read(profileSnapshotWriterProvider)({
          ...current,
          'display_name': name,
        });
      }
      if (!mounted) return;
      setState(() {
        _savedName = name;
        _nameController.text = _savedName;
      });
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            result == AccountWrite.queued
                ? savedOfflineMessage
                : 'Name updated',
          ),
        ),
      );
    } catch (error) {
      if (mounted) setState(() => _error = userFacingErrorMessage(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _changeAvatar(AvatarState? current) async {
    if (_avatarBusy) return;
    final choice = await showAvatarPickerSheet(
      context,
      name: _savedName,
      currentPreset: current?.preset,
      hasPhoto: current?.photo != null,
    );
    if (choice == null || !mounted) return;
    final api = ref.read(avatarApiProvider);
    if (api == null) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _avatarBusy = true);
    try {
      switch (choice) {
        case ChoosePreset(:final id):
          // A photo beats a preset on screen, so picking a preset replaces it.
          if (current?.photo != null) await api.removePhoto();
          await api.setPreset(id);
        case UseInitial():
          if (current?.photo != null) await api.removePhoto();
          if (current?.preset != null) await api.setPreset(null);
        case RemovePhoto():
          await api.removePhoto();
        case ChoosePhoto(:final source):
          final picked = await ref.read(avatarPhotoPickerProvider).pick(source);
          if (picked == null) return; // backed out of the picker
          final jpeg = await prepareAvatarPhoto(picked);
          await api.uploadPhoto(jpeg);
      }
      await clearOwnAvatarCache(ref);
      ref.invalidate(avatarProvider);
      await ref.read(avatarProvider.future);
      if (mounted) messenger.showSnackBar(const SnackBar(content: Text('Avatar updated')));
    } catch (error) {
      final text = error is AvatarPhotoException ? error.message : userFacingErrorMessage(error);
      if (mounted) messenger.showSnackBar(SnackBar(content: Text(text)));
    } finally {
      if (mounted) setState(() => _avatarBusy = false);
    }
  }

  Future<void> _setSharing(bool share) async {
    if (_sharingBusy) return;
    final api = ref.read(avatarApiProvider);
    if (api == null) return;
    final messenger = ScaffoldMessenger.of(context);
    // Show the new value at once; put it back if the server says no.
    setState(() {
      _sharingBusy = true;
      _sharingOverride = share;
    });
    try {
      await api.setPhotoSharing(share);
      await clearOwnAvatarCache(ref);
      ref.invalidate(avatarProvider);
      await ref.read(avatarProvider.future);
    } catch (error) {
      if (mounted) messenger.showSnackBar(SnackBar(content: Text(userFacingErrorMessage(error))));
    } finally {
      if (mounted) {
        setState(() {
          _sharingBusy = false;
          _sharingOverride = null;
        });
      }
    }
  }

  Future<void> _openPhoneChange(bool hasPhone) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => PhoneChangeScreen(changing: hasPhone)),
    );
    if (changed == true) ref.invalidate(phoneStatusProvider);
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(profileProvider);
    final phone = ref.watch(phoneStatusProvider).valueOrNull;
    final avatar = ref.watch(avatarProvider).valueOrNull;

    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text('Edit profile', style: BambooFonts.heading(19, color: BambooInk.ink900)),
      ),
      body: AppBackground(
        child: profile.when(
          skipLoadingOnReload: true,
          skipLoadingOnRefresh: true,
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (err, _) => ErrorState(
            message: userFacingErrorMessage(err),
            onRetry: () => ref.invalidate(profileProvider),
          ),
          data: (data) {
            final email = (data?['email'] as String?)?.trim() ?? '';
            _seed(((data?['display_name'] as String?) ?? '').trim());
            final hasPhone = phone?.hasPhone == true;
            final shownName = AccountNameApi.clean(_nameController.text);
            final initial = shownName.isNotEmpty
                ? shownName.characters.first.toUpperCase()
                : (email.isNotEmpty ? email.characters.first.toUpperCase() : '?');

            return ListView(
              padding: const EdgeInsets.fromLTRB(20, AppSpace.md, 20, 30),
              children: [
                Center(
                  child: Pressable(
                    onTap: () => _changeAvatar(avatar),
                    semanticLabel: 'Change avatar',
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        UserAvatar(
                          key: const Key('edit-avatar'),
                          name: shownName.isNotEmpty ? shownName : initial,
                          preset: avatar?.preset,
                          photo: avatar?.photo,
                          size: 92,
                          radiusFactor: 0.3,
                        ),
                        if (_avatarBusy)
                          Positioned.fill(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.35),
                                borderRadius: BorderRadius.circular(92 * 0.3),
                              ),
                              child: const Center(
                                child: SizedBox(
                                  width: 24,
                                  height: 24,
                                  child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                                ),
                              ),
                            ),
                          ),
                        Positioned(
                          right: -6,
                          bottom: -6,
                          child: Container(
                            key: const Key('edit-avatar-badge'),
                            padding: const EdgeInsets.all(7),
                            decoration: BoxDecoration(
                              color: BambooInk.slate,
                              shape: BoxShape.circle,
                              border: Border.all(color: BambooInk.paper, width: 2),
                            ),
                            child: const Icon(Icons.edit_rounded, size: 14, color: BambooInk.lime),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: AppSpace.sm),
                Center(
                  child: Text(
                    'Tap to change your avatar',
                    style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                  ),
                ),
                if (avatar?.photo != null) ...[
                  const SizedBox(height: AppSpace.lg),
                  _Card(
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Show my photo to people in Split',
                              style: BambooFonts.ui(15, weight: FontWeight.w600, color: BambooInk.ink900),
                            ),
                          ),
                          Switch(
                            key: const Key('edit-share-photo'),
                            value: _sharingOverride ?? avatar!.sharePhoto,
                            onChanged: _sharingBusy ? null : _setSharing,
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpace.xs),
                      Text(
                        'Off: they see your avatar or initial. On: Split members you share a group with can see your photo.',
                        style: BambooFonts.ui(12.5, color: BambooInk.ink500, height: 1.5),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: AppSpace.xl),
                const _SectionLabel('Name'),
                _Card(
                  children: [
                    TextField(
                      key: const Key('edit-name-field'),
                      controller: _nameController,
                      enabled: !_saving,
                      textCapitalization: TextCapitalization.words,
                      textInputAction: TextInputAction.done,
                      autofillHints: const [AutofillHints.name],
                      inputFormatters: [LengthLimitingTextInputFormatter(60)],
                      onChanged: (_) => setState(() => _error = null),
                      onSubmitted: (_) => _saving || !_dirty ? null : _saveName(),
                      style: BambooFonts.ui(16, color: BambooInk.ink900),
                      decoration: InputDecoration(
                        labelText: 'Your name',
                        errorText: _error,
                        errorMaxLines: 3,
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: AppSpace.sm),
                    Text(
                      'This is the name you see across PandaPay and the one friends see in Split.',
                      style: BambooFonts.ui(12.5, color: BambooInk.ink500, height: 1.5),
                    ),
                    const SizedBox(height: AppSpace.md),
                    _FullWidthButton(
                      key: const Key('edit-name-save'),
                      label: _saving ? 'Saving…' : 'Save name',
                      filled: true,
                      onPressed: _saving || !_dirty ? null : _saveName,
                    ),
                  ],
                ),
                const SizedBox(height: AppSpace.xl),
                const _SectionLabel('Phone number'),
                _Card(
                  children: [
                    Text(
                      hasPhone ? (phone?.phoneHint ?? 'On file') : 'Not added',
                      key: const Key('edit-phone-value'),
                      style: BambooFonts.ui(15, weight: FontWeight.w600, color: BambooInk.ink900),
                    ),
                    const SizedBox(height: AppSpace.sm),
                    Text(
                      hasPhone
                          ? 'To change it, we email a code to your sign-in email to confirm it’s you.'
                          : 'Add a mobile number. We email a code to your sign-in email to confirm it’s you.',
                      style: BambooFonts.ui(12.5, color: BambooInk.ink500, height: 1.5),
                    ),
                    const SizedBox(height: AppSpace.md),
                    _FullWidthButton(
                      key: const Key('edit-phone-action'),
                      label: hasPhone ? 'Change phone number' : 'Add phone number',
                      onPressed: phone == null ? null : () => _openPhoneChange(hasPhone),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpace.xl),
                const _SectionLabel('Email'),
                _Card(
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.lock_outline_rounded, size: 18, color: BambooInk.ink500),
                        const SizedBox(width: AppSpace.sm),
                        Expanded(
                          child: Text(
                            email.isEmpty ? 'Not on file' : email,
                            key: const Key('edit-email-value'),
                            overflow: TextOverflow.ellipsis,
                            style: BambooFonts.ui(15, weight: FontWeight.w600, color: BambooInk.ink900),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpace.sm),
                    Text(
                      'Your email is how you sign in and recover your account, so it can’t be '
                      'edited here. If you need to move to a new address, support can do it '
                      'after you confirm from this one.',
                      style: BambooFonts.ui(12.5, color: BambooInk.ink500, height: 1.5),
                    ),
                    if (email.isNotEmpty) ...[
                      const SizedBox(height: AppSpace.md),
                      _FullWidthButton(
                        label: 'Contact support to change email',
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => FeedbackSupportScreen(
                              prefilledKind: 'general',
                              prefilledMessage:
                                  "I'd like to change the email on my account. The current address is $email.",
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.sm),
      child: Text(
        text.toUpperCase(),
        style: BambooFonts.ui(12, weight: FontWeight.w600, color: BambooInk.ink500)
            .copyWith(letterSpacing: 1.4),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  final List<Widget> children;
  const _Card({required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
    );
  }
}

/// A full-width button. It sits in a Column, never a Row or ListTile.trailing:
/// the app-wide button theme forces full width.
class _FullWidthButton extends StatelessWidget {
  final String label;
  final bool filled;
  final VoidCallback? onPressed;
  const _FullWidthButton({super.key, required this.label, required this.onPressed, this.filled = false});

  @override
  Widget build(BuildContext context) {
    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(14));
    if (filled) {
      return FilledButton(
        style: FilledButton.styleFrom(
          backgroundColor: BambooInk.slate,
          foregroundColor: BambooInk.lime,
          minimumSize: const Size.fromHeight(48),
          shape: shape,
        ),
        onPressed: onPressed,
        child: Text(label),
      );
    }
    return OutlinedButton(
      style: OutlinedButton.styleFrom(
        foregroundColor: BambooInk.ink900,
        backgroundColor: BambooInk.paperMuted,
        minimumSize: const Size.fromHeight(46),
        side: const BorderSide(color: BambooInk.hairlineOnPaper),
        shape: shape,
        textStyle: BambooFonts.ui(14, weight: FontWeight.w700),
      ),
      onPressed: onPressed,
      child: Text(label),
    );
  }
}
