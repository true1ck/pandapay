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
