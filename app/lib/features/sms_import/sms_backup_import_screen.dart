import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/needs_review_repository.dart';
import '../../data/sms_backup_xml_parser.dart';

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
/// Real file selection (`file_picker`) + real XML parsing
/// (`data/sms_backup_xml_parser.dart`, the "SMS Backup & Restore" app's
/// de facto standard export format) — not a stub. The per-message
/// parse/log calls were already real before this pass; this closes the
/// remaining gap (fake sample messages instead of a real file).
class SmsBackupImportScreen extends ConsumerStatefulWidget {
  const SmsBackupImportScreen({super.key});

  @override
  ConsumerState<SmsBackupImportScreen> createState() => _SmsBackupImportScreenState();
}

class _SmsBackupImportScreenState extends ConsumerState<SmsBackupImportScreen> {
  String? _selectedCardId;
  String? _fileName;
  List<BackupSmsMessage>? _messages;
  bool _importing = false;
  int? _messageCount;
  int? _parsedCount;
  int? _failedCount;
  String? _pickError;

  Future<void> _pickFile() async {
    setState(() => _pickError = null);
    final result = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['xml']);
    if (result == null || result.files.isEmpty) return;
    final picked = result.files.single;
    try {
      final bytes = await picked.readAsBytes();
      final messages = parseSmsBackupXml(String.fromCharCodes(bytes));
      if (messages.isEmpty) {
        setState(() => _pickError = "Couldn't find any messages in that file.");
        return;
      }
      setState(() {
        _fileName = picked.name;
        _messages = messages;
      });
    } on SmsBackupParseException catch (e) {
      setState(() => _pickError = e.message);
    } catch (e) {
      setState(() => _pickError = "Couldn't read that file. Try picking it again.");
    }
  }

  Future<void> _runImport() async {
    final userCardsRepo = ref.read(userCardsRepositoryProvider);
    final importRepo = ref.read(importRepositoryProvider);
    final messages = _messages;
    if (userCardsRepo == null || importRepo == null || _selectedCardId == null || messages == null) return;

    setState(() => _importing = true);
    var parsed = 0;
    var failed = 0;
    try {
      for (final (:sender, :body) in messages) {
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
        messageCount: messages.length,
        parsedCount: parsed,
        failedCount: failed,
      );
      ref.invalidate(userCardsProvider);
      ref.invalidate(smsImportBatchesProvider);
      if (mounted) {
        setState(() {
          _messageCount = messages.length;
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

    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text('Import SMS backup file', style: BambooFonts.heading(16, color: BambooInk.ink900)),
      ),
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(0.9, -0.5),
            radius: 1.3,
            colors: [BambooInk.wash, BambooInk.paper],
            stops: [0.0, 0.6],
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.lg),
          child: _messageCount != null
              ? EmptyState(
                  icon: Icons.check_circle_outline_rounded,
                  title: 'Import complete',
                  message: '$_messageCount messages · $_parsedCount logged · $_failedCount could not be parsed.',
                  action: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: BambooInk.ink900,
                      side: const BorderSide(color: BambooInk.hairlineOnPaper),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Done'),
                  ),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'This is a one-time import from an SMS backup file (e.g. exported from your phone\'s backup '
                      'app) — separate from, and always available regardless of, the live auto-read listener. '
                      'Parsing happens on-device using the same parser the live listener uses.',
                      style: BambooFonts.ui(13.5, color: BambooInk.ink500),
                    ),
                    const SizedBox(height: AppSpace.lg),
                    if (_pickError != null) ...[
                      Text(_pickError!, style: BambooFonts.ui(12.5, color: BambooInk.clay)),
                      const SizedBox(height: AppSpace.sm),
                    ],
                    if (_messages == null)
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: BambooInk.slate,
                          foregroundColor: BambooInk.lime,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          textStyle: BambooFonts.ui(14.5, weight: FontWeight.w700),
                        ),
                        icon: const Icon(Icons.upload_file_outlined),
                        label: const Text('Select backup file'),
                        onPressed: _pickFile,
                      )
                    else ...[
                      Container(
                        padding: const EdgeInsets.all(AppSpace.md),
                        decoration: BoxDecoration(color: BambooInk.paperMuted, borderRadius: BorderRadius.circular(AppRadius.md)),
                        child: Text(
                          '$_fileName selected — ${_messages!.length} messages found.',
                          style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                        ),
                      ),
                      const SizedBox(height: AppSpace.lg),
                      userCards.when(
                        loading: () => const CircularProgressIndicator(),
                        error: (err, _) => Text(userFacingErrorMessage(err), style: BambooFonts.ui(13.5, color: BambooInk.clay)),
                        data: (cards) => DropdownButtonFormField<String>(
                          initialValue: _selectedCardId,
                          style: BambooFonts.ui(14.5, color: BambooInk.ink900),
                          decoration: InputDecoration(
                            labelText: 'Import against which card?',
                            labelStyle: BambooFonts.ui(13.5, color: BambooInk.ink500),
                            filled: true,
                            fillColor: BambooInk.glassFillOnPaper,
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(16),
                              borderSide: const BorderSide(color: BambooInk.hairlineOnPaper),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(16),
                              borderSide: const BorderSide(color: BambooInk.slate, width: 1.5),
                            ),
                          ),
                          items: [
                            for (final c in cards)
                              DropdownMenuItem(value: c.id, child: Text(c.nickname?.isNotEmpty == true ? c.nickname! : c.cardName)),
                          ],
                          onChanged: (v) => setState(() => _selectedCardId = v),
                        ),
                      ),
                      const SizedBox(height: AppSpace.lg),
                      FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: BambooInk.slate,
                          foregroundColor: BambooInk.lime,
                          minimumSize: const Size.fromHeight(52),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          textStyle: BambooFonts.ui(15, weight: FontWeight.w700),
                        ),
                        onPressed: (_importing || _selectedCardId == null) ? null : _runImport,
                        child: Text(_importing ? 'Importing…' : 'Import messages'),
                      ),
                    ],
                  ],
                ),
        ),
      ),
    );
  }
}
