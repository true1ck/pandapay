import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../sync/split_sync.dart';
import 'shared_providers.dart';

/// "N need attention": saved Split changes the server refused, plus private
/// per-transaction splits that are blocked. Each part reads quietly as 0 until
/// it loads, so this never throws or blocks. A global indicator can watch it.
final needsAttentionCountProvider = Provider.autoDispose<int>((ref) {
  final shared = ref.watch(sharedAttentionCountProvider).valueOrNull ?? 0;
  final private = ref.watch(blockedSplitCountProvider).valueOrNull ?? 0;
  return shared + private;
});
