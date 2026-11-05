import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../app/design/app_theme.dart';
import '../runtime/shared_providers.dart';
import '../runtime/shared_runtime.dart';

/// "Let friends find me by phone number". On by default; turning it off makes
/// this account look the same as an unregistered number to anyone picking a
/// contact. Hidden until the runtime and a verified phone are available.
class SharedDiscoverableTile extends ConsumerStatefulWidget {
  const SharedDiscoverableTile({super.key});
  @override
  ConsumerState<SharedDiscoverableTile> createState() => _TileState();
}

class _TileState extends ConsumerState<SharedDiscoverableTile> {
  bool? _value;
  bool _busy = false, _load = false;

  Future<void> _fetch(SharedExpensesRuntime runtime) async {
    _load = true;
    try {
      final status = await runtime.discoverability();
      if (mounted && status.phoneVerified) {
        setState(() => _value = status.discoverable);
      }
    } catch (_) {
      // Stay hidden when the status cannot be read.
    }
  }

  Future<void> _toggle(SharedExpensesRuntime runtime, bool next) async {
    if (_busy) return;
    final before = _value;
    setState(() {
      _busy = true;
      _value = next;
    });
    try {
      final saved = await runtime.setDiscoverable(next);
      if (mounted) setState(() => _value = saved);
    } catch (_) {
      if (mounted) {
        setState(() => _value = before);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not save. Try again.')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final runtime = ref.watch(sharedExpensesRuntimeProvider).valueOrNull;
    if (runtime == null || !runtime.proposalsEnabled) {
      return const SizedBox.shrink();
    }
    if (!_load) _fetch(runtime);
    final value = _value;
    if (value == null) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      child: SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: value,
        onChanged: _busy ? null : (v) => _toggle(runtime, v),
        title: Text(
          'Let friends find me by phone',
          style: BambooFonts.ui(14, weight: FontWeight.w600),
        ),
        subtitle: Text(
          'When someone picks your number to split, they see your first name and can send an invite. Off: you only get invites by link.',
          style: BambooFonts.ui(12, color: BambooInk.ink700),
        ),
      ),
    );
  }
}
