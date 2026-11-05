import 'package:intl/intl.dart';

enum LiveAlertHealth { off, waiting, working, quiet }

/// What the "Live bank alerts" row says. Any SMS the automation passes to
/// PandaPay counts (OTPs and personal texts too), so a quiet spell of
/// [quietAfter] most likely means the shortcut was removed or switched off.
class LiveAlertStatus {
  static const quietAfter = Duration(days: 3);

  final LiveAlertHealth health;
  final String label;
  const LiveAlertStatus._(this.health, this.label);

  factory LiveAlertStatus.of({
    required bool enabled,
    required DateTime? lastLiveAt,
    required DateTime now,
  }) {
    if (!enabled) {
      return const LiveAlertStatus._(
        LiveAlertHealth.off,
        'Off. Turn on to save new bank SMS automatically.',
      );
    }
    if (lastLiveAt == null) {
      return const LiveAlertStatus._(
        LiveAlertHealth.waiting,
        'Waiting for your first SMS. Add the live alerts shortcut below.',
      );
    }
    final age = now.difference(lastLiveAt);
    if (age >= quietAfter) {
      return LiveAlertStatus._(
        LiveAlertHealth.quiet,
        'No SMS for ${age.inDays} days. Live alerts may be off.',
      );
    }
    return LiveAlertStatus._(
      LiveAlertHealth.working,
      'On · last SMS ${_when(lastLiveAt.toLocal(), now.toLocal())}',
    );
  }

  static String _when(DateTime at, DateTime now) {
    final time = DateFormat('h:mm a').format(at).toLowerCase();
    final day = DateTime(at.year, at.month, at.day);
    final today = DateTime(now.year, now.month, now.day);
    final days = today.difference(day).inDays;
    if (days <= 0) return 'today, $time';
    if (days == 1) return 'yesterday, $time';
    return '${DateFormat('d MMM').format(at)}, $time';
  }
}
