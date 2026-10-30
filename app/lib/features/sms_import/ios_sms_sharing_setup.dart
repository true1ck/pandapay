import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import 'ios_sms_intake_providers.dart';

/// This is a remembered tutorial acknowledgement, not an OS permission grant.
/// It is intentionally absent from the synced account-settings allowlist.
const iosSmsSharingAcknowledgementKey =
    'pandapay_app.ios_sms_large_sharing_acknowledged_v1';

class IosSmsSharingSetup extends ConsumerStatefulWidget {
  final ValueChanged<bool> onConfirmedChanged;
  const IosSmsSharingSetup({super.key, required this.onConfirmedChanged});

  @override
  ConsumerState<IosSmsSharingSetup> createState() => _IosSmsSharingSetupState();
}

class _IosSmsSharingSetupState extends ConsumerState<IosSmsSharingSetup> {
  final _updates = ValueNotifier<int>(0);
  bool _confirmed = false;
  bool _loading = true;
  bool _saving = false;
  bool _openingSettings = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final confirmed = prefs.getBool(iosSmsSharingAcknowledgementKey) ?? false;
      if (!mounted) return;
      _update(() => _confirmed = confirmed);
      widget.onConfirmedChanged(confirmed);
    } catch (_) {
      if (mounted) {
        _update(
          () => _error =
              'Could not load your setup confirmation. Check the setting and confirm below.',
        );
      }
    } finally {
      if (mounted) _update(() => _loading = false);
    }
  }

  Future<void> _confirm(bool value) async {
    if (_loading || _saving) return;
    _update(() {
      _saving = true;
      _error = null;
    });
    // Revocation takes effect immediately even if saving preferences fails.
    if (!value) {
      _update(() => _confirmed = false);
      widget.onConfirmedChanged(false);
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setBool(iosSmsSharingAcknowledgementKey, value)) {
        throw StateError('Could not save setup confirmation');
      }
      if (!mounted) return;
      _update(() => _confirmed = value);
      if (value) widget.onConfirmedChanged(true);
    } catch (_) {
      if (mounted) {
        _update(
          () => _error = 'Could not save your confirmation. Please try again.',
        );
      }
    } finally {
      if (mounted) _update(() => _saving = false);
    }
  }

  Future<void> _openSettings() async {
    if (_openingSettings) return;
    _update(() {
      _openingSettings = true;
      _error = null;
    });
    try {
      final opened = await ref
          .read(iosSmsIntakeServiceProvider)
          .call('openSettings');
      if (opened != true) throw StateError('Settings did not open');
    } catch (_) {
      if (mounted) {
        _update(
          () => _error =
              'Could not open Settings. Open the Settings app yourself and follow the steps above.',
        );
      }
    } finally {
      if (mounted) _update(() => _openingSettings = false);
    }
    // Opening Settings or returning to PandaPay cannot verify this switch.
  }

  void _update(VoidCallback change) {
    if (!mounted) return;
    setState(change);
    _updates.value++;
  }

  @override
  void dispose() {
    _updates.dispose();
    super.dispose();
  }

  void _showHelp() {
    FocusManager.instance.primaryFocus?.unfocus();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: BambooInk.paper,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => ValueListenableBuilder<int>(
        valueListenable: _updates,
        builder: (context, _, _) => SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * .85,
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(AppSpace.xl),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Allow history sharing',
                    style: BambooFonts.heading(22, color: BambooInk.ink900),
                  ),
                  const SizedBox(height: AppSpace.lg),
                  _step('1', 'Settings → Apps → Shortcuts → Advanced'),
                  _step('2', 'Turn on Allow Sharing Large Amounts of Data.'),
                  _step(
                    '3',
                    'Return here. Choose Always Allow when Shortcuts asks to share with PandaPay.',
                  ),
                  Text(
                    'This setting applies to all shortcuts. On older iOS, Shortcuts may appear directly in Settings.',
                    style: BambooFonts.ui(12, color: BambooInk.ink700),
                  ),
                  const SizedBox(height: AppSpace.lg),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: BambooInk.slate,
                      foregroundColor: BambooInk.lime,
                      minimumSize: const Size.fromHeight(48),
                      textStyle: BambooFonts.ui(14, weight: FontWeight.w700),
                    ),
                    onPressed: _openingSettings ? null : _openSettings,
                    icon: const Icon(Icons.settings_outlined),
                    label: const Text('Open Settings'),
                  ),
                  const SizedBox(height: AppSpace.sm),
                  Text(
                    'Opens PandaPay’s settings. Go back to Apps, then choose Shortcuts.',
                    style: BambooFonts.ui(12, color: BambooInk.ink700),
                  ),
                  const SizedBox(height: AppSpace.md),
                  CheckboxListTile(
                    key: const ValueKey('ios-sms-sharing-confirmation'),
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    activeColor: BambooInk.jade,
                    title: Text(
                      'I’ve enabled this setting',
                      style: BambooFonts.ui(
                        14,
                        weight: FontWeight.w600,
                        color: BambooInk.ink900,
                      ),
                    ),
                    subtitle: Text(
                      'Your confirmation is saved on this phone.',
                      style: BambooFonts.ui(12, color: BambooInk.ink700),
                    ),
                    value: _confirmed,
                    onChanged: _loading || _saving
                        ? null
                        : (value) => _confirm(value ?? false),
                  ),
                  if (_loading || _saving)
                    const LinearProgressIndicator(color: BambooInk.jade),
                  if (_error != null)
                    Text(
                      _error!,
                      style: BambooFonts.ui(12, color: BambooInk.clayInk),
                    ),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(
                      'Done',
                      style: BambooFonts.ui(14, color: BambooInk.jade),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _step(String number, String text) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpace.md),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 26,
          height: 26,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: BambooInk.slate,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            number,
            style: BambooFonts.ui(
              12,
              color: BambooInk.lime,
              weight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(width: AppSpace.md),
        Expanded(
          child: Text(text, style: BambooFonts.ui(14, color: BambooInk.ink900)),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: _loading ? null : _showHelp,
    semanticLabel: 'History permissions',
    child: Container(
      padding: const EdgeInsets.all(AppSpace.lg),
      decoration: BoxDecoration(
        color: BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      child: Row(
        children: [
          Icon(
            _confirmed
                ? Icons.check_circle_outline_rounded
                : Icons.tune_rounded,
            color: BambooInk.jade,
          ),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'History permissions',
                  style: BambooFonts.heading(16, color: BambooInk.ink900),
                ),
                Text(
                  _confirmed
                      ? 'Confirmed on this iPhone'
                      : 'One quick setting before you start',
                  style: BambooFonts.ui(12, color: BambooInk.ink700),
                ),
              ],
            ),
          ),
          if (_loading)
            const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: BambooInk.jade,
              ),
            )
          else
            const Icon(Icons.chevron_right_rounded, color: BambooInk.ink700),
        ],
      ),
    ),
  );
}
