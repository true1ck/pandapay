import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import 'sms_backup_import_screen.dart';
import 'sms_consent_screen.dart';
import 'sms_listener_service.dart';

/// UA-5.3 (Chunk 31): permission-request UI + the screen that wires the
/// (unverified — see sms_listener_service.dart) live SMS listener to
/// (verified — curl'd against live Postgres) POST /transactions/from-sms.
///
/// Card selection is now OPTIONAL. This screen used to refuse to start
/// listening until the user picked a card, and then logged every incoming
/// SMS against that one card regardless of which card the message was
/// actually about — correct only for someone with a single card, and
/// quietly wrong for everyone else.
///
/// The server resolves the card per message now, from `user_cards.last4`
/// (migration 0039) or from the issuer behind the matched parser pattern. If
/// a valid spend cannot be safely tied to one card, it is still recorded as a
/// cardless spend so Spending never depends on a manual review step. The dropdown remains as an override for the
/// single-card case and for anyone who hasn't entered their last-4 digits
/// yet.
class SmsImportScreen extends ConsumerStatefulWidget {
  const SmsImportScreen({super.key});

  @override
  ConsumerState<SmsImportScreen> createState() => _SmsImportScreenState();
}

class _SmsImportScreenState extends ConsumerState<SmsImportScreen> {
  final _service = SmsListenerService();
  late final AppLifecycleListener _lifecycleListener;
  bool _permissionGranted = false;
  bool _requesting = false;
  bool _listening = false;
  bool _syncingInbox = false;
  String? _selectedCardId;
  String? _syncMessage;
  String? _error;
  final List<String> _recentLog = [];

  @override
  void initState() {
    super.initState();
    // Permission may have been granted before this screen was opened, or in
    // Android Settings while the screen was already mounted. Reading the
    // current OS state here keeps the live-import controls truthful instead
    // of leaving the user on a dead-looking permission prompt.
    _lifecycleListener = AppLifecycleListener(onResume: _refreshPermission);
    unawaited(_refreshPermission());
  }

  @override
  void dispose() {
    _lifecycleListener.dispose();
    super.dispose();
  }

  Future<void> _refreshPermission() async {
    final granted = await _service.hasPermissions();
    if (!mounted || granted == _permissionGranted) return;
    setState(() => _permissionGranted = granted);
  }

  /// F4: an explicit consent/declaration step now runs before the OS
  /// permission dialog (previously this went straight to
  /// `requestPermissions()`) — see sms_consent_screen.dart's doc-comment.
  Future<void> _requestPermission() async {
    final consented = await Navigator.of(
      context,
    ).push<bool>(MaterialPageRoute(builder: (_) => const SmsConsentScreen()));
    if (consented != true || !mounted) return;

    setState(() => _requesting = true);
    try {
      final granted = await _service.requestPermissions();
      setState(() => _permissionGranted = granted);
      if (!granted && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'SMS permission was not granted — auto-import needs it to read incoming bank SMS.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _requesting = false);
    }
  }

  Future<void> _startListening() async {
    if (_syncingInbox) return;
    setState(() {
      _syncingInbox = true;
      _error = null;
      _syncMessage = null;
    });
    final controller = ref.read(smsAutoImportProvider);
    try {
      // Permission can be revoked in Android Settings while this page is
      // open. Do not show a false "Listening" state in that case.
      if (!await _service.hasPermissions()) {
        throw StateError('SMS permission is no longer granted. Enable it in Android Settings and try again.');
      }
      controller.setCardOverride(_selectedCardId);
      await controller.start();
      final summary = await controller.syncExistingInbox();
      if (!mounted) return;
      setState(() {
        _listening = true;
        _syncingInbox = false;
        _syncMessage = summary.scanned == 0
            ? 'No transaction SMS found in the device inbox.'
            : 'Scanned ${summary.scanned} SMS · ${summary.imported} new spends · '
                '${summary.duplicates} already tracked'
                '${summary.needsReview == 0 ? '' : ' · ${summary.needsReview} need review'}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _syncingInbox = false;
        _error = 'Could not scan existing SMS. $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final userCards = ref.watch(userCardsProvider);

    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text(
          'SMS auto-import',
          style: BambooFonts.heading(17, color: BambooInk.ink900),
        ),
      ),
      body: AppBackground(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Automatically log spends from your bank\'s SMS alerts instead of '
                'entering every transaction by hand. Requires SMS permission.',
                style: BambooFonts.ui(13.5, color: BambooInk.ink500),
              ),
              const SizedBox(height: 16),
              // F4: one-time backup-file import — always available, independent
              // of the live auto-read permission/listener above (per the plan's
              // explicit "always available" requirement).
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: BambooInk.ink900,
                  side: const BorderSide(color: BambooInk.hairlineOnPaper),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                icon: const Icon(Icons.upload_file_outlined),
                label: const Text('Import from an SMS backup file (one-time)'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const SmsBackupImportScreen(),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Divider(color: BambooInk.hairlineOnPaper),
              const SizedBox(height: 16),
              Text(
                'Live auto-read (Android)',
                style: BambooFonts.ui(
                  13,
                  weight: FontWeight.w700,
                  color: BambooInk.ink900,
                ),
              ),
              const SizedBox(height: 8),
              if (!_permissionGranted)
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: BambooInk.slate,
                    foregroundColor: BambooInk.lime,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  onPressed: _requesting ? null : _requestPermission,
                  child: Text(
                    _requesting ? 'Requesting…' : 'Grant SMS permission',
                  ),
                )
              else
                Text(
                  'SMS permission granted.',
                  style: BambooFonts.ui(13.5, color: BambooInk.jade),
                ),
              const SizedBox(height: 16),
              userCards.when(
                loading: () => const CircularProgressIndicator(),
                error: (err, _) => Text(
                  'Failed to load cards: $err',
                  style: BambooFonts.ui(13.5, color: BambooInk.clay),
                ),
                data: (cards) => DropdownButton<String>(
                  hint: Text(
                    'Always use one card? (optional)',
                    style: BambooFonts.ui(13.5, color: BambooInk.ink500),
                  ),
                  value: _selectedCardId,
                  style: BambooFonts.ui(14.5, color: BambooInk.ink900),
                  items: [
                    for (final c in cards)
                      DropdownMenuItem(
                        value: c.id,
                        child: Text(
                          c.nickname?.isNotEmpty == true
                              ? c.nickname!
                              : c.cardName,
                        ),
                      ),
                  ],
                  onChanged: (v) => setState(() => _selectedCardId = v),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Leave this empty and PandaPay works out the card from the last 4 digits in each '
                'message. Add those digits to each card (Cards → Edit) for card-level rewards. '
                'If a message has no safe card match, the spend is still logged without attaching '
                'it to the wrong card.',
                style: BambooFonts.ui(12.5, color: BambooInk.ink500),
              ),
              const SizedBox(height: 16),
              if (_permissionGranted && !_listening)
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: BambooInk.slate,
                    foregroundColor: BambooInk.lime,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  onPressed: _syncingInbox ? null : _startListening,
                  child: _syncingInbox
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Start listening and scan existing SMS'),
                ),
              if (_listening)
                Text(
                  'Listening for incoming SMS…',
                  style: BambooFonts.ui(
                    13.5,
                    color: BambooInk.ink500,
                  ).copyWith(fontStyle: FontStyle.italic),
                ),
              if (_syncMessage != null) ...[
                const SizedBox(height: 8),
                Text(
                  _syncMessage!,
                  style: BambooFonts.ui(12.5, color: BambooInk.jade),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: BambooFonts.ui(12.5, color: BambooInk.clay),
                ),
              ],
              const SizedBox(height: 16),
              Expanded(
                child: ListView(
                  children: [
                    for (final line in _recentLog)
                      Text(
                        line,
                        style: BambooFonts.ui(13, color: BambooInk.ink900),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
