import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

String smsMoney(int? minor) => minor == null
    ? 'unknown'
    : NumberFormat.currency(locale: 'en_IN', symbol: '₹').format(minor / 100);
String smsDate(DateTime date) =>
    DateFormat('d MMM yyyy').format(date.toLocal());

class SmsLoading extends StatelessWidget {
  const SmsLoading({super.key});
  @override
  Widget build(BuildContext context) => Center(
    child: Semantics(
      label: 'Loading your messages',
      child: CircularProgressIndicator(),
    ),
  );
}

class SmsError extends StatelessWidget {
  const SmsError({super.key, required this.onRetry});
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off_outlined, size: 40),
          const SizedBox(height: 16),
          const Text(
            'We couldn’t load this yet. Your saved messages are safe.',
            textAlign: TextAlign.center,
          ),
          TextButton(onPressed: onRetry, child: const Text('Try again')),
        ],
      ),
    ),
  );
}

class SmsEmpty extends StatelessWidget {
  const SmsEmpty(this.message, {super.key});
  final String message;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodyLarge,
      ),
    ),
  );
}

void smsShowError(BuildContext context, Object error) {
  final message = error is ArgumentError
      ? error.message.toString()
      : 'Couldn’t save this yet. Please try again.';
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}
