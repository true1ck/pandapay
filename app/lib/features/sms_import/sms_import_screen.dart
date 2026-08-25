import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/needs_review_repository.dart';
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
/// (migration 0039) or from the issuer behind the matched parser pattern,
/// and files anything it can't identify in the needs-review queue rather
/// than guessing. The dropdown remains as an override for the
/// single-card case and for anyone who hasn't entered their last-4 digits
/// yet.
class SmsImportScreen extends ConsumerStatefulWidget {
  const SmsImportScreen({super.key});

  @override
  ConsumerState<SmsImportScreen> createState() => _SmsImportScreenState();
}

class _SmsImportScreenState extends ConsumerState<SmsImportScreen> {
  final _service = SmsListenerService();
  bool _permissionGranted = false;
  bool _requesting = false;
  bool _listening = false;
  String? _selectedCardId;
  final List<String> _recentLog = [];

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
            content: Text('SMS permission was not granted — auto-import needs it to read incoming bank SMS.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _requesting = false);
    }
  }

  void _startListening() {
    _service.listenForeground((sender, body) async {
      final repo = ref.read(userCardsRepositoryProvider);
      if (repo == null) return;
      try {
        final result = await repo.logTransactionFromSms(
          userCardId: _selectedCardId,
          sender: sender,
          body: body,
        );
        if (mounted) {
          setState(() {
            _recentLog.insert(
              0,
              switch ((result.parsed, result.needsReview, result.duplicate)) {
                (true, true, _) => 'Read an SMS from $sender but couldn\'t tell which card — '
                    'added to Needs Review',
                (true, _, true) => 'Already imported this SMS from $sender — skipped',
                (true, _, _) => 'Logged a transaction from SMS ($sender)',
                _ => 'Could not parse SMS from $sender — added to Needs Review',
              },
            );
          });
          if (result.parsed) {
            // Both the imported and the needs-review outcomes changed
            // server-side state worth re-reading: one moved cap/reward
            // totals, the other added a queue item Home badges.
            ref.invalidate(userCardsProvider);
            if (result.needsReview) ref.invalidate(needsReviewCountProvider);
          } else {
            // Task D-4: never silently drop an unparsed message — the raw
            // text is right here, on-device, and would otherwise vanish
            // once this screen's ephemeral _recentLog scrolls away.
            await ref
                .read(needsReviewRepositoryProvider)
                .add(
                  NeedsReviewItem(
                    id: '${sender}_${DateTime.now().microsecondsSinceEpoch}',
                    sender: sender,
                    body: body,
                    reason: result.reason,
                    receivedAt: DateTime.now(),
                  ),
                );
            ref.invalidate(needsReviewItemsProvider);
          }
        }
      } catch (e) {
        if (mounted) {
          setState(() => _recentLog.insert(0, 'SMS import failed. ${userFacingErrorMessage(e)}'));
        }
      }
    });
    setState(() => _listening = true);
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
        title: Text('SMS auto-import', style: BambooFonts.heading(17, color: BambooInk.ink900)),
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
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                icon: const Icon(Icons.upload_file_outlined),
                label: const Text('Import from an SMS backup file (one-time)'),
                onPressed: () => Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => const SmsBackupImportScreen())),
              ),
              const SizedBox(height: 16),
              const Divider(color: BambooInk.hairlineOnPaper),
              const SizedBox(height: 16),
              Text(
                'Live auto-read (Android)',
                style: BambooFonts.ui(13, weight: FontWeight.w700, color: BambooInk.ink900),
              ),
              const SizedBox(height: 8),
              if (!_permissionGranted)
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: BambooInk.slate,
                    foregroundColor: BambooInk.lime,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  onPressed: _requesting ? null : _requestPermission,
                  child: Text(_requesting ? 'Requesting…' : 'Grant SMS permission'),
                )
              else
                Text('SMS permission granted.', style: BambooFonts.ui(13.5, color: BambooInk.jade)),
              const SizedBox(height: 16),
              userCards.when(
                loading: () => const CircularProgressIndicator(),
                error: (err, _) =>
                    Text('Failed to load cards: $err', style: BambooFonts.ui(13.5, color: BambooInk.clay)),
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
                        child: Text(c.nickname?.isNotEmpty == true ? c.nickname! : c.cardName),
                      ),
                  ],
                  onChanged: (v) => setState(() => _selectedCardId = v),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Leave this empty and PandaPay works out the card from the last 4 digits in each '
                'message. Add those digits to each card (Cards → Edit) so it can. Anything it '
                'can\'t identify goes to Needs Review rather than being logged against the wrong card.',
                style: BambooFonts.ui(12.5, color: BambooInk.ink500),
              ),
              const SizedBox(height: 16),
              if (_permissionGranted && !_listening)
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: BambooInk.slate,
                    foregroundColor: BambooInk.lime,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  onPressed: _startListening,
                  child: const Text('Start listening'),
                ),
              if (_listening)
                Text(
                  'Listening for incoming SMS…',
                  style: BambooFonts.ui(13.5, color: BambooInk.ink500).copyWith(fontStyle: FontStyle.italic),
                ),
              const SizedBox(height: 16),
              Expanded(
                child: ListView(
                  children: [
                    for (final line in _recentLog)
                      Text(line, style: BambooFonts.ui(13, color: BambooInk.ink900)),
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
