import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/needs_review_repository.dart';

/// ui-spec.md F4 SMS Import — the one-time backup-file import path the
/// plan flags as missing ("always available, independent of the auto-read
/// toggle"). `sms_import_batches` exists (0006_ingest.sql) with counters
/// only — nothing wrote to it before this pass.
///
/// Reuses the SAME parser the live listener already calls
/// (POST /transactions/from-sms via UserCardsRepository.logTransactionFromSms)
/// once per message, batched — per the plan's explicit "reuse the same
/// parser... batch it rather than building a second parser" instruction —
/// then records the summary via POST /sms-import-batches.
///
/// Judgment call: Android SMS-backup-file parsing (typically an XML export
/// from a backup app) needs real file access. `file_picker` is not a
/// pubspec dependency and this pass has no Flutter SDK to verify a newly
/// added native plugin compiles (see PROGRESS.md) — so file selection is
/// STUBBED with a small fixed set of sample "backup" messages rather than
/// reading a real file, same scope-down reasoning as the PDF import
/// screen. The per-message parse/log calls that follow are real, not
/// stubbed — this demonstrates the actual batch-write path end to end.
class SmsBackupImportScreen extends ConsumerStatefulWidget {
  const SmsBackupImportScreen({super.key});

  @override
  ConsumerState<SmsBackupImportScreen> createState() => _SmsBackupImportScreenState();
}

// Stand-in for messages that would come from a real parsed backup-file XML.
const _sampleBackupMessages = [
  ('VM-HDFCBK', 'Rs.499.00 spent on HDFC Bank Card x1234 at AMAZON on 01-01-24'),
  ('AX-AxisBk', 'INR 1,250.00 spent on Axis Bank Card XX5678 at SWIGGY on 03-01-24'),
  ('unknown-sender', 'This is not a bank message and will fail to parse.'),
];

class _SmsBackupImportScreenState extends ConsumerState<SmsBackupImportScreen> {
  String? _selectedCardId;
  bool _picked = false;
  bool _importing = false;
  int? _messageCount;
  int? _parsedCount;
  int? _failedCount;

  Future<void> _runImport() async {
    final userCardsRepo = ref.read(userCardsRepositoryProvider);
    final importRepo = ref.read(importRepositoryProvider);
    if (userCardsRepo == null || importRepo == null || _selectedCardId == null) return;

    setState(() => _importing = true);
    var parsed = 0;
    var failed = 0;
    try {
      for (final (sender, body) in _sampleBackupMessages) {
        try {
          final result = await userCardsRepo.logTransactionFromSms(
            userCardId: _selectedCardId!,
            sender: sender,
            body: body,
          );
          if (result.parsed) {
            parsed++;
          } else {
            failed++;
            // Task D-4: same "never silently drop" fix as the live listener
            // — a batch import's failures are just as real as one-at-a-time
            // failures, and this loop already has the raw text in hand.
            await ref.read(needsReviewRepositoryProvider).add(NeedsReviewItem(
                  id: '${sender}_${DateTime.now().microsecondsSinceEpoch}',
                  sender: sender,
                  body: body,
                  reason: result.reason,
                  receivedAt: DateTime.now(),
                ));
          }
        } catch (_) {
          failed++;
        }
      }
      if (failed > 0) ref.invalidate(needsReviewItemsProvider);
      await importRepo.recordSmsImportBatch(
        messageCount: _sampleBackupMessages.length,
        parsedCount: parsed,
        failedCount: failed,
      );
      ref.invalidate(userCardsProvider);
      ref.invalidate(smsImportBatchesProvider);
      if (mounted) {
        setState(() {
          _messageCount = _sampleBackupMessages.length;
          _parsedCount = parsed;
          _failedCount = failed;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(e))));
      }
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final userCards = ref.watch(userCardsProvider);
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Import SMS backup file')),
      body: Padding(
        padding: const EdgeInsets.all(AppSpace.lg),
        child: _messageCount != null
            ? EmptyState(
                icon: Icons.check_circle_outline_rounded,
                title: 'Import complete',
                message: '$_messageCount messages · $_parsedCount logged · $_failedCount could not be parsed.',
                action: OutlinedButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Done')),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'This is a one-time import from an SMS backup file (e.g. exported from your phone\'s backup '
                    'app) — separate from, and always available regardless of, the live auto-read listener. '
                    'Parsing happens on-device using the same parser the live listener uses.',
                    style: textTheme.bodyMedium,
                  ),
                  const SizedBox(height: AppSpace.lg),
                  if (!_picked)
                    ElevatedButton.icon(
                      icon: const Icon(Icons.upload_file_outlined),
                      label: const Text('Select backup file'),
                      onPressed: () => setState(() => _picked = true),
                    )
                  else ...[
                    Container(
                      padding: const EdgeInsets.all(AppSpace.md),
                      decoration: BoxDecoration(color: AppColors.surfaceMuted, borderRadius: BorderRadius.circular(AppRadius.md)),
                      child: Text(
                        'sms_backup.xml selected — ${_sampleBackupMessages.length} messages found '
                        '(stub file contents — see this screen\'s doc-comment).',
                        style: textTheme.bodySmall?.copyWith(color: AppColors.ink500),
                      ),
                    ),
                    const SizedBox(height: AppSpace.lg),
                    userCards.when(
                      loading: () => const CircularProgressIndicator(),
                      error: (err, _) => Text(userFacingErrorMessage(err)),
                      data: (cards) => DropdownButtonFormField<String>(
                        initialValue: _selectedCardId,
                        decoration: const InputDecoration(labelText: 'Import against which card?', border: OutlineInputBorder()),
                        items: [
                          for (final c in cards)
                            DropdownMenuItem(value: c.id, child: Text(c.nickname?.isNotEmpty == true ? c.nickname! : c.cardName)),
                        ],
                        onChanged: (v) => setState(() => _selectedCardId = v),
                      ),
                    ),
                    const SizedBox(height: AppSpace.lg),
                    ElevatedButton(
                      onPressed: (_importing || _selectedCardId == null) ? null : _runImport,
                      child: Text(_importing ? 'Importing…' : 'Import messages'),
                    ),
                  ],
                ],
              ),
      ),
    );
  }
}
