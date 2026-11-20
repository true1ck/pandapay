import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Proof that PandaPay's server answered, taken from the app's own traffic.
///
/// Every response the shared API client receives is reported here. An answer
/// below 500 (or a 429) means the server is reachable, whatever the reachability
/// probe says: the probe is one extra request and loses to a busy server, while
/// a real call that just succeeded is the better witness. Gateway and server
/// errors are not counted: nginx answering 502 or 503 means the app server is
/// down.
class ApiAnswerEvidence {
  ApiAnswerEvidence({DateTime Function()? now}) : _now = now ?? DateTime.now;

  /// Process-wide instance fed by `AuthenticatedHttpClient`.
  static final process = ApiAnswerEvidence();

  final DateTime Function() _now;
  DateTime? _at;
  final _answers = StreamController<void>.broadcast(sync: true);

  /// Emits once per counted answer.
  Stream<void> get answers => _answers.stream;

  void note(int status) {
    if (status < 100 || (status >= 500 && status != 429)) return;
    _at = _now();
    if (!_answers.isClosed) _answers.add(null);
  }

  bool answeredWithin(Duration window) {
    final at = _at;
    return at != null && _now().difference(at) <= window;
  }
}

/// The evidence the reachability monitor reads; tests override it.
final apiAnswerEvidenceProvider = Provider<ApiAnswerEvidence>(
  (ref) => ApiAnswerEvidence.process,
);
