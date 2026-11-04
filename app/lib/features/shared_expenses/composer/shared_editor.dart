import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../data/shared_commands.dart';
import '../storage/shared_store.dart';
import 'shared_draft.dart';
export 'shared_draft.dart' show SharedSplitMode;

class SharedEditorMember {
  final String id, name;
  const SharedEditorMember(this.id, this.name);
}

/// Authenticated form state, embedded in Quick Add. No bank transaction writer.
/// Stable revision/operation identities are sealed atomically with the outbox.
class SharedEditor extends ChangeNotifier {
  final SharedExpensesStore store;
  final String accountId;
  late final String id, revisionId, operationId;
  String? contextId, ownMemberId, singlePayer;
  String contextName = '', billText = '', title = '', sharedText = '';
  late String occurredOn;
  List<SharedEditorMember> members = const [];
  final participants = <String>{};
  final payerInputs = <String, SharedPayerInput>{},
      splitInputs = <String, String>{};
  SharedSplitMode mode = SharedSplitMode.equal;
  bool partial = false,
      multiplePayers = false,
      contextVerified = false,
      _disposed = false,
      _sealing = false;
  int _version = 0;
  Map<String, Object?> privateFields = const {};
  Object? persistenceError;
  Timer? _debounce;
  Future<void> _writes = Future.value();
  Future<SharedCommand>? _seal;
  SharedCommand? _sealed;
  bool get sealed => _sealed != null;
  bool get someoneElsePaid =>
      ownMemberId != null &&
      (multiplePayers
          ? !payerInputs.containsKey(ownMemberId)
          : singlePayer != ownMemberId);
  bool get canSubmit =>
      !_sealing &&
      !sealed &&
      contextVerified &&
      persistenceError == null &&
      title.trim().isNotEmpty &&
      title.trim().length <= 200 &&
      !RegExp(r'[\x00-\x1f\x7f]').hasMatch(title) &&
      evaluation.canPropose;
  SharedEditor({
    required this.store,
    required this.accountId,
    String? draftId,
  }) {
    if (store.namespace != 'user:$accountId') {
      throw const FormatException('Wrong draft account');
    }
    id = draftId ?? const Uuid().v4();
    if (!sharedUuid(id)) throw const FormatException('Invalid draft identity');
    occurredOn = _day(DateTime.now());
    final old = store.editorDraft(id);
    if (draftId != null && old == null) {
      throw const FormatException('Draft is unavailable');
    }
    if (old == null) {
      revisionId = const Uuid().v4();
      operationId = const Uuid().v4();
    } else {
      final data = old.value;
      if (data['schemaVersion'] != 1 ||
          !sharedUuid(data['revisionId']) ||
          !sharedUuid(data['operationId'])) {
        throw const FormatException('Incompatible draft');
      }
      revisionId = data['revisionId'] as String;
      operationId = data['operationId'] as String;
      _version = old.version;
      contextId = old.contextId;
      contextName = data['contextName'] as String;
      billText = data['billText'] as String;
      sharedText = data['sharedText'] as String;
      title = data['title'] as String;
      occurredOn = data['occurredOn'] as String;
      ownMemberId = data['ownMemberId'] as String?;
      singlePayer = data['singlePayer'] as String?;
      partial = data['partial'] as bool;
      multiplePayers = data['multiplePayers'] as bool;
      mode = SharedSplitMode.values.byName(data['mode'] as String);
      members = [
        for (final raw in data['members'] as List)
          SharedEditorMember(
            (raw as Map)['id'] as String,
            raw['name'] as String,
          ),
      ];
      participants.addAll((data['participants'] as List).cast<String>());
      splitInputs.addAll(Map<String, String>.from(data['splitInputs'] as Map));
      for (final entry in (data['payers'] as Map).entries) {
        final input = entry.value as Map;
        payerInputs[entry.key as String] = SharedPayerInput(
          fullText: input['fullText'] as String,
          sharedText: input['sharedText'] as String,
        );
      }
      privateFields = Map.unmodifiable(
        Map<String, Object?>.from(data['privateFields'] as Map),
      );
      if (old.operationId != null) {
        _sealed = store.operation(old.operationId!)?.command;
        if (_sealed == null) {
          throw const FormatException('Missing submitted draft');
        }
      }
    }
  }
  static String _day(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  void _changed() {
    if (_disposed) return;
    notifyListeners();
    _debounce?.cancel();
    if (!sealed && !_sealing) {
      _debounce = Timer(const Duration(milliseconds: 250), () {
        unawaited(
          persist().catchError((Object e) {
            persistenceError = e;
            if (!_disposed) notifyListeners();
          }),
        );
      });
    }
  }

  bool get _editable => !sealed && !_sealing && !_disposed;
  void selectContext(
    String context,
    String name,
    List<SharedEditorMember> roster,
    String own,
  ) {
    if (!_editable) return;
    if (!sharedUuid(context) ||
        roster.isEmpty ||
        roster.length > 200 ||
        roster.any((m) => !sharedUuid(m.id)) ||
        roster.map((m) => m.id).toSet().length != roster.length ||
        !roster.any((m) => m.id == own)) {
      throw const FormatException('Invalid group members');
    }
    final same = context == contextId;
    final incoming = [...roster]..sort((a, b) => a.id.compareTo(b.id));
    if (same) {
      // Existing remainder order is stable; new members append, never reorder.
      final oldIds = members.map((m) => m.id).toList();
      members = List.unmodifiable([
        for (final member in members)
          if (incoming.any((m) => m.id == member.id))
            incoming.firstWhere((m) => m.id == member.id),
        for (final member in incoming)
          if (!oldIds.contains(member.id)) member,
      ]);
    } else {
      members = List.unmodifiable(incoming);
      participants.clear();
      participants.addAll(roster.take(50).map((m) => m.id));
      payerInputs.clear();
      splitInputs.clear();
      singlePayer = own;
      multiplePayers = false;
    }
    contextId = context;
    contextName = name;
    ownMemberId = own;
    contextVerified = true;
    _changed();
  }

  void setBill(String text) {
    if (_editable && billText != text) {
      billText = text;
      _changed();
    }
  }

  void setTitle(String text) {
    if (_editable && title != text) {
      title = text;
      _changed();
    }
  }

  void setDate(DateTime date) {
    if (_editable && occurredOn != _day(date)) {
      occurredOn = _day(date);
      _changed();
    }
  }

  void setPrivateFields(Map<String, Object?> fields) {
    if (_editable &&
        sharedCanonicalJson(privateFields) != sharedCanonicalJson(fields)) {
      privateFields = Map.unmodifiable(
        jsonDecode(sharedCanonicalJson(fields)) as Map<String, dynamic>,
      );
      _changed();
    }
  }

  void setShared(String text) {
    if (_editable) {
      partial = true;
      sharedText = text;
      _changed();
    }
  }

  void setPartial(bool value) {
    if (_editable) {
      partial = value;
      if (value && sharedText.isEmpty) sharedText = billText;
      _changed();
    }
  }

  void choosePayer(String id) {
    if (_editable && members.any((m) => m.id == id)) {
      singlePayer = id;
      multiplePayers = false;
      _changed();
    }
  }

  void setMultiplePayers(bool value) {
    if (_editable) {
      multiplePayers = value;
      if (value && payerInputs.isEmpty && singlePayer != null) {
        payerInputs[singlePayer!] = SharedPayerInput(
          fullText: billText,
          sharedText: partial ? sharedText : billText,
        );
      }
      _changed();
    }
  }

  void setPayer(String id, String full, String shared) {
    if (_editable && members.any((m) => m.id == id)) {
      payerInputs[id] = SharedPayerInput(fullText: full, sharedText: shared);
      _changed();
    }
  }

  void removePayer(String id) {
    if (_editable) {
      payerInputs.remove(id);
      _changed();
    }
  }

  bool get hasUnavailableMembers {
    final ids = members.map((m) => m.id).toSet();
    return participants.any((id) => !ids.contains(id)) ||
        payerInputs.keys.any((id) => !ids.contains(id)) ||
        singlePayer != null && !ids.contains(singlePayer);
  }

  /// Membership changes require an explicit correction, never a silent re-split.
  void removeUnavailableMembers() {
    if (!_editable) return;
    final ids = members.map((m) => m.id).toSet();
    participants.removeWhere((id) => !ids.contains(id));
    payerInputs.removeWhere((id, _) => !ids.contains(id));
    splitInputs.removeWhere((id, _) => !ids.contains(id));
    if (!ids.contains(singlePayer)) singlePayer = null;
    _changed();
  }

  void toggleParticipant(String id, bool selected) {
    if (_editable && members.any((m) => m.id == id)) {
      selected ? participants.add(id) : participants.remove(id);
      _changed();
    }
  }

  void setMode(SharedSplitMode value) {
    if (_editable) {
      mode = value;
      splitInputs.clear();
      _changed();
    }
  }

  void setSplit(String id, String text) {
    if (_editable) {
      splitInputs[id] = text;
      _changed();
    }
  }

  SharedDraftEvaluation get evaluation {
    final paid = multiplePayers
        ? Map<String, SharedPayerInput>.of(payerInputs)
        : {
            ?singlePayer: SharedPayerInput(
                fullText: billText,
                sharedText: partial ? sharedText : billText,
              ),
          };
    final own = paid[ownMemberId];
    return SharedExpenseDraft(
      ownMemberId: ownMemberId ?? '',
      ownAccountId: accountId,
      memberOrder: members.map((m) => m.id).toList(),
      billText: billText,
      sharedText: partial ? sharedText : billText,
      payers: paid,
      participants: participants.toList(),
      mode: mode,
      splitInputs: splitInputs,
      entryKind: own == null
          ? SharedEntryKind.someoneElsePaid
          : SharedEntryKind.newOwnPayment,
    ).evaluate();
  }

  Map<String, Object?> _json() => {
    'schemaVersion': 1,
    'revisionId': revisionId,
    'operationId': operationId,
    'contextName': contextName,
    'billText': billText,
    'title': title,
    'sharedText': sharedText,
    'occurredOn': occurredOn,
    'ownMemberId': ownMemberId,
    'singlePayer': singlePayer,
    'partial': partial,
    'multiplePayers': multiplePayers,
    'mode': mode.name,
    'members': [
      for (final m in members) {'id': m.id, 'name': m.name},
    ],
    'participants': [
      ...members.where((m) => participants.contains(m.id)).map((m) => m.id),
      ...(participants.where((id) => !members.any((m) => m.id == id)).toList()
        ..sort()),
    ],
    'splitInputs': Map.of(splitInputs),
    'payers': {
      for (final e in payerInputs.entries)
        e.key: {'fullText': e.value.fullText, 'sharedText': e.value.sharedText},
    },
    'privateFields': privateFields,
  };
  Future<void> persist() {
    _debounce?.cancel();
    if (sealed) return Future.value();
    final value = _json(), scope = contextId;
    final next = _writes.then((_) async {
      if (persistenceError != null) throw persistenceError!;
      final saved = await store.saveEditorDraft(
        id,
        contextId: scope,
        expectedVersion: _version,
        value: value,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );
      _version = saved.version;
    });
    _writes = next.catchError((Object e) {
      persistenceError = e;
    });
    return next;
  }

  Future<SharedCommand> seal() {
    if (_sealed != null) return Future.value(_sealed);
    if (_seal != null) return _seal!;
    if (persistenceError != null) return Future.error(persistenceError!);
    if (!canSubmit) {
      return Future.error(
        StateError(
          'Complete and validate the shared expense before submitting.',
        ),
      );
    }
    _sealing = true;
    _debounce?.cancel();
    final future = () async {
      await persist();
      final preview = evaluation.preview!;
      final command = SharedCommand(
        operationId: operationId,
        kind: 'expense.propose',
        payload: {
          'contextId': contextId,
          'expenseId': id,
          'revisionId': revisionId,
          'expectedHeadRevisionId': null,
          'title': title.trim(),
          'occurredOn': occurredOn,
          'snapshot': preview.financialSnapshot,
          'bill': preview.billMetadata,
          'sources': <Object?>[],
          'void': false,
        },
      );
      await store.sealEditorDraft(
        id,
        expectedVersion: _version,
        command: command,
        provisional: {
          'title': title.trim(),
          'bill': preview.billMetadata,
          'snapshot': preview.financialSnapshot,
          'privateFields': privateFields,
        },
        createdAt: DateTime.now().millisecondsSinceEpoch,
      );
      _sealed = command;
      return command;
    }();
    _seal = future;
    return future.whenComplete(() {
      _sealing = false;
      if (_sealed == null) _seal = null;
      if (!_disposed) notifyListeners();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _disposed = true;
    super.dispose();
  }
}
