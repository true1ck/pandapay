import 'package:flutter/material.dart';
import '../../../app/design/app_theme.dart';
import '../data/shared_directory.dart';
import '../data/shared_phone_display.dart';
import '../data/shared_transport.dart';
import '../runtime/shared_join_batch.dart';
import '../runtime/shared_runtime.dart';
import 'shared_claimant_phone.dart';
import 'shared_join_requests_summary.dart';

/// "5 minutes ago", "2 days ago".
String sharedAgo(Duration d) {
  if (d.inMinutes < 1) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 24) return '${d.inHours} h ago';
  final days = d.inDays;
  return days == 1 ? '1 day ago' : '$days days ago';
}

String _in(Duration d) {
  if (d.inHours < 1) return 'less than an hour';
  if (d.inHours < 24) return '${d.inHours} h';
  final days = d.inDays;
  return days == 1 ? '1 day' : '$days days';
}

/// Everyone who asked to join the owner's splits, grouped by split. Approve or
/// decline one at a time, or select several in one split and approve them
/// together. The whole page is one scrollable.
class SharedJoinRequestsPage extends StatefulWidget {
  final SharedExpensesRuntime runtime;
  final VoidCallback? onShareGroupLink;
  final DateTime Function()? now;
  const SharedJoinRequestsPage({
    super.key,
    required this.runtime,
    this.onShareGroupLink,
    this.now,
  });
  @override
  State<SharedJoinRequestsPage> createState() => _PageState();
}

class _PageState extends State<SharedJoinRequestsPage> {
  List<SharedJoinRequest>? _requests;
  bool _loading = false, _offline = false, _working = false;
  bool _failedLoad = false;
  final _collapsed = <String>{};

  /// Stable per request so a retried call replays instead of answering 409.
  final _approveOps = <String, String>{};
  final _declineOps = <String, String>{};
  final _reasons = <String, String>{};

  String? _selectContext;
  final _selected = <String>{};
  String? _progress, _summary;
  List<SharedJoinRequest> _retry = const [];
  bool _retryApprove = true;

  DateTime _now() => (widget.now ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    _requests = widget.runtime.cachedJoinRequests;
    _offline = widget.runtime.offline;
    _refresh();
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    setState(() {
      _failedLoad = false;
      _loading = _requests == null;
    });
    try {
      final items = await widget.runtime.joinRequests();
      if (!mounted) return;
      setState(() {
        _requests = items;
        _offline = false;
        _loading = false;
        final ids = {for (final r in items) r.invitationId};
        _selected.removeWhere((id) => !ids.contains(id));
        if (_selected.isEmpty && _selectContext != null) _selectContext = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _offline =
            error is SharedTransportException &&
            error.code == 'network_unavailable';
        _failedLoad = _requests == null;
      });
    }
  }

  bool _expired(SharedJoinRequest r) =>
      r.expiresAt != null && !r.expiresAt!.isAfter(_now());

  Map<String, List<SharedJoinRequest>> _grouped() {
    final map = <String, List<SharedJoinRequest>>{};
    for (final r in _requests ?? const <SharedJoinRequest>[]) {
      (map[r.contextId] ??= []).add(r);
    }
    DateTime stamp(SharedJoinRequest r) =>
        r.createdAt ?? DateTime.fromMillisecondsSinceEpoch(1 << 50);
    for (final list in map.values) {
      list.sort((a, b) => stamp(a).compareTo(stamp(b)));
    }
    final keys = map.keys.toList()
      ..sort((a, b) => stamp(map[a]!.first).compareTo(stamp(map[b]!.first)));
    return {for (final k in keys) k: map[k]!};
  }

  // ---- doing things -------------------------------------------------------

  Future<void> _run(
    List<SharedJoinRequest> items, {
    required bool approve,
  }) async {
    if (_working || items.isEmpty) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() {
      _working = true;
      _summary = null;
      _progress = '${approve ? 'Approving' : 'Declining'} 1 of ${items.length}';
      for (final r in items) {
        _reasons.remove(r.invitationId);
      }
    });
    final outcome = await sharedRunJoinBatch(
      items: items,
      operationIds: approve ? _approveOps : _declineOps,
      respond: (id, op) => widget.runtime.respondToJoinRequest(
        id,
        approve: approve,
        operationId: op,
        refreshAfter: false,
      ),
      onProgress: (done, total) {
        if (mounted && done < total) {
          setState(
            () => _progress =
                '${approve ? 'Approving' : 'Declining'} ${done + 1} of $total',
          );
        }
      },
    );
    if (!mounted) return;
    final gone = {...outcome.done, ...outcome.expired};
    setState(() {
      _requests = [
        for (final r in _requests ?? const <SharedJoinRequest>[])
          if (!gone.contains(r.invitationId)) r,
      ];
      _selected.removeAll(gone);
      if (_selected.isEmpty) _selectContext = null;
      _reasons.addAll(outcome.failed);
      for (final id in outcome.expired) {
        _reasons.remove(id);
      }
      final retry = [
        for (final r in items)
          if (outcome.failed.containsKey(r.invitationId) ||
              outcome.notRun.contains(r.invitationId))
            r,
      ];
      _retry = retry;
      _retryApprove = approve;
      _progress = null;
      _working = false;
      final verb = approve ? 'approved' : 'declined';
      final parts = <String>[
        if (outcome.succeeded > 0)
          items.length == 1 && outcome.alreadyIn.isNotEmpty
              ? 'Already in the group.'
              : '${outcome.succeeded} $verb.',
        if (outcome.expired.isNotEmpty)
          '${outcome.expired.length} expired or withdrawn.',
        if (outcome.failed.isNotEmpty)
          '${outcome.failed.length} could not be $verb.',
        if (outcome.notRun.isNotEmpty)
          'Connection lost. ${outcome.notRun.length} not sent.',
      ];
      _summary = parts.isEmpty ? null : parts.join(' ');
    });
    if (items.length == 1 && outcome.allDone && !approve) {
      messenger?.showSnackBar(
        SnackBar(content: Text('${items.single.label ?? 'Request'} declined')),
      );
    } else if (items.length == 1 && outcome.expired.isNotEmpty) {
      messenger?.showSnackBar(
        const SnackBar(content: Text('That request expired or was withdrawn.')),
      );
    }
    if (outcome.succeeded > 0 || outcome.expired.isNotEmpty) {
      // One refresh for the whole run, then re-read the list.
      await widget.runtime.refresh();
      if (mounted) await _refresh();
    }
  }

  Future<bool> _confirm({
    required String title,
    required Widget body,
    required String action,
  }) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(child: body),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              key: const Key('confirm-action'),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _approveSelected(
    String contextId,
    List<SharedJoinRequest> inGroup,
  ) async {
    final chosen = [
      for (final r in inGroup)
        if (_selected.contains(r.invitationId)) r,
    ];
    if (chosen.isEmpty) return;
    final name = sharedRequestSplitName(chosen.first);
    final n = chosen.length;
    final concerns = [
      for (final r in chosen)
        if (sharedJoinBulkConcern(r) != null) r,
    ];
    final sharedCount = n - concerns.length;
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('Approving lets them see the split’s people and expenses.'),
        const SizedBox(height: 8),
        Text(
          sharedCount > 0
              ? '$sharedCount shared a number${concerns.isEmpty ? '' : ', ${concerns.length} to check'}.'
              : '${concerns.length} to check.',
        ),
        if (concerns.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            '${concerns.length} ${concerns.length == 1 ? 'has' : 'have'} no matching number (different number, did not share, or not verified):',
            key: const Key('bulk-concern'),
          ),
          for (final r in concerns.take(5))
            Text(
              '• ${r.label ?? 'Someone'}: ${sharedJoinBulkConcern(r)}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
        ],
        const SizedBox(height: 8),
        for (final r in chosen.take(5))
          Directionality(
            textDirection: TextDirection.ltr,
            child: Text(
              '${r.label ?? 'Someone'}  ${r.claimantPhone?.mask ?? ''}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        if (n > 5) Text('and ${n - 5} more'),
      ],
    );
    final ok = await _confirm(
      title: 'Approve $n ${n == 1 ? 'person' : 'people'} to $name?',
      body: body,
      action: 'Approve $n',
    );
    if (!ok || !mounted) return;
    await _run(chosen, approve: true);
  }

  Future<void> _declineAll(List<SharedJoinRequest> inGroup) async {
    final live = [
      for (final r in inGroup)
        if (!_expired(r)) r,
    ];
    if (live.isEmpty) return;
    final name = sharedRequestSplitName(live.first);
    final ok = await _confirm(
      title: 'Decline all ${live.length} requests to $name?',
      body: const Text('None of them will be added.'),
      action: 'Decline all',
    );
    if (!ok || !mounted) return;
    await _run(live, approve: false);
  }

  Future<void> _enterSelect(
    String contextId, {
    SharedJoinRequest? first,
  }) async {
    if (_selectContext != null &&
        _selectContext != contextId &&
        _selected.isNotEmpty) {
      final ok = await _confirm(
        title: 'Switch split?',
        body: const Text('Your current selection will be cleared.'),
        action: 'Clear and switch',
      );
      if (!ok || !mounted) return;
    }
    setState(() {
      if (_selectContext != contextId) _selected.clear();
      _selectContext = contextId;
      if (first != null && sharedJoinBulkAllowed(first) && !_expired(first)) {
        _selected.add(first.invitationId);
      }
    });
  }

  void _toggle(SharedJoinRequest r) {
    if (!sharedJoinBulkAllowed(r) || _expired(r)) return;
    setState(() {
      if (_selected.contains(r.invitationId)) {
        _selected.remove(r.invitationId);
      } else if (_selected.length >= sharedJoinBatchMax) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(
            content: Text('You can approve up to 25 people at a time.'),
          ),
        );
      } else {
        _selected.add(r.invitationId);
      }
    });
  }

  void _selectAll(List<SharedJoinRequest> inGroup) {
    setState(() {
      _selected
        ..clear()
        ..addAll(
          inGroup
              .where((r) => sharedJoinSelectAllEligible(r) && !_expired(r))
              .take(sharedJoinBatchMax)
              .map((r) => r.invitationId),
        );
    });
  }

  void _cancelSelect() => setState(() {
    _selected.clear();
    _selectContext = null;
  });

  // ---- building -----------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final groups = _grouped();
    final all = _requests ?? const <SharedJoinRequest>[];
    final slivers = <Widget>[];
    void add(Widget w) => slivers.add(w);

    if (_offline) {
      add(
        _note(
          const Key('offline-banner'),
          Icons.cloud_off_outlined,
          'You are offline. Showing the last list; approving and declining are paused.',
          scheme,
        ),
      );
    }
    if (_progress != null) {
      add(
        _note(
          const Key('batch-progress'),
          Icons.hourglass_empty_rounded,
          _progress!,
          scheme,
        ),
      );
    }
    if (_summary != null) {
      add(
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Container(
            key: const Key('batch-summary'),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _summary!,
                    style: BambooFonts.ui(13, color: scheme.onSurface),
                  ),
                ),
                if (_retry.isNotEmpty)
                  TextButton(
                    key: const Key('retry-batch'),
                    onPressed: _working || _offline
                        ? null
                        : () => _run(_retry, approve: _retryApprove),
                    child: const Text('Retry'),
                  ),
              ],
            ),
          ),
        ),
      );
    }
    if (all.isNotEmpty) {
      add(
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(
            'Only approve people you recognise. Approving lets them see the '
            'split’s people and expenses; they still cannot approve '
            'expenses for anyone else.',
            key: const Key('requests-warning'),
            style: BambooFonts.ui(12.5, color: scheme.onSurfaceVariant),
          ),
        ),
      );
    }

    if (_loading) {
      for (var i = 0; i < 3; i++) {
        add(_skeleton(scheme));
      }
    } else if (_failedLoad) {
      add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 32),
          child: Column(
            children: [
              Text(
                _offline
                    ? 'No connection. Check it and try again.'
                    : 'Could not load the requests.',
                textAlign: TextAlign.center,
                style: BambooFonts.ui(14, color: scheme.onSurface),
              ),
              TextButton(
                key: const Key('retry-load'),
                onPressed: _refresh,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    } else if (all.isEmpty) {
      add(
        Padding(
          key: const Key('empty-state'),
          padding: const EdgeInsets.symmetric(vertical: 40),
          child: Column(
            children: [
              Icon(Icons.group_outlined, size: 40, color: scheme.outline),
              const SizedBox(height: 12),
              Text(
                'No one is waiting to join.',
                style: BambooFonts.heading(16),
              ),
              const SizedBox(height: 4),
              Text(
                'Share a group link and people can ask to join.',
                textAlign: TextAlign.center,
                style: BambooFonts.ui(13, color: scheme.onSurfaceVariant),
              ),
              TextButton(
                key: const Key('share-group-link'),
                onPressed: widget.onShareGroupLink,
                child: const Text('Share group link'),
              ),
            ],
          ),
        ),
      );
    } else {
      for (final entry in groups.entries) {
        add(_groupHeader(entry.key, entry.value, scheme));
        if (_collapsed.contains(entry.key)) continue;
        final compare = _compare(entry.value, scheme);
        if (compare != null) add(compare);
        for (final r in entry.value) {
          add(_row(r, entry.value, scheme));
        }
      }
    }

    final selecting = _selectContext != null;
    final inSelected = selecting ? groups[_selectContext] : null;
    return Scaffold(
      appBar: AppBar(
        title: Text('Join requests', style: BambooFonts.heading(17)),
        actions: [
          if (selecting)
            TextButton(
              key: const Key('cancel-select'),
              onPressed: _cancelSelect,
              child: const Text('Cancel'),
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: CustomScrollView(
          key: const Key('join-requests-page'),
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              sliver: SliverList(delegate: SliverChildListDelegate(slivers)),
            ),
          ],
        ),
      ),
      bottomNavigationBar: selecting && inSelected != null
          ? _selectionBar(inSelected, scheme)
          : null,
    );
  }

  Widget _note(Key key, IconData icon, String text, ColorScheme scheme) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Container(
          key: key,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          child: Row(
            children: [
              Icon(icon, size: 18, color: scheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  text,
                  style: BambooFonts.ui(13, color: scheme.onSurface),
                ),
              ),
            ],
          ),
        ),
      );

  Widget _skeleton(ColorScheme scheme) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Container(
      key: const Key('skeleton-row'),
      height: 88,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
    ),
  );

  Widget _groupHeader(
    String contextId,
    List<SharedJoinRequest> list,
    ColorScheme scheme,
  ) {
    final name = sharedRequestSplitName(list.first);
    final collapsed = _collapsed.contains(contextId);
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              button: true,
              expanded: !collapsed,
              child: InkWell(
                key: Key('group-header-$contextId'),
                onTap: () => setState(() {
                  collapsed
                      ? _collapsed.remove(contextId)
                      : _collapsed.add(contextId);
                }),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Row(
                    children: [
                      Icon(
                        collapsed
                            ? Icons.chevron_right_rounded
                            : Icons.expand_more_rounded,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          '$name · ${list.length} waiting',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: BambooFonts.heading(15),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          PopupMenuButton<String>(
            key: Key('group-menu-$contextId'),
            tooltip: 'More for $name',
            enabled: !_working,
            onSelected: (v) {
              if (v == 'select') _enterSelect(contextId);
              if (v == 'decline_all') _declineAll(list);
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'select',
                key: Key('select-$contextId'),
                child: const Text('Select'),
              ),
              PopupMenuItem(
                value: 'decline_all',
                key: Key('decline-all-$contextId'),
                enabled: !_offline,
                child: const Text('Decline all'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Two or more look-alikes in one split: their full numbers side by side.
  Widget? _compare(List<SharedJoinRequest> list, ColorScheme scheme) {
    final byMask = <String, List<SharedJoinRequest>>{};
    for (final r in list) {
      final p = r.claimantPhone;
      if (p != null && p.lookalike && p.fullNumber != null && p.mask != null) {
        (byMask[p.mask!] ??= []).add(r);
      }
    }
    final pair = byMask.values.where((v) => v.length >= 2).firstOrNull;
    if (pair == null) return null;
    final numbers = [for (final r in pair) r.claimantPhone!.fullNumber!];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        key: const Key('compare-card'),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          border: Border.all(color: scheme.error),
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'These look alike. Compare the numbers.',
              style: BambooFonts.ui(
                13,
                weight: FontWeight.w700,
                color: scheme.error,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < pair.length && i < 2; i++)
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(right: i == 0 ? 8 : 0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            pair[i].label ?? 'Someone',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: BambooFonts.ui(
                              12.5,
                              weight: FontWeight.w600,
                            ),
                          ),
                          _underlined(
                            numbers[i],
                            sharedDifferingDigits(numbers[i], [
                              for (var j = 0; j < numbers.length; j++)
                                if (j != i) numbers[j],
                            ]),
                            scheme,
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _underlined(String e164, Set<int> differing, ColorScheme scheme) {
    final shown = sharedFormatE164(e164, countryCode: null);
    var digit = 0;
    final spans = <InlineSpan>[];
    for (final ch in shown.split('')) {
      final isDigit = RegExp(r'[0-9]').hasMatch(ch);
      final bad = isDigit && differing.contains(digit);
      if (isDigit) digit++;
      spans.add(
        TextSpan(
          text: ch,
          style: bad
              ? const TextStyle(
                  decoration: TextDecoration.underline,
                  fontWeight: FontWeight.w800,
                )
              : null,
        ),
      );
    }
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Text.rich(
        TextSpan(
          children: spans,
          style: BambooFonts.ui(
            13,
            color: scheme.onSurface,
          ).copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
        ),
      ),
    );
  }

  Widget _row(
    SharedJoinRequest r,
    List<SharedJoinRequest> siblings,
    ColorScheme scheme,
  ) {
    final selecting = _selectContext == r.contextId;
    final expired = _expired(r);
    final canTick =
        selecting && sharedJoinBulkAllowed(r) && !expired && !_working;
    final reason = _reasons[r.invitationId];
    final signed = r.signedInAs;
    final created = r.createdAt, expires = r.expiresAt;
    final when = expired
        ? 'Expired'
        : [
            if (created != null)
              'Asked ${sharedAgo(_now().difference(created))}',
            if (expires != null)
              'expires in ${_in(expires.difference(_now()))}',
          ].join(' · ');
    final disabled = _working || _offline;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        key: Key('row-${r.invitationId}'),
        color: scheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          side: BorderSide(
            color: _selected.contains(r.invitationId)
                ? scheme.primary
                : scheme.outlineVariant,
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.md),
          onLongPress: _working
              ? null
              : () => _enterSelect(r.contextId, first: r),
          onTap: selecting ? () => _toggle(r) : null,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (selecting)
                      Padding(
                        padding: const EdgeInsetsDirectional.only(end: 8),
                        child: SizedBox(
                          width: 24,
                          height: 24,
                          child: Checkbox(
                            key: Key('check-${r.invitationId}'),
                            value: _selected.contains(r.invitationId),
                            onChanged: canTick ? (_) => _toggle(r) : null,
                          ),
                        ),
                      ),
                    Expanded(
                      child: Text(
                        r.label ?? 'Someone',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: BambooFonts.heading(15),
                      ),
                    ),
                  ],
                ),
                if (signed != null)
                  Text(
                    signed,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: BambooFonts.ui(12.5, color: scheme.onSurfaceVariant),
                  ),
                SharedClaimantPhoneView(
                  key: ValueKey('phone-${r.invitationId}'),
                  request: r,
                  siblings: siblings,
                  onReveal: () =>
                      widget.runtime.revealClaimantPhone(r.invitationId),
                ),
                if (when.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      when,
                      key: Key('when-${r.invitationId}'),
                      style: BambooFonts.ui(
                        12,
                        color: expired ? scheme.error : scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                if (reason != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      reason,
                      key: Key('reason-${r.invitationId}'),
                      style: BambooFonts.ui(12.5, color: scheme.error),
                    ),
                  ),
                if (!selecting)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Wrap(
                      alignment: WrapAlignment.end,
                      spacing: 16,
                      children: [
                        TextButton(
                          key: Key('decline-${r.invitationId}'),
                          onPressed: disabled
                              ? null
                              : () => _run([r], approve: false),
                          child: const Text('Decline'),
                        ),
                        TextButton(
                          key: Key('approve-${r.invitationId}'),
                          onPressed: disabled || expired
                              ? null
                              : () => _run([r], approve: true),
                          child: Text(
                            'Approve',
                            style: BambooFonts.ui(14, weight: FontWeight.w700),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _selectionBar(List<SharedJoinRequest> inGroup, ColorScheme scheme) {
    final n = _selected.length;
    return Material(
      elevation: 8,
      color: scheme.surface,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FilledButton(
                key: const Key('approve-selected'),
                onPressed: n == 0 || _working || _offline
                    ? null
                    : () => _approveSelected(_selectContext!, inGroup),
                child: Text('Approve selected ($n)'),
              ),
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                children: [
                  TextButton(
                    key: const Key('select-all'),
                    onPressed: _working ? null : () => _selectAll(inGroup),
                    child: const Text('Select all'),
                  ),
                  TextButton(
                    key: const Key('clear-selection'),
                    onPressed: _working ? null : _cancelSelect,
                    child: const Text('Clear'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
