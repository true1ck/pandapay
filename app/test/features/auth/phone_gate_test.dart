import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/features/auth/phone_gate_provider.dart';

ProviderContainer container() {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  c.listen(phoneGateProvider, (_, _) {});
  c.read(accessTokenProvider.notifier).state = 'token';
  return c;
}

void main() {
  test('the gate starts closed', () {
    expect(container().read(phoneGateProvider).needsPhone, isFalse);
  });

  test('opening it keeps the number that was refused and why', () {
    final c = container();
    c.read(phoneGateProvider.notifier).needs(prefill: '9876543210', message: 'That number cannot be used.');
    // A later phone_required reply passes nothing and must not wipe what is known.
    c.read(phoneGateProvider.notifier).needs();
    final gate = c.read(phoneGateProvider);
    expect(gate.needsPhone, isTrue);
    expect(gate.prefill, '9876543210');
    expect(gate.message, 'That number cannot be used.');
  });

  test('saving a phone closes the gate', () {
    final c = container();
    c.read(phoneGateProvider.notifier).needs(prefill: '9876543210');
    c.read(phoneGateProvider.notifier).satisfied();
    final gate = c.read(phoneGateProvider);
    expect(gate.needsPhone, isFalse);
    expect(gate.prefill, isNull);
  });

  test('signing out closes the gate and forgets what was typed', () {
    final c = container();
    c.read(phoneGateProvider.notifier).needs(prefill: '9876543210', message: 'x');
    c.read(accessTokenProvider.notifier).state = null;
    final gate = c.read(phoneGateProvider);
    expect(gate.needsPhone, isFalse);
    expect(gate.prefill, isNull);
    expect(gate.message, isNull);
  });
}
