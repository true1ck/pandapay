import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import 'app/design/app_theme.dart';
import 'app/providers.dart';
import 'data/api_exception.dart';
import 'features/account/account_screen.dart';
import 'features/activity/activity_screen.dart';
import 'features/cards/cards_screen.dart';
import 'features/home/home_screen.dart';
import 'features/scan/scan_card_screen.dart';

void main() {
  runApp(const ProviderScope(child: PandaPayApp()));
}

class PandaPayApp extends StatelessWidget {
  const PandaPayApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PandaPay',
      theme: AppTheme.light(),
      home: const _AppShell(),
    );
  }
}

/// UA-0.4.2 bottom nav: Home · Cards · raised SCAN FAB · Activity · More.
/// All four tabs are real as of Chunk 18: Home (Chunk 5) the ranked
/// catalogue/wallet, Cards (Chunk 16) the signed-in user's wallet,
/// Activity (Chunk 18) their logged transactions, More (Chunk 15) OTP
/// login + profile.
class _AppShell extends ConsumerStatefulWidget {
  const _AppShell();
  @override
  ConsumerState<_AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<_AppShell> {
  int _tab = 0;
  bool _scanning = false;

  static const _tabLabels = ['Home', 'Cards', 'Activity', 'Account'];

  /// UA-4 (Chunk 30 built the scanner; this shell-level FAB was still a
  /// no-op placeholder from the original scaffold until now). Pushes the
  /// same ScanCardScreen the Cards tab's Add Card form uses, then hands any
  /// pick to Cards via pendingScannedCardIdProvider and switches to that
  /// tab — the FAB itself has no "add a card" form of its own to fill in.
  Future<void> _scanFromFab() async {
    setState(() => _scanning = true);
    try {
      final catalogue = await ref.read(catalogueProvider.future);
      if (!mounted) return;
      final picked = await Navigator.of(context).push<CardProduct>(
        MaterialPageRoute(builder: (_) => ScanCardScreen(catalogue: catalogue)),
      );
      if (picked != null && mounted) {
        ref.read(pendingScannedCardIdProvider.notifier).state = picked.id;
        setState(() => _tab = 1);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not start the scanner. ${userFacingErrorMessage(e)}')));
      }
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  static const _navIcons = [Icons.home_rounded, Icons.credit_card_rounded, Icons.receipt_long_rounded, Icons.person_rounded];

  @override
  Widget build(BuildContext context) {
    // Runs sessionKeepAliveProvider for the app's whole lifetime — see its
    // doc comment in app/providers.dart for why this can't just be
    // sessionInitProvider running once at startup.
    ref.watch(sessionKeepAliveProvider);
    return Scaffold(
      appBar: AppBar(title: Text('PandaPay — ${_tabLabels[_tab]}')),
      body: switch (_tab) {
        0 => const HomeScreen(),
        1 => const CardsScreen(),
        2 => const ActivityScreen(),
        _ => const AccountScreen(),
      },
      floatingActionButton: FloatingActionButton.large(
        onPressed: _scanning ? null : _scanFromFab,
        tooltip: 'Scan a card',
        child: _scanning
            ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
              )
            : const Icon(Icons.qr_code_scanner_rounded),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      bottomNavigationBar: BottomAppBar(
        shape: const CircularNotchedRectangle(),
        notchMargin: 8,
        padding: EdgeInsets.zero,
        child: SizedBox(
          height: 64,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _navButton(0),
              _navButton(1),
              const SizedBox(width: 56),
              _navButton(2),
              _navButton(3),
            ],
          ),
        ),
      ),
    );
  }

  Widget _navButton(int index) {
    final selected = _tab == index;
    final color = selected ? Theme.of(context).colorScheme.primary : const Color(0xFF6B7684);
    return Expanded(
      child: InkWell(
        onTap: () => setState(() => _tab = index),
        child: Semantics(
          label: _tabLabels[index],
          selected: selected,
          button: true,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(_navIcons[index], color: color, size: 24),
              const SizedBox(height: 2),
              Text(
                _tabLabels[index],
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: color,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// UA-0.2.4: financial figures must always render through a widget that
/// requires a [Confidence] — a bare `Text('₹\$x')` is a compile-time trap
/// waiting to happen once the custom_lint rule lands (see analysis_options.yaml).
class MoneyText extends StatelessWidget {
  final Money amount;
  final Confidence confidence;
  final TextStyle? style;

  const MoneyText(this.amount, {super.key, required this.confidence, this.style});

  @override
  Widget build(BuildContext context) {
    final baseStyle = style ?? Theme.of(context).textTheme.titleMedium;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // This *is* the required Money-rendering widget — exempt by design.
        // ignore: no_bare_money_text
        Text(
          amount.format(),
          style: baseStyle?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
        ),
        const SizedBox(width: 6),
        Icon(
          confidence.isConfirmed ? Icons.check_circle_rounded : Icons.hourglass_top_rounded,
          size: 14,
          color: confidence.isConfirmed ? const Color(0xFF15803D) : const Color(0xFFB45309),
        ),
      ],
    );
  }
}
