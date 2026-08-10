import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import 'app/design/app_theme.dart';
import 'app/router.dart';
import 'features/settings/appearance_providers.dart';

void main() {
  runApp(const ProviderScope(child: PandaPayApp()));
}

/// UA-0.4.2 bottom nav: Home · Cards · raised SCAN FAB · Activity · Account.
/// All four tabs are real as of Chunk 18. Navigation shell (route
/// registration, the FAB, and the bottom nav itself) lives in
/// app/router.dart as of the go_router migration (Task 3) — this widget
/// just wires the router into MaterialApp.
///
/// Task H6 (Appearance): themeMode/theme/darkTheme are wired to
/// themeModeProvider (app/lib/features/settings/appearance_providers.dart)
/// here, at the app root, same as any other MaterialApp.router config would
/// need. Text-scale is deliberately NOT applied at this root level yet — see
/// appearance_screen.dart's own doc-comment for why that's left as a
/// follow-up rather than wrapped in here blind.
class PandaPayApp extends ConsumerWidget {
  const PandaPayApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    return MaterialApp.router(
      title: 'PandaPay',
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: themeMode,
      routerConfig: ref.watch(goRouterProvider),
    );
  }
}

/// UA-0.2.4: financial figures must always render through a widget that
/// requires a [Confidence] — a bare `Text('₹\$x')` is a compile-time trap
/// waiting to happen once the custom_lint rule lands (see analysis_options.yaml).
///
/// Task H6: reads numberFormatProvider so every one of this widget's 40+
/// call sites picks up the Appearance screen's lakh/crore-vs-international
/// preference without threading a parameter through each of them — this is
/// the one call site H6 needs to edit, not all its callers.
class MoneyText extends ConsumerWidget {
  final Money amount;
  final Confidence confidence;
  final TextStyle? style;

  const MoneyText(this.amount, {super.key, required this.confidence, this.style});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final baseStyle = style ?? Theme.of(context).textTheme.titleMedium;
    final numberFormat = ref.watch(numberFormatProvider);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // This *is* the required Money-rendering widget — exempt by design.
        // ignore: no_bare_money_text
        Text(
          amount.format(format: numberFormat),
          style: baseStyle?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
        ),
        const SizedBox(width: 6),
        Icon(
          confidence.isConfirmed ? Icons.check_circle_rounded : Icons.hourglass_top_rounded,
          size: 14,
          color: confidence.isConfirmed ? BambooInk.jade : BambooInk.amber,
        ),
      ],
    );
  }
}
