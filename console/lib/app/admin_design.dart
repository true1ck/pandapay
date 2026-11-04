import 'package:flutter/material.dart';

/// Visual tokens shared by the operations console and PandaPay's consumer app.
/// Keep the bamboo-lime accent on slate surfaces so it stays legible.
abstract final class AdminColors {
  static const slate = Color(0xFF2B313A);
  static const slateRaised = Color(0xFF333A45);
  static const slateLine = Color(0xFF424956);
  static const lime = Color(0xFFCDF564);
  static const onSlateMuted = Color(0xFF8B9099);
  static const onSlateSubtle = Color(0xFFB9BFC5);
  static const jade = Color(0xFF12805C);
  static const paper = Color(0xFFFFFFFF);
  static const paperMuted = Color(0xFFF7F6F0);
  static const canvas = Color(0xFFF1F4F1);
  static const ink = Color(0xFF2B313A);
  static const muted = Color(0xFF6E7379);
  static const hairline = Color(0x1F2B313A);
  static const warning = Color(0xFF9A4A12);
  static const warningBg = Color(0xFFFFF3ED);
  static const success = Color(0xFF12805C);
  static const successBg = Color(0xFFEDF7F0);
  static const error = Color(0xFFB42318);
  static const errorBg = Color(0xFFFFF1F0);
  // BambooInk accents for environment and attention states.
  static const clay = Color(0xFFE8623C);
  static const clayInk = Color(0xFFB4441F);
  static const amber = Color(0xFFD97706);
  static const wash = Color(0xFFE4F2CF);
}

ThemeData adminConsoleTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: AdminColors.slate,
    brightness: Brightness.light,
    primary: AdminColors.slate,
    onPrimary: AdminColors.lime,
    secondary: AdminColors.jade,
    surface: AdminColors.paper,
    error: AdminColors.error,
  );
  final baseText = ThemeData.light().textTheme.apply(
    bodyColor: AdminColors.ink,
    displayColor: AdminColors.ink,
    fontFamily: 'Roboto',
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    fontFamily: 'Roboto',
    fontFamilyFallback: const ['Roboto'],
    visualDensity: VisualDensity.compact,
    scaffoldBackgroundColor: AdminColors.canvas,
    textTheme: baseText.copyWith(
      headlineLarge: baseText.headlineLarge?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -0.8,
      ),
      headlineMedium: baseText.headlineMedium?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -0.45,
      ),
      titleLarge: baseText.titleLarge?.copyWith(fontWeight: FontWeight.w700),
      titleMedium: baseText.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      bodyMedium: baseText.bodyMedium?.copyWith(height: 1.45),
      bodySmall: baseText.bodySmall?.copyWith(color: AdminColors.muted),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: AdminColors.paper,
      foregroundColor: AdminColors.ink,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
    ),
    cardTheme: CardThemeData(
      color: AdminColors.paper,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: AdminColors.hairline),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AdminColors.paperMuted,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AdminColors.hairline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AdminColors.hairline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AdminColors.jade, width: 1.5),
      ),
    ),
    tabBarTheme: const TabBarThemeData(
      labelColor: AdminColors.ink,
      unselectedLabelColor: AdminColors.muted,
      indicatorColor: AdminColors.jade,
      dividerColor: AdminColors.hairline,
      labelStyle: TextStyle(fontWeight: FontWeight.w600),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AdminColors.slate,
        foregroundColor: AdminColors.lime,
        minimumSize: const Size(44, 44),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AdminColors.ink,
        side: const BorderSide(color: AdminColors.hairline),
        minimumSize: const Size(44, 44),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    dividerTheme: const DividerThemeData(
      color: AdminColors.hairline,
      thickness: 1,
    ),
    chipTheme: ChipThemeData(
      side: const BorderSide(color: AdminColors.hairline),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      labelStyle: const TextStyle(color: AdminColors.ink),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: AdminColors.slate,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
  );
}

/// Consistent empty states explain what the operator is looking at and why it
/// may be empty, instead of leaving an isolated sentence in the middle.
class AdminEmptyState extends StatelessWidget {
  const AdminEmptyState({
    required this.title,
    required this.message,
    this.icon = Icons.inbox_outlined,
    this.action,
    super.key,
  });

  final String title;
  final String message;
  final IconData icon;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportWidth = MediaQuery.sizeOf(context).width;
        final availableWidth = constraints.hasBoundedWidth
            ? (constraints.maxWidth < viewportWidth
                  ? constraints.maxWidth
                  : viewportWidth)
            : viewportWidth;
        final contentWidth = availableWidth.clamp(0.0, 460.0);
        final horizontalPadding = availableWidth < 420 ? 16.0 : 24.0;
        return Center(
          child: SizedBox(
            width: contentWidth,
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: horizontalPadding,
                vertical: 24,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: AdminColors.slate,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Icon(icon, color: AdminColors.lime, size: 26),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    message,
                    textAlign: TextAlign.center,
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(color: AdminColors.muted),
                  ),
                  if (action != null) ...[const SizedBox(height: 20), action!],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class AdminLoadError extends StatelessWidget {
  const AdminLoadError({
    required this.title,
    required this.error,
    this.onRetry,
    super.key,
  });

  final String title;
  final Object error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportWidth = MediaQuery.sizeOf(context).width;
        final availableWidth = constraints.hasBoundedWidth
            ? (constraints.maxWidth < viewportWidth
                  ? constraints.maxWidth
                  : viewportWidth)
            : viewportWidth;
        final contentWidth = availableWidth.clamp(0.0, 560.0);
        final horizontalPadding = availableWidth < 420 ? 16.0 : 24.0;
        return Center(
          child: SizedBox(
            width: contentWidth,
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: horizontalPadding,
                vertical: 24,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.cloud_off_outlined,
                    size: 34,
                    color: AdminColors.warning,
                  ),
                  const SizedBox(height: 12),
                  Text(title, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 6),
                  Text(
                    'The console could not retrieve this information. Check the local services and retry.',
                    textAlign: TextAlign.center,
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(color: AdminColors.muted),
                  ),
                  const SizedBox(height: 10),
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: const Text('Technical details'),
                    children: [SelectableText(error.toString())],
                  ),
                  if (onRetry != null) ...[
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: onRetry,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Try again'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
