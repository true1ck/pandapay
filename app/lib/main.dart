import 'package:flutter/material.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

void main() {
  runApp(const PandaPayApp());
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

/// UA-0.4.2 bottom nav stub: Home · Cards · raised SCAN FAB · Activity · More.
/// Screens are placeholders until UA-1..UA-4 land; this just proves the shell
/// and the shared pandapay_domain dependency wire up correctly end to end.
class _AppShell extends StatefulWidget {
  const _AppShell();
  @override
  State<_AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<_AppShell> {
  int _tab = 0;

  static const _tabs = ['Home', 'Cards', 'Activity', 'More'];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('PandaPay — ${_tabs[_tab]}')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(_tabs[_tab], style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 8),
            MoneyText(Money.fromRupees(1234567), confidence: Confidence.estimated),
          ],
        ),
      ),
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
