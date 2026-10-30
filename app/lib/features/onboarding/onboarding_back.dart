import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Back never changes authentication. Cold-start setup routes still have an
/// explicit previous destination when there is no Navigator history to pop.
void onboardingBack(BuildContext context, {required String fallback}) {
  if (Navigator.of(context).canPop()) {
    Navigator.of(context).pop();
  } else {
    context.go(fallback);
  }
}

/// The app-bar arrow and Android system Back use the same in-page step logic.
/// Ordinary pushed pages retain their native back gesture when it can pop.
class OnboardingBackScope extends StatelessWidget {
  final Widget child;
  final VoidCallback onBack;
  final bool handlesStep;
  final bool busy;

  const OnboardingBackScope({
    super.key,
    required this.child,
    required this.onBack,
    this.handlesStep = false,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy && !handlesStep && Navigator.of(context).canPop(),
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop && !busy) onBack();
    },
    child: child,
  );
}
