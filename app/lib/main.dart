import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import 'features/account/account_screen.dart';
import 'features/activity/activity_screen.dart';
import 'features/cards/cards_screen.dart';
import 'features/home/home_screen.dart';

void main() {
  runApp(const ProviderScope(child: PandaPayApp()));
}

class PandaPayApp extends StatelessWidget {
  const PandaPayApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PandaPay',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal)),
      home: const _AppShell(),
    );
  }
}

/// UA-0.4.2 bottom nav: Home · Cards · raised SCAN FAB · Activity · More.
/// All four tabs are real as of Chunk 18: Home (Chunk 5) the ranked
/// catalogue/wallet, Cards (Chunk 16) the signed-in user's wallet,
/// Activity (Chunk 18) their logged transactions, More (Chunk 15) OTP
/// login + profile.
class _AppShell extends StatefulWidget {
  const _AppShell();
  @override
  State<_AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<_AppShell> {
  int _tab = 0;

  static const _tabLabels = ['Home', 'Cards', 'Activity', 'More'];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('PandaPay — ${_tabLabels[_tab]}')),
      body: switch (_tab) {
        0 => const HomeScreen(),
        1 => const CardsScreen(),
        2 => const ActivityScreen(),
        _ => const AccountScreen(),
      },
      floatingActionButton: FloatingActionButton.large(
        onPressed: () {},
        tooltip: 'Scan QR',
        child: const Icon(Icons.qr_code_scanner),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      bottomNavigationBar: BottomAppBar(
        shape: const CircularNotchedRectangle(),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _navButton(Icons.home, 0),
            _navButton(Icons.credit_card, 1),
            const SizedBox(width: 48),
            _navButton(Icons.receipt_long, 2),
            _navButton(Icons.more_horiz, 3),
          ],
        ),
      ),
    );
  }

  Widget _navButton(IconData icon, int index) {
    return IconButton(
      icon: Icon(icon, color: _tab == index ? Theme.of(context).colorScheme.primary : null),
      onPressed: () => setState(() => _tab = index),
    );
  }
}

/// UA-0.2.4: financial figures must always render through a widget that
/// requires a [Confidence] — a bare `Text('₹\$x')` is a compile-time trap
/// waiting to happen once the custom_lint rule lands (see analysis_options.yaml).
class MoneyText extends StatelessWidget {
  final Money amount;
  final Confidence confidence;

  const MoneyText(this.amount, {super.key, required this.confidence});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // This *is* the required Money-rendering widget — exempt by design.
        // ignore: no_bare_money_text
        Text(amount.format()),
        const SizedBox(width: 6),
        Icon(
          confidence.isConfirmed ? Icons.check_circle : Icons.hourglass_top,
          size: 14,
          color: confidence.isConfirmed ? Colors.green : Colors.orange,
        ),
      ],
    );
  }
}
