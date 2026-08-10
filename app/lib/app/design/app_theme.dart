import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// PandaPay's design system. Fintech UI conventions this follows: a
/// trust-signaling deep-navy/teal palette (blues read as stable, teals as
/// "financial health"), a bold display face for money/headings paired with
/// a highly legible workhorse body face, an 8pt spacing rhythm, and
/// generous whitespace so the one number that matters on a given screen
/// (a balance, a reward value) is never competing for attention.
abstract final class AppColors {
  // Brand — deep navy for trust/authority, teal accent for "financial
  // health" energy. Kept as a small, disciplined palette rather than
  // decorative color, per fintech UX guidance (color should guide
  // decisions, not decorate).
  static const navy900 = Color(0xFF0B1F33);
  static const navy800 = Color(0xFF122A45);
  static const navy700 = Color(0xFF1B3A5C);
  static const teal600 = Color(0xFF0F9B8E);
  static const teal500 = Color(0xFF14B8A6);
  static const teal400 = Color(0xFF2DD4BF);
  static const teal50 = Color(0xFFECFDF9);

  // Semantic — success/error must never be the only signal (paired with
  // icon/text elsewhere), but the color itself still needs to read
  // instantly and meet contrast at small sizes.
  static const success = Color(0xFF15803D);
  static const successBg = Color(0xFFEAF7EE);
  static const warning = Color(0xFFB45309);
  static const warningBg = Color(0xFFFEF3E2);
  static const error = Color(0xFFB91C1C);
  static const errorBg = Color(0xFFFDECEC);

  // Neutrals — the calm backdrop everything else sits on.
  static const ink900 = Color(0xFF11151A);
  static const ink700 = Color(0xFF3C4652);
  static const ink500 = Color(0xFF6B7684);
  static const ink300 = Color(0xFFAEB8C2);
  static const ink100 = Color(0xFFE7EBEF);
  static const surface = Color(0xFFFFFFFF);
  static const surfaceMuted = Color(0xFFF6F8FA);
  static const canvas = Color(0xFFF4F6F8);
}

/// 8pt spacing scale — every padding/gap in the redesigned screens should
/// reference this rather than a bespoke literal.
abstract final class AppSpace {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
  static const xxl = 32.0;
  static const xxxl = 48.0;
}

abstract final class AppRadius {
  static const sm = 10.0;
  static const md = 14.0;
  static const lg = 20.0;
  static const pill = 999.0;
}

/// "Bamboo Ink" — the design system from the Claude Design handoff
/// (`PandaPay Redesign.dc.html`, see `chats/chat1.md` and `chat2.md` in
/// that bundle for how it was arrived at): slate carries every decision
/// surface, bamboo lime marks the one thing worth acting on — and ONLY
/// ever on a slate surface, never as text/a number directly on paper,
/// per the design chat's own P4 palette finding ("lime can't be a number
/// on white") — and screens sit on white under a faint bamboo wash.
/// Money is set in Bricolage Grotesque, everything else in Instrument
/// Sans.
///
/// Landed additively, alongside [AppColors]/[AppTheme] rather than
/// replacing them: a global `ColorScheme`/`ThemeData` swap would silently
/// touch every already-built, already-tested screen's buttons/contrast
/// before each one gets its own reviewed restyle pass (most of those
/// screens are real, shipped features with widget-test coverage — see
/// PROGRESS.md). Home is the first screen migrated to these tokens;
/// further screens adopt [BambooInk]/[BambooFonts] one at a time.
abstract final class BambooInk {
  // Decision surfaces — the dark slate cards/sheets that carry a verdict
  // or an action, per the design chat's "L2"/Slate #2B313A pick.
  static const slate = Color(0xFF2B313A);
  static const slateRaised = Color(0xFF333A45); // top of a subtle vertical gradient on slate
  static const slateLow = Color(0xFF262B33); // bottom of that same gradient
  static const slateHairline = Color(0xFF424956);

  /// The one accent. Only ever on [slate]/[slateRaised] surfaces (a
  /// money figure, a badge, a filled button) — never set as text or a
  /// number directly on [paper], which is exactly the contrast problem
  /// the design chat ran into and fixed by confining lime to dark
  /// surfaces.
  static const lime = Color(0xFFCDF564);

  // Secondary accents (P4 palette: lime for money, ink/slate for
  // actions — jade/clay are the "Design DNA" swatch's supporting pair,
  // used sparingly for non-money semantic accents).
  static const jade = Color(0xFF12805C);
  static const clay = Color(0xFFE8623C);

  // Paper base — screens sit on white under a faint green wash falling
  // from the top-right, not a flat tint.
  static const paper = Color(0xFFFFFFFF);
  static const wash = Color(0xFFE4F2CF);
  static const paperMuted = Color(0xFFF7F6F0);

  // Text/icon colors on paper.
  static const ink900 = Color(0xFF2B313A);
  static const ink500 = Color(0xFF8B8F94);
  static const ink300 = Color(0xFF6E7379);
  static const hairlineOnPaper = Color(0x1F2B313A); // rgba(43,49,58,.12)

  // Text/icon colors on slate.
  static const onSlate = Color(0xFFFBFAF5);
  static const onSlateMuted = Color(0xFF8B9099);
  static const onSlateSubtle = Color(0xFFB9BFC5);

  // Glass panel fill for a card floating on the paper wash (frosted via
  // BackdropFilter at the call site — this is just the tint underneath).
  static const glassFillOnPaper = Color(0xD1FFFFFF); // rgba(255,255,255,.82)

  static const warningBg = Color(0xFFFFF3ED);
  static const warningBorder = Color(0xFFFBD9C9);

  // Mid-severity amber — the token set otherwise defines only a two-tier
  // clay/jade pairing, but a few Insights screens (caps, fee waivers) have
  // a genuine third "getting close" tier between "fine" (jade) and "over
  // the line" (clay) that's real functional signal, not decoration.
  static const amber = Color(0xFFD97706);
}

/// Bamboo Ink's two-face type system: Bricolage Grotesque for money and
/// headings, Instrument Sans for everything else. Thin wrappers around
/// `google_fonts` (already a dependency for the navy/teal system's own
/// Plus Jakarta Sans/Inter pairing) rather than a second `TextTheme`,
/// since Home is the only screen using these so far — see [BambooInk]'s
/// own doc-comment for why this isn't wired into the global `ThemeData`
/// yet.
abstract final class BambooFonts {
  static TextStyle money(
    double size, {
    FontWeight weight = FontWeight.w800,
    Color color = BambooInk.ink900,
    double? letterSpacing,
  }) =>
      GoogleFonts.bricolageGrotesque(
        fontSize: size,
        fontWeight: weight,
        color: color,
        letterSpacing: letterSpacing ?? -size * 0.045,
        height: 1.0,
        fontFeatures: const [FontFeature.tabularFigures()],
      );

  static TextStyle heading(
    double size, {
    FontWeight weight = FontWeight.w700,
    Color color = BambooInk.ink900,
    double? letterSpacing,
    double? height,
  }) =>
      GoogleFonts.bricolageGrotesque(
        fontSize: size,
        fontWeight: weight,
        color: color,
        letterSpacing: letterSpacing ?? -size * 0.035,
        height: height,
      );

  static TextStyle ui(
    double size, {
    FontWeight weight = FontWeight.w400,
    Color color = BambooInk.ink900,
    double? height,
  }) =>
      GoogleFonts.instrumentSans(fontSize: size, fontWeight: weight, color: color, height: height);
}

/// Dark-mode neutrals. `AppColors` above is a set of hardcoded light-mode
/// constants used throughout the app's widgets (cards, borders, icons) —
/// turning those genuinely theme-aware is a larger refactor than Task H6
/// (Appearance) scopes; this gives `ThemeMode.dark` a real, coherent
/// `ThemeData` to switch to (so the Appearance screen's theme control has
/// something to control) without rewriting every widget's color
/// references. Brand teal/navy accents are reused as-is — they already read
/// fine on a dark backdrop.
abstract final class _AppColorsDark {
  static const ink900 = Color(0xFFF3F5F7); // primary text on dark
  static const ink700 = Color(0xFFC7D0D9);
  static const ink500 = Color(0xFF8B96A3);
  static const ink300 = Color(0xFF4A5560);
  static const ink100 = Color(0xFF2A323C);
  static const surface = Color(0xFF161C24);
  static const surfaceMuted = Color(0xFF1E2630);
  static const canvas = Color(0xFF10151B);
}

class AppTheme {
  AppTheme._();

  static ThemeData light() {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: AppColors.teal500,
      brightness: Brightness.light,
      primary: AppColors.teal600,
      onPrimary: Colors.white,
      secondary: AppColors.navy700,
      surface: AppColors.surface,
      error: AppColors.error,
    );

    // Plus Jakarta Sans for headings/money (a bold, geometric, distinctly
    // "modern fintech" display face — the free, widely-used stand-in for
    // the commissioned faces houses like Stripe use); Inter for body copy
    // (the highest-legibility workhorse at small sizes). Tabular figures
    // are set explicitly wherever money/amounts render (see MoneyText).
    final display = GoogleFonts.plusJakartaSansTextTheme();
    final body = GoogleFonts.interTextTheme();

    final textTheme = body.copyWith(
      displayLarge: display.displayLarge?.copyWith(fontWeight: FontWeight.w700),
      displayMedium: display.displayMedium?.copyWith(fontWeight: FontWeight.w700),
      displaySmall: display.displaySmall?.copyWith(fontWeight: FontWeight.w700),
      headlineLarge: display.headlineLarge?.copyWith(fontWeight: FontWeight.w700),
      headlineMedium: display.headlineMedium?.copyWith(fontWeight: FontWeight.w700),
      headlineSmall: display.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
      titleLarge: display.titleLarge?.copyWith(fontWeight: FontWeight.w700, color: AppColors.ink900),
      titleMedium: display.titleMedium?.copyWith(fontWeight: FontWeight.w600, color: AppColors.ink900),
      titleSmall: display.titleSmall?.copyWith(fontWeight: FontWeight.w600, color: AppColors.ink900),
      bodyLarge: body.bodyLarge?.copyWith(color: AppColors.ink900, height: 1.5),
      bodyMedium: body.bodyMedium?.copyWith(color: AppColors.ink700, height: 1.5),
      bodySmall: body.bodySmall?.copyWith(color: AppColors.ink500, height: 1.4),
      labelLarge: body.labelLarge?.copyWith(fontWeight: FontWeight.w600, color: AppColors.ink900),
      labelMedium: body.labelMedium?.copyWith(fontWeight: FontWeight.w600, color: AppColors.ink700),
      labelSmall: body.labelSmall?.copyWith(fontWeight: FontWeight.w500, color: AppColors.ink500),
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: AppColors.canvas,
      textTheme: textTheme,
      appBarTheme: AppBarTheme(
        backgroundColor: AppColors.canvas,
        foregroundColor: AppColors.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: textTheme.titleLarge,
      ),
      cardTheme: CardThemeData(
        color: AppColors.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.lg)),
        margin: EdgeInsets.zero,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: AppColors.surfaceMuted,
        selectedColor: AppColors.teal50,
        labelStyle: textTheme.labelLarge,
        secondaryLabelStyle: textTheme.labelLarge?.copyWith(color: AppColors.teal600),
        side: BorderSide.none,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.pill)),
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.md, vertical: AppSpace.xs),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surfaceMuted,
        contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.lg, vertical: AppSpace.lg),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: const BorderSide(color: AppColors.teal500, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: const BorderSide(color: AppColors.error, width: 1.5),
        ),
        labelStyle: textTheme.bodyMedium,
        hintStyle: textTheme.bodyMedium?.copyWith(color: AppColors.ink300),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.teal600,
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(52),
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.xl),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
          textStyle: textTheme.labelLarge?.copyWith(color: Colors.white, fontSize: 16),
          disabledBackgroundColor: AppColors.ink100,
          disabledForegroundColor: AppColors.ink300,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.navy800,
          minimumSize: const Size.fromHeight(48),
          side: const BorderSide(color: AppColors.ink100, width: 1.5),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: BambooInk.ink900,
          textStyle: textTheme.labelLarge,
        ),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: AppColors.navy900,
        foregroundColor: Colors.white,
        elevation: 2,
      ),
      bottomAppBarTheme: const BottomAppBarThemeData(
        color: AppColors.surface,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
      dividerTheme: const DividerThemeData(color: AppColors.ink100, thickness: 1, space: 1),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: AppColors.navy900,
        contentTextStyle: textTheme.bodyMedium?.copyWith(color: Colors.white),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.sm)),
      ),
      // Bamboo Ink dialog/date-picker chrome — additive, same reasoning as
      // every per-screen restyle this session: AlertDialog/showDatePicker
      // are cross-cutting overlays used from dozens of already-restyled
      // screens (delete/restore confirmations, the future-date warning,
      // help dialogs, tutorial completion) that would otherwise still pop
      // up in this theme's old navy/teal M3 defaults, clashing with the
      // Bamboo Ink screen underneath. Deliberately identical in light()
      // and dark(): every Bamboo-restyled screen already renders on
      // BambooInk.paper regardless of ThemeMode (see appearance_screen.dart's
      // own doc-comment on text-scale/theme-mode scope), so a dialog that
      // swapped to a dark surface under dark ThemeMode would itself clash
      // with the light Bamboo screen behind it.
      dialogTheme: DialogThemeData(
        backgroundColor: BambooInk.paper,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.lg)),
        titleTextStyle: BambooFonts.heading(17, color: BambooInk.ink900),
        contentTextStyle: BambooFonts.ui(13.5, color: BambooInk.ink500),
      ),
      datePickerTheme: DatePickerThemeData(
        backgroundColor: BambooInk.paper,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.lg)),
        headerBackgroundColor: BambooInk.slate,
        headerForegroundColor: BambooInk.lime,
        todayForegroundColor: const WidgetStatePropertyAll(BambooInk.jade),
        todayBorder: const BorderSide(color: BambooInk.jade, width: 1),
        dayForegroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? BambooInk.onSlate : BambooInk.ink900,
        ),
        dayBackgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? BambooInk.slate : null,
        ),
        yearForegroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? BambooInk.onSlate : BambooInk.ink900,
        ),
        yearBackgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? BambooInk.slate : null,
        ),
      ),
    );
  }

  /// Task H6 (Appearance) — minimal dark variant. Mirrors light()'s
  /// structure component-for-component so both themes stay visually
  /// consistent; only the neutral surface/text colors swap to
  /// [_AppColorsDark], brand teal/navy accents are unchanged.
  static ThemeData dark() {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: AppColors.teal500,
      brightness: Brightness.dark,
      primary: AppColors.teal400,
      onPrimary: AppColors.navy900,
      secondary: AppColors.teal500,
      surface: _AppColorsDark.surface,
      error: const Color(0xFFEF5350),
    );

    final display = GoogleFonts.plusJakartaSansTextTheme(ThemeData.dark().textTheme);
    final body = GoogleFonts.interTextTheme(ThemeData.dark().textTheme);

    final textTheme = body.copyWith(
      displayLarge: display.displayLarge?.copyWith(fontWeight: FontWeight.w700),
      displayMedium: display.displayMedium?.copyWith(fontWeight: FontWeight.w700),
      displaySmall: display.displaySmall?.copyWith(fontWeight: FontWeight.w700),
      headlineLarge: display.headlineLarge?.copyWith(fontWeight: FontWeight.w700),
      headlineMedium: display.headlineMedium?.copyWith(fontWeight: FontWeight.w700),
      headlineSmall: display.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
      titleLarge: display.titleLarge?.copyWith(fontWeight: FontWeight.w700, color: _AppColorsDark.ink900),
      titleMedium: display.titleMedium?.copyWith(fontWeight: FontWeight.w600, color: _AppColorsDark.ink900),
      titleSmall: display.titleSmall?.copyWith(fontWeight: FontWeight.w600, color: _AppColorsDark.ink900),
      bodyLarge: body.bodyLarge?.copyWith(color: _AppColorsDark.ink900, height: 1.5),
      bodyMedium: body.bodyMedium?.copyWith(color: _AppColorsDark.ink700, height: 1.5),
      bodySmall: body.bodySmall?.copyWith(color: _AppColorsDark.ink500, height: 1.4),
      labelLarge: body.labelLarge?.copyWith(fontWeight: FontWeight.w600, color: _AppColorsDark.ink900),
      labelMedium: body.labelMedium?.copyWith(fontWeight: FontWeight.w600, color: _AppColorsDark.ink700),
      labelSmall: body.labelSmall?.copyWith(fontWeight: FontWeight.w500, color: _AppColorsDark.ink500),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: _AppColorsDark.canvas,
      textTheme: textTheme,
      appBarTheme: AppBarTheme(
        backgroundColor: _AppColorsDark.canvas,
        foregroundColor: _AppColorsDark.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: textTheme.titleLarge,
      ),
      cardTheme: CardThemeData(
        color: _AppColorsDark.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.lg)),
        margin: EdgeInsets.zero,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: _AppColorsDark.surfaceMuted,
        selectedColor: AppColors.teal600.withValues(alpha: 0.25),
        labelStyle: textTheme.labelLarge,
        secondaryLabelStyle: textTheme.labelLarge?.copyWith(color: AppColors.teal400),
        side: BorderSide.none,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.pill)),
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.md, vertical: AppSpace.xs),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: _AppColorsDark.surfaceMuted,
        contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.lg, vertical: AppSpace.lg),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: const BorderSide(color: AppColors.teal400, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: const BorderSide(color: Color(0xFFEF5350), width: 1.5),
        ),
        labelStyle: textTheme.bodyMedium,
        hintStyle: textTheme.bodyMedium?.copyWith(color: _AppColorsDark.ink300),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.teal500,
          foregroundColor: AppColors.navy900,
          minimumSize: const Size.fromHeight(52),
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.xl),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
          textStyle: textTheme.labelLarge?.copyWith(color: AppColors.navy900, fontSize: 16),
          disabledBackgroundColor: _AppColorsDark.ink100,
          disabledForegroundColor: _AppColorsDark.ink300,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: _AppColorsDark.ink900,
          minimumSize: const Size.fromHeight(48),
          side: const BorderSide(color: Color(0xFF33404D), width: 1.5),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: BambooInk.ink900,
          textStyle: textTheme.labelLarge,
        ),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: AppColors.teal500,
        foregroundColor: AppColors.navy900,
        elevation: 2,
      ),
      bottomAppBarTheme: BottomAppBarThemeData(
        color: _AppColorsDark.surface,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
      dividerTheme: const DividerThemeData(color: Color(0xFF33404D), thickness: 1, space: 1),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: _AppColorsDark.surfaceMuted,
        contentTextStyle: textTheme.bodyMedium?.copyWith(color: _AppColorsDark.ink900),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.sm)),
      ),
      // Same Bamboo Ink dialog/date-picker chrome as light() — deliberately
      // identical rather than swapped to the dark navy surfaces this
      // method otherwise uses, since every Bamboo-restyled screen already
      // renders on BambooInk.paper regardless of ThemeMode. See light()'s
      // own comment on this block for the full reasoning.
      dialogTheme: DialogThemeData(
        backgroundColor: BambooInk.paper,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.lg)),
        titleTextStyle: BambooFonts.heading(17, color: BambooInk.ink900),
        contentTextStyle: BambooFonts.ui(13.5, color: BambooInk.ink500),
      ),
      datePickerTheme: DatePickerThemeData(
        backgroundColor: BambooInk.paper,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.lg)),
        headerBackgroundColor: BambooInk.slate,
        headerForegroundColor: BambooInk.lime,
        todayForegroundColor: const WidgetStatePropertyAll(BambooInk.jade),
        todayBorder: const BorderSide(color: BambooInk.jade, width: 1),
        dayForegroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? BambooInk.onSlate : BambooInk.ink900,
        ),
        dayBackgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? BambooInk.slate : null,
        ),
        yearForegroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? BambooInk.onSlate : BambooInk.ink900,
        ),
        yearBackgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? BambooInk.slate : null,
        ),
      ),
    );
  }
}
