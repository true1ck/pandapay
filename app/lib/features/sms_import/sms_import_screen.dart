import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import 'sms_listener_service.dart';

/// UA-5.3 (Chunk 31): permission-request UI + the screen that wires the
/// (unverified — see sms_listener_service.dart) live SMS listener to
/// (verified — curl'd against live Postgres) POST /transactions/from-sms.
///
/// A parsed SMS still needs a `userCardId` (the parser extracts amount/
/// merchant/last4/date, not which owned card it belongs to — see
/// UserCardsRepository.logTransactionFromSms's doc comment), so this
/// screen asks the user to pick a card once permission is granted and
/// keeps using that choice for `_selectedCardId` until changed; it does
/// NOT attempt to auto-resolve by last4 since `user_cards` carries no
/// last4 column in this schema.
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

  Future<void> _requestPermission() async {
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
    if (_selectedCardId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pick a card first — a parsed SMS needs to know which card to log it against.')),
      );
      return;
    }
    _service.listenForeground((sender, body) async {
      final repo = ref.read(userCardsRepositoryProvider);
      if (repo == null) return;
      try {
        final result = await repo.logTransactionFromSms(
          userCardId: _selectedCardId!,
          sender: sender,
          body: body,
        );
        if (mounted) {
          setState(() {
            _recentLog.insert(
              0,
              result.parsed ? 'Logged a transaction from SMS ($sender)' : 'Could not parse SMS from $sender (${result.reason})',
            );
          });
          if (result.parsed) ref.invalidate(userCardsProvider);
        }
      } catch (e) {
        if (mounted) {
          setState(() => _recentLog.insert(0, 'SMS import failed: $e'));
        }
      }
    });
    setState(() => _listening = true);
  }

  @override
  Widget build(BuildContext context) {
    final userCards = ref.watch(userCardsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('SMS auto-import')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Automatically log spends from your bank\'s SMS alerts instead of '
              'entering every transaction by hand. Requires SMS permission.',
            ),
            const SizedBox(height: 16),
            if (!_permissionGranted)
              ElevatedButton(
                onPressed: _requesting ? null : _requestPermission,
                child: Text(_requesting ? 'Requesting…' : 'Grant SMS permission'),
              )
            else
              const Text('SMS permission granted.', style: TextStyle(color: Colors.green)),
            const SizedBox(height: 16),
            userCards.when(
              loading: () => const CircularProgressIndicator(),
              error: (err, _) => Text('Failed to load cards: $err'),
              data: (cards) => DropdownButton<String>(
                hint: const Text('Log parsed SMS against which card?'),
                value: _selectedCardId,
                items: [
                  for (final c in cards)
                    DropdownMenuItem(value: c.id, child: Text(c.nickname?.isNotEmpty == true ? c.nickname! : c.cardName)),
                ],
                onChanged: (v) => setState(() => _selectedCardId = v),
              ),
            ),
            const SizedBox(height: 16),
            if (_permissionGranted && !_listening)
              ElevatedButton(onPressed: _startListening, child: const Text('Start listening')),
            if (_listening) const Text('Listening for incoming SMS…', style: TextStyle(fontStyle: FontStyle.italic)),
            const SizedBox(height: 16),
            Expanded(
              child: ListView(
                children: [for (final line in _recentLog) Text(line)],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
