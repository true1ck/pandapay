import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../app/design/app_theme.dart';
import '../../data/premium_reminders.dart';

class InsurancePremiumsSection extends StatelessWidget {
  final List<PremiumReminder> reminders;
  final bool upcoming;

  const InsurancePremiumsSection({
    required this.reminders,
    required this.upcoming,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    if (reminders.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                upcoming ? 'Upcoming premiums' : 'Insurance premiums',
                style: BambooFonts.heading(17, color: BambooInk.ink900),
              ),
              const SizedBox(width: AppSpace.sm),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpace.sm,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: BambooInk.rankBadgeBg,
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                  border: Border.all(color: BambooInk.rankBadgeBorder),
                ),
                child: Text(
                  '${reminders.length}',
                  style: BambooFonts.ui(
                    11,
                    weight: FontWeight.w600,
                    color: BambooInk.rankBadgeInk,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.xs),
          Text(
            'The message states a month, not a day. Check your policy for the exact date and amount.',
            style: BambooFonts.ui(12, color: BambooInk.ink500),
          ),
          const SizedBox(height: AppSpace.md),
          for (final reminder in reminders)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.sm),
              child: _PremiumRow(reminder: reminder),
            ),
        ],
      ),
    );
  }
}

class _PremiumRow extends StatelessWidget {
  final PremiumReminder reminder;

  const _PremiumRow({required this.reminder});

  @override
  Widget build(BuildContext context) {
    final meta = [
      reminder.category.label,
      if (reminder.accountLast4?.isNotEmpty == true)
        'Policy ••${reminder.accountLast4}',
    ].join(' · ');
    return Container(
      padding: const EdgeInsets.all(AppSpace.md),
      decoration: BoxDecoration(
        color: BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: reminder.category.iconBg,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              reminder.category.icon,
              color: reminder.category.iconColor,
              size: 20,
            ),
          ),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  reminder.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: BambooFonts.ui(
                    14,
                    weight: FontWeight.w600,
                    color: BambooInk.ink900,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  meta,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: BambooFonts.ui(11.5, color: BambooInk.ink700),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpace.sm),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                'Next premium',
                style: BambooFonts.ui(11, color: BambooInk.ink500),
              ),
              const SizedBox(height: 2),
              Text(
                DateFormat('MMM yyyy').format(reminder.premiumMonth),
                style: BambooFonts.money(14, color: BambooInk.ink900),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
