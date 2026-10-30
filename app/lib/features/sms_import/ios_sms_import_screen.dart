import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import 'ios_sms_intake_controller.dart';
import 'ios_sms_intake_providers.dart';
import 'ios_sms_intake_service.dart';
import 'ios_sms_sharing_setup.dart';

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
                          state.enabled
                              ? 'Enabled on this iPhone'
                              : 'Connect your incoming-message shortcut',
                          style: BambooFonts.ui(12, color: BambooInk.ink700),
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
                    'Import your history',
                    style: BambooFonts.heading(18, color: BambooInk.ink900),
                  ),
                  const SizedBox(height: AppSpace.md),
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
                    style: _primaryStyle,
                    onPressed: _busy || !state.enabled || !_sharingConfirmed
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
                        : 'Months import in order. You can pause anytime.',
                    style: BambooFonts.ui(12, color: BambooInk.ink700),
                  ),
                ],
              ),
            ),
            if (_error != null || state.error != null)
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
                    'Import details',
                    style: BambooFonts.ui(13, color: BambooInk.ink700),
                  ),
                  children: [
                    for (final window in state.latestWindows)
                      ListTile(
                        dense: true,
                        title: Text(
                          DateFormat.yMMMd().format(
                            DateTime.parse(window['start'] as String).toLocal(),
                          ),
                          style: BambooFonts.ui(13, color: BambooInk.ink900),
                        ),
                        subtitle: Text(
                          '${window['state']} · ${state.countsFor([window])}\n${window['duplicates'] ?? 0} already saved · ${window['security_excluded'] ?? 0} security excluded · ${window['ignored'] ?? 0} ignored\nShortcut: ${_historyStageLabel(window['last_stage'])}${_handoffLabel(window['handoff_stage'])}',
                          style: BambooFonts.ui(12, color: BambooInk.ink700),
                        ),
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
            if (state.activeJob == null &&
                state.jobs.any((job) => job['state'] == 'complete'))
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
                        'Latest import complete\n${state.countsFor(state.latestWindows)}',
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
    final total = state.activeJob?['kind'] == 'history'
        ? state.monthCount
        : state.currentWindows.length;
    final done = state.activeJob?['kind'] == 'history'
        ? state.completedMonths
        : state.completed;
    final title = state.paused
        ? 'Import paused'
        : state.partial || state.error != null
        ? 'Import needs a check'
        : automatic
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
            '$done of $total ${state.activeJob?['kind'] == 'history' ? 'months' : 'date windows'} checked',
            style: BambooFonts.ui(13, color: BambooInk.onSlateSubtle),
          ),
          const SizedBox(height: AppSpace.sm),
          Text(
            state.countsFor(state.currentWindows),
            style: BambooFonts.ui(13, color: BambooInk.onSlateSubtle),
          ),
          if (state.partial && state.missingSenders > 0) ...[
            const SizedBox(height: AppSpace.sm),
            Text(
              '${state.missingSenders} ${state.missingSenders == 1 ? 'message arrived' : 'messages arrived'} without a sender.',
              style: BambooFonts.ui(13, color: BambooInk.onSlateSubtle),
            ),
          ],
          const SizedBox(height: AppSpace.lg),
          LinearProgressIndicator(
            value: total == 0 ? null : done / total,
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
              onPressed: _busy || state.processing || !_sharingConfirmed
                  ? null
                  : () => _run(_launch),
              child: const Text('Resume import'),
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
                  'Name it PANDAPAY SMS HISTORY. Save Shortcut Input as Import request. Begin → Window Start / End → Find Messages (Limit off) → Count → Repeat each message with Capture PandaPay History SMS → Finish PandaPay History Import with the count. Pass the same request throughout, plus each message’s body, sender text and original date. History Capture does not need Repeat Index. Keep Stop and Output set to the Finish result. PandaPay returns automatically between months.',
                  style: BambooFonts.ui(13, color: BambooInk.ink700),
                ),
                const SizedBox(height: AppSpace.lg),
                Text(
                  'Optional daily check',
                  style: BambooFonts.heading(16, color: BambooInk.ink900),
                ),
                Text(
                  'Time of Day → Prepare PandaPay SMS Catch-up → run a background copy of your history shortcut with its output when nonempty. Use Capture PandaPay History SMS and Finish PandaPay SMS Window in that copy to keep PandaPay in the background. The older Window Capture remains compatible with its existing Repeat Index mapping.',
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
