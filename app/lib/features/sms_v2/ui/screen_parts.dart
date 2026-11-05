import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../app/design/app_theme.dart';
import '../../../app/design/bamboo_components.dart';
import '../../../app/design/widgets.dart';

String smsMoney(int? minor) => minor == null
    ? 'unknown'
    : NumberFormat.currency(locale: 'en_IN', symbol: '₹').format(minor / 100);

/// SMS dates are Indian calendar days, whatever the phone's time zone says.
String smsDate(DateTime date) => DateFormat(
  'd MMM yyyy',
).format(date.toUtc().add(const Duration(hours: 5, minutes: 30)));

class SmsLoading extends StatelessWidget {
  const SmsLoading({super.key});
  @override
  Widget build(BuildContext context) => Center(
    child: Semantics(
      label: 'Loading your messages',
      child: const SizedBox(
        width: 28,
        height: 28,
        child: CircularProgressIndicator(strokeWidth: 2.5),
      ),
    ),
  );
}

class SmsError extends StatelessWidget {
  const SmsError({super.key, required this.onRetry});
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpace.xxl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const BambooIconTile(Icons.cloud_off_outlined, size: 56),
          const SizedBox(height: AppSpace.lg),
          Text(
            'We couldn’t load this yet. Your saved messages are safe.',
            textAlign: TextAlign.center,
            style: BambooFonts.ui(14, color: BambooInk.ink700, height: 1.45),
          ),
          const SizedBox(height: AppSpace.lg),
          OutlinedButton.icon(
            style: BambooButtons.secondary,
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('Try again'),
          ),
        ],
      ),
    ),
  );
}

/// Empty state for the SMS screens. The first sentence of [message] becomes
/// the headline and the rest the supporting line, so call sites keep
/// passing one plain sentence pair.
class SmsEmpty extends StatelessWidget {
  const SmsEmpty(this.message, {super.key, this.icon = Icons.inbox_outlined});
  final String message;
  final IconData icon;
  @override
  Widget build(BuildContext context) {
    final split = message.indexOf('. ');
    final title = split < 0
        ? message.replaceFirst(RegExp(r'\.$'), '')
        : message.substring(0, split);
    final detail = split < 0 ? null : message.substring(split + 2);
    return EmptyState(icon: icon, title: title, message: detail);
  }
}

void smsShowError(BuildContext context, Object error) {
  final message = error is ArgumentError
      ? error.message.toString()
      : 'Couldn’t save this yet. Please try again.';
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}
