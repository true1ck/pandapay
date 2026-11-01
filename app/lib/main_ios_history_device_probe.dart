import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';
import 'data/ios_device_probe_session.dart';
import 'data/ios_live_probe_session.dart';
import 'data/ios_sender_probe_session.dart';
import 'data/ios_body_evidence_session.dart';
import 'data/ios_probe_diagnostics.dart';
import 'widgets/ios_live_probe_panel.dart';
import 'widgets/ios_sender_probe_panel.dart';
import 'widgets/ios_probe_export_button.dart';
import 'widgets/ios_body_evidence_panel.dart';
import 'data/ios_history_range_request.dart';
import 'data/local/app_database.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  if (kReleaseMode || !Platform.isIOS) {
    throw UnsupportedError('Isolated iPhone Debug/Profile diagnostic only.');
  }
  runApp(const MaterialApp(home: DeviceHistoryProbeScreen()));
}

class DeviceHistoryProbeScreen extends StatefulWidget {
  const DeviceHistoryProbeScreen({super.key});
  @override
  State<DeviceHistoryProbeScreen> createState() => _DeviceHistoryProbeState();
}

class _DeviceHistoryProbeState extends State<DeviceHistoryProbeScreen>
    with WidgetsBindingObserver {
  static const channel = MethodChannel('pandapay/ios_history_device_probe');
  late var _session = IosDeviceProbeSession(
    openInMemoryForTesting(),
    allowSenderInference: false,
  );
  late var _live = IosLiveProbeSession(
    openInMemoryForTesting(),
    allowSenderInference: false,
  );
  late var _senderCheck = IosSenderProbeSession();
  String _shortcutName = 'PANDAPAY SENDER CHECK';
  Map<Object?, Object?> _liveSnapshot = {};
  Map<Object?, Object?> _nativeExportSnapshot = {};
  Map<String, Object?>? _lastFailure;
  DateTime _startedAt = DateTime.now();
  bool _replayChecked = false;
  Map<String, Object?>? _replayInfo;
  String? _replayStatus;
  String? _liveError;
  Future<void>? _refreshing;
  bool _refreshAgain = false;
  String? _error, _selfTestResult;
  IosHistoryRangeRequest? _request;
  Map<Object?, Object?>? _nativeRun;
  bool _showSession = false, _launching = false;
  DateTimeRange _range = DateTimeRange(
    start: DateTime(2026, 9, 1),
    end: DateTime(2026, 9, 30),
  );
  String _date(DateTime? date) =>
      date == null ? 'Unavailable' : date.toLocal().toString().split('.').first;
  String _day(DateTime date) => _date(date).split(' ').first;
  int _count(String key) => (_nativeRun?['counts'] as Map?)?[key] as int? ?? 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    channel.setMethodCallHandler((call) async {
      if (call.method == 'ready') await _refresh();
    });
    unawaited(_refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    channel.setMethodCallHandler(null);
    _session.dispose();
    _live.dispose();
    _senderCheck.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_refresh());
  }

  Future<void> _refresh() {
    _refreshAgain = true;
    return _refreshing ??= (() async {
      while (_refreshAgain && mounted) {
        _refreshAgain = false;
        await _readReplay();
        await _read();
      }
    })().whenComplete(() => _refreshing = null);
  }

  Future<void> _readReplay() async {
    if (_replayChecked) return;
    try {
      final payload = await channel.invokeMapMethod<Object?, Object?>(
        'readDiagnosticReplay',
      );
      if (payload == null || !mounted) return;
      final text = payload['json'] as String;
      final rows = IosBodyEvidenceSession.inputsFromExport(text);
      final report = jsonDecode(text) as Map;
      for (var start = 0; start < rows.length; start += 50) {
        if (!mounted) return;
        final batch = rows.sublist(start, (start + 50).clamp(0, rows.length));
        _session.accept(batch.map(IosSenderProbeSession.directRow).toList());
        _senderCheck.process(batch);
        await Future<void>.delayed(Duration.zero);
      }
      final summary = _senderCheck.bodyEvidence.snapshot;
      final counts = <String, int>{
        'input_records': rows.length,
        for (final key in [
          'unique_message_inputs',
          'transaction_candidates',
          'payment_requests',
          'omitted_inputs',
        ])
          key: summary[key] as int,
      };
      await channel.invokeMethod<void>('completeDiagnosticReplay', {
        'fingerprint': payload['fingerprint'],
        'counts': counts,
      });
      // A missing file or protected-data failure during startup must remain
      // retryable when the app resumes after the phone is unlocked.
      _replayChecked = true;
      if (!mounted) return;
      setState(() {
        _replayInfo = {
          'source_build': (report['native_app'] as Map?)?['build'],
          'source_exported_at': report['exported_at'],
          'counts': counts,
          'mode': 'diagnostic_file_replay',
        };
        _replayStatus =
            'Replayed your exported session. No new Shortcut run was needed.';
        final dates =
            rows
                .map(
                  (r) => DateTime.tryParse(
                    r['receivedAt'] as String? ?? '',
                  )?.toLocal(),
                )
                .whereType<DateTime>()
                .toList()
              ..sort();
        if (dates.isNotEmpty) {
          _range = DateTimeRange(start: dates.first, end: dates.last);
        }
      });
    } catch (error, stack) {
      _recordFailure('replay_diagnostic_file', error, stack);
      if (mounted) {
        setState(
          () => _replayStatus =
              'The diagnostic file could not be replayed. The original file is unchanged.',
        );
      }
    }
  }

  Future<void> _read() async {
    try {
      final data = await channel.invokeMapMethod<Object?, Object?>(
        'readPending',
      );
      if (data == null || !mounted) return;
      await _readLive(Map<Object?, Object?>.from(data['live'] as Map? ?? {}));
      final rows = [
        for (final row in data['records'] as List)
          Map<Object?, Object?>.from(row as Map),
      ];
      _nativeExportSnapshot = {
        'runs': data['runs'] ?? [],
        'pending_range_records': rows.length,
        'pending_records': rows,
        'snapshot_at': DateTime.now().toUtc().toIso8601String(),
      };
      for (var offset = 0; offset < rows.length; offset += 50) {
        if (!mounted) return;
        final batch = rows.sublist(offset, (offset + 50).clamp(0, rows.length));
        _session.accept(batch.map(IosSenderProbeSession.directRow).toList());
        _senderCheck.process(batch);
        await channel.invokeMethod<void>('acknowledge', [
          for (final row in batch) row['id'] as String,
        ]);
        _nativeExportSnapshot['pending_records'] = rows.sublist(
          offset + batch.length,
        );
        await Future<void>.delayed(Duration.zero);
      }
      if (!mounted) return;
      final reports = data['runs'] as List? ?? [];
      setState(() {
        _nativeRun = reports
            .cast<Map>()
            .where((r) => r['run_id'] == _request?.id)
            .firstOrNull;
        if (_nativeRun?['status'] == 'completed' && _request != null) {
          _senderCheck.completeHistoryComparison(_request!.id);
        }
        _error = null;
      });
    } catch (error, stack) {
      _recordFailure('read_capture', error, stack);
      if (mounted) {
        setState(() {
          _error = 'Capture failed. Refresh to retry the pending handoff.';
          _liveError =
              'Diagnostic read failed; live receiver status is unconfirmed. Refresh to retry.';
        });
      }
    }
  }

  Future<void> _readLive(Map<Object?, Object?> snapshot) async {
    if (!mounted) return;
    setState(() => _liveSnapshot = snapshot);
    try {
      final rows = [
        for (final row in snapshot['records'] as List? ?? [])
          Map<Object?, Object?>.from(row as Map),
      ];
      var failed = false;
      for (var offset = 0; offset < rows.length; offset += 50) {
        if (!mounted) return;
        final batch = rows.sublist(offset, (offset + 50).clamp(0, rows.length));
        _senderCheck.process(batch);
        final outcomes = _live.process(batch);
        failed |= outcomes.any((row) => row['outcome'] == 'processing_error');
        if (outcomes.isEmpty) continue;
        final confirmed = await channel.invokeMapMethod<Object?, Object?>(
          'completeLive',
          outcomes,
        );
        if (!mounted) return;
        setState(() {
          if (confirmed != null) _liveSnapshot = confirmed;
          _liveError = failed
              ? 'Shared intake failed. The record remains pending; Refresh retries it.'
              : null;
        });
        await Future<void>.delayed(Duration.zero);
      }
      if (rows.isEmpty && mounted) {
        setState(() => _liveError = null);
      }
    } catch (error, stack) {
      _recordFailure('read_single_message', error, stack);
      if (mounted) {
        setState(
          () => _liveError =
              'Live handoff processing/acknowledgement failed. Pending status is unconfirmed; Refresh retries without adding the message twice.',
        );
      }
    }
  }

  Future<void> _fetch({bool useLatestReference = false}) async {
    final request = IosHistoryRangeRequest.days(
      id: const Uuid().v4(),
      firstDay: _range.start,
      lastDay: _range.end,
    );
    setState(() {
      _senderCheck.beginHistoryComparison(
        request.id,
        useLatestReference: useLatestReference,
      );
      _request = request;
      _nativeRun = null;
      _showSession = false;
      _launching = true;
      _error = null;
    });
    try {
      final launched = await channel.invokeMethod<bool>('runShortcut', {
        'name': _shortcutName,
        'input': request.json,
      });
      if (mounted && launched != true) {
        setState(
          () => _error =
              'Shortcuts could not open. Import the revised V2 shortcut and retry.',
        );
      }
    } catch (error, stack) {
      _recordFailure('launch_shortcut', error, stack);
      if (mounted) {
        setState(
          () =>
              _error = 'The range could not be launched. Retry from this app.',
        );
      }
    } finally {
      if (mounted) setState(() => _launching = false);
      await _refresh();
    }
  }

  void _recordFailure(String stage, Object error, StackTrace stack) {
    _lastFailure = {
      'stage': stage,
      'type': error.runtimeType.toString(),
      if (error is PlatformException) 'native_code': error.code,
      'at': DateTime.now().toUtc().toIso8601String(),
      'stack': stack.toString().substring(
        0,
        stack.toString().length.clamp(0, 8192),
      ),
    };
  }

  String _exportReport() => jsonEncode(
    buildIosProbeDiagnostics(
      shortcut: _shortcutName,
      startedAt: _startedAt,
      exportedAt: DateTime.now(),
      selection: {
        'first_receive_day': _day(_range.start),
        'last_receive_day': _day(_range.end),
        if (_request != null) 'request': jsonDecode(_request!.json),
        'native_snapshot_at': _nativeExportSnapshot['snapshot_at'],
      },
      nativeSnapshot: {..._nativeExportSnapshot, 'live': _liveSnapshot},
      sender: _senderCheck,
      rangeSession: _session,
      singleSession: _live.intake,
      processing: _refreshing != null || _launching,
      errors: {
        'range': _error,
        'single_message': _liveError,
        'last_failure': _lastFailure,
        'synthetic_check': _selfTestResult,
      },
      replayInfo: _replayInfo,
    ),
  );

  Future<void> _checkDay(
    DateTime day, {
    bool useLatestReference = false,
  }) async {
    final local = day.toLocal();
    setState(() => _range = DateTimeRange(start: local, end: local));
    await _fetch(useLatestReference: useLatestReference);
  }

  Future<void> _clear() async {
    await _refresh();
    try {
      await channel.invokeMethod<void>('clear');
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not clear native intake. Retry.');
      }
      return;
    }
    _session.dispose();
    _session = IosDeviceProbeSession(
      openInMemoryForTesting(),
      allowSenderInference: false,
    );
    _live.dispose();
    _live = IosLiveProbeSession(
      openInMemoryForTesting(),
      allowSenderInference: false,
    );
    _senderCheck.dispose();
    _senderCheck = IosSenderProbeSession();
    if (mounted) {
      setState(() {
        _request = null;
        _nativeRun = null;
        _liveSnapshot = {};
        _nativeExportSnapshot = {};
        _lastFailure = null;
        _startedAt = DateTime.now();
        _replayChecked = false;
        _replayInfo = null;
        _replayStatus = null;
        _liveError = null;
        _selfTestResult = null;
        _error = null;
      });
    }
  }

  void _selfTest() {
    final session = IosDeviceProbeSession(openInMemoryForTesting());
    try {
      final rows = <Map<Object?, Object?>>[
        {
          'id': 'synthetic',
          'runId': 'test',
          'sender': 'VM-ICICIB',
          'body': 'INR 250 spent on ICICI Bank Card XX7788 at SWIGGY.',
          'receivedAt': '2026-09-30T14:40:51Z',
        },
        {
          'id': 'missing-date',
          'runId': 'test',
          'sender': 'VM-ICICIB',
          'body': 'INR 450 spent on ICICI Bank Card XX7788 at UBER.',
          'capturedAt': '2026-10-29T10:00:00Z',
        },
      ];
      session.accept(rows);
      session.accept([
        {...rows.first, 'id': 'repeat', 'runId': 'repeat'},
      ]);
      final passed =
          session.counts.captured == 1 &&
          session.missingDate == 1 &&
          session.runs['repeat']!.retainedAdded == 0 &&
          session.findSourceMessage(session.transactionList.single) != null;
      setState(
        () => _selfTestResult = passed
            ? 'Synthetic check passed: exact source linked, missing date withheld, repeat added zero.'
            : 'Synthetic check failed.',
      );
    } finally {
      session.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final request = _request;
    final result = _session.runs[request?.id];
    final transactions = _showSession
        ? _session.transactionList
        : _session.transactionsForRun(request?.id ?? '');
    final status =
        _nativeRun?['status'] as String? ??
        (request == null ? 'not_started' : 'waiting_for_shortcut');
    final statusText = switch (status) {
      'completed' => 'Shortcut handoff completed',
      'running' => 'Shortcut is searching or handing off messages',
      'incomplete_handoff' => 'Incomplete: found and handoff counts differ',
      'launch_failed' => 'Shortcuts failed to open',
      'interrupted' => 'Previous fetch interrupted',
      'not_started' => 'No fetch started',
      _ => 'Waiting for the revised Shortcut to start',
    };
    return Scaffold(
      appBar: AppBar(title: const Text('PandaPay Sender Probe · 12')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          IosProbeExportButton(report: _exportReport),
          IosBodyEvidencePanel(
            snapshot: _senderCheck.bodyEvidence.snapshot,
            replayStatus: _replayStatus,
          ),
          IosSenderProbePanel(
            showChecks: true,
            events: _senderCheck.events,
            liveInput: _senderCheck.latestLiveInput,
            historyInput: _senderCheck.latestHistoryInput,
            comparison: _senderCheck.comparison,
            onCheckToday: _launching ? null : () => _checkDay(DateTime.now()),
            onCheckLiveDay:
                _launching ||
                    DateTime.tryParse(
                          _senderCheck.latestLiveInput?['original_receive_date']
                                  as String? ??
                              '',
                        ) ==
                        null
                ? null
                : () => _checkDay(
                    DateTime.parse(
                      _senderCheck.latestLiveInput!['original_receive_date']
                          as String,
                    ),
                    useLatestReference: true,
                  ),
          ),
          const Divider(height: 28),
          const Text(
            'Sender-test copy: inside Repeat, call Inspect Financial Message With Sender, then Probe Main-App History Input. Pass the same Body, Sender and Date to both. The second action also takes the original range request. Keep the probe’s existing search and Finish.',
          ),
          IosLiveProbePanel(
            snapshot: _liveSnapshot,
            session: _live,
            error: _liveError,
            onRefresh: _refresh,
          ),
          const Divider(height: 28),
          const Text('Temporary local database · No account or active upload'),
          const Text(
            'Select receive dates, then Fetch. Results last for this app process. Opening Shortcuts does not complete an import.',
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            initialValue: _shortcutName,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Prototype range shortcut',
            ),
            items: [
              for (final name in [
                'PANDAPAY SENDER CHECK',
                'PANDAPAY SELECTED RANGE V2',
              ])
                DropdownMenuItem(value: name, child: Text(name)),
            ],
            onChanged: _launching
                ? null
                : (value) => setState(() => _shortcutName = value!),
          ),
          const SizedBox(height: 16),
          Text(
            'Selected SMS receive days: ${_day(_range.start)} → ${_day(_range.end)}',
          ),
          Wrap(
            spacing: 8,
            children: [
              for (final month in [3, 9, 10])
                ActionChip(
                  label: Text(
                    '${{3: 'March', 9: 'September', 10: 'October'}[month]} 2026',
                  ),
                  onPressed: () => setState(
                    () => _range = DateTimeRange(
                      start: DateTime(2026, month),
                      end: DateTime(2026, month + 1, 0),
                    ),
                  ),
                ),
              ActionChip(
                label: const Text('Pick dates'),
                onPressed: () async {
                  final picked = await showDateRangePicker(
                    context: context,
                    initialDateRange: _range,
                    firstDate: DateTime(2020),
                    lastDate: DateTime.now().add(const Duration(days: 31)),
                  );
                  if (picked != null && mounted) {
                    setState(() => _range = picked);
                  }
                },
              ),
            ],
          ),
          FilledButton.icon(
            onPressed: _launching ? null : _fetch,
            icon: const Icon(Icons.history),
            label: const Text('Fetch selected receive range'),
          ),
          const Text(
            'Choose one known receive day for the sender test. Direct processing has sender inference OFF. Body-only inference runs separately for comparison.',
          ),
          const Divider(height: 28),
          Text(
            'Latest fetch: $statusText',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          if (request != null) ...[
            Text(
              'Requested: ${_date(request.start)} inclusive → ${_date(request.endExclusive)} exclusive',
            ),
            Text('Run: ${request.id.substring(0, 8)}'),
            Text(
              'Search found: ${status == 'completed' || status == 'incomplete_handoff' ? _count('found') : 'not reported yet'} · Native handoffs: ${_count('received')}',
            ),
            Text(
              'Passed range/metadata checks: ${_count('accepted')} · Native duplicates: ${_count('duplicates')}',
            ),
            Text(
              'Missing original date: ${_count('missing_date')} · Missing sender: ${_count('missing_sender')}',
            ),
            Text(
              'Native sender inputs: ${_count('sender_handle')} handle · ${_count('sender_name')} name only · ${_count('sender_text')} text',
            ),
            Text(
              'Outside range: ${_count('out_of_range')} · Sensitive: ${_count('sensitive')} · Invalid: ${_count('invalid')} · Capacity rejected: ${_count('limit_reached')}',
            ),
            Text(
              'Shared intake: ${result?.retainedAdded ?? 0} newly retained · ${result?.existing ?? 0} already retained · ${result?.reviewed ?? 0} need review · ${result?.ignored ?? 0} ignored by triage',
            ),
            Text(
              'Parser: ${_session.transactionsForRun(request.id).length} matched transactions · ${result?.transactionsAdded ?? 0} newly added',
            ),
            Text(
              'Shared validation rejected: ${result?.missingDate ?? 0} missing dates · ${result?.invalid ?? 0} invalid · ${result?.sensitive ?? 0} sensitive',
            ),
            if (_count('limit_reached') > 0 ||
                _count('missing_date') > 0 ||
                status == 'incomplete_handoff')
              const Text(
                'This fetch is partial. Review rejections before interpreting results.',
                style: TextStyle(color: Colors.deepOrange),
              ),
          ],
          OutlinedButton(
            onPressed: _refresh,
            child: const Text('Refresh results'),
          ),
          const Divider(height: 28),
          Text(
            'Cumulative session: ${_session.counts.captured} retained SMS · ${_session.transactions} transactions · ${_session.reviewCount} review items',
          ),
          Text(
            'Accepted handoffs: ${_session.complete} · Missing senders: ${_session.missingSender} · Missing dates withheld: ${_session.missingDate}',
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Show cumulative session transactions'),
            value: _showSession,
            onChanged: (value) => setState(() => _showSession = value),
          ),
          Text(
            '${_showSession ? 'Session' : 'Latest fetch'} parsed transactions (${transactions.length})',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          if (transactions.isEmpty)
            const Text(
              'No imported transaction matches are available in this view. This does not establish that no transactions occurred.',
            ),
          for (final tx in transactions) _transactionCard(tx),
          const Divider(height: 28),
          Text('Cumulative retained SMS (${_session.retainedInputs.length})'),
          for (final source in _session.retainedInputs)
            Card(
              child: ExpansionTile(
                title: Text(
                  '${source.sender}${source.senderInferred ? ' (inferred)' : ' (${source.senderEvidence})'}',
                ),
                subtitle: Text(
                  'Original received: ${_date(source.date)}\nImported: ${_date(source.capturedAt)}',
                ),
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: SelectableText(source.body),
                  ),
                ],
              ),
            ),
          OutlinedButton(
            onPressed: _selfTest,
            child: const Text('Run synthetic shared-intake check'),
          ),
          if (_selfTestResult != null) Text(_selfTestResult!),
          OutlinedButton(
            onPressed: _clear,
            child: const Text('Clear temporary session'),
          ),
          if (_error != null)
            Text(_error!, style: const TextStyle(color: Colors.red)),
        ],
      ),
    );
  }

  Widget _transactionCard(Map<String, dynamic> tx) {
    final sources = _session.sourcesForTransaction(
      tx,
      runId: _showSession ? null : _request?.id,
    );
    final occurred = tx['occurred_at'];
    final date = occurred is int
        ? DateTime.fromMillisecondsSinceEpoch(occurred)
        : DateTime.tryParse('$occurred');
    return Card(
      child: ExpansionTile(
        title: Text(
          '${tx['merchant_name'] ?? tx['counterparty'] ?? 'Transaction'} · ₹${tx['amount_inr'] ?? tx['amount'] ?? ''}',
        ),
        subtitle: Text('Parser occurrence: ${_date(date)}'),
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Parser occurrence may use SMS receive date when the body has no date.',
                ),
                for (final source in sources) ...[
                  Text('Original SMS received: ${_date(source.date)}'),
                  Text('Imported: ${_date(source.capturedAt)}'),
                  Text(
                    'Sender: ${source.sender} (${source.senderInferred ? 'inferred for parsing' : source.senderEvidence})',
                  ),
                  SelectableText(source.body),
                ],
                if (sources.isEmpty)
                  const Text('No exact source link is available.'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
