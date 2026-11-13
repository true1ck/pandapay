import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:pandapay_domain/pandapay_domain.dart' show Confidence;
import 'package:pandapay_domain/shared_expenses.dart';
import '../../../app/design/app_theme.dart';
import '../runtime/shared_runtime.dart';
import 'shared_components.dart';
import 'shared_context_guard.dart';

/// Bounded, authorized payment reports. A queued response is not confirmation.
String _methodLabel(String method) => switch (method) {
  'upi' => 'UPI',
  'cash' => 'Cash',
  'bank' => 'Bank transfer',
  _ => 'Payment',
};

/// Readable local date; never shows a raw ISO string.
String _dateLabel(Object? raw) {
  final parsed = raw is String ? DateTime.tryParse(raw) : null;
  return parsed == null ? '' : DateFormat.yMMMd().format(parsed);
}

class SharedSettlementsSheet extends StatefulWidget {
  final SharedExpensesRuntime runtime;
  final String contextId, groupName;
  const SharedSettlementsSheet({
    super.key,
    required this.runtime,
    required this.contextId,
    required this.groupName,
  });
  static Future<void> show(
    BuildContext context, {
    required SharedExpensesRuntime runtime,
    required String contextId,
    required String groupName,
  }) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: BambooInk.paper,
    builder: (_) => SharedSettlementsSheet(
      runtime: runtime,
      contextId: contextId,
      groupName: groupName,
    ),
  );
  @override
  State<SharedSettlementsSheet> createState() => _SharedSettlementsSheetState();
}

class _SharedSettlementsSheetState extends State<SharedSettlementsSheet> {
  final _history = <String?>[null];
  late Future<({SharedRoster roster, Map<String, Object?> page})> _data;
  String? _responding, _notice;
  bool get _authorized =>
      widget.runtime.isCurrent() &&
      !widget.runtime.store.isContextRevoked(widget.contextId);
  @override
  void initState() {
    super.initState();
    _data = _load();
  }

  Future<({SharedRoster roster, Map<String, Object?> page})> _load() async {
    final roster = await widget.runtime.contextRoster(widget.contextId);
    final page = await widget.runtime.settlements(
      widget.contextId,
      after: _history.last,
    );
    if (!_authorized) throw const SharedRuntimeUnavailable();
    return (roster: roster, page: page);
  }

  Future<void> _respond(String id, String decision) async {
    if (_responding != null ||
        !_authorized ||
        !widget.runtime.canQueueSettlements) {
      return;
    }
    setState(() {
      _responding = id;
      _notice = null;
    });
    final op = widget.runtime.settlementResponseId(widget.contextId, id);
    try {
      await widget.runtime.respondToSettlement(widget.contextId, id, decision);
    } catch (_) {
      if (mounted) {
        _notice =
            'Could not save your response yet. It is kept on this phone. Try again.';
      }
    }
    if (mounted && _authorized) {
      setState(() {
        _notice = widget.runtime.operationStatus(op);
        _responding = null;
        _data = _load();
      });
    }
  }

  Widget _row(Map row, SharedRoster roster) {
    final id = row['settlementId'] as String,
        status = row['status'] as String? ?? 'unknown';
    final names = {
      for (final member in roster.members)
        member.id: member.id == roster.ownMemberId ? 'You' : member.name,
    };
    final own = roster.ownMemberId;
    final pending = widget.runtime.store.operation(
      widget.runtime.settlementResponseId(widget.contextId, id),
    );
    final canRespond =
        status == 'pending' &&
        row['receiverMemberId'] == own &&
        widget.runtime.canQueueSettlements &&
        pending == null &&
        _responding == null;
    return SharedPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${names[row['payerMemberId']] ?? 'Former member'} → ${names[row['receiverMemberId']] ?? 'Former member'}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: BambooFonts.heading(15),
          ),
          SharedMoneyLine(
            'Payment amount',
            sharedMoneyFromMinor(row['amountMinor']),
            confidence: Confidence.confirmed,
          ),
          Text(
            '${_methodLabel(row['method'] as String)} · ${_dateLabel(row['paidOn'])}',
            style: BambooFonts.ui(12, color: BambooInk.ink700),
          ),
          Text(switch (status) {
            'confirmed' => 'Confirmed by receiver',
            'rejected' => 'Payment report rejected',
            'reversed' => 'Payment confirmation reversed',
            'pending' => 'Reported · awaiting receiver confirmation',
            _ => 'Refresh to check status',
          }, style: BambooFonts.ui(13, weight: FontWeight.w600)),
          if (pending != null && status == 'pending')
            SharedNotice(
              widget.runtime.operationStatus(pending.command.operationId),
            ),
          if (canRespond) ...[
            const SharedNotice(
              'Confirm only if you received this amount. A report alone does not prove payment.',
            ),
            SharedAction(
              label: 'Confirm received',
              primary: true,
              onTap: () => _respond(id, 'confirm'),
            ),
            SharedTextAction(
              label: 'Reject report',
              onTap: () => _respond(id, 'reject'),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => SharedContextGuard(
    runtime: widget.runtime,
    contextId: widget.contextId,
    builder: (context) {
      if (!_authorized) {
        return const SafeArea(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text('This shared expense is no longer available.'),
          ),
        );
      }
      return SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .8,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Payment history',
                        style: BambooFonts.heading(20),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Refresh',
                      onPressed: _responding != null
                          ? null
                          : () async {
                              await widget.runtime.flushEditor();
                              if (mounted && _authorized) {
                                setState(() {
                                  _data = _load();
                                });
                              }
                            },
                      icon: const Icon(Icons.refresh_rounded),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
              if (_notice != null) SharedNotice(_notice!),
              Expanded(
                child:
                    FutureBuilder<
                      ({SharedRoster roster, Map<String, Object?> page})
                    >(
                      future: _data,
                      builder: (context, snapshot) {
                        if (snapshot.hasError) {
                          return Center(
                            child: TextButton(
                              onPressed: () => setState(() {
                                _data = _load();
                              }),
                              child: const Text('Try again'),
                            ),
                          );
                        }
                        if (!snapshot.hasData ||
                            snapshot.connectionState ==
                                ConnectionState.waiting) {
                          return const Center(
                            child: CircularProgressIndicator(
                              color: BambooInk.slate,
                            ),
                          );
                        }
                        final data = snapshot.data!,
                            rows = data.page['items'] as List;
                        return ListView(
                          padding: const EdgeInsets.all(16),
                          children: [
                            if (widget.runtime.offline)
                              const SharedNotice(
                                'Offline · saved payment reports shown',
                              ),
                            if (rows.isEmpty)
                              const SharedNotice(
                                'No payment reports on this page.',
                              ),
                            for (final raw in rows)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: _row(raw as Map, data.roster),
                              ),
                            if (_history.length > 1)
                              TextButton(
                                onPressed: () => setState(() {
                                  _history.removeLast();
                                  _data = _load();
                                }),
                                child: const Text('Previous page'),
                              ),
                            if (data.page['hasMore'] == true)
                              TextButton(
                                onPressed: () => setState(() {
                                  _history.add(
                                    data.page['nextCursor'] as String,
                                  );
                                  _data = _load();
                                }),
                                child: const Text('Next page'),
                              ),
                          ],
                        );
                      },
                    ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
