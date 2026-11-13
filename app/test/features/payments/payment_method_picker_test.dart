import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/user_cards_repository.dart'
    show TxnEntryKind, TxnInstrument;
import 'package:pandapay/features/payments/payment_method_picker.dart';
import 'package:pandapay/features/payments/payment_method_rules.dart';

class _Host extends StatefulWidget {
  final PaymentSelection initial;
  final TxnEntryKind kind;
  final String? category;
  final TextEditingController? amount;
  final bool methodsEnabled;
  final PaymentSelection? saved;
  final bool cardSelected;
  final List<PaymentSelection> log;

  const _Host({
    required this.log,
    this.initial = const PaymentSelection(instrument: TxnInstrument.creditCard),
    this.kind = TxnEntryKind.spend,
    this.category,
    this.amount,
    this.methodsEnabled = true,
    this.saved,
    this.cardSelected = false,
  });

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late PaymentSelection selection = widget.initial;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: PaymentMethodPicker(
          entryKind: widget.kind,
          selection: selection,
          categorySlug: widget.category,
          amountController: widget.amount,
          methodsEnabled: widget.methodsEnabled,
          savedInstrument: widget.saved?.instrument,
          savedMethod: widget.saved?.method,
          cardSelected: widget.cardSelected,
          unknownHint: 'Unknown — choose a method',
          onChanged: (next) {
            widget.log.add(next);
            setState(() => selection = next);
          },
        ),
      ),
    ),
  );
}

Finder _instrumentChip(TxnInstrument i) =>
    find.byKey(ValueKey('payment-chip-instrument-${i.wireValue}'));
const _cheque = ValueKey('payment-chip-method-cheque');
const _more = ValueKey('payment-more-chip');

bool _isSelected(WidgetTester tester, Finder chip) {
  final semantics = tester.widget<Semantics>(
    find.descendant(of: chip, matching: find.byType(Semantics)).first,
  );
  return semantics.properties.selected ?? false;
}

/// Wide and tall so every chip and sheet row is built and hittable.
void _bigSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(2400, 2600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('shows the six instrument chips and More, no Cheque on a card', (
    tester,
  ) async {
    _bigSurface(tester);
    await tester.pumpWidget(_Host(log: []));
    for (final label in [
      'Credit card',
      'Debit',
      'Cash',
      'UPI / bank',
      'Wallet',
      'Other',
      'More',
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.byKey(_cheque), findsNothing);
    expect(_isSelected(tester, _instrumentChip(TxnInstrument.creditCard)),
        isTrue);
  });

  testWidgets('choosing an instrument chip behaves as it always has', (
    tester,
  ) async {
    _bigSurface(tester);
    final log = <PaymentSelection>[];
    await tester.pumpWidget(_Host(log: log));
    await tester.tap(find.text('Cash'));
    await tester.pump();
    expect(log.single, const PaymentSelection(instrument: TxnInstrument.cash));
    expect(_isSelected(tester, _instrumentChip(TxnInstrument.cash)), isTrue);
    expect(_isSelected(tester, _instrumentChip(TxnInstrument.creditCard)),
        isFalse);
  });

  testWidgets('UPI / bank reveals Cheque; tapping it selects it and toggles off',
      (tester) async {
    _bigSurface(tester);
    final log = <PaymentSelection>[];
    await tester.pumpWidget(_Host(log: log));
    await tester.tap(find.text('UPI / bank'));
    await tester.pump();
    expect(find.byKey(_cheque), findsOneWidget);

    await tester.tap(find.byKey(_cheque));
    await tester.pump();
    expect(
      log.last,
      const PaymentSelection(
        instrument: TxnInstrument.upiBank,
        method: 'cheque',
      ),
    );
    expect(_isSelected(tester, find.byKey(_cheque)), isTrue);
    expect(_isSelected(tester, _instrumentChip(TxnInstrument.upiBank)), isTrue);

    await tester.tap(find.byKey(_cheque));
    await tester.pump();
    expect(log.last,
        const PaymentSelection(instrument: TxnInstrument.upiBank));
  });

  testWidgets('switching to Cash clears a chosen Cheque and hides it', (
    tester,
  ) async {
    _bigSurface(tester);
    final log = <PaymentSelection>[];
    await tester.pumpWidget(
      _Host(
        log: log,
        initial: const PaymentSelection(
          instrument: TxnInstrument.upiBank,
          method: 'cheque',
        ),
      ),
    );
    await tester.tap(find.text('Cash'));
    await tester.pump();
    expect(log.single, const PaymentSelection(instrument: TxnInstrument.cash));
    expect(find.byKey(_cheque), findsNothing);
    expect(find.byKey(_more), findsNothing, reason: 'cash offers no method');
  });

  testWidgets('More opens a sheet grouped Bank / Credit / Cards / Other', (
    tester,
  ) async {
    _bigSurface(tester);
    final log = <PaymentSelection>[];
    await tester.pumpWidget(
      _Host(
        log: log,
        initial: const PaymentSelection(instrument: TxnInstrument.upiBank),
      ),
    );
    await tester.tap(find.byKey(_more));
    await tester.pumpAndSettle();
    for (final heading in ['Bank', 'Credit', 'Cards']) {
      expect(find.text(heading), findsOneWidget, reason: heading);
    }
    // 'Other' is also the instrument chip behind the sheet.
    expect(find.text('Other'), findsNWidgets(2));
    expect(find.text('Net banking'), findsOneWidget);
    expect(find.text('EMI'), findsOneWidget);
    expect(find.text('Prepaid / forex card'), findsOneWidget);
    expect(find.text('Gift card / voucher'), findsOneWidget);
    expect(find.text('Auto-debit (NACH / standing instruction)'),
        findsOneWidget);
    expect(find.text('Cheque'), findsOneWidget, reason: 'only the main chip');
    expect(find.byKey(const ValueKey('payment-more-clear')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('payment-more-option-neft')));
    await tester.pumpAndSettle();
    expect(
      log.single,
      const PaymentSelection(instrument: TxnInstrument.upiBank, method: 'neft'),
    );
    // The chip now names the choice and is highlighted.
    expect(find.text('NEFT'), findsOneWidget);
    expect(_isSelected(tester, find.byKey(_more)), isTrue);
  });

  testWidgets('a method for another instrument moves the instrument', (
    tester,
  ) async {
    _bigSurface(tester);
    final log = <PaymentSelection>[];
    await tester.pumpWidget(_Host(log: log));
    await tester.tap(find.byKey(_more));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('payment-more-option-prepaid_card')),
    );
    await tester.pumpAndSettle();
    expect(
      log.single,
      const PaymentSelection(
        instrument: TxnInstrument.wallet,
        method: 'prepaid_card',
      ),
    );
  });

  testWidgets('a chosen card is not offered methods that would drop it', (
    tester,
  ) async {
    _bigSurface(tester);
    await tester.pumpWidget(_Host(log: [], cardSelected: true));
    await tester.tap(find.byKey(_more));
    await tester.pumpAndSettle();
    expect(find.text('UPI'), findsOneWidget);
    expect(find.text('EMI'), findsOneWidget);
    expect(find.text('Prepaid / forex card'), findsNothing);
    expect(find.text('Gift card / voucher'), findsNothing);
  });

  testWidgets('a chosen method can be removed from the sheet', (tester) async {
    _bigSurface(tester);
    final log = <PaymentSelection>[];
    await tester.pumpWidget(
      _Host(
        log: log,
        initial: const PaymentSelection(
          instrument: TxnInstrument.upiBank,
          method: 'neft',
        ),
      ),
    );
    await tester.tap(find.byKey(_more));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('payment-more-clear')));
    await tester.pumpAndSettle();
    expect(log.single, const PaymentSelection(instrument: TxnInstrument.upiBank));
    expect(find.text('More'), findsOneWidget);
  });

  testWidgets('RTGS follows the amount being typed', (tester) async {
    _bigSurface(tester);
    final amount = TextEditingController(text: '5000');
    addTearDown(amount.dispose);
    await tester.pumpWidget(
      _Host(
        log: [],
        amount: amount,
        initial: const PaymentSelection(instrument: TxnInstrument.upiBank),
      ),
    );
    await tester.tap(find.byKey(_more));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('payment-more-option-rtgs')), findsNothing);
    await tester.tapAt(const Offset(5, 5)); // dismiss the sheet
    await tester.pumpAndSettle();

    amount.text = '250000';
    await tester.pump();
    await tester.tap(find.byKey(_more));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('payment-more-option-rtgs')),
      findsOneWidget,
    );
  });

  testWidgets('a saved RTGS stays in the sheet below the minimum amount', (
    tester,
  ) async {
    _bigSurface(tester);
    final amount = TextEditingController(text: '5000');
    addTearDown(amount.dispose);
    const saved = PaymentSelection(
      instrument: TxnInstrument.upiBank,
      method: 'rtgs',
    );
    await tester.pumpWidget(
      _Host(log: [], amount: amount, initial: saved, saved: saved),
    );
    await tester.tap(find.byKey(_more));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('payment-more-option-rtgs')),
      findsOneWidget,
    );
  });

  testWidgets('a suggested category puts Cheque right after UPI / bank', (
    tester,
  ) async {
    _bigSurface(tester);
    await tester.pumpWidget(
      _Host(
        log: [],
        category: 'rent',
        initial: const PaymentSelection(instrument: TxnInstrument.upiBank),
      ),
    );
    final bank = tester.getTopLeft(find.text('UPI / bank')).dx;
    final cheque = tester.getTopLeft(find.text('Cheque')).dx;
    final wallet = tester.getTopLeft(find.text('Wallet')).dx;
    expect(bank < cheque && cheque < wallet, isTrue);
  });

  testWidgets('methodsEnabled false shows only the instrument chips', (
    tester,
  ) async {
    _bigSurface(tester);
    await tester.pumpWidget(
      _Host(
        log: [],
        methodsEnabled: false,
        initial: const PaymentSelection(instrument: TxnInstrument.upiBank),
      ),
    );
    expect(find.byKey(_cheque), findsNothing);
    expect(find.byKey(_more), findsNothing);
    expect(find.text('UPI / bank'), findsOneWidget);
  });

  testWidgets('no instrument shows the unknown hint and no selection', (
    tester,
  ) async {
    _bigSurface(tester);
    await tester.pumpWidget(_Host(log: [], initial: const PaymentSelection()));
    expect(find.text('Unknown — choose a method'), findsOneWidget);
    for (final instrument in TxnInstrument.values) {
      expect(_isSelected(tester, _instrumentChip(instrument)), isFalse);
    }
  });

  testWidgets('income entries do not offer the credit-card chip', (
    tester,
  ) async {
    _bigSurface(tester);
    await tester.pumpWidget(
      _Host(
        log: [],
        kind: TxnEntryKind.income,
        initial: const PaymentSelection(instrument: TxnInstrument.upiBank),
      ),
    );
    expect(find.text('Credit card'), findsNothing);
    expect(find.text('UPI / bank'), findsOneWidget);
  });
}
