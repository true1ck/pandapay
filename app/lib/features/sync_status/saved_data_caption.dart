import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../app/design/app_theme.dart';

/// "Saved data · updated 6:40 PM" (WP-C16). A quiet caption for screens that
/// show a purely cached read; not a banner. Hidden when [updatedAt] is null.
String savedDataCaption(DateTime updatedAt, {DateTime? now}) {
  final today = now ?? DateTime.now();
  final sameDay = updatedAt.year == today.year &&
      updatedAt.month == today.month &&
      updatedAt.day == today.day;
  final time = DateFormat('h:mm a').format(updatedAt);
  return sameDay
      ? 'Saved data · updated $time'
      : 'Saved data · updated ${DateFormat('d MMM').format(updatedAt)}, $time';
}

class SavedDataCaption extends StatelessWidget {
  const SavedDataCaption({super.key, required this.updatedAt});

  final DateTime? updatedAt;

  @override
  Widget build(BuildContext context) {
    final at = updatedAt;
    if (at == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
      child: Text(
        savedDataCaption(at),
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: BambooInk.ink500,
        ),
      ),
    );
  }
}
