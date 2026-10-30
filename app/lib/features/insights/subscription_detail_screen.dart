import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/local/sms_intake_repository.dart';
import '../../data/spend_reports_repository.dart';
import '../../main.dart' show MoneyText;

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
    if (service.length < 3) return null;
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
      if (!normalized.contains(service)) continue;
      if (!RegExp(
        r'\b(subscription|membership|renewal|renews|renewed|auto\s*pay|mandate)\b',
        caseSensitive: false,
      ).hasMatch(body)) {
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

  String _mask(String body) {
    var masked = body.replaceAllMapped(
      RegExp(r'\b(?:\d{4}[ -]){3}(\d{4})\b'),
      (match) => '•••• •••• •••• ${match.group(1)}',
    );
    masked = masked.replaceAllMapped(
      RegExp(r'\b\d{8,}\b'),
      (match) => '•••• ${match.group(0)!.substring(match.group(0)!.length - 4)}',
    );
    return masked;
  }

  Widget _headerStatusBadge(RecurringSeries series) {
    final (label, icon, color, bg) = switch (series.setupConfirmed) {
      true => (
        'Setup confirmed',
        Icons.verified_outlined,
        BambooInk.lime,
        BambooInk.lime.withValues(alpha: 0.15),
      ),
      false => switch (series.status) {
        'confirmed' || 'active' => (
          'Active',
          Icons.check_circle_outline_rounded,
          BambooInk.lime,
          BambooInk.lime.withValues(alpha: 0.15),
        ),
        'at_risk' || 'renewal_unverified' => (
          'Needs review',
          Icons.warning_amber_rounded,
          BambooInk.amber,
          BambooInk.amber.withValues(alpha: 0.15),
        ),
        'unused' => (
          'No charges yet',
          Icons.pause_circle_outline_rounded,
          BambooInk.amber,
          BambooInk.amber.withValues(alpha: 0.15),
        ),
        'payment_issue' => (
          'Payment issue',
          Icons.error_outline_rounded,
          const Color(0xFFFF8B66),
          const Color(0x33FF8B66),
        ),
        'ended' => (
          'Ended',
          Icons.stop_circle_outlined,
          BambooInk.onSlateMuted,
          Colors.white.withValues(alpha: 0.1),
        ),
        _ => (
          series.status,
          Icons.info_outline_rounded,
          BambooInk.onSlateMuted,
          Colors.white.withValues(alpha: 0.1),
        ),
      },
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 5),
          Text(
            label,
            style: BambooFonts.ui(12, weight: FontWeight.w600, color: color),
          ),
        ],
      ),
    );
  }

  Widget _subBadge({
    required IconData icon,
    required String label,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: BambooFonts.ui(11.5, weight: FontWeight.w600, color: color),
          ),
        ],
      ),
    );
  }

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
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
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
                          size: 22,
                        ),
                      ),
                      _headerStatusBadge(series),
                    ],
                  ),
                  const SizedBox(height: AppSpace.md),
                  Text(
                    series.displayName,
                    style: BambooFonts.heading(24, color: BambooInk.onSlate),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: AppSpace.sm),
                  Wrap(
                    spacing: AppSpace.xs,
                    runSpacing: AppSpace.xs,
                    children: [
                      if (series.hasActiveAutoPay ||
                          series.autopayStatus == 'active' ||
                          series.isMandate)
                        _subBadge(
                          icon: Icons.bolt_rounded,
                          label: 'AutoPay Active',
                          color: BambooInk.lime,
                        ),
                      if (series.cadenceConfirmed)
                        _subBadge(
                          icon: Icons.event_repeat_rounded,
                          label: series.cadenceLabel,
                          color: BambooInk.onSlate,
                        ),
                      if (series.detectionSource == 'manual')
                        _subBadge(
                          icon: Icons.edit_outlined,
                          label: 'Added by you',
                          color: BambooInk.onSlate,
                        ),
                    ],
                  ),
                  if (series.amountKnown && series.typicalAmount.paise > 0) ...[
                    const SizedBox(height: AppSpace.md),
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 6,
                      children: [
                        MoneyText(
                          series.typicalAmount,
                          confidence: Confidence.estimated,
                          style: BambooFonts.money(26, color: BambooInk.onSlate),
                          showConfidenceIcon: false,
                        ),
                        Text(
                          '/ ${series.cadenceConfirmed ? series.cadenceLabel.toLowerCase() : 'cycle'}',
                          style: BambooFonts.ui(
                            13,
                            color: BambooInk.onSlateMuted,
                          ),
                        ),
                      ],
                    ),
                  ] else if (!series.amountKnown) ...[
                    const SizedBox(height: AppSpace.md),
                    Text(
                      series.hasActiveAutoPay ||
                              series.autopayStatus == 'active' ||
                              series.isMandate
                          ? 'AutoPay Active • Awaiting first charge'
                          : 'Setup confirmed • Awaiting first charge',
                      style: BambooFonts.ui(
                        13,
                        weight: FontWeight.w600,
                        color: BambooInk.lime,
                      ),
                    ),
                  ],
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
                    series.setupConfirmed
                        ? 'Setup confirmed'
                        : switch (series.status) {
                            'confirmed' || 'active' => 'Active',
                            'at_risk' || 'renewal_unverified' => 'Needs review',
                            'unused' => 'No charges yet',
                            'payment_issue' => 'Payment issue',
                            'ended' => 'Ended',
                            _ => series.status,
                          },
                  ),
                  _detail(
                    'Amount',
                    series.amountKnown
                        ? (series.typicalAmount.isZero
                            ? 'Free'
                            : series.typicalAmount.format())
                        : 'Awaiting first charge',
                  ),
                  _detail(
                    'Billing cycle',
                    series.cadenceConfirmed
                        ? series.cadenceLabel
                        : 'Not confirmed',
                  ),
                  if (series.annualCost.paise > 0)
                    _detail(
                      'Annual estimate',
                      series.annualCost.format(hidePaise: true),
                    ),
                  _detail(
                    'Last seen date',
                    series.lastSeenOn != null
                        ? _date(series.lastSeenOn!)
                        : 'None yet',
                  ),
                  _detail(
                    'Next expected date',
                    series.nextExpectedOn != null
                        ? _date(series.nextExpectedOn!)
                        : (series.setupConfirmed
                            ? 'Awaiting schedule'
                            : 'Not scheduled'),
                  ),
                  _detail(
                    'Payment card',
                    (series.cardName != null && series.cardName!.isNotEmpty)
                        ? series.cardName!
                        : (series.paymentMethod != null &&
                                series.paymentMethod!.isNotEmpty)
                            ? series.paymentMethod!
                            : (series.hasActiveAutoPay || series.isMandate
                                ? 'AutoPay Mandate'
                                : 'Not specified'),
                  ),
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
                  return Container(
                    padding: const EdgeInsets.all(AppSpace.md),
                    decoration: BoxDecoration(
                      color: BambooInk.glassFillOnPaper,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: BambooInk.hairlineOnPaper),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          snapshot.connectionState == ConnectionState.waiting
                              ? Icons.sync_rounded
                              : Icons.info_outline_rounded,
                          size: 20,
                          color: BambooInk.ink500,
                        ),
                        const SizedBox(width: AppSpace.sm),
                        Expanded(
                          child: Text(
                            snapshot.connectionState == ConnectionState.waiting
                                ? 'Checking messages stored on this device…'
                                : 'The original SMS is not available on this device for this subscription.',
                            style: BambooFonts.ui(13, color: BambooInk.ink500),
                          ),
                        ),
                      ],
                    ),
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
                      Wrap(
                        alignment: WrapAlignment.spaceBetween,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: AppSpace.sm,
                        runSpacing: AppSpace.xs,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 5,
                            ),
                            decoration: BoxDecoration(
                              color: evidence.exact
                                  ? BambooInk.rankBadgeBg
                                  : BambooInk.paperMuted,
                              borderRadius: BorderRadius.circular(
                                AppRadius.pill,
                              ),
                              border: Border.all(
                                color: evidence.exact
                                    ? BambooInk.jade.withValues(alpha: 0.25)
                                    : BambooInk.hairlineOnPaper,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  evidence.exact
                                      ? Icons.verified_rounded
                                      : Icons.info_outline_rounded,
                                  size: 13,
                                  color: evidence.exact
                                      ? BambooInk.rankBadgeInk
                                      : BambooInk.ink700,
                                ),
                                const SizedBox(width: 5),
                                Text(
                                  evidence.exact
                                      ? 'Source message on this device'
                                      : 'Related service message',
                                  style: BambooFonts.ui(
                                    11.5,
                                    weight: FontWeight.w700,
                                    color: evidence.exact
                                        ? BambooInk.rankBadgeInk
                                        : BambooInk.ink700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: BambooInk.slate.withValues(alpha: 0.06),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              evidence.message.message.sender,
                              style: BambooFonts.ui(
                                11.5,
                                weight: FontWeight.w700,
                                color: BambooInk.ink700,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpace.sm),
                      Row(
                        children: [
                          const Icon(
                            Icons.access_time_rounded,
                            size: 13,
                            color: BambooInk.ink500,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            'Received ${_date(evidence.message.message.receivedAt)}',
                            style: BambooFonts.ui(12, color: BambooInk.ink500),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(AppSpace.md),
                        decoration: BoxDecoration(
                          color: BambooInk.paperMuted,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: BambooInk.hairlineOnPaper.withValues(
                              alpha: 0.5,
                            ),
                          ),
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
                        const SizedBox(height: 10),
                        Text(
                          'Matched by service name and AutoPay wording. This message is related; an exact source link was not saved for this older record.',
                          style: BambooFonts.ui(11.5, color: BambooInk.ink500),
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
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 120,
          child: Text(
            label,
            style: BambooFonts.ui(13, color: BambooInk.ink500),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: BambooFonts.ui(
              13,
              weight: FontWeight.w600,
              color: BambooInk.ink900,
            ),
          ),
        ),
      ],
    ),
  );
}
