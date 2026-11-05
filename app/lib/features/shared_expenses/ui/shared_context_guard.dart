import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../app/design/bamboo_components.dart';
import '../../../app/providers.dart' show cacheNamespaceProvider;
import '../runtime/shared_runtime.dart';

/// Modal routes may outlive the provider generation which opened them. Watch
/// the account as well as runtime events before rendering any private content.
class SharedContextGuard extends ConsumerWidget {
  final SharedExpensesRuntime runtime;
  final String contextId;
  final WidgetBuilder builder;
  const SharedContextGuard({
    super.key,
    required this.runtime,
    required this.contextId,
    required this.builder,
  });
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final namespace = ref.watch(cacheNamespaceProvider);
    return AnimatedBuilder(
      animation: runtime,
      builder: (context, _) {
        if (namespace != runtime.store.namespace ||
            !runtime.isCurrent() ||
            runtime.store.isContextRevoked(contextId)) {
          return const SafeArea(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: BambooNote(
                'This shared expense is no longer available.',
                icon: Icons.link_off_rounded,
              ),
            ),
          );
        }
        return builder(context);
      },
    );
  }
}
