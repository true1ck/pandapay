import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart' show accessTokenProvider;
import '../../data/api_exception.dart';
import '../../data/notification_preferences_repository.dart';
import '../../app/env.dart';

const _apiBaseUrl = Env.apiBaseUrl; // plan Phase 0.3 — see app/env.dart

/// Task H3 Notification Settings. Local providers only (per this pass's
/// "create only new files, don't touch providers.dart" constraint) — same
/// null-when-signed-out pattern as userCardsRepositoryProvider in
/// app/lib/app/providers.dart, just replicated in this file rather than
/// imported from it.
final _notificationPreferencesRepositoryProvider = Provider<NotificationPreferencesRepository?>((ref) {
  final token = ref.watch(accessTokenProvider);
  if (token == null) return null;
  return NotificationPreferencesRepository(apiBaseUrl: _apiBaseUrl, accessToken: token);
});

final _notificationPreferencesProvider = FutureProvider<NotificationPreferences?>((ref) async {
  final repo = ref.watch(_notificationPreferencesRepositoryProvider);
  if (repo == null) return null;
  return repo.fetch();
});

final _mutedMerchantsProvider = FutureProvider<List<MutedMerchant>>((ref) async {
  final repo = ref.watch(_notificationPreferencesRepositoryProvider);
  if (repo == null) return const [];
  return repo.fetchMutedMerchants();
});

/// ui-spec.md H3 Notification Settings. Every toggle/slider/time-picker
/// change writes through PUT /notification-preferences immediately (no
/// separate Save button) — exact same UX pattern as
/// my_contributions_screen.dart's contributions opt-in toggle: call the
/// API, then refresh local state from the server's own response rather
/// than optimistically flipping a local bool and never confirming it.
class NotificationSettingsScreen extends ConsumerWidget {
  const NotificationSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final signedOut = ref.watch(accessTokenProvider) == null;

    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text('Notifications', style: BambooFonts.heading(18, color: BambooInk.ink900)),
      ),
      body: AppBackground(
        // Every SwitchListTile below relies on the ambient SwitchThemeData
        // for its colors rather than each setting its own activeColor —
        // one Theme override here restyles all eight consistently instead
        // of eight near-identical edits.
        child: Theme(
          data: Theme.of(context).copyWith(
            switchTheme: SwitchThemeData(
              thumbColor: WidgetStateProperty.resolveWith(
                (states) => states.contains(WidgetState.selected) ? BambooInk.lime : Colors.white,
              ),
              trackColor: WidgetStateProperty.resolveWith(
                (states) => states.contains(WidgetState.selected) ? BambooInk.slate : BambooInk.paperMuted,
              ),
              trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
            ),
          ),
          child: signedOut
              ? const EmptyState(
                  icon: Icons.notifications_off_outlined,
                  title: 'Sign in to manage notification settings',
                )
              : const _NotificationSettingsBody(),
        ),
      ),
    );
  }
}

class _NotificationSettingsBody extends ConsumerWidget {
  const _NotificationSettingsBody();

  Future<void> _update(BuildContext context, WidgetRef ref, Map<String, dynamic> changes) async {
    final repo = ref.read(_notificationPreferencesRepositoryProvider);
    if (repo == null) return;
    try {
      await repo.update(changes);
      ref.invalidate(_notificationPreferencesProvider);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(e))));
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefsAsync = ref.watch(_notificationPreferencesProvider);

    return prefsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => ErrorState(
        message: userFacingErrorMessage(err),
        onRetry: () => ref.invalidate(_notificationPreferencesProvider),
      ),
      data: (prefs) {
        if (prefs == null) {
          return const EmptyState(
            icon: Icons.notifications_off_outlined,
            title: 'Sign in to manage notification settings',
          );
        }
        return ListView(
          padding: const EdgeInsets.symmetric(vertical: AppSpace.md),
          children: [
            _SectionHeader('Categories'),
            SwitchListTile(
              title: const Text('Location-based tips'),
              subtitle: const Text('Nudges when you\'re near a merchant with a better card'),
              value: prefs.categoryLocation,
              onChanged: (v) => _update(context, ref, {'category_location': v}),
            ),
            SwitchListTile(
              title: const Text('Cap alerts'),
              subtitle: const Text('When you\'re close to a spend or reward cap'),
              value: prefs.categoryCaps,
              onChanged: (v) => _update(context, ref, {'category_caps': v}),
            ),
            SwitchListTile(
              title: const Text('Milestones'),
              subtitle: const Text('Progress toward a milestone benefit'),
              value: prefs.categoryMilestones,
              onChanged: (v) => _update(context, ref, {'category_milestones': v}),
            ),
            SwitchListTile(
              title: const Text('Fee waivers'),
              subtitle: const Text('Annual fee waiver progress and confirmations'),
              value: prefs.categoryFeeWaivers,
              onChanged: (v) => _update(context, ref, {'category_fee_waivers': v}),
            ),
            SwitchListTile(
              title: const Text('Bill due dates'),
              subtitle: const Text('Reminders before a payment is due'),
              value: prefs.categoryBills,
              onChanged: (v) => _update(context, ref, {'category_bills': v}),
            ),
            SwitchListTile(
              title: const Text('Points / offer expiry'),
              subtitle: const Text('Before rewards or offers expire'),
              value: prefs.categoryExpiry,
              onChanged: (v) => _update(context, ref, {'category_expiry': v}),
            ),
            SwitchListTile(
              title: const Text('Monthly savings report'),
              subtitle: const Text('A summary of what your cards earned this month'),
              value: prefs.categoryMonthlyReport,
              onChanged: (v) => _update(context, ref, {'category_monthly_report': v}),
            ),
            SwitchListTile(
              title: const Text('Needs-review queue'),
              subtitle: const Text('Transactions PandaPay couldn\'t confidently categorize'),
              value: prefs.categoryNeedsReview,
              onChanged: (v) => _update(context, ref, {'category_needs_review': v}),
            ),
            const Divider(height: AppSpace.xl),
            _SectionHeader('Quiet hours'),
            _QuietHoursTile(prefs: prefs, onUpdate: (changes) => _update(context, ref, changes)),
            const Divider(height: AppSpace.xl),
            _SectionHeader('Daily notification cap'),
            _DailyCapTile(prefs: prefs, onUpdate: (changes) => _update(context, ref, changes)),
            const Divider(height: AppSpace.xl),
            _SectionHeader('Muted merchants'),
            const _MutedMerchantsList(),
          ],
        );
      },
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpace.lg, AppSpace.md, AppSpace.lg, AppSpace.sm),
      child: Text(
        title.toUpperCase(),
        style: BambooFonts.ui(
          12,
          weight: FontWeight.w700,
          color: BambooInk.ink500,
        ).copyWith(letterSpacing: 1.1),
      ),
    );
  }
}

class _QuietHoursTile extends StatelessWidget {
  final NotificationPreferences prefs;
  final void Function(Map<String, dynamic> changes) onUpdate;

  const _QuietHoursTile({required this.prefs, required this.onUpdate});

  static TimeOfDay? _parse(String? hhmmss) {
    if (hhmmss == null) return null;
    final parts = hhmmss.split(':');
    if (parts.length < 2) return null;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null) return null;
    return TimeOfDay(hour: h, minute: m);
  }

  static String _format(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:00';

  Future<void> _pick(BuildContext context, {required bool isStart}) async {
    final current = isStart ? _parse(prefs.quietHoursStart) : _parse(prefs.quietHoursEnd);
    final picked = await showTimePicker(
      context: context,
      initialTime: current ?? const TimeOfDay(hour: 22, minute: 0),
    );
    if (picked == null) return;
    onUpdate({isStart ? 'quiet_hours_start' : 'quiet_hours_end': _format(picked)});
  }

  @override
  Widget build(BuildContext context) {
    final start = _parse(prefs.quietHoursStart);
    final end = _parse(prefs.quietHoursEnd);
    final isOff = start == null && end == null;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isOff
                ? 'Off — notifications may arrive any time'
                : 'No notifications between ${start?.format(context) ?? '--:--'} and ${end?.format(context) ?? '--:--'}',
            style: BambooFonts.ui(13.5, color: BambooInk.ink500),
          ),
          const SizedBox(height: AppSpace.sm),
          Wrap(
            spacing: AppSpace.sm,
            children: [
              TextButton(
                style: TextButton.styleFrom(foregroundColor: BambooInk.jade),
                onPressed: () => _pick(context, isStart: true),
                child: Text('Start: ${start?.format(context) ?? 'Off'}'),
              ),
              TextButton(
                style: TextButton.styleFrom(foregroundColor: BambooInk.jade),
                onPressed: () => _pick(context, isStart: false),
                child: Text('End: ${end?.format(context) ?? 'Off'}'),
              ),
              if (!isOff)
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: BambooInk.ink500),
                  onPressed: () => onUpdate({'quiet_hours_start': null, 'quiet_hours_end': null}),
                  child: const Text('Clear'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DailyCapTile extends StatefulWidget {
  final NotificationPreferences prefs;
  final void Function(Map<String, dynamic> changes) onUpdate;

  const _DailyCapTile({required this.prefs, required this.onUpdate});

  @override
  State<_DailyCapTile> createState() => _DailyCapTileState();
}

class _DailyCapTileState extends State<_DailyCapTile> {
  late double _value = widget.prefs.dailyCap.toDouble();

  @override
  void didUpdateWidget(covariant _DailyCapTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.prefs.dailyCap != widget.prefs.dailyCap) {
      _value = widget.prefs.dailyCap.toDouble();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Up to ${_value.round()} notification${_value.round() == 1 ? '' : 's'} per day',
            style: BambooFonts.ui(13.5, color: BambooInk.ink500),
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: BambooInk.slate,
              inactiveTrackColor: BambooInk.paperMuted,
              thumbColor: BambooInk.slate,
              overlayColor: BambooInk.slate.withValues(alpha: 0.12),
              valueIndicatorColor: BambooInk.slate,
            ),
            child: Slider(
              value: _value,
              min: 0,
              max: 20,
              divisions: 20,
              label: '${_value.round()}',
              onChanged: (v) => setState(() => _value = v),
              onChangeEnd: (v) => widget.onUpdate({'daily_cap': v.round()}),
            ),
          ),
        ],
      ),
    );
  }
}

class _MutedMerchantsList extends ConsumerWidget {
  const _MutedMerchantsList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mutedAsync = ref.watch(_mutedMerchantsProvider);

    return mutedAsync.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(AppSpace.lg),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (err, _) => Padding(
        padding: const EdgeInsets.all(AppSpace.lg),
        child: ErrorState(
          message: userFacingErrorMessage(err),
          onRetry: () => ref.invalidate(_mutedMerchantsProvider),
        ),
      ),
      data: (muted) {
        if (muted.isEmpty) {
          return const Padding(
            padding: EdgeInsets.fromLTRB(AppSpace.lg, 0, AppSpace.lg, AppSpace.lg),
            child: EmptyState(
              icon: Icons.volume_off_outlined,
              title: 'No muted merchants yet',
              message: 'You can mute a place after getting a notification from it.',
            ),
          );
        }
        return Column(
          children: [
            for (final m in muted)
              ListTile(
                title: Text(m.merchantName),
                trailing: TextButton(
                  style: TextButton.styleFrom(foregroundColor: BambooInk.jade),
                  onPressed: () async {
                    final repo = ref.read(_notificationPreferencesRepositoryProvider);
                    if (repo == null) return;
                    try {
                      await repo.unmuteMerchant(m.merchantId);
                      ref.invalidate(_mutedMerchantsProvider);
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(
                          context,
                        ).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(e))));
                      }
                    }
                  },
                  child: const Text('Unmute'),
                ),
              ),
          ],
        );
      },
    );
  }
}
