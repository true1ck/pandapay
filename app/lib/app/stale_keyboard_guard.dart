import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemChannels;

/// True when a text field has the keyboard's focus right now.
bool textFieldHasFocus() {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return false;
  return context.widget is EditableText ||
      context.findAncestorWidgetOfExactType<EditableText>() != null;
}

/// Puts the keyboard away if no text field is focused. A keyboard with nothing
/// to type into is stale: the phone can keep one up after a screenshot, a trip
/// to the background or a screen replaced under it, and neither a back button
/// nor a tap closes it because Flutter no longer tracks the field. Hiding is
/// harmless when it is already hidden, and never done while a field is focused.
void hideKeyboardIfNothingToTypeInto() {
  if (textFieldHasFocus()) return;
  SystemChannels.textInput
      .invokeMethod<void>('TextInput.hide')
      .catchError((Object _) {});
}

/// Carries "check soon" requests to the mounted [StaleKeyboardGuard], which
/// owns the timer. With no guard mounted (a test, a screen on its own) a
/// request does nothing and leaves nothing pending.
class _Requests extends ChangeNotifier {
  Duration delay = Duration.zero;
  void request(Duration d) {
    delay = d;
    notifyListeners();
  }
}

final _requests = _Requests();

/// Checks again once things have settled (a new screen may be about to focus
/// its own field, so a check at once could cut that keyboard off).
void scheduleStaleKeyboardCheck([
  Duration delay = const Duration(milliseconds: 450),
]) => _requests.request(delay);

/// Checks after every screen change, including sheets and dialogs.
class StaleKeyboardObserver extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      scheduleStaleKeyboardCheck();

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      scheduleStaleKeyboardCheck();

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      scheduleStaleKeyboardCheck();

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      scheduleStaleKeyboardCheck();
}

/// App-wide: checks when the app comes back to the front and when the keyboard
/// shows with nothing focused.
class StaleKeyboardGuard extends StatefulWidget {
  const StaleKeyboardGuard({super.key, required this.child});
  final Widget child;

  @override
  State<StaleKeyboardGuard> createState() => _StaleKeyboardGuardState();
}

class _StaleKeyboardGuardState extends State<StaleKeyboardGuard>
    with WidgetsBindingObserver {
  Timer? _timer;

  void _onRequest() {
    _timer?.cancel();
    _timer = Timer(_requests.delay, hideKeyboardIfNothingToTypeInto);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _requests.addListener(_onRequest);
  }

  @override
  void dispose() {
    _requests.removeListener(_onRequest);
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      scheduleStaleKeyboardCheck(const Duration(milliseconds: 300));
    }
  }

  @override
  void didChangeMetrics() {
    // The keyboard moved the screen: if nothing is focused, it is not wanted.
    scheduleStaleKeyboardCheck(const Duration(milliseconds: 250));
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
