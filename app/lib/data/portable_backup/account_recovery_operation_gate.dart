import 'dart:async';

/// Process-local admission and drain for operations which can mutate local
/// state after an await. The SQLite fence is separately mandatory: this gate
/// cannot see another isolate, raw Database handles or external file writers.
class AccountRecoveryOperationGate {
  static final process = AccountRecoveryOperationGate();
  int _active = 0;
  bool _closed = false;
  Completer<void>? _drained;
  final Object _zoneKey = Object();

  bool get isRecovering => _closed;
  int get activeOperations => _active;

  AccountRecoveryOperationAdmission admit() {
    final context = Zone.current[_zoneKey];
    final joinsAdmittedWork =
        context is _RecoveryOperationContext &&
        context.gate == this &&
        context.active;
    if (_closed && !joinsAdmittedWork) throw const AccountRecoveryBusy();
    // Count nested work too: an unawaited child must keep recovery waiting
    // even if its parent operation has already returned.
    _active++;
    return AccountRecoveryOperationAdmission._(() {
      _active--;
      if (_active == 0) {
        _drained?.complete();
        _drained = null;
      }
    });
  }

  /// Existing operations finish normally. New work fails before its first
  /// side effect, so durable outboxes retain their original mutation IDs.
  Future<T> run<T>(Future<T> Function() operation) async {
    // A sync job already admitted before closure may finish its nested HTTP
    // calls and durable acknowledgements, rather than failing half a job.
    final admission = admit();
    final context = _RecoveryOperationContext(this);
    try {
      return await runZoned(operation, zoneValues: {_zoneKey: context});
    } finally {
      context.active = false;
      admission.finish();
    }
  }

  /// Hold admission closed through the complete DB/file operation. A timeout
  /// never cancels or abandons an existing mutation; recovery simply refuses.
  Future<T> exclusive<T>(
    Future<T> Function() recovery, {
    Duration drainTimeout = const Duration(seconds: 30),
  }) async {
    if (_closed) throw const AccountRecoveryBusy();
    _closed = true;
    try {
      if (_active > 0) {
        _drained ??= Completer<void>();
        await _drained!.future.timeout(drainTimeout);
      }
      return await recovery();
    } finally {
      _closed = false;
    }
  }
}

class AccountRecoveryOperationAdmission {
  final void Function() _finish;
  bool _finished = false;
  AccountRecoveryOperationAdmission._(this._finish);
  void finish() {
    if (_finished) return;
    _finished = true;
    _finish();
  }
}

class AccountRecoveryBusy implements Exception {
  const AccountRecoveryBusy();
  @override
  String toString() => 'Local account recovery is in progress';
}

class _RecoveryOperationContext {
  final AccountRecoveryOperationGate gate;
  bool active = true;
  _RecoveryOperationContext(this.gate);
}
