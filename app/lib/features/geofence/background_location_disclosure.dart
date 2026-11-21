import 'package:flutter/material.dart';

import '../../app/design/app_theme.dart';

/// Prominent in-app disclosure shown immediately before PandaPay asks Android
/// for background ("Allow all the time") location.
///
/// Google Play requires this for ACCESS_BACKGROUND_LOCATION: it must say what
/// is collected, that it happens even when the app is closed or not in use,
/// and why, and it needs an explicit tap or tick before the system prompt.
/// "Not now" leaves the app fully usable; the one-shot "check nearby" button
/// keeps working with foreground location only.
///
/// The Play declaration quotes this copy and the screen recording shows it, so
/// do not reword it without updating both.
class BackgroundLocationDisclosure extends StatefulWidget {
  const BackgroundLocationDisclosure({super.key});

  /// Resolves to `true` only after the person ticked the box and tapped
  /// Continue. Dismissing the sheet or tapping "Not now" resolves to `false`.
  static Future<bool> show(BuildContext context) async {
    final agreed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: BambooInk.paper,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
      ),
      builder: (_) => const BackgroundLocationDisclosure(),
    );
    return agreed ?? false;
  }

  @override
  State<BackgroundLocationDisclosure> createState() =>
      _BackgroundLocationDisclosureState();
}

class BackgroundLocationDisclosureCopy {
  const BackgroundLocationDisclosureCopy._();

  static const title = 'PandaPay uses your location in the background';
  static const collects =
      'PandaPay collects your location, even when the app is closed or not in '
      'use, to alert you to the card that earns the most when you are near a '
      'shop.';
  static const usedFor =
      'Your location is used only for this alert. To find nearby shops it is '
      'sent to PandaPay and map data providers working for us. It is never '
      'used for ads or sold.';
  static const androidPrompt =
      'Android will ask you to choose "Allow all the time". A notification '
      'stays visible while this is on.';
  static const turnOff =
      'You can switch this off at any time here or in Settings.';
  static const agree =
      'I agree to PandaPay using my location in the background as described.';
}

class _BackgroundLocationDisclosureState
    extends State<BackgroundLocationDisclosure> {
  bool _agreed = false;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        AppSpace.lg,
        AppSpace.lg,
        AppSpace.lg,
        AppSpace.lg + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            BackgroundLocationDisclosureCopy.title,
            style: BambooFonts.heading(20, color: BambooInk.ink900),
          ),
          const SizedBox(height: AppSpace.lg),
          const _Point(
            icon: Icons.location_on_outlined,
            text: BackgroundLocationDisclosureCopy.collects,
          ),
          const _Point(
            icon: Icons.shield_outlined,
            text: BackgroundLocationDisclosureCopy.usedFor,
          ),
          const _Point(
            icon: Icons.notifications_active_outlined,
            text: BackgroundLocationDisclosureCopy.androidPrompt,
          ),
          const _Point(
            icon: Icons.toggle_on_outlined,
            text: BackgroundLocationDisclosureCopy.turnOff,
          ),
          const SizedBox(height: AppSpace.sm),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _agreed,
            onChanged: (value) => setState(() => _agreed = value ?? false),
            title: Text(
              BackgroundLocationDisclosureCopy.agree,
              style: BambooFonts.ui(14, color: BambooInk.ink900),
            ),
          ),
          const SizedBox(height: AppSpace.md),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: BambooInk.slate,
              foregroundColor: BambooInk.lime,
              minimumSize: const Size.fromHeight(52),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              textStyle: BambooFonts.ui(15, weight: FontWeight.w700),
            ),
            onPressed: _agreed ? () => Navigator.of(context).pop(true) : null,
            child: const Text('Continue'),
          ),
          const SizedBox(height: AppSpace.sm),
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Not now'),
          ),
        ],
      ),
    );
  }
}

class _Point extends StatelessWidget {
  const _Point({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: BambooInk.slate),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: Text(
              text,
              style: BambooFonts.ui(14, color: BambooInk.ink900),
            ),
          ),
        ],
      ),
    );
  }
}

/// Turning background alerts ON must show the disclosure first, and only an
/// agreement lets [apply] run (which is what asks Android for "Allow all the
/// time"). Turning them OFF never needs it.
Future<void> setBackgroundAlertsWithDisclosure(
  BuildContext context, {
  required bool enable,
  required Future<void> Function(bool enable) apply,
}) async {
  if (enable) {
    final agreed = await BackgroundLocationDisclosure.show(context);
    if (!agreed || !context.mounted) return;
  }
  await apply(enable);
}
