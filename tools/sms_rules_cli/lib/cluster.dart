import 'package:pandapay_domain/sms_v2_template.dart';

import 'family.dart';
import 'messages_io.dart';

/// One template: all messages sharing a brand and a coarse skeleton.
class SmsTemplate {
  SmsTemplate({
    required this.templateHash,
    required this.brand,
    required this.skeleton,
    required this.family,
    required this.firstSeen,
  }) : lastSeen = firstSeen;

  final String templateHash;
  final String brand;
  final String skeleton;
  final String family;
  int count = 0;
  final List<String> samples = [];
  DateTime firstSeen;
  DateTime lastSeen;

  Map<String, Object?> toJson() => {
    'templateHash': templateHash,
    'brand': brand,
    'family': family,
    'skeleton': skeleton,
    'count': count,
    'samples': samples,
    'firstSeen': firstSeen.toUtc().toIso8601String(),
    'lastSeen': lastSeen.toUtc().toIso8601String(),
  };
}

/// Clusters already-redacted messages into templates.
///
/// Amounts, dates, masks, UPI IDs and references become placeholders, and every
/// word seen in fewer than [minMessages] messages (merchant and person names
/// included) becomes `<W>`. Replacing only numbers left thousands of groups on
/// a year of real messages; this step is what reaches a few hundred.
///
/// The result is sorted by count, highest first.
List<SmsTemplate> clusterMessages(
  List<RawSms> messages, {
  int minMessages = 5,
  int sampleCount = 3,
}) {
  final skeletons = [for (final m in messages) smsSkeleton(m.body)];
  final df = skeletonWordFrequency(skeletons);
  final byHash = <String, SmsTemplate>{};
  for (var i = 0; i < messages.length; i++) {
    final m = messages[i];
    final brand = smsTemplateBrand(m.sender);
    final skeleton = coarsenSkeleton(skeletons[i], df, minMessages: minMessages);
    final hash = smsTemplateHash(brand, skeleton);
    final t = byHash.putIfAbsent(
      hash,
      () => SmsTemplate(
        templateHash: hash,
        brand: brand,
        skeleton: skeleton,
        family: guessFamily(m.body),
        firstSeen: m.observedAt,
      ),
    );
    t.count++;
    if (t.samples.length < sampleCount && !t.samples.contains(m.body)) {
      t.samples.add(m.body);
    }
    if (m.observedAt.isBefore(t.firstSeen)) t.firstSeen = m.observedAt;
    if (m.observedAt.isAfter(t.lastSeen)) t.lastSeen = m.observedAt;
  }
  return byHash.values.toList()
    ..sort((a, b) {
      final c = b.count.compareTo(a.count);
      return c != 0 ? c : a.templateHash.compareTo(b.templateHash);
    });
}
