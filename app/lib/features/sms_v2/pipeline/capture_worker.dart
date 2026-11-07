import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../../data/local/app_database.dart';
import '../../../data/local/financial_store.dart';
import '../../../data/portable_backup/account_recovery_operation_gate.dart';
import '../../sms_import/sms_background_queue.dart';
import '../personal/personal_rule_engine.dart';
import '../personal/personal_rule_store.dart';
import '../storage/instrument_store.dart';
import '../storage/provisional_store.dart';
import '../storage/schema.dart';
import '../storage/sync_state_store.dart';
import 'capture_executor.dart';

/// Serial, database-owning worker for SMS v2 capture. It opens its own SQLite
/// connection (path + key; a native handle is never shared across isolates)
/// and runs [runCaptureChunk] there. Only plain data crosses the boundary:
/// messages and the rule bundle as JSON in, changed entity names or an error
/// string out. See docs/sms-capture-isolate-design.md.
///
/// Each group of a chunk commits in one `BEGIN IMMEDIATE` transaction together
/// with its acknowledgements, so any failure leaves the messages in
/// `sms_intake` for the next sync. The worker is never killed (a killed isolate
/// would keep its write lock until GC); a timeout only stops waiting.
class SmsCaptureWorker implements CaptureExecutor {
  SmsCaptureWorker(
    this.databasePath, {
    this.keyHex,
    AccountRecoveryOperationGate? recoveryGate,
    this.maxPendingRequests = 4,
    this.jobTimeout = const Duration(seconds: 90),
  }) : recoveryGate = recoveryGate ?? AccountRecoveryOperationGate.process {
    _responses.listen(_onMessage);
  }

  final String databasePath;

  /// Null only in host tests, which run on the system SQLite.
  final String? keyHex;
  final AccountRecoveryOperationGate recoveryGate;
  final int maxPendingRequests;
  final Duration jobTimeout;

  final _responses = ReceivePort();
  final _pending = <int, _Job>{};
  final _exited = Completer<void>();
  Completer<SendPort>? _ready;
  Future<SendPort>? _startup;
  SendPort? _commands;
  Object? _terminalError;
  String? _sentBundleHash;
  var _sequence = 0;
  var _closed = false;
  Timer? _idle;
  Duration? _idleTimeout;
  void Function()? _onIdleClosed;

  bool get isUsable => !_closed && _terminalError == null;

  static final _encodedBundles = Expando<({String hash, String json})>(
    'captureBundleJson',
  );

  /// Encoded once per bundle object: R3, never re-hash unchanged data.
  static ({String hash, String json}) _encode(RuleBundle bundle) =>
      _encodedBundles[bundle] ??= () {
        final json = jsonEncode(bundle.toJson());
        return (hash: sha256.convert(utf8.encode(json)).toString(), json: json);
      }();

  // ---------------------------------------------------------------- shared

  static final _shared = <String, SmsCaptureWorker>{};

  /// One lazily started worker per database file, reused by every rebuilt
  /// `SmsV2Runtime`. It closes itself after [idleTimeout] without a job, and a
  /// dead one is replaced on the next use.
  static SmsCaptureWorker sharedFor(
    AppDatabase database, {
    Duration idleTimeout = const Duration(minutes: 2),
  }) {
    final path = database.filePath;
    if (path == null) {
      throw ArgumentError('A shared capture worker needs a file database');
    }
    final existing = _shared[path];
    if (existing != null && existing.isUsable) return existing;
    final worker = SmsCaptureWorker(path, keyHex: database.keyHexForWorker);
    worker._idleTimeout = idleTimeout;
    worker._onIdleClosed = () {
      if (identical(_shared[path], worker)) _shared.remove(path);
    };
    return _shared[path] = worker;
  }

  /// Closes every shared worker (tests, sign-out of the whole app).
  static Future<void> closeAllShared() async {
    final workers = _shared.values.toList();
    _shared.clear();
    for (final worker in workers) {
      await worker.close();
    }
  }

  // ------------------------------------------------------------ UI isolate

  void _onMessage(Object? message) {
    if (message is SendPort) {
      _commands = message;
      _ready!.complete(message);
      if (_closed) message.send(null);
    } else if (message is List && message.isNotEmpty && message[0] is int) {
      final id = message[0] as int;
      final error = message[1] as String?;
      if (id == -1) {
        _fail(StateError(error ?? 'SMS capture worker unavailable'));
        return;
      }
      final job = _pending.remove(id);
      if (job == null) return;
      final committed = (message[2] as List).cast<String>().toSet();
      job.finish(committed);
      if (error != null) {
        job.reply.completeError(StateError(error));
      } else {
        job.reply.complete();
      }
      _armIdle();
    } else if (message == null) {
      _fail(_terminalError ?? StateError('SMS capture worker stopped'));
      if (!_exited.isCompleted) _exited.complete();
      _responses.close();
    } else {
      // onError can precede onExit; an in-flight transaction is settled only
      // once the isolate has exited, so keep admissions until that event.
      _terminalError = StateError('SMS capture worker stopped');
    }
  }

  void _fail(Object error) {
    _terminalError = error;
    _idle?.cancel();
    if (!(_ready?.isCompleted ?? true)) _ready!.completeError(error);
    for (final job in _pending.values) {
      // The chunk may have committed just before the worker died: refresh.
      job.finish(const {'observations', 'needs_review', 'transactions'});
      job.reply.completeError(error);
    }
    _pending.clear();
  }

  Future<SendPort> _start() {
    final ready = _ready = Completer<SendPort>();
    unawaited(
      Isolate.spawn(
        _run,
        [_responses.sendPort, databasePath, keyHex],
        onError: _responses.sendPort,
        onExit: _responses.sendPort,
        debugName: 'pandapay-sms-capture',
      ).then<void>(
        (_) {},
        onError: (Object error, StackTrace stack) {
          _fail(StateError('SMS capture worker could not start'));
          if (!_exited.isCompleted) _exited.complete();
          _responses.close();
        },
      ),
    );
    return ready.future;
  }

  void _armIdle() {
    final timeout = _idleTimeout;
    if (timeout == null || _closed) return;
    _idle?.cancel();
    if (_pending.isNotEmpty) return;
    _idle = Timer(timeout, () {
      if (_pending.isEmpty) {
        _onIdleClosed?.call();
        unawaited(close());
      }
    });
  }

  @override
  Future<void> run(CaptureChunkRequest request) async {
    if (_closed) throw const CaptureWorkerUnavailable('closed');
    if (_terminalError != null) {
      throw CaptureWorkerUnavailable('$_terminalError');
    }
    // Admission is held until the worker's reply or exit, not merely until the
    // caller gives up: recovery must not copy a database a writer still holds.
    final admission = recoveryGate.admit();
    _idle?.cancel();
    final _Job job;
    try {
      final SendPort commands;
      try {
        commands = await (_startup ??= _start());
      } catch (error) {
        throw CaptureWorkerUnavailable('$error');
      }
      if (_closed || _terminalError != null) {
        throw CaptureWorkerUnavailable('${_terminalError ?? 'closed'}');
      }
      if (_pending.length >= maxPendingRequests) {
        throw StateError('SMS capture worker queue is full');
      }
      final bundle = _encode(request.shared);
      final sendBundle = _sentBundleHash != bundle.hash;
      final id = ++_sequence;
      job = _Job(admission, request.onCommitted);
      _pending[id] = job;
      commands.send([
        id,
        request.namespace,
        request.appVersion,
        request.categoryIdBySlug,
        request.session,
        bundle.hash,
        sendBundle ? bundle.json : null,
        [
          for (final group in request.groups)
            [
              group.backfill,
              [
                for (final message in group.messages)
                  [
                    message.sender,
                    message.body,
                    message.receivedAt.microsecondsSinceEpoch,
                    message.receivedAt.isUtc,
                  ],
              ],
            ],
        ],
        request.debugFault,
        request.ownerNames,
      ]);
      _sentBundleHash = bundle.hash;
    } catch (_) {
      admission.finish();
      rethrow;
    }
    return job.reply.future.timeout(
      jobTimeout,
      onTimeout: () => throw TimeoutException(
        'SMS capture worker did not answer; messages stay pending',
        jobTimeout,
      ),
    );
  }

  /// Gracefully queues shutdown behind admitted jobs.
  @override
  Future<void> close() async {
    _idle?.cancel();
    if (!_closed) {
      _closed = true;
      if (_startup == null) {
        _responses.close();
        if (!_exited.isCompleted) _exited.complete();
      } else {
        _commands?.send(null);
      }
    }
    await _exited.future;
  }

  // --------------------------------------------------------- worker isolate

  static void _run(List<Object?> arguments) {
    final replies = arguments[0] as SendPort;
    AppDatabase? database;
    FinancialStore? store;
    try {
      final keyHex = arguments[2] as String?;
      database = keyHex == null
          ? AppDatabase.openUnencryptedFileForTesting(arguments[1] as String)
          : AppDatabase.openFile(arguments[1] as String, keyHex: keyHex);
      final changed = <String>{};
      store = FinancialStore(
        database,
        onEntityChanged: (change) => changed.add(change.entity),
      );
      final owner = store;
      final state = _WorkerState(database, store, changed);
      final commands = ReceivePort();
      replies.send(commands.sendPort);
      commands.listen((command) {
        if (command == null) {
          owner.dispose();
          database!.close();
          commands.close();
          return;
        }
        final values = command as List;
        final id = values[0] as int;
        final committed = <String>{};
        try {
          state.run(values, committed);
          replies.send([id, null, committed.toList()]);
        } catch (error) {
          // Only a type / SQLite message: SMS text must not reach the logs.
          final text = error is SqliteException
              ? 'SMS capture failed: ${error.message} (${error.resultCode})'
              : 'SMS capture failed: ${error.runtimeType}';
          replies.send([id, text, committed.toList()]);
        }
      });
    } catch (_) {
      store?.dispose();
      database?.close();
      replies.send([-1, 'SMS capture storage unavailable', const <String>[]]);
    }
  }
}

class _Job {
  _Job(this.admission, this.onCommitted);
  final AccountRecoveryOperationAdmission admission;
  final void Function(Set<String>)? onCommitted;
  final reply = Completer<void>();
  void finish(Set<String> committed) {
    if (committed.isNotEmpty) {
      try {
        onCommitted?.call(committed);
      } catch (_) {
        // A disposed store has nothing left to refresh.
      }
    }
    admission.finish();
  }
}

class _Account {
  _Account(Database db, String namespace)
    : personalRules = PersonalRuleStore(
        SyncStateStore(db, namespace: namespace),
      ) {
    engine = PersonalRuleEngine(
      store: personalRules,
      instruments: InstrumentStore(db, namespace: namespace),
    );
  }
  final PersonalRuleStore personalRules;
  late final PersonalRuleEngine engine;
  int? session;
  String? bundleHash;
  ({RuleBundle bundle, String revision})? overlay;
}

class _WorkerState {
  _WorkerState(this.database, this.store, this.changed);
  final AppDatabase database;
  final FinancialStore store;
  final Set<String> changed;
  final _bundles = <String, RuleBundle>{};
  final _overlays = <String, RuleBundle>{};
  final _accounts = <String, _Account>{};
  var _schemaReady = false;

  Database get _db => database.db;

  void run(List<dynamic> v, Set<String> committed) {
    final namespace = v[1] as String;
    final appVersion = v[2] as String;
    final categoryIdBySlug = (v[3] as Map).cast<String, String>();
    final session = v[4] as int;
    final hash = v[5] as String;
    final json = v[6] as String?;
    final fault = v[8] as String?;
    final ownerNames = (v[9] as List).cast<String>();
    var injected = false;
    assert(() {
      injected = true;
      return true;
    }());
    if (injected && fault == 'exit') Isolate.exit();
    if (injected && fault == 'stall') {
      sleep(const Duration(milliseconds: 1500));
      throw StateError('stalled');
    }

    var shared = _bundles[hash];
    if (shared == null) {
      if (json == null) throw StateError('bundle_missing');
      shared = RuleBundle.fromJson(
        (jsonDecode(json) as Map).cast<String, Object?>(),
      );
      if (_bundles.length >= 3) _bundles.remove(_bundles.keys.first);
      _bundles[hash] = shared;
    }
    if (!_schemaReady) {
      SmsV2Schema.ensure(_db);
      _schemaReady = true;
    }
    final account = _accounts[namespace] ??= _Account(_db, namespace);
    if (account.session != session ||
        account.bundleHash != hash ||
        account.overlay == null) {
      // Computed once per capture session from this connection's own rows,
      // like the in-process path. A bundle object is reused while its
      // revision is unchanged so the engine's compile cache is hit.
      final fresh = ProvisionalStore(
        account.personalRules.state,
      ).overlay(shared);
      final key = '$hash|${fresh.revision}';
      if (_overlays.length >= 4) _overlays.remove(_overlays.keys.first);
      final bundle = _overlays[key] ??= fresh.bundle;
      account.overlay = (bundle: bundle, revision: fresh.revision);
      account.session = session;
      account.bundleHash = hash;
    }
    final overlay = account.overlay!;
    final groups = [
      for (final group in v[7] as List)
        CaptureGroup(
          backfill: (group as List)[0] as bool,
          messages: [
            for (final raw in group[1] as List)
              QueuedSms(
                sender: (raw as List)[0] as String,
                body: raw[1] as String,
                receivedAt: DateTime.fromMicrosecondsSinceEpoch(
                  raw[2] as int,
                  isUtc: raw[3] as bool,
                ),
              ),
          ],
        ),
    ];
    runCaptureChunk(
      financial: store,
      namespace: namespace,
      bundle: overlay.bundle,
      overlayRevision: overlay.revision,
      engine: account.engine,
      personalRules: account.personalRules,
      appVersion: appVersion,
      categoryIdBySlug: categoryIdBySlug,
      groups: groups,
      ownerNames: ownerNames,
      transact: (work) {
        changed.clear();
        _db.execute('BEGIN IMMEDIATE');
        try {
          work();
          if (injected && fault == 'throw') throw StateError('injected');
          _db.execute('COMMIT');
        } catch (_) {
          try {
            _db.execute('ROLLBACK');
          } catch (_) {
            // Already rolled back by SQLite.
          }
          changed.clear();
          rethrow;
        }
        committed.addAll(changed);
        changed.clear();
      },
    );
  }
}

/// Resolves the shared per-database worker at each chunk, so a dead or idle-
/// closed worker is replaced by a fresh one on the next use.
class PooledCaptureExecutor implements CaptureExecutor {
  PooledCaptureExecutor(this.database);
  final AppDatabase database;

  @override
  Future<void> run(CaptureChunkRequest request) =>
      SmsCaptureWorker.sharedFor(database).run(request);

  @override
  Future<void> close() async {}
}
