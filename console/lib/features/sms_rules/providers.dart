import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../app/providers.dart';
import '../../data/sms_v2_admin_api.dart';

final smsV2AdminApiProvider = Provider<SmsV2AdminApi?>((ref) {
  final admin = ref.watch(adminApiProvider);
  return admin == null ? null : SmsV2AdminApi(admin);
});
final smsV2RulesProvider = FutureProvider<List<Map<String, dynamic>>>((
  ref,
) async {
  final api = ref.watch(smsV2AdminApiProvider);
  if (api == null) throw StateError('Sign in to review SMS rules.');
  return api.rules();
});

/// The Learning page's numbers, for the Overview tile.
final smsLearningSummaryProvider = FutureProvider<Map<String, dynamic>>((
  ref,
) async {
  final api = ref.watch(smsV2AdminApiProvider);
  if (api == null) throw StateError('Sign in to review SMS rules.');
  return api.learningSummary();
});

/// Settings and this month's AI spend, for the Overview's AI drafting tile.
final smsAiSettingsProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  final api = ref.watch(smsV2AdminApiProvider);
  if (api == null) throw StateError('Sign in to review SMS rules.');
  final settings = await api.settings();
  Map<String, dynamic>? metrics;
  try {
    metrics = await api.metrics();
  } catch (_) {
    metrics = null;
  }
  return {'settings': settings, 'metrics': metrics};
});
