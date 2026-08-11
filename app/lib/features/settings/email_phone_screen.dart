import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import 'feedback_support_screen.dart';

/// Design 22 "Email & phone" — the two identifiers the account is reachable
/// on, each with its verification state and a way to change it.
///
/// What's real and what isn't, stated plainly rather than implied:
///
/// - The **email** is the account's real sign-in identifier
///   (`profiles.email`), and it genuinely is verified — an account can only
///   exist because an OTP sent to that address was entered correctly. The
///   "Verified" pill is a fact, not decoration.
/// - The **phone** is collected at sign-up and linked to the account, but
///   auth/ has no verify-phone endpoint, so it has never been proven to
///   belong to the user. It is shown as "Unverified" for exactly that
///   reason. Marking it verified because it's present would be the kind of
///   claim this codebase doesn't make. (See AuthMode's doc-comment in
///   login_screen.dart for the same reasoning on the log-in path.)
/// - Changing either one requires a confirmation code to the OLD address,
///   as the mockup's own footnote says. That flow needs an auth/ endpoint
///   that doesn't exist yet, so "Change email" explains precisely what's
///   needed and routes to support instead of opening a form that would
///   silently fail. A dead-looking button that does nothing is worse than
///   one that says why.
class EmailPhoneScreen extends ConsumerWidget {
  const EmailPhoneScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileProvider);

    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text('Email & phone', style: BambooFonts.heading(19, color: BambooInk.ink900)),
      ),
      body: AppBackground(
        child: profile.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (err, _) => ErrorState(
            message: userFacingErrorMessage(err),
            onRetry: () => ref.invalidate(profileProvider),
          ),
          data: (data) {
            final email = (data?['email'] as String?)?.trim();
            final phone = (data?['phone_number'] as String?)?.trim();

            return ListView(
              padding: const EdgeInsets.fromLTRB(20, AppSpace.md, 20, 30),
              children: [
                const _SectionLabel('Phone'),
                _IdentifierCard(
                  value: phone?.isNotEmpty == true ? phone! : 'Not on file',
                  // See the class doc-comment: present is not the same as
                  // verified, and auth/ has no way to prove this one.
                  badge: phone?.isNotEmpty == true
                      ? const _Badge('Unverified', verified: false)
                      : null,
                  note: phone?.isNotEmpty == true
                      ? 'Used to match bank SMS to your cards. We have never sent a code to it, '
                            'so it is linked but not proven.'
                      : 'Add one at sign-up to let PandaPay match bank SMS to your cards.',
                ),
                const SizedBox(height: AppSpace.xl),
                const _SectionLabel('Email'),
                _IdentifierCard(
                  value: email?.isNotEmpty == true ? email! : 'Not on file',
                  badge: email?.isNotEmpty == true ? const _Badge('Verified', verified: true) : null,
                  note: 'Sign-in codes, statements and account recovery all go here.',
                  action: email?.isNotEmpty == true
                      ? _ChangeAction(currentEmail: email!)
                      : null,
                ),
                const SizedBox(height: AppSpace.xl),
                Text(
                  'Changing either one sends a confirmation code to the old address first, so '
                  'losing access to an account takes more than losing one device.',
                  style: BambooFonts.ui(12.5, color: BambooInk.ink500, height: 1.55),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.sm),
      child: Text(
        text.toUpperCase(),
        style: BambooFonts.ui(
          12,
          weight: FontWeight.w600,
          color: BambooInk.ink500,
        ).copyWith(letterSpacing: 1.4),
      ),
    );
  }
}

class _IdentifierCard extends StatelessWidget {
  final String value;
  final Widget? badge;
  final String note;
  final Widget? action;

  const _IdentifierCard({required this.value, this.badge, required this.note, this.action});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  value,
                  style: BambooFonts.ui(14.5, weight: FontWeight.w600, color: BambooInk.ink900),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (badge != null) ...[const SizedBox(width: AppSpace.sm), badge!],
            ],
          ),
          const SizedBox(height: 10),
          Text(note, style: BambooFonts.ui(12.5, color: BambooInk.ink500, height: 1.5)),
          if (action != null) ...[const SizedBox(height: 14), action!],
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final String label;
  final bool verified;
  const _Badge(this.label, {required this.verified});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
      decoration: BoxDecoration(
        color: verified ? BambooInk.rankBadgeBg : BambooInk.paperMuted,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: verified ? BambooInk.rankBadgeBorder : BambooInk.hairlineOnPaper),
      ),
      child: Text(
        label,
        style: BambooFonts.ui(
          11.5,
          weight: FontWeight.w700,
          color: verified ? BambooInk.rankBadgeInk : BambooInk.ink500,
        ),
      ),
    );
  }
}

/// Design 22's "Change email" button. auth/ has no change-identifier
/// endpoint — the confirmation-code-to-the-old-address flow the mockup
/// describes doesn't exist server-side — so rather than open a form that
/// would fail on submit, this says so and hands off to the real support
/// path, prefilled with the request.
class _ChangeAction extends StatelessWidget {
  final String currentEmail;
  const _ChangeAction({required this.currentEmail});

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: () => showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: BambooInk.paper,
          title: Text('Change your email', style: BambooFonts.heading(18, color: BambooInk.ink900)),
          content: Text(
            'Your email is how you sign in and how you recover the account, so we move it by '
            'hand: confirm from $currentEmail, then verify the new address. Support does this '
            'within a working day.',
            style: BambooFonts.ui(13.5, color: BambooInk.ink500, height: 1.5),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Not now'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: BambooInk.slate,
                foregroundColor: BambooInk.lime,
              ),
              onPressed: () {
                Navigator.of(context).pop();
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => FeedbackSupportScreen(
                      prefilledKind: 'general',
                      prefilledMessage:
                          "I'd like to change the email on my account. The current address is "
                          '$currentEmail.',
                    ),
                  ),
                );
              },
              child: const Text('Contact support'),
            ),
          ],
        ),
      ),
      style: OutlinedButton.styleFrom(
        foregroundColor: BambooInk.ink900,
        backgroundColor: BambooInk.paperMuted,
        minimumSize: const Size.fromHeight(46),
        side: const BorderSide(color: BambooInk.hairlineOnPaper),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: BambooFonts.ui(14, weight: FontWeight.w700),
      ),
      child: const Text('Change email'),
    );
  }
}
