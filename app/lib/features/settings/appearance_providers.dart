import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Task H6 (Appearance). Three local, device-only display preferences —
/// theme mode, text scale, and money-number-format — following the exact
/// SharedPreferences-backed load-on-construction pattern
/// `OnboardingController`/`TutorialController` already establish in
/// app/lib/app/providers.dart. Deliberately NOT added to providers.dart
/// itself (multiple agents are touching sibling screens in parallel this
/// session; keeping these here avoids a shared-file merge conflict) and
/// deliberately local-only — there's no server-side column for any of
/// these three, and ui-spec.md doesn't ask for cross-device sync of them.

const _themeModeKey = 'appearance_theme_mode_v1';
const _textScaleKey = 'appearance_text_scale_v1';
const _numberFormatKey = 'appearance_number_format_v1';

/// Allowed text-scale steps, per H6's spec: 85% / 100% / 115% / 130%.
/// (Deliberately well under the spec's own 200% accessibility ceiling —
/// this is an app-chosen "comfortable reading" control, not a substitute
/// for the OS-level accessibility text scale, which still stacks on top
/// of it via MediaQuery's own textScaler composition at the app root.)
const kTextScaleSteps = <double>[0.85, 1.0, 1.15, 1.3];

ThemeMode _themeModeFromString(String? value) {
  switch (value) {
    case 'light':
      return ThemeMode.light;
    case 'dark':
      return ThemeMode.dark;
    default:
      return ThemeMode.system;
  }
}

String _themeModeToString(ThemeMode mode) {
  switch (mode) {
    case ThemeMode.light:
      return 'light';
    case ThemeMode.dark:
      return 'dark';
    case ThemeMode.system:
      return 'system';
  }
}

MoneyNumberFormat _numberFormatFromString(String? value) {
  return value == 'international' ? MoneyNumberFormat.international : MoneyNumberFormat.lakhCrore;
}

String _numberFormatToString(MoneyNumberFormat format) {
  return format == MoneyNumberFormat.international ? 'international' : 'lakh_crore';
}

final themeModeProvider = StateNotifierProvider<ThemeModeController, ThemeMode>(
  (ref) => ThemeModeController(),
);

class ThemeModeController extends StateNotifier<ThemeMode> {
  ThemeModeController() : super(ThemeMode.system) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = _themeModeFromString(prefs.getString(_themeModeKey));
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    state = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_themeModeKey, _themeModeToString(mode));
  }
}

final textScaleProvider = StateNotifierProvider<TextScaleController, double>(
  (ref) => TextScaleController(),
);

class TextScaleController extends StateNotifier<double> {
  TextScaleController() : super(1.0) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getDouble(_textScaleKey);
    state = (stored != null && kTextScaleSteps.contains(stored)) ? stored : 1.0;
  }

  Future<void> setTextScale(double scale) async {
    state = scale;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_textScaleKey, scale);
  }
}

/// The one provider `MoneyText` (app/lib/main.dart) reads from directly so
/// every existing call site — 40+ of them — picks up the preference without
/// threading a parameter through each one. Defaults to lakhCrore, matching
/// `profiles.number_format`'s own server-side default of `'lakh_crore'`.
final numberFormatProvider = StateNotifierProvider<NumberFormatController, MoneyNumberFormat>(
  (ref) => NumberFormatController(),
);

class NumberFormatController extends StateNotifier<MoneyNumberFormat> {
  NumberFormatController() : super(MoneyNumberFormat.lakhCrore) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = _numberFormatFromString(prefs.getString(_numberFormatKey));
  }

  Future<void> setNumberFormat(MoneyNumberFormat format) async {
    state = format;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_numberFormatKey, _numberFormatToString(format));
  }
}
