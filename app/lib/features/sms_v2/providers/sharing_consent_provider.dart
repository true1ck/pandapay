import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart' as app;
import '../sync/sharing_consent_mirror.dart';

/// Whether the account agreed to share SMS fixes: the server's answer, or the
/// local mirror of it when the server cannot be reached (S-02). A failure that
/// is not "offline" reads as "not agreed". Invalidate
/// [app.smsSharedLearningConsentProvider] after a grant or a withdrawal; this
/// provider follows it.
final smsSharingGrantedProvider = FutureProvider.autoDispose<bool>((ref) {
  final namespace = ref.watch(app.cacheNamespaceProvider);
  return sharingConsentWithMirror(
    namespace: namespace,
    read: () => ref.watch(app.smsSharedLearningConsentProvider.future),
  );
});
