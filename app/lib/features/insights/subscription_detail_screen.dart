import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/local/sms_intake_repository.dart';
import '../../data/spend_reports_repository.dart';

class SubscriptionDetailScreen extends ConsumerStatefulWidget {
  final RecurringSeries series;

  const SubscriptionDetailScreen({super.key, required this.series});

  @override
  ConsumerState<SubscriptionDetailScreen> createState() =>
      _SubscriptionDetailScreenState();
}

class _SubscriptionEvidence {
  final SmsIntakeEntry message;
  final bool exact;

  const _SubscriptionEvidence(this.message, {required this.exact});
}

class _SubscriptionDetailScreenState
    extends ConsumerState<SubscriptionDetailScreen> {
  late final Future<_SubscriptionEvidence?> _evidence = _findEvidence();

  Future<_SubscriptionEvidence?> _findEvidence() async {
    final namespace = ref.read(cacheNamespaceProvider);
    if (namespace == 'signed-out') return null;
    final cache = await ref.read(responseCacheProvider.future);
    final repo = SmsIntakeRepository(cache.financialStore.database);
    final series = widget.series;
    final sourceKey = series.sourceKey;
    if (sourceKey != null && sourceKey.isNotEmpty) {
      final captured = repo.capturedById(namespace, sourceKey);
      if (captured != null) {
        return _SubscriptionEvidence(captured, exact: true);
      }
    }

    // Older recurring rows predate source keys. A mandate reference is an
    // exact link to its setup SMS; a name match alone is only related evidence.
    final reference = series.mandateReference?.trim();
    final db = cache.financialStore.database.db;
    if (reference != null && reference.length >= 5) {
      final rows = db.select(
        'SELECT id FROM sms_captured_messages WHERE namespace=? '
        'AND instr(lower(body), lower(?)) > 0 ORDER BY received_at DESC LIMIT 1',
        [namespace, reference],
      );
      if (rows.isNotEmpty) {
        final captured = repo.capturedById(
          namespace,
          rows.first['id'] as String,
        );
        if (captured != null) {
          return _SubscriptionEvidence(captured, exact: true);
        }
      }
    }

    final service = series.displayName.toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9]'),
      '',
    );
    if (!series.setupConfirmed || service.length < 4) return null;
    final rows = db.select(
      'SELECT id, body FROM sms_captured_messages WHERE namespace=? '
      'ORDER BY received_at DESC LIMIT 5000',
      [namespace],
    );
    for (final row in rows) {
      final body = row['body'] as String;
      final normalized = body.toLowerCase().replaceAll(
        RegExp(r'[^a-z0-9]'),
        '',
      );
      if (!normalized.contains(service) ||
          !RegExp(r'auto\s*pay|mandate', caseSensitive: false).hasMatch(body)) {
        continue;
      }
      final captured = repo.capturedById(namespace, row['id'] as String);
      if (captured != null) {
        return _SubscriptionEvidence(captured, exact: false);
      }
    }
    return null;
  }

  String _date(DateTime value) {
    final day = value.toLocal();
    return '${day.day}/${day.month}/${day.year}';
  }

  String _mask(String body) => body.replaceAllMapped(
    RegExp(r'\b\d{8,}\b'),
    (match) => '•••• ${match.group(0)!.substring(match.group(0)!.length - 4)}',
  );

  @override
  Widget build(BuildContext context) {
    final series = widget.series;
    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        title: Text(
          'Subscription details',
          style: BambooFonts.heading(18, color: BambooInk.ink900),
        ),
        backgroundColor: BambooInk.paper,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
      ),
      body: AppBackground(
        child: ListView(
          padding: const EdgeInsets.all(AppSpace.lg),
          children: [
            Container(
              padding: const EdgeInsets.all(AppSpace.lg),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    BambooInk.slateRaised,
                    BambooInk.slate,
                    BambooInk.slateLow,
                  ],
                ),
                borderRadius: BorderRadius.circular(26),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: BambooInk.lime.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(13),
                      border: Border.all(
                        color: BambooInk.lime.withValues(alpha: 0.25),
                      ),
                    ),
                    child: const Icon(
                      Icons.autorenew_rounded,
                      color: BambooInk.lime,
                    ),
                  ),
                  const SizedBox(height: AppSpace.md),
                  Text(
                    series.displayName,
                    style: BambooFonts.heading(24, color: BambooInk.onSlate),
                  ),
                  const SizedBox(height: AppSpace.xs),
                  Text(
                    series.setupConfirmed ? 'Setup confirmed' : series.status,
                    style: BambooFonts.ui(13, color: BambooInk.onSlateSubtle),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpace.lg),
            Text(
              'What we know',
              style: BambooFonts.heading(18, color: BambooInk.ink900),
            ),
            const SizedBox(height: AppSpace.sm),
            Container(
              padding: const EdgeInsets.all(AppSpace.md),
              decoration: BoxDecoration(
                color: BambooInk.glassFillOnPaper,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: BambooInk.hairlineOnPaper),
              ),
              child: Column(
                children: [
                  _detail(
                    'Status',
                    series.setupConfirmed ? 'Setup confirmed' : series.status,
                  ),
                  _detail(
                    'Amount',
                    series.amountKnown
                        ? series.typicalAmount.isZero
                              ? 'Free'
                              : '₹${series.typicalAmount.format()}'
                        : 'Not stated',
                  ),
                  _detail(
                    'Billing cycle',
                    series.cadenceConfirmed
                        ? series.cadenceLabel
                        : 'Not confirmed',
                  ),
                  if (series.lastSeenOn != null)
                    _detail('Last payment seen', _date(series.lastSeenOn!)),
                  if (series.nextExpectedOn != null)
                    _detail('Next expected', _date(series.nextExpectedOn!)),
                  if (series.cardName != null)
                    _detail('Payment card', series.cardName!),
                ],
              ),
            ),
            const SizedBox(height: AppSpace.lg),
            Row(
              children: [
                const Icon(Icons.sms_outlined, color: BambooInk.jade, size: 21),
                const SizedBox(width: AppSpace.xs),
                Text(
                  'SMS evidence',
                  style: BambooFonts.heading(18, color: BambooInk.ink900),
                ),
              ],
            ),
            const SizedBox(height: AppSpace.sm),
            FutureBuilder<_SubscriptionEvidence?>(
              future: _evidence,
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return Text(
                    snapshot.connectionState == ConnectionState.waiting
                        ? 'Checking messages stored on this device…'
                        : 'The original SMS is not available on this device for this subscription.',
                    style: BambooFonts.ui(13, color: BambooInk.ink500),
                  );
                }
                final evidence = snapshot.data!;
                return Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: BambooInk.glassFillOnPaper,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: BambooInk.hairlineOnPaper),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: BambooInk.rankBadgeBg,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          evidence.exact
                              ? 'Source message on this device'
                              : 'Related service message',
                          style: BambooFonts.ui(
                            11.5,
                            weight: FontWeight.w700,
                            color: BambooInk.rankBadgeInk,
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '${evidence.message.message.sender} · ${_date(evidence.message.message.receivedAt)}',
                        style: BambooFonts.ui(12, color: BambooInk.ink500),
                      ),
                      const SizedBox(height: 12),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(AppSpace.md),
                        decoration: BoxDecoration(
                          color: BambooInk.paperMuted,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: SelectableText(
                          _mask(evidence.message.message.body),
                          style: BambooFonts.ui(
                            13,
                            color: BambooInk.ink900,
                            height: 1.5,
                          ),
                        ),
                      ),
                      if (!evidence.exact) ...[
                        const SizedBox(height: 12),
                        Text(
                          'Matched by service name and AutoPay wording. This message is related; an exact source link was not saved for this older record.',
                          style: BambooFonts.ui(12, color: BambooInk.ink500),
                        ),
                      ],
                    ],
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _detail(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 135,
          child: Text(
            label,
            style: BambooFonts.ui(13, color: BambooInk.ink500),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: BambooFonts.ui(13, color: BambooInk.ink900),
          ),
        ),
      ],
    ),
  );
}
