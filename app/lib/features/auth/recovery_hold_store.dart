import 'dart:convert';

import '../../data/secure_storage/secure_storage_options.dart';

/// A recovery that is waiting out its 24 hours. The resume token is a credential
/// for finishing it, so it lives in secure storage and only on this install.
class RecoveryHold {
  final String attemptId;
  final String resumeToken;
  final DateTime holdUntil;
  final String newEmailHint;

  const RecoveryHold({
    required this.attemptId,
    required this.resumeToken,
    required this.holdUntil,
    required this.newEmailHint,
  });

  bool isOver(DateTime now) => !now.isBefore(holdUntil);

  Map<String, Object?> toJson() => {
    'attempt_id': attemptId,
    'resume_token': resumeToken,
    'hold_until': holdUntil.toUtc().toIso8601String(),
    'new_email_hint': newEmailHint,
  };
}

class RecoveryHoldStore {
  static const _key = 'pandapay_app.recovery_hold_v1';

  Future<void> save(RecoveryHold hold) =>
      pandaPaySecureStorage.write(key: _key, value: jsonEncode(hold.toJson()));

  Future<RecoveryHold?> load() async {
    try {
      final raw = await pandaPaySecureStorage.read(key: _key);
      if (raw == null) return null;
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final until = DateTime.tryParse('${json['hold_until']}');
      final id = json['attempt_id'];
      final token = json['resume_token'];
      if (until == null || id is! String || token is! String) return null;
      return RecoveryHold(
        attemptId: id,
        resumeToken: token,
        holdUntil: until.toLocal(),
        newEmailHint: '${json['new_email_hint'] ?? ''}',
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> clear() async {
    try {
      await pandaPaySecureStorage.delete(key: _key);
    } catch (_) {
      // Nothing useful to do; a stale hold simply fails to finish and is cleared then.
    }
  }
}
