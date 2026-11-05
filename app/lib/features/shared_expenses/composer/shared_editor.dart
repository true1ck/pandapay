import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:pandapay_domain/shared_expenses.dart';
import '../data/shared_commands.dart';
import '../storage/shared_store.dart';
import 'shared_draft.dart';
export 'shared_draft.dart' show SharedSplitMode;

class SharedEditorMember {
  final String id, name;
  final String state, role;
  final String? profileId;
  const SharedEditorMember(
    this.id,
    this.name, {
    this.state = 'active',
    this.role = 'member',
    this.profileId,
  });
  bool get canSettle => state == 'active' && profileId != null;
}

/// Authenticated form state, embedded in Quick Add. No bank transaction writer.
/// Unsubmitted input stays in memory. Submit atomically seals the outbox and
/// optional receipt; retries preserve the same revision and operation identity.
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
  Map<String, Object?> privateFields = const {};
  SharedExpenseSourceReference? linkedSource;
  Money? lockedOwnPaid;
  SharedSubmissionReceipt? receipt;
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
      title.trim().isNotEmpty &&
      title.trim().length <= 200 &&
      !RegExp(r'[\x00-\x1f\x7f]').hasMatch(title) &&
      evaluation.canPropose;
  SharedEditor({
    required this.store,
    required this.accountId,
    String? expenseId,
  }) {
    if (store.namespace != 'user:$accountId') {
      throw const FormatException('Wrong expense account');
    }
    id = expenseId ?? const Uuid().v4();
    if (!sharedUuid(id))
      throw const FormatException('Invalid expense identity');
    revisionId = const Uuid().v4();
    operationId = const Uuid().v4();
    occurredOn = _day(DateTime.now());
  }
  static String _day(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  void setReceipt(SharedSubmissionReceipt value) {
    if (!_editable) return;
    receipt = value;
    _changed();
  }

  bool get _editable => !sealed && !_sealing && !_disposed;
  void attachSourceIntent(SharedExpenseSourceReference source, Money paid) {
    if (!_editable) return;
    if (source.ownerAccountId != accountId ||
        paid.paise <= 0 ||
        linkedSource != null &&
            sharedCanonicalJson(linkedSource!.toJson()) !=
                sharedCanonicalJson(source.toJson())) {
      throw const FormatException('Invalid source intent');
    }
    linkedSource = source;
    lockedOwnPaid = paid;
    _changed();
  }

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
      source: linkedSource,
      lockedOwnPaid: lockedOwnPaid,
      entryKind: linkedSource != null
          ? SharedEntryKind.existingOwnPayment
          : own == null
          ? SharedEntryKind.someoneElsePaid
          : SharedEntryKind.newOwnPayment,
    ).evaluate();
  }

  Future<SharedCommand> seal() {
    if (_sealed != null) return Future.value(_sealed);
    if (_seal != null) return _seal!;
    if (!canSubmit) {
      return Future.error(
        StateError(
          'Complete and validate the shared expense before submitting.',
        ),
      );
    }
    _sealing = true;
    final future = () async {
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
      await store.enqueueExpenseSubmission(
        command,
        receipt: receipt,
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
    _disposed = true;
    super.dispose();
  }
}
