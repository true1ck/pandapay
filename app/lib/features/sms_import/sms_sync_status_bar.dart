import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../app/design/app_theme.dart';

import 'ios_sms_import_screen.dart';
import 'ios_sms_intake_controller.dart';
import 'ios_sms_intake_providers.dart';

typedef _StatusView = ({bool enabled, bool visible, String label, bool busy});

_StatusView _statusView(IosSmsIntakeController controller) {
  final state = controller.state;
  return (
    enabled: state.enabled,
    visible: state.visible,
    label: state.label,
    busy: state.processing || state.launching,
  );
}

/// Keep the page in one stable element subtree while the strip changes. Short
/// batches share one presentation, rather than repeatedly resizing the page.
class SmsSyncStatusLayout extends ConsumerStatefulWidget {
  final Widget child;
  const SmsSyncStatusLayout({super.key, required this.child});

  @override
  ConsumerState<SmsSyncStatusLayout> createState() =>
      _SmsSyncStatusLayoutState();
}

class _SmsSyncStatusLayoutState extends ConsumerState<SmsSyncStatusLayout> {
  static const _showDelay = Duration(milliseconds: 200);
  static const _hideDelay = Duration(milliseconds: 900);
  ProviderSubscription<_StatusView>? _subscription;
  Timer? _showTimer, _hideTimer;
  bool _shown = false;
  _StatusView _latest = (
    enabled: false,
    visible: false,
    label: '',
    busy: false,
  );
  late _StatusView _displayed = _latest;

  @override
  void initState() {
    super.initState();
    if (!ref.read(iosSmsIntakeServiceProvider).supported) return;
    _latest = _statusView(ref.read(iosSmsIntakeControllerProvider));
    _displayed = _latest;
    _shown = _latest.visible;
    // Ignore receipt/count changes that do not alter this compact strip.
    _subscription = ref.listenManual(
      iosSmsIntakeControllerProvider.select(_statusView),
      (_, next) => _receive(next),
    );
  }

  void _receive(_StatusView next) {
    _latest = next;
    if (!next.enabled) {
      // Account revocation must not keep the previous account's status around.
      _showTimer?.cancel();
      _showTimer = null;
      _hideTimer?.cancel();
      _hideTimer = null;
      if (_shown) setState(() => _shown = false);
      return;
    }
    if (next.visible) {
      _hideTimer?.cancel();
      _hideTimer = null;
      if (_shown) {
        if (_displayed != next) setState(() => _displayed = next);
      } else {
        _showTimer ??= Timer(_showDelay, () {
          _showTimer = null;
          if (!mounted || !_latest.enabled || !_latest.visible) return;
          setState(() {
            _shown = true;
            _displayed = _latest;
          });
        });
      }
    } else {
      _showTimer?.cancel();
      _showTimer = null;
      if (_shown) {
        _hideTimer ??= Timer(_hideDelay, () {
          _hideTimer = null;
          if (!mounted || _latest.visible) return;
          setState(() => _shown = false);
        });
      }
    }
  }

  @override
  void dispose() {
    _subscription?.close();
    _showTimer?.cancel();
    _hideTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      // This slot always exists, so the page below is never reparented.
      _shown
          ? SmsSyncStatusBar(label: _displayed.label, busy: _displayed.busy)
          : const SizedBox.shrink(),
      Expanded(
        child: MediaQuery.removePadding(
          context: context,
          removeTop: _shown,
          child: widget.child,
        ),
      ),
    ],
  );
}

/// A fixed-height row and progress slot prevent processing/label changes from
/// moving navigation, scrolling content or focused fields underneath the strip.
class SmsSyncStatusBar extends StatelessWidget {
  final String label;
  final bool busy;
  const SmsSyncStatusBar({super.key, required this.label, required this.busy});

  @override
  Widget build(BuildContext context) {
    final rowHeight = math.max(
      48.0,
      MediaQuery.textScalerOf(context).scale(12.5) * 1.3 * 2,
    );
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return SafeArea(
      bottom: false,
      child: Material(
        color: BambooInk.slate,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: rowHeight,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        label,
                        style: BambooFonts.ui(
                          12.5,
                          color: BambooInk.onSlate,
                          height: 1.3,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    TextButton(
                      style: TextButton.styleFrom(
                        foregroundColor: BambooInk.lime,
                        textStyle: BambooFonts.ui(12, weight: FontWeight.w600),
                      ),
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const IosSmsImportScreen(),
                        ),
                      ),
                      child: const Text('Details'),
                    ),
                  ],
                ),
              ),
              SizedBox(
                height: 4,
                child: LinearProgressIndicator(
                  value: busy && !reduceMotion ? null : 1,
                  color: busy ? BambooInk.lime : BambooInk.slateHairline,
                  backgroundColor: BambooInk.slateHairline,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
