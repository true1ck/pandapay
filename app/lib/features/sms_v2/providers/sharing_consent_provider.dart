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

/// A withdrawal of "share SMS fixes with the community" must call this FIRST,
/// before the server call: it clears the local mirror at once, so a correction
/// still queued offline is sent without its share-only parts. Then refreshes
/// the consent providers. (Call site: privacy settings screen, WP-C11.)
Future<void> withdrawSharedLearningLocally(WidgetRef ref) async {
  await SmsSharedLearningConsentMirror.set(
    ref.read(app.cacheNamespaceProvider),
    false,
  );
  ref.invalidate(app.smsSharedLearningConsentProvider);
}
