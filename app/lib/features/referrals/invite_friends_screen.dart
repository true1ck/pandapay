import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/user_cards_repository.dart' show Referral, ReferralInfo;
import '../../main.dart' show MoneyText;

/// Design 25 "Invite friends".
///
/// The mockup's "Give ₹100, get ₹100" is a commercial commitment, not a
/// layout choice, so the amounts come from the `referral_program` config row
/// (migration 0026) rather than being hardcoded. Two consequences worth
/// knowing:
///
/// - If the programme is switched off server-side this screen still works —
///   you can still invite people — but it makes no reward claim at all. It
///   will never advertise money that isn't on offer.
/// - The friends list shows each referral's real state. "Earned" appears
///   only for rows the backend has marked qualified; everyone else reads
///   "signed up, no payment yet" or "invited". Nothing is counted early.
///
/// Crediting the reward itself is a payout system that does not exist. This
/// screen tracks and displays qualification; it does not move money, and
/// says nothing that implies it has.
class InviteFriendsScreen extends ConsumerWidget {
  const InviteFriendsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final referrals = ref.watch(referralsProvider);
    final signedIn = ref.watch(accessTokenProvider) != null;

    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text('Invite friends', style: BambooFonts.heading(19, color: BambooInk.ink900)),
      ),
      body: AppBackground(
        child: !signedIn
            ? const EmptyState(
                icon: Icons.card_giftcard_rounded,
                title: 'Invites need an account',
                message: 'Your invite code is tied to your account, so we can tell who joined '
                    'through you.',
              )
            : referrals.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (err, _) => ErrorState(
                  message: userFacingErrorMessage(err),
                  onRetry: () => ref.invalidate(referralsProvider),
                ),
                data: (info) => info == null ? const SizedBox.shrink() : _InviteBody(info: info),
              ),
      ),
    );
  }
}

class _InviteBody extends StatelessWidget {
  final ReferralInfo info;
  const _InviteBody({required this.info});

  String get _link => 'https://pandapay.app/i/${info.code ?? ''}';

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 30),
      children: [
        Container(
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            color: BambooInk.slate,
            borderRadius: BorderRadius.circular(26),
          ),
          child: Column(
            children: [
              if (info.rewardsActive) ...[
                Wrap(
                  alignment: WrapAlignment.center,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text('Give ', style: _headline),
                    MoneyText(
                      info.refereeReward,
                      confidence: Confidence.confirmed,
                      style: _headline,
                      hidePaise: true,
                      showConfidenceIcon: false,
                    ),
                    Text(', get ', style: _headline),
                    MoneyText(
                      info.referrerReward,
                      confidence: Confidence.confirmed,
                      style: _headline,
                      hidePaise: true,
                      showConfidenceIcon: false,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Your friend gets theirs on their ${info.qualifyingAction}. You get yours '
                  'when they do.',
                  textAlign: TextAlign.center,
                  style: BambooFonts.ui(13, color: BambooInk.onSlateSubtle, height: 1.5),
                ),
              ] else ...[
                // Programme switched off server-side: invite mechanics stay,
                // reward claim goes. See the class doc-comment.
                Text('Bring a friend along', style: _headline),
                const SizedBox(height: 8),
                Text(
                  "Share your code and we'll know they came from you. There's no reward "
                  'running right now.',
                  textAlign: TextAlign.center,
                  style: BambooFonts.ui(13, color: BambooInk.onSlateSubtle, height: 1.5),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 18),
        if (info.code != null) ...[
          Container(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            decoration: BoxDecoration(
              color: BambooInk.glassFillOnPaper,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: BambooInk.hairlineOnPaper),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    info.code!,
                    style: BambooFonts.heading(17, color: BambooInk.ink900, letterSpacing: 1),
                  ),
                ),
                TextButton(
                  onPressed: () async {
                    final messenger = ScaffoldMessenger.of(context);
                    await Clipboard.setData(ClipboardData(text: info.code!));
                    messenger.showSnackBar(const SnackBar(content: Text('Invite code copied.')));
                  },
                  style: TextButton.styleFrom(
                    foregroundColor: BambooInk.ink900,
                    backgroundColor: BambooInk.paperMuted,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                    ),
                    textStyle: BambooFonts.ui(12.5, weight: FontWeight.w700),
                  ),
                  child: const Text('Copy'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: () => SharePlus.instance.share(
              ShareParams(
                text: info.rewardsActive
                    ? 'I use PandaPay to pick the right credit card at checkout. Use my code '
                          '${info.code} and we both get a bonus: $_link'
                    : 'I use PandaPay to pick the right credit card at checkout — try it with '
                          'my code ${info.code}: $_link',
                subject: 'Try PandaPay',
              ),
            ),
            style: FilledButton.styleFrom(
              backgroundColor: BambooInk.lime,
              foregroundColor: BambooInk.slate,
              minimumSize: const Size.fromHeight(52),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              textStyle: BambooFonts.ui(15, weight: FontWeight.w700),
            ),
            child: const Text('Share invite link'),
          ),
        ],
        const SizedBox(height: 22),
        if (info.referrals.isEmpty)
          Text(
            'No one has joined through you yet. Your code above is live — anyone who signs up '
            'with it shows here.',
            style: BambooFonts.ui(13, color: BambooInk.ink500, height: 1.5),
          )
        else ...[
          Text(
            '${info.referrals.length} friend${info.referrals.length == 1 ? '' : 's'} invited'
            '${info.qualifiedCount > 0 ? ' · ${info.qualifiedCount} qualified' : ''}',
            style: BambooFonts.ui(
              12,
              weight: FontWeight.w600,
              color: BambooInk.ink500,
            ).copyWith(letterSpacing: 1.4),
          ),
          const SizedBox(height: AppSpace.sm),
          for (final r in info.referrals) _ReferralRow(referral: r, info: info),
        ],
      ],
    );
  }

  static TextStyle get _headline =>
      BambooFonts.heading(24, weight: FontWeight.w800, color: BambooInk.lime);
}

class _ReferralRow extends StatelessWidget {
  final Referral referral;
  final ReferralInfo info;
  const _ReferralRow({required this.referral, required this.info});

  @override
  Widget build(BuildContext context) {
    final label = referral.label?.isNotEmpty == true ? referral.label! : 'Invited friend';
    return Container(
      margin: const EdgeInsets.only(bottom: 9),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      decoration: BoxDecoration(
        color: BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: BambooInk.paperMuted,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              label.characters.first.toUpperCase(),
              style: BambooFonts.heading(13, color: BambooInk.ink300),
            ),
          ),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: Text(
              label,
              style: BambooFonts.ui(14, weight: FontWeight.w600, color: BambooInk.ink900),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // Only a row the backend marked qualified says anything about
          // money. The other two states say exactly where they've got to.
          if (referral.isQualified && info.rewardsActive)
            MoneyText(
              info.referrerReward,
              confidence: Confidence.confirmed,
              style: BambooFonts.ui(12.5, weight: FontWeight.w600, color: BambooInk.jade),
              suffix: ' earned',
              hidePaise: true,
              showConfidenceIcon: false,
            )
          else
            Text(
              switch (referral.rewardState) {
                'qualified' => 'Qualified',
                'signed_up' => 'Signed up · no payment yet',
                _ => 'Invited',
              },
              style: BambooFonts.ui(12.5, color: BambooInk.ink500),
            ),
        ],
      ),
    );
  }
}
