import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import 'ios_sms_intake_controller.dart';
import 'ios_sms_intake_providers.dart';
import 'ios_sms_intake_service.dart';
import 'ios_history_coverage.dart';
import 'ios_shortcut_links.dart';
import 'ios_sms_sharing_setup.dart';
import 'live_alert_status.dart';

const iosSmsHistoryShortcutName = 'PANDAPAY SMS HISTORY';
const _shortcutNameKey = 'pandapay_app.ios_history_shortcut_name_v1';

class IosSmsImportScreen extends ConsumerStatefulWidget {
  const IosSmsImportScreen({super.key});
  @override
  ConsumerState<IosSmsImportScreen> createState() => _IosSmsImportScreenState();
}

class _IosSmsImportScreenState extends ConsumerState<IosSmsImportScreen> {
  final _shortcutName = TextEditingController(text: iosSmsHistoryShortcutName);
  final _nameScroll = ScrollController(keepScrollOffset: false);
  int _months = 24;
  DateTimeRange? _custom;
  String? _error;
  bool _busy = false;
  bool _sharingConfirmed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadName());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(ref.read(iosSmsIntakeControllerProvider).refresh());
      }
    });
  }

  Future<void> _loadName() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      _shortcutName.text =
          prefs.getString(_shortcutNameKey) ?? iosSmsHistoryShortcutName;
    }
  }

  @override
  void dispose() {
    _shortcutName.dispose();
    _nameScroll.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    FocusManager.instance.primaryFocus?.unfocus();
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Could not start. Check Shortcut setup and try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _launch() async {
    final prefs = await SharedPreferences.getInstance();
    final name = _shortcutName.text.trim();
    if (name.isEmpty) throw StateError('Shortcut name required');
    await prefs.setString(_shortcutNameKey, name);
    await ref.read(iosSmsIntakeControllerProvider).continueImport(name);
  }

  Future<void> _chooseDates() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final now = DateTime.now();
    final dates = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: now,
      initialDateRange:
          _custom ?? DateTimeRange(start: iosSmsMonthsAgo(now, 24), end: now),
    );
    if (dates != null && mounted) {
      setState(() {
        _custom = dates;
        _months = 0;
      });
    }
  }

  ButtonStyle get _primaryStyle => FilledButton.styleFrom(
    backgroundColor: BambooInk.slate,
    foregroundColor: BambooInk.lime,
    disabledBackgroundColor: BambooInk.slate.withValues(alpha: .12),
    disabledForegroundColor: BambooInk.ink700,
    minimumSize: const Size.fromHeight(50),
    textStyle: BambooFonts.ui(15, weight: FontWeight.w700),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppRadius.md),
    ),
  );

  @override
  Widget build(BuildContext context) {
    ref.watch(iosSmsIntakeLifecycleProvider);
    final controller = ref.watch(iosSmsIntakeControllerProvider);
    final state = controller.state;
    final now = DateTime.now();
    final start = _months == 0 && _custom != null
        ? _custom!.start
        : iosSmsMonthsAgo(now, _months == 0 ? 24 : _months);
    final selectedEnd = _custom == null
        ? now
        : DateTime(_custom!.end.year, _custom!.end.month, _custom!.end.day + 1);
    final end = _months == 0 && selectedEnd.isBefore(now) ? selectedEnd : now;
    final active = state.activeJob != null;
    final live = LiveAlertStatus.of(
      enabled: state.enabled,
      lastLiveAt: state.lastLiveAt,
      now: now,
    );
    final history = buildHistoryMonths(
      now: now,
      coverage: state.importedRanges,
      jobWindows: state.currentWindows,
    );
    final pastMonths = history
        .where((m) => m.status != MonthCoverage.future)
        .length;
    final importedMonths = history
        .where((m) => m.status == MonthCoverage.imported)
        .length;
    final toImport = history
        .where(
          (m) => m.canImport && m.end.isAfter(start) && m.start.isBefore(end),
        )
        .length;
    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          foregroundColor: BambooInk.ink900,
          elevation: 0,
          title: Text(
            'SMS on iPhone',
            style: BambooFonts.heading(18, color: BambooInk.ink900),
          ),
          actions: [
            IconButton(
              tooltip: 'Shortcut setup',
              onPressed: () => _help(context),
              icon: const Icon(Icons.help_outline_rounded),
            ),
          ],
        ),
        body: ListView(
          key: const ValueKey('ios-sms-import-scroll'),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.all(AppSpace.lg),
          children: [
            Text(
              'Your spending, up to date.',
              style: BambooFonts.heading(
                25,
                color: BambooInk.ink900,
                weight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: AppSpace.sm),
            Text(
              'Live bank alerts and your past spending, through Shortcuts.',
              style: BambooFonts.ui(13.5, color: BambooInk.ink700),
            ),
            const SizedBox(height: AppSpace.xl),
            SmsSetupPanel(
              child: Row(
                children: [
                  const Icon(Icons.sms_outlined, color: BambooInk.jade),
                  const SizedBox(width: AppSpace.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Live bank alerts',
                          style: BambooFonts.heading(
                            16,
                            color: BambooInk.ink900,
                          ),
                        ),
                        Text(
                          live.label,
                          key: const ValueKey('live-alert-status'),
                          style: BambooFonts.ui(
                            12,
                            color: live.health == LiveAlertHealth.quiet
                                ? BambooInk.clayInk
                                : BambooInk.ink700,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Switch.adaptive(
                    value: state.enabled,
                    activeTrackColor: BambooInk.jade,
                    onChanged: _busy
                        ? null
                        : (value) => _run(() => controller.setEnabled(value)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpace.md),
            IosSmsSharingSetup(
              onConfirmedChanged: (value) {
                if (mounted) setState(() => _sharingConfirmed = value);
              },
            ),
            IosShortcutInstallPanel(liveHealth: live.health),
            const SizedBox(height: AppSpace.lg),
            if (active) ...[
              _progress(state, controller),
              const SizedBox(height: AppSpace.lg),
            ],
            SmsSetupPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Your SMS history',
                    style: BambooFonts.heading(18, color: BambooInk.ink900),
                  ),
                  const SizedBox(height: AppSpace.xs),
                  Text(
                    '$importedMonths of $pastMonths months imported'
                    '${importedMonths < pastMonths ? ' · tap a month to import it' : ''}',
                    style: BambooFonts.ui(12.5, color: BambooInk.ink700),
                  ),
                  const SizedBox(height: AppSpace.md),
                  HistoryCoverageStrip(
                    months: history,
                    onTap: (month) => _showMonth(month, state, controller),
                  ),
                  const SizedBox(height: AppSpace.lg),
                  const Divider(height: 1, color: BambooInk.hairlineOnPaper),
                  const SizedBox(height: AppSpace.md),
                  Text(
                    'Import your history',
                    style: BambooFonts.heading(15, color: BambooInk.ink900),
                  ),
                  const SizedBox(height: AppSpace.sm),
                  Wrap(
                    spacing: AppSpace.sm,
                    runSpacing: AppSpace.xs,
                    children: [
                      for (final months in [3, 6, 12, 24])
                        ChoiceChip(
                          label: Text(
                            months < 12
                                ? '$months months'
                                : '${months ~/ 12} ${months == 12 ? 'year' : 'years'}',
                          ),
                          selected: _months == months,
                          selectedColor: BambooInk.slate,
                          backgroundColor: BambooInk.paper,
                          showCheckmark: false,
                          side: const BorderSide(
                            color: BambooInk.hairlineOnPaper,
                          ),
                          labelStyle: BambooFonts.ui(
                            12.5,
                            weight: FontWeight.w600,
                            color: _months == months
                                ? BambooInk.lime
                                : BambooInk.ink700,
                          ),
                          onSelected: (_) => setState(() {
                            _months = months;
                            _custom = null;
                          }),
                        ),
                    ],
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      style: TextButton.styleFrom(
                        foregroundColor: BambooInk.jade,
                        textStyle: BambooFonts.ui(13, weight: FontWeight.w600),
                      ),
                      onPressed: _chooseDates,
                      child: Text(
                        _months == 0
                            ? '${DateFormat.yMMMd().format(start)} – ${DateFormat.yMMMd().format(end)}'
                            : 'Custom dates',
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpace.sm),
                  FilledButton(
                    key: const ValueKey('ios-sms-start-import'),
                    style: _primaryStyle,
                    onPressed:
                        _busy ||
                            !state.enabled ||
                            !_sharingConfirmed ||
                            (_months != 0 && toImport == 0)
                        ? null
                        : () => _run(() async {
                            await controller.startHistory(
                              start,
                              end,
                              replacingJobId: state.activeJob?['id'] as String?,
                            );
                            await _launch();
                          }),
                    child: Text(
                      _busy
                          ? 'Starting…'
                          : _months != 0 && toImport == 0
                          ? 'All these months are imported'
                          : toImport > 0
                          ? 'Import $toImport missing ${toImport == 1 ? 'month' : 'months'}'
                          : active
                          ? 'Start new import'
                          : 'Start import',
                    ),
                  ),
                  const SizedBox(height: AppSpace.sm),
                  Text(
                    !state.enabled
                        ? 'Connect live bank alerts to enable import.'
                        : !_sharingConfirmed
                        ? 'Complete History permissions first.'
                        : active
                        ? 'Replaces the current check. Saved messages stay.'
                        : 'Takes a few minutes per month and runs in Shortcuts. '
                              'You can switch apps while it imports.',
                    style: BambooFonts.ui(12, color: BambooInk.ink700),
                  ),
                ],
              ),
            ),
            // With an import open, its card shows the error instead.
            if (_error != null || (state.error != null && !active))
              Padding(
                padding: const EdgeInsets.only(top: AppSpace.md),
                child: Text(
                  _error ?? state.error!,
                  style: BambooFonts.ui(13, color: BambooInk.clayInk),
                ),
              ),
            const SizedBox(height: AppSpace.lg),
            ExpansionTile(
              key: const PageStorageKey('ios-sms-options'),
              tilePadding: EdgeInsets.zero,
              title: Text(
                'Import options',
                style: BambooFonts.heading(14, color: BambooInk.ink700),
              ),
              iconColor: BambooInk.ink700,
              collapsedIconColor: BambooInk.ink700,
              children: [
                TextField(
                  key: const ValueKey('ios-sms-shortcut-name'),
                  controller: _shortcutName,
                  scrollController: _nameScroll,
                  style: BambooFonts.ui(14, color: BambooInk.ink900),
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) =>
                      FocusManager.instance.primaryFocus?.unfocus(),
                  onTapOutside: (_) =>
                      FocusManager.instance.primaryFocus?.unfocus(),
                  decoration: InputDecoration(
                    labelText: 'History shortcut name',
                    labelStyle: BambooFonts.ui(12, color: BambooInk.ink700),
                    suffixIcon: IconButton(
                      tooltip: 'Done editing',
                      onPressed: () =>
                          FocusManager.instance.primaryFocus?.unfocus(),
                      icon: const Icon(
                        Icons.check_rounded,
                        color: BambooInk.jade,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpace.sm),
                TextButton(
                  onPressed: _busy ? null : () => _run(controller.refresh),
                  child: Text(
                    'Refresh messages',
                    style: BambooFonts.ui(13, color: BambooInk.jade),
                  ),
                ),
                ExpansionTile(
                  key: const PageStorageKey('ios-sms-details'),
                  title: Text(
                    'Troubleshooting details',
                    style: BambooFonts.ui(13, color: BambooInk.ink700),
                  ),
                  children: [
                    for (final window
                        in [...state.latestWindows]..sort(
                          (a, b) => (a['ordinal'] as int? ?? 0).compareTo(
                            b['ordinal'] as int? ?? 0,
                          ),
                        ))
                      _windowDetails(state, window),
                    if (state.lastCompletedJob != null &&
                        state.lastCompletedJob?['id'] !=
                            (state.activeJob ?? state.jobs.firstOrNull)?['id'])
                      ExpansionTile(
                        key: PageStorageKey(
                          'ios-sms-completed-${state.lastCompletedJob?['id']}',
                        ),
                        title: Text(
                          'Last completed import',
                          style: BambooFonts.ui(13, color: BambooInk.ink900),
                        ),
                        subtitle: Text(
                          state.countsFor(state.lastCompletedWindows),
                          style: BambooFonts.ui(12, color: BambooInk.ink700),
                        ),
                        children: [
                          for (final window in state.lastCompletedWindows)
                            _windowDetails(state, window),
                        ],
                      ),
                    if (state.snapshot['reconciledThrough'] is String)
                      Text(
                        'Checked through ${DateFormat.yMMMd().format(DateTime.parse(state.snapshot['reconciledThrough'] as String).toLocal())}',
                        style: BambooFonts.ui(12, color: BambooInk.ink700),
                      ),
                  ],
                ),
              ],
            ),
            if (state.activeJob == null && state.lastCompletedJob != null)
              Padding(
                padding: const EdgeInsets.only(top: AppSpace.sm),
                child: Row(
                  children: [
                    const Icon(
                      Icons.check_circle_outline_rounded,
                      color: BambooInk.jade,
                      size: 18,
                    ),
                    const SizedBox(width: AppSpace.sm),
                    Expanded(
                      child: Text(
                        'Last import finished · ${_messages(_sum(state.lastCompletedWindows, 'enumerated'))} read',
                        style: BambooFonts.ui(13, color: BambooInk.jade),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: AppSpace.xl),
          ],
        ),
      ),
    );
  }

  Widget _windowDetails(IosSmsIntakeState state, Map<String, Object?> window) {
    final senderDetails = (window['enumerated'] as int? ?? 0) == 0
        ? 'No messages received yet'
        : 'Valid inputs: ${window['sender_received'] ?? 0} sender received · ${window['sender_unavailable'] ?? 0} sender missing';
    final receiverBuild = window['receiver_build'];
    final buildDetails = receiverBuild is String
        ? '\nCapture received by build $receiverBuild'
        : '';
    final senderInput = switch (window['sender_input']) {
      'person_handle' => 'Message sender handle',
      'person_without_handle' => 'Message sender supplied without an address',
      'text' => 'Sender text',
      'missing' => 'No sender value arrived',
      _ => null,
    };
    final inputDetails = senderInput == null
        ? ''
        : '\nLast sender input: $senderInput';
    return ListTile(
      dense: true,
      title: Text(
        '${_range(window)} · ${_statusLabel(window['state'])}',
        style: BambooFonts.ui(13, color: BambooInk.ink900),
      ),
      subtitle: Text(
        '${window['found'] == null ? '' : '${window['found']} found${(window['found'] as int) >= 500 ? ' (Shortcuts limit, continued below)' : ''} · '}${state.countsFor([window])}\n${window['duplicates'] ?? 0} already saved · ${window['security_excluded'] ?? 0} security excluded · ${window['ignored'] ?? 0} ignored\n$senderDetails$buildDetails$inputDetails\nShortcut: ${_historyStageLabel(window['last_stage'])}${_handoffLabel(window['handoff_stage'])}',
        style: BambooFonts.ui(12, color: BambooInk.ink700),
      ),
    );
  }

  static int _sum(Iterable<Map<String, Object?>> rows, String key) =>
      rows.fold(0, (total, row) => total + (row[key] as int? ?? 0));

  static String _messages(int count) => count == 1
      ? '1 message'
      : '${NumberFormat.decimalPattern('en_IN').format(count)} messages';

  void _showMonth(
    HistoryMonth month,
    IosSmsIntakeState state,
    IosSmsIntakeController controller,
  ) {
    final ready = state.enabled && _sharingConfirmed;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: BambooInk.paper,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheet) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                month.label,
                style: BambooFonts.heading(20, color: BambooInk.ink900),
              ),
              const SizedBox(height: AppSpace.xs),
              Text(switch (month.status) {
                MonthCoverage.imported =>
                  'Imported. New messages arrive through live alerts.',
                MonthCoverage.partial =>
                  'Partly imported. Import the missing days to complete it.',
                MonthCoverage.missing => 'Not imported yet.',
                MonthCoverage.importing => 'Importing now…',
                MonthCoverage.waiting =>
                  'Waiting its turn in the current import.',
                MonthCoverage.future => '',
              }, style: BambooFonts.ui(13.5, color: BambooInk.ink700)),
              if (month.canImport) ...[
                const SizedBox(height: AppSpace.lg),
                FilledButton(
                  style: _primaryStyle,
                  onPressed: !ready || _busy
                      ? null
                      : () {
                          Navigator.pop(sheet);
                          final now = DateTime.now();
                          _run(() async {
                            await controller.startHistory(
                              month.start,
                              month.end.isAfter(now) ? now : month.end,
                              replacingJobId: state.activeJob?['id'] as String?,
                            );
                            await _launch();
                          });
                        },
                  child: Text(
                    month.status == MonthCoverage.partial
                        ? 'Import missing days'
                        : 'Import this month',
                  ),
                ),
                if (!ready) ...[
                  const SizedBox(height: AppSpace.sm),
                  Text(
                    !state.enabled
                        ? 'Turn on live bank alerts first.'
                        : 'Complete History permissions first.',
                    style: BambooFonts.ui(12, color: BambooInk.ink700),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }

  static String _day(DateTime value, {bool year = false}) =>
      (year ? DateFormat('d MMM yyyy') : DateFormat('d MMM')).format(
        value.toLocal(),
      );

  /// "1 Aug – 18 Aug 2026". The end is exclusive, so show the last instant
  /// inside the range.
  static String _range(Map<String, Object?> window) {
    final start = DateTime.tryParse(window['start'] as String? ?? '');
    final end = DateTime.tryParse(
      window['end'] as String? ?? '',
    )?.subtract(const Duration(milliseconds: 1));
    if (start == null) return 'Date range';
    if (end == null || end.isBefore(start)) return _day(start, year: true);
    return '${_day(start)} – ${_day(end, year: true)}';
  }

  static String _rangeVerb(Map<String, Object?> window) =>
      switch (window['state']) {
        'waiting' || 'running' => 'Now importing',
        'finished' => 'Saving messages from',
        'partial' => 'Stopped at',
        _ => 'Next:',
      };

  static String _statusLabel(Object? state) => switch (state) {
    'complete' => 'Done',
    'partial' => 'Needs a check',
    'waiting' || 'running' => 'Importing',
    'finished' => 'Saving',
    'queued' => 'Waiting',
    _ => '$state',
  };

  String _historyStageLabel(Object? value) => switch (value) {
    'window_start' => 'Start reached PandaPay',
    'window_end' => 'End reached PandaPay',
    'capture' => 'Capture reached PandaPay',
    'finish' => 'Finish reached PandaPay',
    _ => 'Waiting for the first action',
  };

  String _handoffLabel(Object? value) => switch (value) {
    'launch_requested' => '\nHandoff: Waiting for Shortcuts to return',
    'resume_shortcuts' => '\nHandoff: Returning to the existing Shortcuts run',
    'resume_stalled' => '\nHandoff: Continuing the current message search',
    'app_return_requested' => '\nHandoff: Returning to PandaPay during import',
    'app_return_unavailable' => '\nHandoff: Continuing safely in Shortcuts',
    'returned_success' => '\nHandoff: Shortcuts returned successfully',
    'returned_cancel' => '\nHandoff: Cancelled in Shortcuts',
    'returned_error' => '\nHandoff: Shortcuts stopped',
    _ => '',
  };

  Widget _progress(IosSmsIntakeState state, IosSmsIntakeController controller) {
    final automatic = controller.automaticallyAdvancing;
    final counts = state.importCounts;
    final total = state.activeJob?['kind'] == 'history'
        ? state.monthCount
        : state.currentWindows.length;
    final done = state.activeJob?['kind'] == 'history'
        ? state.completedMonths
        : state.completed;
    final title = state.paused
        ? 'Import paused'
        : controller.canRetryProcessing
        ? 'Processing needs attention'
        : state.partial || state.error != null
        ? 'Import needs a check'
        : state.acquisitionFinished && state.savingMessages
        ? 'Processing saved messages'
        : automatic || state.waiting
        ? 'Importing your history'
        : 'Ready to resume';
    return Container(
      padding: const EdgeInsets.all(AppSpace.lg),
      decoration: BoxDecoration(
        color: BambooInk.slate,
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: BambooFonts.heading(19, color: BambooInk.onSlate)),
          const SizedBox(height: AppSpace.sm),
          Text(
            state.importedThrough == null
                ? 'Nothing imported yet'
                : 'Imported through ${_day(state.importedThrough!.subtract(const Duration(milliseconds: 1)), year: true)}',
            style: BambooFonts.ui(14, color: BambooInk.onSlate),
          ),
          if (state.currentWindow case final window?) ...[
            const SizedBox(height: AppSpace.xs),
            Text(
              '${_rangeVerb(window)} ${_range(window)}',
              style: BambooFonts.ui(13, color: BambooInk.onSlateSubtle),
            ),
          ],
          if (automatic) ...[
            const SizedBox(height: AppSpace.sm),
            Text(
              'Messages are saved as Shortcuts runs. PandaPay processes them '
              'automatically and keeps its progress if iOS pauses the work.',
              style: BambooFonts.ui(12, color: BambooInk.onSlateSubtle),
            ),
          ],
          const SizedBox(height: AppSpace.xs),
          Text(
            '$done of $total ${state.activeJob?['kind'] == 'history' ? 'months' : 'date windows'} done',
            style: BambooFonts.ui(12, color: BambooInk.onSlateSubtle),
          ),
          if (state.error ?? state.stopReason case final reason?) ...[
            const SizedBox(height: AppSpace.sm),
            Text(reason, style: BambooFonts.ui(13, color: BambooInk.lime)),
          ],
          const SizedBox(height: AppSpace.sm),
          Text(
            '${_messages(counts.saved)} read'
            ' · ${counts.processed} processed'
            '${counts.review > 0 ? ' · ${counts.review} to review' : ''}',
            style: BambooFonts.ui(13, color: BambooInk.onSlateSubtle),
          ),
          if (!state.paused && state.activeJob?['kind'] == 'history') ...[
            const SizedBox(height: AppSpace.xs),
            Text(
              'Runs in Shortcuts. You can switch apps; progress stays on '
              'your Lock Screen.',
              key: const ValueKey('import-runs-in-shortcuts'),
              style: BambooFonts.ui(12, color: BambooInk.onSlateSubtle),
            ),
          ],
          const SizedBox(height: AppSpace.lg),
          LinearProgressIndicator(
            value: state.coverage ?? (total == 0 ? null : done / total),
            color: BambooInk.lime,
            backgroundColor: BambooInk.slateHairline,
            borderRadius: BorderRadius.circular(6),
          ),
          const SizedBox(height: AppSpace.lg),
          if (!automatic)
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: BambooInk.lime,
                foregroundColor: BambooInk.slate,
                minimumSize: const Size.fromHeight(46),
                textStyle: BambooFonts.ui(14, weight: FontWeight.w700),
              ),
              // Local processing and external acquisition have separate
              // actions. An active or already searched range is never reissued.
              onPressed:
                  _busy ||
                      !_sharingConfirmed ||
                      (!controller.canRetryProcessing &&
                          !controller.canResumeImport)
                  ? null
                  : () => _run(
                      controller.canRetryProcessing
                          ? controller.refresh
                          : _launch,
                    ),
              child: Text(
                controller.canRetryProcessing
                    ? 'Retry processing'
                    : 'Resume import',
              ),
            ),
          Wrap(
            spacing: AppSpace.sm,
            children: [
              if (automatic)
                TextButton(
                  style: TextButton.styleFrom(
                    foregroundColor: BambooInk.onSlate,
                  ),
                  onPressed: _busy
                      ? null
                      : () => _run(() => controller.control('pause')),
                  child: const Text('Pause'),
                ),
              TextButton(
                style: TextButton.styleFrom(
                  foregroundColor: BambooInk.onSlateSubtle,
                ),
                onPressed: _busy
                    ? null
                    : () => _run(() => controller.control('stop')),
                child: const Text('Stop'),
              ),
              if (state.partial && state.missingSenders == 0)
                TextButton(
                  style: TextButton.styleFrom(
                    foregroundColor: BambooInk.onSlate,
                  ),
                  onPressed: _busy
                      ? null
                      : () => _run(() => controller.control('split')),
                  child: const Text('Split busy dates'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  void _help(BuildContext context) {
    FocusManager.instance.primaryFocus?.unfocus();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: BambooInk.paper,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.xl),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Connect your Shortcuts',
                  style: BambooFonts.heading(22, color: BambooInk.ink900),
                ),
                const SizedBox(height: AppSpace.lg),
                Text(
                  'Live messages',
                  style: BambooFonts.heading(16, color: BambooInk.ink900),
                ),
                Text(
                  'Use Capture Incoming SMS in PandaPay. Pass the incoming message’s body, sender and date. Current Date uses Estimated date evidence.',
                  style: BambooFonts.ui(13, color: BambooInk.ink700),
                ),
                const SizedBox(height: AppSpace.lg),
                Text(
                  'History',
                  style: BambooFonts.heading(16, color: BambooInk.ink900),
                ),
                Text(
                  'Name it PANDAPAY SMS HISTORY. Save Shortcut Input as Import request. Begin → Window Start / End → Find Messages (Limit off) → Count → Repeat each message with Capture PandaPay History SMS as Text → Finish PandaPay History Import with the count. Pass the same request throughout, plus each message’s body and original date. Map Repeat Item → Message → Sender to Sender (text). Use the text-only action; it has no Person field. History Capture does not need Repeat Index. Keep Stop and Output set to the Finish result. PandaPay returns automatically between months.',
                  style: BambooFonts.ui(13, color: BambooInk.ink700),
                ),
                const SizedBox(height: AppSpace.lg),
                Text(
                  'Optional daily check',
                  style: BambooFonts.heading(16, color: BambooInk.ink900),
                ),
                Text(
                  'Time of Day → Prepare PandaPay SMS Catch-up → run a background copy of your history shortcut with its output when nonempty. Use Capture PandaPay History SMS as Text and Finish PandaPay SMS Window in that copy to keep PandaPay in the background. The older Window Capture remains compatible with its existing Repeat Index mapping.',
                  style: BambooFonts.ui(13, color: BambooInk.ink700),
                ),
                const SizedBox(height: AppSpace.lg),
                Text(
                  'Financial messages use the same checks and account sync as Android. Security codes are excluded. A space trigger misses messages without spaces, and history depends on what Messages returns.',
                  style: BambooFonts.ui(12, color: BambooInk.ink700),
                ),
                const SizedBox(height: AppSpace.md),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(
                    'Done',
                    style: BambooFonts.ui(14, color: BambooInk.jade),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class SmsSetupPanel extends StatelessWidget {
  final Widget child;
  const SmsSetupPanel({super.key, required this.child});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(AppSpace.lg),
    decoration: BoxDecoration(
      color: BambooInk.glassFillOnPaper,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      border: Border.all(color: BambooInk.hairlineOnPaper),
    ),
    child: child,
  );
}

/// One-tap install of PandaPay's Shortcuts. Hidden until a link is set, so
/// nobody sees a button that goes nowhere.
class IosShortcutInstallPanel extends StatelessWidget {
  final String historyLink;
  final String liveLink;
  final Future<bool> Function(Uri uri)? open;

  /// Once live alerts are working the live button is no longer needed; when
  /// they go quiet it offers to turn them back on.
  final LiveAlertHealth? liveHealth;
  const IosShortcutInstallPanel({
    super.key,
    this.historyLink = IosShortcutLinks.history,
    this.liveLink = IosShortcutLinks.live,
    this.open,
    this.liveHealth,
  });

  Future<void> _open(BuildContext context, Uri uri) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final opened =
        await (open ??
            (u) => launchUrl(u, mode: LaunchMode.externalApplication))(uri);
    if (!opened) {
      messenger?.showSnackBar(
        const SnackBar(content: Text('Couldn’t open Shortcuts. Try again.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final history = IosShortcutLinks.parse(historyLink);
    final live = liveHealth == LiveAlertHealth.working
        ? null
        : IosShortcutLinks.parse(liveLink);
    if (history == null && live == null) return const SizedBox.shrink();
    ButtonStyle style(bool primary) => FilledButton.styleFrom(
      backgroundColor: primary ? BambooInk.slate : BambooInk.paper,
      foregroundColor: primary ? BambooInk.lime : BambooInk.ink900,
      side: primary ? null : const BorderSide(color: BambooInk.hairlineOnPaper),
      minimumSize: const Size.fromHeight(46),
      textStyle: BambooFonts.ui(14, weight: FontWeight.w700),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(top: AppSpace.md),
      child: SmsSetupPanel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.bolt_rounded, color: BambooInk.jade),
                const SizedBox(width: AppSpace.md),
                Expanded(
                  child: Text(
                    'PandaPay shortcuts',
                    style: BambooFonts.heading(16, color: BambooInk.ink900),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpace.xs),
            Text(
              'Add them in one tap. Shortcuts opens and asks you to confirm.',
              style: BambooFonts.ui(12.5, color: BambooInk.ink700),
            ),
            if (history != null) ...[
              const SizedBox(height: AppSpace.md),
              FilledButton.icon(
                key: const ValueKey('add-history-shortcut'),
                style: style(true),
                onPressed: () => _open(context, history),
                icon: const Icon(Icons.add_rounded),
                label: const Text('Add history shortcut'),
              ),
            ],
            if (live != null) ...[
              const SizedBox(height: AppSpace.sm),
              FilledButton.icon(
                key: const ValueKey('add-live-shortcut'),
                style: style(false),
                onPressed: () => _open(context, live),
                icon: const Icon(Icons.add_rounded),
                label: Text(
                  liveHealth == LiveAlertHealth.quiet
                      ? 'Turn live alerts back on'
                      : 'Add live alerts shortcut',
                ),
              ),
              const SizedBox(height: AppSpace.md),
              Text(
                'New bank SMS then reach PandaPay on their own. If Shortcuts '
                'shows an Automation switch, keep it on.',
                style: BambooFonts.ui(12, color: BambooInk.ink700),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
