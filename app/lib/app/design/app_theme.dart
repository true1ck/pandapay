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

/// Measurements the four tab screens share with the shell's floating nav
/// pill (app/router.dart's `_FloatingNavBar`).
abstract final class AppShell {
  /// Bottom scroll padding every tab screen owes the pill — the mockups'
  /// own `padding:58px 0 128px` on each tab's scroll container. Content
  /// scrolls *under* the translucent bar (that's what its backdrop blur is
  /// for); this is the clearance that keeps the last row reachable.
  static const navClearance = 128.0;

  /// The pill's own height and inset from the bottom of the frame.
  static const navBarHeight = 66.0;
  static const navBarBottomInset = 26.0;
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
/// Outfit carries headings and interface copy; IBM Plex Sans keeps monetary
/// figures compact and easy to compare.
///
/// [AppTheme.light] is built on these tokens, so Material defaults (buttons,
/// fields, switches, chips, sheets, dialogs) match the hand-styled screens.
/// [AppColors] is the legacy navy/teal palette, kept only for the unused
/// dark theme and a few old references; don't use it for new UI.
abstract final class BambooInk {
  // Decision surfaces — the dark slate cards/sheets that carry a verdict
  // or an action, per the design chat's "L2"/Slate #2B313A pick.
  static const slate = Color(0xFF2B313A);
  static const slateRaised = Color(
    0xFF333A45,
  ); // top of a subtle vertical gradient on slate
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

  /// The cool grey that lifts from the bottom-left of every light screen —
  /// the second radial in the handoff's root background (see
  /// [AppBackground]). Balances the bamboo wash so white screens don't read
  /// as flat.
  static const paperCool = Color(0xFFEFF3F6);

  // Text/icon colors on paper.
  static const ink900 = Color(0xFF2B313A);
  static const ink700 = Color(0xFF59636C);
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

  // Design 05's rank badge — the one place the deck sets a bamboo-tinted
  // pill on paper. It works where [lime] wouldn't because the ink is a much
  // darker olive, not the accent itself.
  static const rankBadgeBg = Color(0xFFEEF7DA);
  static const rankBadgeBorder = Color(0xFFDCEDB6);
  static const rankBadgeInk = Color(0xFF4B7A12);

  // Ink colours for text set ON [warningBg] — clay itself is a fill/border
  // colour and fails contrast as body text on its own tint.
  static const clayInk = Color(0xFFB4441F);
  static const clayInkMuted = Color(0xFF8B5E4E);

  // Mid-severity amber — the token set otherwise defines only a two-tier
  // clay/jade pairing, but a few Insights screens (caps, fee waivers) have
  // a genuine third "getting close" tier between "fine" (jade) and "over
  // the line" (clay) that's real functional signal, not decoration.
  static const amber = Color(0xFFD97706);
}

/// Neutral paper tones for the Material surface roles the theme fills in
/// (menus, tracks, pressed states). Warm greys that sit with
/// [BambooInk.paperMuted], instead of the tinted tones Material derives
/// from a seed colour.
abstract final class _BambooSurfaces {
  static const low = Color(0xFFFBFAF7);
  static const high = Color(0xFFF1F0EA);
  static const highest = Color(0xFFE8E7E1);
  static const dim = Color(0xFFE4E3DD);
  static const outline = Color(0x4D2B313A); // rgba(43,49,58,.30)
}

/// Bright, light-theme colors for data visualizations.
///
/// These are intentionally separate from semantic status colors and the
/// slate/lime decision-surface pair. Charts need several distinct colors that
/// remain easy to compare on a white card without making the rest of the UI
/// feel noisy.
abstract final class BambooChartColors {
  static const teal = Color(0xFF159A78);
  static const blue = Color(0xFF3B82D0);
  static const amber = Color(0xFFE99A2F);
  static const violet = Color(0xFF8064C7);
  static const cyan = Color(0xFF2B9DB7);
  static const coral = Color(0xFFE96B58);
  static const rose = Color(0xFFD65D78);
  static const indigo = Color(0xFF5A6FD6);
  static const pink = Color(0xFFB85E9A);

  /// Stable order for charts whose categories are supplied by the API.
  static const categorical = <Color>[
    teal,
    blue,
    amber,
    violet,
    cyan,
    coral,
    rose,
    indigo,
    pink,
  ];

  static const chartTrack = Color(0xFFE8F0EC);
}

/// Bamboo Ink's type system. Outfit carries headings and interface copy;
/// IBM Plex Sans keeps monetary figures compact and easy to compare.
abstract final class BambooFonts {
  /// Lets widget tests render deterministically without fetching remote font
  /// files. Production keeps the branded Google Fonts enabled by default.
  @visibleForTesting
  static bool useSystemFontsForTests = false;

  static TextStyle money(
    double size, {
    FontWeight weight = FontWeight.w800,
    Color color = BambooInk.ink900,
    double? letterSpacing,
  }) => useSystemFontsForTests
      ? TextStyle(
          fontSize: size,
          fontWeight: weight,
          color: color,
          letterSpacing: letterSpacing ?? 0,
          height: 1.0,
          fontFeatures: const [FontFeature.tabularFigures()],
        )
      : GoogleFonts.ibmPlexSans(
          fontSize: size,
          fontWeight: weight,
          color: color,
          letterSpacing: letterSpacing ?? 0,
          height: 1.0,
          fontFeatures: const [FontFeature.tabularFigures()],
        );

  static TextStyle heading(
    double size, {
    FontWeight weight = FontWeight.w700,
    Color color = BambooInk.ink900,
    double? letterSpacing,
    double? height,
  }) => useSystemFontsForTests
      ? TextStyle(
          fontSize: size,
          fontWeight: weight,
          color: color,
          letterSpacing: letterSpacing ?? -size * 0.035,
          height: height,
        )
      : GoogleFonts.outfit(
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
  }) => useSystemFontsForTests
      ? TextStyle(
          fontSize: size,
          fontWeight: weight,
          color: color,
          height: height,
        )
      : GoogleFonts.outfit(
          fontSize: size,
          fontWeight: weight,
          color: color,
          height: height,
        );
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

  /// The app-wide theme, built on Bamboo Ink.
  ///
  /// Every Material default — buttons, fields, dropdown menus, switches,
  /// checkboxes, chips, spinners, bottom sheets, dialogs, snack bars — takes
  /// its colour from here. The old version seeded the scheme from the legacy
  /// teal, so any widget a screen didn't hand-style (a loading spinner, a
  /// focused field, a "Save" button in a sheet) came out teal-green and read
  /// as a different app. The rules this follows:
  ///
  /// - Slate carries every interactive decision: filled buttons, the "on"
  ///   state of switches/checkboxes/radios, selected chips, focus rings,
  ///   progress.
  /// - Lime only ever appears ON slate (button labels, switch thumbs, check
  ///   marks), never as text on white.
  /// - Surfaces are paper white with hairline borders, no tinted M3 tones.
  static ThemeData light() {
    const colorScheme = ColorScheme(
      brightness: Brightness.light,
      primary: BambooInk.slate,
      onPrimary: BambooInk.onSlate,
      primaryContainer: BambooInk.paperMuted,
      onPrimaryContainer: BambooInk.ink900,
      secondary: BambooInk.slate,
      onSecondary: BambooInk.onSlate,
      secondaryContainer: BambooInk.paperMuted,
      onSecondaryContainer: BambooInk.ink900,
      tertiary: BambooInk.jade,
      onTertiary: Colors.white,
      tertiaryContainer: BambooInk.rankBadgeBg,
      onTertiaryContainer: BambooInk.rankBadgeInk,
      error: BambooInk.clayInk,
      onError: Colors.white,
      errorContainer: BambooInk.warningBg,
      onErrorContainer: BambooInk.clayInk,
      surface: BambooInk.paper,
      onSurface: BambooInk.ink900,
      onSurfaceVariant: BambooInk.ink700,
      surfaceDim: _BambooSurfaces.dim,
      surfaceBright: BambooInk.paper,
      surfaceContainerLowest: BambooInk.paper,
      surfaceContainerLow: _BambooSurfaces.low,
      surfaceContainer: BambooInk.paperMuted,
      surfaceContainerHigh: _BambooSurfaces.high,
      surfaceContainerHighest: _BambooSurfaces.highest,
      outline: _BambooSurfaces.outline,
      outlineVariant: BambooInk.hairlineOnPaper,
      shadow: Colors.black,
      scrim: Colors.black,
      inverseSurface: BambooInk.slate,
      onInverseSurface: BambooInk.onSlate,
      inversePrimary: BambooInk.lime,
      surfaceTint: Colors.transparent,
    );

    // Outfit throughout, coloured with Bamboo Ink's warm inks rather than
    // the legacy cool greys. Tests that opt into system fonts (see
    // [BambooFonts.useSystemFontsForTests]) skip the remote font fetch.
    final base = BambooFonts.useSystemFontsForTests
        ? Typography.material2021().black
        : GoogleFonts.outfitTextTheme();
    final textTheme = base.copyWith(
      displayLarge: base.displayLarge?.copyWith(
        fontWeight: FontWeight.w700,
        color: BambooInk.ink900,
      ),
      displayMedium: base.displayMedium?.copyWith(
        fontWeight: FontWeight.w700,
        color: BambooInk.ink900,
      ),
      displaySmall: base.displaySmall?.copyWith(
        fontWeight: FontWeight.w700,
        color: BambooInk.ink900,
      ),
      headlineLarge: base.headlineLarge?.copyWith(
        fontWeight: FontWeight.w700,
        color: BambooInk.ink900,
      ),
      headlineMedium: base.headlineMedium?.copyWith(
        fontWeight: FontWeight.w700,
        color: BambooInk.ink900,
      ),
      headlineSmall: base.headlineSmall?.copyWith(
        fontWeight: FontWeight.w700,
        color: BambooInk.ink900,
      ),
      titleLarge: base.titleLarge?.copyWith(
        fontWeight: FontWeight.w700,
        color: BambooInk.ink900,
      ),
      titleMedium: base.titleMedium?.copyWith(
        fontWeight: FontWeight.w600,
        color: BambooInk.ink900,
      ),
      titleSmall: base.titleSmall?.copyWith(
        fontWeight: FontWeight.w600,
        color: BambooInk.ink900,
      ),
      bodyLarge: base.bodyLarge?.copyWith(color: BambooInk.ink900, height: 1.5),
      bodyMedium: base.bodyMedium?.copyWith(
        color: BambooInk.ink700,
        height: 1.5,
      ),
      bodySmall: base.bodySmall?.copyWith(color: BambooInk.ink500, height: 1.4),
      labelLarge: base.labelLarge?.copyWith(
        fontWeight: FontWeight.w600,
        color: BambooInk.ink900,
      ),
      labelMedium: base.labelMedium?.copyWith(
        fontWeight: FontWeight.w600,
        color: BambooInk.ink700,
      ),
      labelSmall: base.labelSmall?.copyWith(
        fontWeight: FontWeight.w500,
        color: BambooInk.ink500,
      ),
    );

    final fieldRadius = BorderRadius.circular(16);
    final buttonShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppRadius.md),
    );
    bool selected(Set<WidgetState> s) => s.contains(WidgetState.selected);
    bool disabled(Set<WidgetState> s) => s.contains(WidgetState.disabled);

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: BambooInk.paper,
      canvasColor: BambooInk.paper,
      cardColor: BambooInk.paper,
      dividerColor: BambooInk.hairlineOnPaper,
      textTheme: textTheme,
      iconTheme: const IconThemeData(color: BambooInk.ink700),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: BambooInk.slate,
        selectionColor: BambooInk.lime.withValues(alpha: 0.55),
        selectionHandleColor: BambooInk.slate,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: BambooInk.paper,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: BambooFonts.heading(18, color: BambooInk.ink900),
        iconTheme: const IconThemeData(color: BambooInk.ink900),
      ),
      cardTheme: CardThemeData(
        color: BambooInk.paper,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          side: const BorderSide(color: BambooInk.hairlineOnPaper),
        ),
        margin: EdgeInsets.zero,
      ),
      listTileTheme: ListTileThemeData(
        iconColor: BambooInk.ink700,
        textColor: BambooInk.ink900,
        titleTextStyle: BambooFonts.ui(
          15,
          weight: FontWeight.w500,
          color: BambooInk.ink900,
        ),
        subtitleTextStyle: BambooFonts.ui(13, color: BambooInk.ink500),
        leadingAndTrailingTextStyle: BambooFonts.ui(
          14,
          weight: FontWeight.w600,
          color: BambooInk.ink900,
        ),
        selectedColor: BambooInk.ink900,
      ),
      expansionTileTheme: const ExpansionTileThemeData(
        iconColor: BambooInk.ink900,
        collapsedIconColor: BambooInk.ink500,
        textColor: BambooInk.ink900,
        collapsedTextColor: BambooInk.ink900,
        shape: Border(),
        collapsedShape: Border(),
      ),
      // Per-state colours rather than `color`: a theme-level `color` would
      // override every chip's own backgroundColor/selectedColor.
      chipTheme: ChipThemeData(
        backgroundColor: BambooInk.paper,
        selectedColor: BambooInk.slate,
        disabledColor: BambooInk.paperMuted,
        checkmarkColor: BambooInk.lime,
        labelStyle: BambooFonts.ui(
          13,
          weight: FontWeight.w600,
          color: WidgetStateColor.resolveWith(
            (s) => disabled(s)
                ? BambooInk.ink500
                : selected(s)
                ? BambooInk.onSlate
                : BambooInk.ink900,
          ),
        ),
        iconTheme: const IconThemeData(color: BambooInk.ink700, size: 16),
        side: WidgetStateBorderSide.resolveWith(
          (s) => BorderSide(
            color: selected(s) ? BambooInk.slate : BambooInk.hairlineOnPaper,
          ),
        ),
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpace.sm,
          vertical: AppSpace.xs,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: BambooInk.glassFillOnPaper,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpace.lg,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: fieldRadius,
          borderSide: const BorderSide(color: BambooInk.hairlineOnPaper),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: fieldRadius,
          borderSide: const BorderSide(color: BambooInk.hairlineOnPaper),
        ),
        disabledBorder: OutlineInputBorder(
          borderRadius: fieldRadius,
          borderSide: const BorderSide(color: BambooInk.hairlineOnPaper),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: fieldRadius,
          borderSide: const BorderSide(color: BambooInk.slate, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: fieldRadius,
          borderSide: const BorderSide(color: BambooInk.clay, width: 1.2),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: fieldRadius,
          borderSide: const BorderSide(color: BambooInk.clay, width: 1.5),
        ),
        labelStyle: BambooFonts.ui(13.5, color: BambooInk.ink500),
        floatingLabelStyle: BambooFonts.ui(
          13.5,
          weight: FontWeight.w600,
          color: BambooInk.ink900,
        ),
        hintStyle: BambooFonts.ui(14, color: BambooInk.ink500),
        helperStyle: BambooFonts.ui(12, color: BambooInk.ink500),
        errorStyle: BambooFonts.ui(12, color: BambooInk.clayInk),
        counterStyle: BambooFonts.ui(11, color: BambooInk.ink500),
        prefixIconColor: BambooInk.ink500,
        suffixIconColor: BambooInk.ink500,
      ),
      dropdownMenuTheme: DropdownMenuThemeData(
        menuStyle: MenuStyle(
          backgroundColor: const WidgetStatePropertyAll(BambooInk.paper),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.md),
              side: const BorderSide(color: BambooInk.hairlineOnPaper),
            ),
          ),
        ),
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor: const WidgetStatePropertyAll(BambooInk.paper),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.md),
              side: const BorderSide(color: BambooInk.hairlineOnPaper),
            ),
          ),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: BambooInk.paper,
        surfaceTintColor: Colors.transparent,
        elevation: 6,
        shadowColor: Colors.black.withValues(alpha: 0.18),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          side: const BorderSide(color: BambooInk.hairlineOnPaper),
        ),
        textStyle: BambooFonts.ui(14, color: BambooInk.ink900),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: BambooInk.slate,
          foregroundColor: BambooInk.lime,
          iconColor: BambooInk.lime,
          disabledBackgroundColor: BambooInk.slate.withValues(alpha: 0.12),
          disabledForegroundColor: BambooInk.ink500,
          minimumSize: const Size.fromHeight(52),
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.xl),
          shape: buttonShape,
          textStyle: BambooFonts.ui(15.5, weight: FontWeight.w700),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: BambooInk.slate,
          foregroundColor: BambooInk.lime,
          elevation: 0,
          shape: buttonShape,
          textStyle: BambooFonts.ui(15, weight: FontWeight.w700),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: BambooInk.ink900,
          backgroundColor: BambooInk.paper,
          disabledForegroundColor: BambooInk.ink500,
          minimumSize: const Size.fromHeight(48),
          side: const BorderSide(color: BambooInk.hairlineOnPaper),
          shape: buttonShape,
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
          textStyle: BambooFonts.ui(15, weight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: BambooInk.ink900,
          disabledForegroundColor: BambooInk.ink500,
          shape: buttonShape,
          textStyle: BambooFonts.ui(14.5, weight: FontWeight.w600),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(foregroundColor: BambooInk.ink900),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          backgroundColor: BambooInk.paper,
          foregroundColor: BambooInk.ink900,
          selectedBackgroundColor: BambooInk.slate,
          selectedForegroundColor: BambooInk.lime,
          side: const BorderSide(color: BambooInk.hairlineOnPaper),
          textStyle: BambooFonts.ui(13.5, weight: FontWeight.w600),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => selected(s)
              ? BambooInk.lime
              : disabled(s)
              ? BambooInk.paperMuted
              : Colors.white,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => selected(s)
              ? (disabled(s)
                    ? BambooInk.slate.withValues(alpha: 0.35)
                    : BambooInk.slate)
              : _BambooSurfaces.highest,
        ),
        trackOutlineColor: WidgetStateProperty.resolveWith(
          (s) => selected(s) ? Colors.transparent : _BambooSurfaces.outline,
        ),
        overlayColor: WidgetStatePropertyAll(
          BambooInk.slate.withValues(alpha: 0.08),
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (s) => selected(s)
              ? (disabled(s)
                    ? BambooInk.slate.withValues(alpha: 0.35)
                    : BambooInk.slate)
              : Colors.transparent,
        ),
        checkColor: const WidgetStatePropertyAll(BambooInk.lime),
        side: WidgetStateBorderSide.resolveWith(
          (s) => selected(s)
              ? const BorderSide(color: BambooInk.slate)
              : const BorderSide(color: BambooInk.ink500, width: 1.5),
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (s) => selected(s) ? BambooInk.slate : BambooInk.ink500,
        ),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: BambooInk.slate,
        inactiveTrackColor: _BambooSurfaces.highest,
        thumbColor: BambooInk.slate,
        overlayColor: BambooInk.slate.withValues(alpha: 0.10),
        valueIndicatorColor: BambooInk.slate,
        valueIndicatorTextStyle: BambooFonts.ui(
          12,
          weight: FontWeight.w700,
          color: BambooInk.lime,
        ),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: BambooInk.slate,
        linearTrackColor: _BambooSurfaces.highest,
        circularTrackColor: Colors.transparent,
        refreshBackgroundColor: BambooInk.paper,
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: BambooInk.ink900,
        unselectedLabelColor: BambooInk.ink500,
        indicatorColor: BambooInk.slate,
        dividerColor: BambooInk.hairlineOnPaper,
        labelStyle: BambooFonts.ui(14, weight: FontWeight.w700),
        unselectedLabelStyle: BambooFonts.ui(14, weight: FontWeight.w500),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: BambooInk.slate,
        foregroundColor: BambooInk.lime,
        elevation: 2,
      ),
      bottomAppBarTheme: const BottomAppBarThemeData(
        color: BambooInk.paper,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: BambooInk.paper,
        modalBackgroundColor: BambooInk.paper,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        modalElevation: 0,
        clipBehavior: Clip.antiAlias,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        dragHandleColor: BambooInk.slate.withValues(alpha: 0.18),
        dragHandleSize: const Size(36, 4),
        modalBarrierColor: BambooInk.slate.withValues(alpha: 0.42),
      ),
      dividerTheme: const DividerThemeData(
        color: BambooInk.hairlineOnPaper,
        thickness: 1,
        space: 1,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: BambooInk.slate,
        contentTextStyle: BambooFonts.ui(14, color: BambooInk.onSlate),
        actionTextColor: BambooInk.lime,
        closeIconColor: BambooInk.onSlateSubtle,
        behavior: SnackBarBehavior.floating,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: BambooInk.slate,
          borderRadius: BorderRadius.circular(8),
        ),
        textStyle: BambooFonts.ui(12, color: BambooInk.onSlate),
      ),
      // Dialogs and date pickers: paper surface, slate header, lime only on
      // slate. Same values in light() and dark() — see main.dart for why the
      // app is pinned to light.
      dialogTheme: DialogThemeData(
        backgroundColor: BambooInk.paper,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
        ),
        titleTextStyle: BambooFonts.heading(18, color: BambooInk.ink900),
        contentTextStyle: BambooFonts.ui(14, color: BambooInk.ink700),
        barrierColor: BambooInk.slate.withValues(alpha: 0.42),
      ),
      datePickerTheme: _bambooDatePickerTheme,
      timePickerTheme: TimePickerThemeData(
        backgroundColor: BambooInk.paper,
        dialBackgroundColor: BambooInk.paperMuted,
        dialHandColor: BambooInk.slate,
        dialTextColor: WidgetStateColor.resolveWith(
          (s) => selected(s) ? BambooInk.lime : BambooInk.ink900,
        ),
        hourMinuteColor: WidgetStateColor.resolveWith(
          (s) => selected(s) ? BambooInk.slate : BambooInk.paperMuted,
        ),
        hourMinuteTextColor: WidgetStateColor.resolveWith(
          (s) => selected(s) ? BambooInk.lime : BambooInk.ink900,
        ),
        dayPeriodColor: WidgetStateColor.resolveWith(
          (s) => selected(s) ? BambooInk.slate : BambooInk.paper,
        ),
        dayPeriodTextColor: WidgetStateColor.resolveWith(
          (s) => selected(s) ? BambooInk.lime : BambooInk.ink900,
        ),
        entryModeIconColor: BambooInk.ink700,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
        ),
      ),
    );
  }

  static final _bambooDatePickerTheme = DatePickerThemeData(
    backgroundColor: BambooInk.paper,
    surfaceTintColor: Colors.transparent,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    headerBackgroundColor: BambooInk.slate,
    headerForegroundColor: BambooInk.lime,
    todayForegroundColor: WidgetStateProperty.resolveWith(
      (states) => states.contains(WidgetState.selected)
          ? BambooInk.lime
          : BambooInk.ink900,
    ),
    todayBorder: const BorderSide(color: BambooInk.slate, width: 1),
    dayForegroundColor: WidgetStateProperty.resolveWith(
      (states) => states.contains(WidgetState.disabled)
          ? BambooInk.ink500.withValues(alpha: 0.5)
          : states.contains(WidgetState.selected)
          ? BambooInk.lime
          : BambooInk.ink900,
    ),
    dayBackgroundColor: WidgetStateProperty.resolveWith(
      (states) =>
          states.contains(WidgetState.selected) ? BambooInk.slate : null,
    ),
    yearForegroundColor: WidgetStateProperty.resolveWith(
      (states) => states.contains(WidgetState.selected)
          ? BambooInk.lime
          : BambooInk.ink900,
    ),
    yearBackgroundColor: WidgetStateProperty.resolveWith(
      (states) =>
          states.contains(WidgetState.selected) ? BambooInk.slate : null,
    ),
    rangePickerBackgroundColor: BambooInk.paper,
    rangePickerSurfaceTintColor: Colors.transparent,
    rangePickerHeaderBackgroundColor: BambooInk.slate,
    rangePickerHeaderForegroundColor: BambooInk.lime,
    rangeSelectionBackgroundColor: BambooInk.wash,
    dividerColor: BambooInk.hairlineOnPaper,
    cancelButtonStyle: TextButton.styleFrom(foregroundColor: BambooInk.ink700),
    confirmButtonStyle: TextButton.styleFrom(
      foregroundColor: BambooInk.ink900,
      textStyle: BambooFonts.ui(14.5, weight: FontWeight.w700),
    ),
  );

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

    final display = BambooFonts.useSystemFontsForTests
        ? ThemeData.dark().textTheme
        : GoogleFonts.outfitTextTheme(ThemeData.dark().textTheme);
    final body = BambooFonts.useSystemFontsForTests
        ? ThemeData.dark().textTheme
        : GoogleFonts.outfitTextTheme(ThemeData.dark().textTheme);

    final textTheme = body.copyWith(
      displayLarge: display.displayLarge?.copyWith(fontWeight: FontWeight.w700),
      displayMedium: display.displayMedium?.copyWith(
        fontWeight: FontWeight.w700,
      ),
      displaySmall: display.displaySmall?.copyWith(fontWeight: FontWeight.w700),
      headlineLarge: display.headlineLarge?.copyWith(
        fontWeight: FontWeight.w700,
      ),
      headlineMedium: display.headlineMedium?.copyWith(
        fontWeight: FontWeight.w700,
      ),
      headlineSmall: display.headlineSmall?.copyWith(
        fontWeight: FontWeight.w700,
      ),
      titleLarge: display.titleLarge?.copyWith(
        fontWeight: FontWeight.w700,
        color: _AppColorsDark.ink900,
      ),
      titleMedium: display.titleMedium?.copyWith(
        fontWeight: FontWeight.w600,
        color: _AppColorsDark.ink900,
      ),
      titleSmall: display.titleSmall?.copyWith(
        fontWeight: FontWeight.w600,
        color: _AppColorsDark.ink900,
      ),
      bodyLarge: body.bodyLarge?.copyWith(
        color: _AppColorsDark.ink900,
        height: 1.5,
      ),
      bodyMedium: body.bodyMedium?.copyWith(
        color: _AppColorsDark.ink700,
        height: 1.5,
      ),
      bodySmall: body.bodySmall?.copyWith(
        color: _AppColorsDark.ink500,
        height: 1.4,
      ),
      labelLarge: body.labelLarge?.copyWith(
        fontWeight: FontWeight.w600,
        color: _AppColorsDark.ink900,
      ),
      labelMedium: body.labelMedium?.copyWith(
        fontWeight: FontWeight.w600,
        color: _AppColorsDark.ink700,
      ),
      labelSmall: body.labelSmall?.copyWith(
        fontWeight: FontWeight.w500,
        color: _AppColorsDark.ink500,
      ),
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
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        margin: EdgeInsets.zero,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: _AppColorsDark.surfaceMuted,
        selectedColor: AppColors.teal600.withValues(alpha: 0.25),
        labelStyle: textTheme.labelLarge,
        secondaryLabelStyle: textTheme.labelLarge?.copyWith(
          color: AppColors.teal400,
        ),
        side: BorderSide.none,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpace.md,
          vertical: AppSpace.xs,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: _AppColorsDark.surfaceMuted,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpace.lg,
          vertical: AppSpace.lg,
        ),
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
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          textStyle: textTheme.labelLarge?.copyWith(
            color: AppColors.navy900,
            fontSize: 16,
          ),
          disabledBackgroundColor: _AppColorsDark.ink100,
          disabledForegroundColor: _AppColorsDark.ink300,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: _AppColorsDark.ink900,
          minimumSize: const Size.fromHeight(48),
          side: const BorderSide(color: Color(0xFF33404D), width: 1.5),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
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
      dividerTheme: const DividerThemeData(
        color: Color(0xFF33404D),
        thickness: 1,
        space: 1,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: _AppColorsDark.surfaceMuted,
        contentTextStyle: textTheme.bodyMedium?.copyWith(
          color: _AppColorsDark.ink900,
        ),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
      ),
      // Same Bamboo Ink dialog/date-picker chrome as light() — deliberately
      // identical rather than swapped to the dark navy surfaces this
      // method otherwise uses, since every Bamboo-restyled screen already
      // renders on BambooInk.paper regardless of ThemeMode. See light()'s
      // own comment on this block for the full reasoning.
      dialogTheme: DialogThemeData(
        backgroundColor: BambooInk.paper,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        titleTextStyle: BambooFonts.heading(17, color: BambooInk.ink900),
        contentTextStyle: BambooFonts.ui(13.5, color: BambooInk.ink500),
      ),
      datePickerTheme: DatePickerThemeData(
        backgroundColor: BambooInk.paper,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        headerBackgroundColor: BambooInk.slate,
        headerForegroundColor: BambooInk.lime,
        todayForegroundColor: const WidgetStatePropertyAll(BambooInk.jade),
        todayBorder: const BorderSide(color: BambooInk.jade, width: 1),
        dayForegroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? BambooInk.onSlate
              : BambooInk.ink900,
        ),
        dayBackgroundColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? BambooInk.slate : null,
        ),
        yearForegroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? BambooInk.onSlate
              : BambooInk.ink900,
        ),
        yearBackgroundColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? BambooInk.slate : null,
        ),
      ),
    );
  }
}
