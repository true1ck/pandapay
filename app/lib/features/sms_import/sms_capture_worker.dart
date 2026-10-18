import 'dart:async';
import 'dart:isolate';
import '../../data/local/app_database.dart';
import '../../data/local/financial_store.dart';
import '../../data/local/sms_import_store.dart';
import 'sms_background_queue.dart';

/// A serial database owner for bulk inbox capture. Only plain values cross
/// isolates; UI providers retain their own connection and receive commit events.
class SmsCaptureWorker {
  final String databasePath;
  final _responses = ReceivePort();
  final _pending = <int, Completer<List<String>>>{};
  Completer<SendPort>? _ready;
  Future<SendPort>? _startup;
  Isolate? _isolate;
  SendPort? _commands;
  var _sequence = 0;
  var _disposed = false;

  SmsCaptureWorker(this.databasePath) {
    _responses.listen((message) {
      if (message is SendPort) {
        _commands = message;
        if (!(_ready?.isCompleted ?? true)) _ready!.complete(message);
      } else if (message is List && message.first is int) {
        final id = message[0] as int;
        final error = message[2] as String?;
        if (id == -1) {
          _fail(StateError(error ?? 'SMS capture worker unavailable'));
        } else {
          final reply = _pending.remove(id);
          if (error != null) {
            reply?.completeError(StateError(error));
          } else {
            reply?.complete((message[1] as List).cast<String>());
          }
        }
      } else {
        _fail(StateError('SMS capture worker stopped unexpectedly'));
      }
    });
  }

  void _fail(Object error) {
    if (!(_ready?.isCompleted ?? true)) _ready!.completeError(error);
    for (final reply in _pending.values) {
      reply.completeError(error);
    }
    _pending.clear();
    _startup = null;
  }

  Future<SendPort> _start() {
    final ready = _ready = Completer<SendPort>();
    unawaited(
      Isolate.spawn(
        _run,
        [_responses.sendPort, databasePath],
        onError: _responses.sendPort,
        debugName: 'pandapay-sms-capture',
      ).then<void>(
        (isolate) {
          _isolate = isolate;
          if (_disposed) {
            isolate.kill();
            if (!ready.isCompleted) {
              ready.completeError(StateError('SMS capture disposed'));
            }
          }
        },
        onError: (Object error, StackTrace stack) {
          if (!ready.isCompleted) ready.completeError(error, stack);
        },
      ),
    );
    return ready.future;
  }

  Future<List<String>> capture(
    String namespace,
    List<QueuedSms> messages,
  ) async {
    if (_disposed) throw StateError('SMS capture disposed');
    late SendPort commands;
    try {
      commands = await (_startup ??= _start());
    } catch (_) {
      _startup = null;
      rethrow;
    }
    if (_disposed) throw StateError('SMS capture disposed');
    final id = ++_sequence;
    final reply = Completer<List<String>>();
    _pending[id] = reply;
    commands.send([
      id,
      namespace,
      [
        for (final message in messages)
          [
            message.sender,
            message.body,
            message.receivedAt.millisecondsSinceEpoch,
          ],
      ],
    ]);
    try {
      return await reply.future.timeout(const Duration(seconds: 30));
    } finally {
      _pending.remove(id);
    }
  }

  void dispose() {
    _disposed = true;
    _fail(StateError('SMS capture disposed'));
    if (_commands != null) {
      _commands!.send(null);
    } else {
      _isolate?.kill(priority: Isolate.beforeNextEvent);
    }
    _responses.close();
  }

  static void _run(List<Object?> arguments) {
    final replies = arguments[0] as SendPort;
    try {
      final database = AppDatabase.openFile(arguments[1] as String);
      var changed = <String>{};
      final store = FinancialStore(
        database,
        onEntityChanged: (change) => changed.add(change.entity),
      );
      final commands = ReceivePort();
      replies.send(commands.sendPort);
      commands.listen((command) {
        if (command == null) {
          store.dispose();
          database.close();
          commands.close();
          return;
        }
        final values = command as List;
        final id = values[0] as int;
        changed = <String>{};
        try {
          final namespace = values[1] as String;
          final messages = [
            for (final row in values[2] as List)
              QueuedSms(
                sender: row[0] as String,
                body: row[1] as String,
                receivedAt: DateTime.fromMillisecondsSinceEpoch(row[2] as int),
              ),
          ];
          SmsImportStore(store).captureBatch(namespace, messages);
          replies.send([id, changed.toList(), null]);
        } catch (error) {
          // Never return raw message bodies in diagnostics.
          replies.send([
            id,
            <String>[],
            'Local SMS capture failed (${error.runtimeType})',
          ]);
        }
      });
    } catch (error) {
      replies.send([
        -1,
        <String>[],
        'Local SMS storage unavailable (${error.runtimeType})',
      ]);
    }
  }
}
