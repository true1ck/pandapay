import 'package:intl/intl.dart';

enum LiveAlertHealth { off, waiting, working, quiet }

/// What the "Live bank alerts" row says. Any SMS the automation passes to
/// PandaPay counts (OTPs and personal texts too), so a quiet spell of
/// [quietAfter] most likely means the shortcut was removed or switched off.
class LiveAlertStatus {
  static const quietAfter = Duration(days: 3);

  final LiveAlertHealth health;
  final String label;

  /// "44 messages captured since 13 Nov · 8 today"; null before the first one.
  final String? counts;

  /// What became of the newest live message ("Saved", "Not a bank message,
  /// skipped"...); null when nothing is known.
  final String? lastResult;

  /// "2 waiting to be added": saved on the phone, not yet read by the app.
  final String? waitingNote;
  const LiveAlertStatus._(
    this.health,
    this.label, {
    this.counts,
    this.lastResult,
    this.waitingNote,
  });

  /// [total], [today], [since] and the last-message fields come from the
  /// phone's own spool; they only decorate the headline, never change [health].
  factory LiveAlertStatus.of({
    required bool enabled,
    required DateTime? lastLiveAt,
    required DateTime now,
    int total = 0,
    int today = 0,
    int waiting = 0,
    DateTime? since,
    String? intake,
    String? lastState,
    String? processed,
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
      counts: _counts(total, today, since),
      lastResult: _result(intake, lastState, processed),
      waitingNote: waiting > 0 ? '$waiting waiting to be added' : null,
    );
  }

  static String? _counts(int total, int today, DateTime? since) {
    if (total <= 0) return null;
    final noun = total == 1 ? 'message' : 'messages';
    final from = since == null
        ? ''
        : ' since ${DateFormat('d MMM').format(since.toLocal())}';
    final day = today > 0 ? ' · $today today' : '';
    return '$total $noun captured$from$day';
  }

  /// The words for the newest live message. [intake] is what the phone did
  /// when it arrived; [processed] is what the app decided once it read it.
  static String? _result(String? intake, String? lastState, String? processed) {
    switch (intake) {
      case 'excluded_security':
        return 'Security code, ignored and never saved';
      case 'invalid_body':
        return 'Empty message, skipped';
      case 'missing_date':
      case 'missing_sender':
        return 'Message details missing, skipped';
    }
    if (lastState == 'pending') return 'Saved, waiting to be added';
    return switch (processed) {
      'captured' => 'Saved',
      'review' => 'Needs your review',
      'ignored' => 'Not a bank message, skipped',
      'existing' => 'Already saved',
      _ => null,
    };
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
