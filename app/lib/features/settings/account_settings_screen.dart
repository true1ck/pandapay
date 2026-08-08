import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/account_api.dart';
import '../../data/api_exception.dart';
import '../auth/login_screen.dart';

/// H2 Account (real) — replaces AccountScreen's ~15%-built body (signed-in
/// state + sign-out only) with the full spec surface: sign-out, "upgrade
/// from local mode", a biometric-lock toggle, and the account-deletion
/// flow. Built as a standalone pushed screen per this task's plan — a
/// later task wires it into AccountScreen/SettingsHubScreen, so this file
/// does not touch providers.dart, router.dart, or account_screen.dart.
class AccountSettingsScreen extends ConsumerWidget {
  const AccountSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('Account')),
      body: const _AccountSettingsBody(),
    );
  }
}

class _AccountSettingsBody extends ConsumerWidget {
  const _AccountSettingsBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileProvider);
    return profile.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => ErrorState(
        message: userFacingErrorMessage(err),
        onRetry: () => ref.invalidate(profileProvider),
      ),
      data: (profileData) => ListView(
        padding: const EdgeInsets.all(AppSpace.lg),
        children: [
          _IdentityCard(profileData: profileData),
          const SizedBox(height: AppSpace.xxl),
          const _UpgradeFromLocalModeRow(),
          const SizedBox(height: AppSpace.xxl),
          Text('Security', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: AppSpace.sm),
          const _BiometricLockTile(),
          const SizedBox(height: AppSpace.xxl),
          const _SignOutButton(),
          const SizedBox(height: AppSpace.xxxl),
          _DeleteAccountSection(profileData: profileData),
        ],
      ),
    );
  }
}

class _IdentityCard extends StatelessWidget {
  final Map<String, dynamic>? profileData;
  const _IdentityCard({required this.profileData});

  @override
  Widget build(BuildContext context) {
    final email = profileData?['email'] as String?;
    final identifier = (email != null && email.isNotEmpty)
        ? email
        : 'ID · ${profileData?['id'] ?? '—'}';
    return Container(
      padding: const EdgeInsets.all(AppSpace.lg),
      decoration: BoxDecoration(
        color: AppColors.navy900,
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.person_rounded,
              color: Colors.white,
              size: 24,
            ),
          ),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Signed in',
                  style: Theme.of(
                    context,
                  ).textTheme.titleMedium?.copyWith(color: Colors.white),
                ),
                const SizedBox(height: 2),
                Text(
                  identifier,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: Colors.white60),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Visible only in local/guest mode (`accessTokenProvider == null`).
/// Per the plan's own honesty scoping: this wires the navigation to
/// account creation only. Local->cloud data migration (moving any
/// locally-cached cards/transactions onto the new account) is a real,
/// separate gap — there is no offline cache today for Cards/Activity to
/// migrate from (both screens are server-fetched once signed in), so
/// nothing here silently implies migration works.
class _UpgradeFromLocalModeRow extends ConsumerWidget {
  const _UpgradeFromLocalModeRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final token = ref.watch(accessTokenProvider);
    if (token != null) return const SizedBox.shrink();

    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => const LoginScreen(mode: AuthMode.signUp),
          ),
        ),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(color: AppColors.ink100),
          ),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpace.lg,
            vertical: AppSpace.md,
          ),
          child: Row(
            children: [
              const Icon(
                Icons.cloud_upload_outlined,
                size: 20,
                color: AppColors.navy800,
              ),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Upgrade from local mode',
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Sync across devices and back up your cards.',
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: AppColors.ink300),
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: AppColors.ink300,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SignOutButton extends ConsumerWidget {
  const _SignOutButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return OutlinedButton.icon(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.error,
        side: const BorderSide(color: AppColors.errorBg, width: 1.5),
      ),
      icon: const Icon(Icons.logout_rounded, size: 18),
      onPressed: () => _signOut(ref),
      label: const Text('Sign out'),
    );
  }
}

/// Same clear-token-store + null-out-state pattern as AccountScreen's
/// existing sign-out button — reused (not reinvented) by both the manual
/// "Sign out" button and the post-deletion-request auto-sign-out below.
Future<void> _signOut(WidgetRef ref) async {
  final store = await ref.read(tokenStoreProvider.future);
  await store.clear();
  ref.read(accessTokenProvider.notifier).state = null;
}

// ---------------------------------------------------------------------------
// Biometric lock toggle
// ---------------------------------------------------------------------------

const _biometricLockKey = 'biometric_lock_enabled_v1';

/// Same load/toggle shape as providers.dart's OnboardingController — a
/// local SharedPreferences-backed bool, nothing server-side. Gates
/// app-open per the caption below; actual biometric-prompt enforcement at
/// launch is a separate follow-up not built here (this ships the toggle +
/// persisted state only, matching this codebase's existing "toggle is
/// real, enforcement is a documented follow-up" pattern).
final biometricLockProvider =
    StateNotifierProvider<BiometricLockController, AsyncValue<bool>>(
      (ref) => BiometricLockController(),
    );

class BiometricLockController extends StateNotifier<AsyncValue<bool>> {
  BiometricLockController() : super(const AsyncValue.loading()) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = AsyncValue.data(prefs.getBool(_biometricLockKey) ?? false);
  }

  Future<void> setEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_biometricLockKey, enabled);
    state = AsyncValue.data(enabled);
  }
}

class _BiometricLockTile extends ConsumerWidget {
  const _BiometricLockTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lockState = ref.watch(biometricLockProvider);
    final enabled = lockState.valueOrNull ?? false;
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: AppColors.ink100),
        ),
        child: SwitchListTile(
          value: enabled,
          onChanged: lockState.isLoading
              ? null
              : (value) =>
                    ref.read(biometricLockProvider.notifier).setEnabled(value),
          title: const Text('Biometric lock'),
          subtitle: const Text('Require Face/Touch ID to open the app'),
          activeTrackColor: AppColors.navy900,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Delete account
// ---------------------------------------------------------------------------

class _DeleteAccountSection extends ConsumerStatefulWidget {
  final Map<String, dynamic>? profileData;
  const _DeleteAccountSection({required this.profileData});

  @override
  ConsumerState<_DeleteAccountSection> createState() =>
      _DeleteAccountSectionState();
}

class _DeleteAccountSectionState extends ConsumerState<_DeleteAccountSection> {
  final _confirmController = TextEditingController();
  bool _submitting = false;
  String? _error;

  /// Local override once a request/cancel call completes this session —
  /// lets the UI flip immediately without waiting for profileProvider to
  /// refetch. Falls back to widget.profileData's server value otherwise.
  DateTime? _dueAtOverride;
  bool _cancelledThisSession = false;

  @override
  void dispose() {
    _confirmController.dispose();
    super.dispose();
  }

  DateTime? get _effectiveDueAt {
    if (_cancelledThisSession) return null;
    if (_dueAtOverride != null) return _dueAtOverride;
    final raw = widget.profileData?['deletion_due_at'] as String?;
    return raw == null ? null : DateTime.tryParse(raw);
  }

  Future<void> _confirmDelete() async {
    final token = ref.read(accessTokenProvider);
    if (token == null) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final api = AccountApi(
        apiBaseUrl: _accountApiBaseUrl,
        accessToken: token,
      );
      final dueAt = await api.requestDeletion();
      // Deletion is scheduled, not immediate — the account is not gone
      // yet. Sign out locally (same path as the manual "Sign out" button)
      // so the device stops presenting itself as this account, while the
      // 30-day grace period runs server-side.
      await _signOut(ref);
      if (!mounted) return;
      setState(() {
        _dueAtOverride = dueAt;
        _submitting = false;
      });
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _error = userFacingErrorMessage(err);
        _submitting = false;
      });
    }
  }

  Future<void> _cancelDelete() async {
    final token = ref.read(accessTokenProvider);
    // Signed out post-request; re-sign-in reaches this screen again to cancel.
    if (token == null) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final api = AccountApi(
        apiBaseUrl: _accountApiBaseUrl,
        accessToken: token,
      );
      await api.cancelDeletion();
      if (!mounted) return;
      setState(() {
        _cancelledThisSession = true;
        _submitting = false;
      });
      ref.invalidate(profileProvider);
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _error = userFacingErrorMessage(err);
        _submitting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final dueAt = _effectiveDueAt;
    return Container(
      padding: const EdgeInsets.all(AppSpace.lg),
      decoration: BoxDecoration(
        color: AppColors.errorBg,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.error.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.warning_amber_rounded,
                color: AppColors.error,
                size: 20,
              ),
              const SizedBox(width: AppSpace.sm),
              Text(
                'Delete account',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(color: AppColors.error),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.md),
          if (dueAt != null)
            _ScheduledDeletionState(
              dueAt: dueAt,
              submitting: _submitting,
              onCancel: _cancelDelete,
            )
          else
            _TypedConfirmDeletionForm(
              controller: _confirmController,
              submitting: _submitting,
              onConfirm: _confirmDelete,
            ),
          if (_error != null) ...[
            const SizedBox(height: AppSpace.sm),
            Text(
              _error!,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: AppColors.error),
            ),
          ],
        ],
      ),
    );
  }
}

class _TypedConfirmDeletionForm extends StatefulWidget {
  final TextEditingController controller;
  final bool submitting;
  final VoidCallback onConfirm;

  const _TypedConfirmDeletionForm({
    required this.controller,
    required this.submitting,
    required this.onConfirm,
  });

  @override
  State<_TypedConfirmDeletionForm> createState() =>
      _TypedConfirmDeletionFormState();
}

class _TypedConfirmDeletionFormState extends State<_TypedConfirmDeletionForm> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final canConfirm =
        widget.controller.text.trim() == 'DELETE' && !widget.submitting;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Your account, cards, and transaction history will be permanently '
          'deleted in 30 days. Crowdsourced merchant data you\'ve contributed '
          'stays anonymous and is never linked back to you. Backups are '
          'purged on their own retention schedule.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: AppSpace.lg),
        TextField(
          controller: widget.controller,
          decoration: const InputDecoration(
            labelText: 'Type DELETE to confirm',
            hintText: 'DELETE',
          ),
          textCapitalization: TextCapitalization.characters,
        ),
        const SizedBox(height: AppSpace.md),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: canConfirm ? widget.onConfirm : null,
            child: widget.submitting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Text('Delete my account'),
          ),
        ),
      ],
    );
  }
}

class _ScheduledDeletionState extends StatelessWidget {
  final DateTime dueAt;
  final bool submitting;
  final VoidCallback onCancel;

  const _ScheduledDeletionState({
    required this.dueAt,
    required this.submitting,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final formatted =
        '${dueAt.day.toString().padLeft(2, '0')}/${dueAt.month.toString().padLeft(2, '0')}/${dueAt.year}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Deletion scheduled for $formatted. Your account is not deleted '
          'yet — sign back in any time before then to cancel.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: AppSpace.md),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.error,
              side: const BorderSide(color: AppColors.error, width: 1.5),
            ),
            onPressed: submitting ? null : onCancel,
            child: submitting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Cancel deletion'),
          ),
        ),
      ],
    );
  }
}

/// Same dev-default host as providers.dart's private `_apiBaseUrl` — kept
/// as a separate literal rather than importing that private top-level
/// const (it's not exported), matching this task's "create only new
/// files" constraint.
const _accountApiBaseUrl = 'http://localhost:4000';
