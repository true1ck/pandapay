import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'widgets.dart';

/// Shared Bamboo Ink building blocks for sheets, forms and list screens.
///
/// Screens that were built straight on Material defaults (plain `Card`,
/// `ListTile`, `SimpleDialog`, fields stacked with no gaps) read as a
/// different app from the hand-styled ones. These pieces carry the same
/// measurements the polished screens use — white glass panels with a
/// hairline border and a 20pt radius, uppercase section labels, 12pt gaps
/// between form fields — so a screen can be built to match without
/// re-deriving them.

/// Opens a bottom sheet with the app's standard chrome: paper surface, a
/// drag handle, rounded top corners and keyboard-aware sizing. Pair it with
/// [BambooSheet] for the body.
Future<T?> showBambooSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isDismissible = true,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    isDismissible: isDismissible,
    backgroundColor: BambooInk.paper,
    builder: builder,
  );
}

/// The body of a bottom sheet: a title block, evenly spaced content and
/// the actions underneath. Scrolls, and lifts above the keyboard.
///
/// Wrap it in a `Form` when the content holds validated fields.
class BambooSheet extends StatelessWidget {
  const BambooSheet({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    required this.children,
    this.actions = const [],
    this.spacing = AppSpace.md,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final List<Widget> children;

  /// Buttons under the content, primary first. Each takes the full width.
  final List<Widget> actions;

  /// Gap between [children]. 12pt matches every hand-built form sheet.
  final double spacing;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          20,
          0,
          20,
          20 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            BambooTitleBlock(title: title, subtitle: subtitle, icon: icon),
            const SizedBox(height: 20),
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              spacing: spacing,
              children: children,
            ),
            if (actions.isNotEmpty) ...[
              const SizedBox(height: AppSpace.xl),
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                spacing: AppSpace.sm,
                children: actions,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Title, optional supporting line and optional icon tile — the header of
/// a sheet or the top of a screen's body.
class BambooTitleBlock extends StatelessWidget {
  const BambooTitleBlock({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.titleSize = 20,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final double titleSize;

  @override
  Widget build(BuildContext context) {
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          style: BambooFonts.heading(titleSize, color: BambooInk.ink900),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: AppSpace.xs),
          Text(
            subtitle!,
            style: BambooFonts.ui(13.5, color: BambooInk.ink500, height: 1.4),
          ),
        ],
      ],
    );
    if (icon == null) return text;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        BambooIconTile(icon!, size: 44),
        const SizedBox(width: AppSpace.md),
        Expanded(child: text),
      ],
    );
  }
}

/// A white glass panel with a hairline border — the card every polished
/// screen uses. Pass [onTap] to make the whole panel pressable.
class BambooPanel extends StatelessWidget {
  const BambooPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppSpace.lg),
    this.onTap,
    this.semanticLabel,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    // A Material rather than a decorated box, so ListTiles and ink
    // responses inside the panel paint on it instead of underneath it.
    final panel = Material(
      color: BambooInk.glassFillOnPaper,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        side: const BorderSide(color: BambooInk.hairlineOnPaper),
      ),
      child: SizedBox(
        width: double.infinity,
        child: Padding(padding: padding, child: child),
      ),
    );
    if (onTap == null) return panel;
    return Pressable(onTap: onTap, semanticLabel: semanticLabel, child: panel);
  }
}

/// The label above a group of panels or rows, with an optional trailing
/// value (a section total, say). Small uppercase caps by default; pass
/// `asTitle: true` for a sentence-case heading when the label is a question
/// or a name the user reads as a title ("Is this the same payment?").
class BambooSectionLabel extends StatelessWidget {
  const BambooSectionLabel(
    this.text, {
    super.key,
    this.trailing,
    this.asTitle = false,
    this.padding = const EdgeInsets.fromLTRB(4, AppSpace.xl, 4, 10),
  });

  final String text;
  final String? trailing;
  final bool asTitle;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final style = asTitle
        ? BambooFonts.heading(16.5, color: BambooInk.ink900)
        : BambooFonts.ui(
            12,
            weight: FontWeight.w700,
            color: BambooInk.ink500,
          ).copyWith(letterSpacing: 1.1);
    return Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Expanded(
            child: Text(asTitle ? text : text.toUpperCase(), style: style),
          ),
          if (trailing != null)
            Text(
              trailing!,
              style: BambooFonts.money(
                asTitle ? 14 : 13,
                weight: FontWeight.w700,
                color: asTitle ? BambooInk.ink900 : BambooInk.ink700,
              ),
            ),
        ],
      ),
    );
  }
}

/// A rounded square holding an icon — the leading visual of a row or the
/// mark beside a sheet title.
class BambooIconTile extends StatelessWidget {
  const BambooIconTile(
    this.icon, {
    super.key,
    this.size = 40,
    this.background = BambooInk.paperMuted,
    this.foreground = BambooInk.ink900,
  });

  final IconData icon;
  final double size;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(size * 0.3),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      child: Icon(icon, size: size * 0.5, color: foreground),
    );
  }
}

/// A quiet, tinted line of reassurance or context ("Your message text stays
/// on this phone"). Not a warning — use clay tones for those.
class BambooNote extends StatelessWidget {
  const BambooNote(this.text, {super.key, this.icon = Icons.lock_outline});

  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: BambooInk.paperMuted,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, size: 16, color: BambooInk.ink500),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: BambooFonts.ui(12.5, color: BambooInk.ink700, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

/// A clay-tinted inline message for a problem the user needs to act on
/// (a validation failure, a step that stopped).
class BambooAlertNote extends StatelessWidget {
  const BambooAlertNote(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: BambooInk.warningBg,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: BambooInk.warningBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.error_outline_rounded,
            size: 16,
            color: BambooInk.clayInk,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: BambooFonts.ui(
                12.5,
                color: BambooInk.clayInk,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One labelled figure on a line: label on the left, value on the right.
class BambooFigureRow extends StatelessWidget {
  const BambooFigureRow(this.label, this.value, {super.key});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Expanded(
            child: Text(
              label,
              style: BambooFonts.ui(13.5, color: BambooInk.ink700),
            ),
          ),
          const SizedBox(width: AppSpace.md),
          Text(
            value,
            textAlign: TextAlign.right,
            style: BambooFonts.money(
              14,
              weight: FontWeight.w700,
              color: BambooInk.ink900,
            ),
          ),
        ],
      ),
    );
  }
}

/// The text of an SMS, set apart from the app's own copy so it reads as a
/// quote. Selectable, because users copy merchant names out of it.
class BambooMessageQuote extends StatelessWidget {
  const BambooMessageQuote(this.body, {super.key, this.sender});

  final String body;
  final String? sender;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: BambooInk.paperMuted,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: const Border(
          left: BorderSide(color: BambooInk.slate, width: 3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (sender != null) ...[
            Text(
              sender!,
              style: BambooFonts.ui(
                11,
                weight: FontWeight.w700,
                color: BambooInk.ink500,
              ).copyWith(letterSpacing: 0.6),
            ),
            const SizedBox(height: 6),
          ],
          SelectableText(
            body,
            style: BambooFonts.ui(13.5, color: BambooInk.ink900, height: 1.45),
          ),
        ],
      ),
    );
  }
}

/// One option in [showBambooChoiceSheet].
class BambooChoice<T> {
  const BambooChoice({
    required this.value,
    required this.label,
    this.detail,
    this.icon,
  });

  final T value;
  final String label;
  final String? detail;
  final IconData? icon;
}

/// A bottom sheet that asks the user to pick one option — the mobile
/// replacement for a `SimpleDialog` list.
Future<T?> showBambooChoiceSheet<T>({
  required BuildContext context,
  required String title,
  String? subtitle,
  IconData? icon,
  required List<BambooChoice<T>> options,
  String? emptyMessage,
}) {
  return showBambooSheet<T>(
    context: context,
    builder: (sheetContext) => BambooSheet(
      title: title,
      subtitle: subtitle,
      icon: icon,
      spacing: AppSpace.sm,
      children: [
        if (options.isEmpty && emptyMessage != null)
          BambooNote(emptyMessage, icon: Icons.info_outline),
        for (final option in options)
          BambooPanel(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            onTap: () => Navigator.pop(sheetContext, option.value),
            child: Row(
              children: [
                if (option.icon != null) ...[
                  BambooIconTile(option.icon!, size: 36),
                  const SizedBox(width: AppSpace.md),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        option.label,
                        style: BambooFonts.ui(
                          14.5,
                          weight: FontWeight.w600,
                          color: BambooInk.ink900,
                        ),
                      ),
                      if (option.detail != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          option.detail!,
                          style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                        ),
                      ],
                    ],
                  ),
                ),
                const Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: BambooInk.ink500,
                ),
              ],
            ),
          ),
      ],
    ),
  );
}

/// Buttons laid out the same way everywhere a card offers more than one
/// action: the primary action fills the row, secondary actions share the
/// line beneath it, and quiet text actions sit centred at the bottom.
class BambooActionBar extends StatelessWidget {
  const BambooActionBar({
    super.key,
    this.primary,
    this.secondary = const [],
    this.quiet = const [],
  });

  final Widget? primary;

  /// Outlined buttons sharing one row under the primary action.
  final List<Widget> secondary;

  /// Low-emphasis text buttons ("Not financial"), centred on the last row.
  final List<Widget> quiet;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      spacing: AppSpace.sm,
      children: [
        ?primary,
        if (secondary.isNotEmpty)
          Row(
            spacing: AppSpace.sm,
            children: [for (final button in secondary) Expanded(child: button)],
          ),
        if (quiet.isNotEmpty)
          Wrap(
            alignment: WrapAlignment.center,
            spacing: AppSpace.xs,
            children: quiet,
          ),
      ],
    );
  }
}

/// Compact button styles for actions that sit inside a panel, where the
/// theme's full-width 52pt button would dominate the card.
abstract final class BambooButtons {
  static ButtonStyle get primary => FilledButton.styleFrom(
    minimumSize: const Size(0, 44),
    padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
    textStyle: BambooFonts.ui(14.5, weight: FontWeight.w700),
  );

  static ButtonStyle get secondary => OutlinedButton.styleFrom(
    minimumSize: const Size(0, 44),
    padding: const EdgeInsets.symmetric(horizontal: AppSpace.md),
    textStyle: BambooFonts.ui(14, weight: FontWeight.w600),
  );

  static ButtonStyle get quiet => TextButton.styleFrom(
    minimumSize: const Size(0, 44),
    padding: const EdgeInsets.symmetric(horizontal: AppSpace.md),
    foregroundColor: BambooInk.ink700,
    textStyle: BambooFonts.ui(14, weight: FontWeight.w600),
  );
}
