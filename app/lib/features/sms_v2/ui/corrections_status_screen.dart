import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/design/app_theme.dart';
import '../../../app/providers.dart' as app;
import '../corrections/corrections_status.dart';
import '../personal/personal_merchant_aliases.dart';

/// What happened to the person's corrections, and the shop names they chose.
/// For a tester this is where "did my fix reach anyone" is answered.
class CorrectionsStatusScreen extends ConsumerStatefulWidget {
  const CorrectionsStatusScreen({super.key});

  @override
  ConsumerState<CorrectionsStatusScreen> createState() =>
      _CorrectionsStatusScreenState();
}

class _CorrectionsStatusScreenState
    extends ConsumerState<CorrectionsStatusScreen> {
  late Future<_Loaded> _future = _load();

  Future<_Loaded> _load() async {
    final namespace = ref.read(app.cacheNamespaceProvider);
    final cache = await ref.read(app.responseCacheProvider.future);
    final db = cache.financialStore.database.db;
    return _Loaded(
      namespace: namespace,
      corrections: correctionStatuses(db, namespace),
      aliases: PersonalMerchantAliases(db, namespace: namespace).load().values.toList()
        ..sort((a, b) => a.name.compareTo(b.name)),
    );
  }

  Future<void> _stopUsing(_Loaded loaded, PersonalMerchantAlias alias) async {
    final cache = await ref.read(app.responseCacheProvider.future);
    PersonalMerchantAliases(
      cache.financialStore.database.db,
      namespace: loaded.namespace,
    ).remove(alias.printedKey);
    if (mounted) setState(() => _future = _load());
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Your corrections')),
    body: FutureBuilder<_Loaded>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError || !snapshot.hasData) {
          return const Center(child: Text('Could not load your corrections.'));
        }
        final loaded = snapshot.data!;
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            Text('Shop names you chose', style: BambooFonts.heading(17, color: BambooInk.ink900)),
            const SizedBox(height: 4),
            Text(
              'Every SMS from the shop uses your name. Stopping only affects new SMS; ones already renamed keep your name until you edit them.',
              style: BambooFonts.ui(12.5, color: BambooInk.ink500),
            ),
            const SizedBox(height: 8),
            if (loaded.aliases.isEmpty)
              Text('None yet.', style: BambooFonts.ui(13.5, color: BambooInk.ink700))
            else
              for (final alias in loaded.aliases)
                ListTile(
                  key: ValueKey('alias-${alias.printedKey}'),
                  contentPadding: EdgeInsets.zero,
                  title: Text(alias.name),
                  subtitle: Text('SMS print it as ${alias.printedKey}'),
                  trailing: TextButton(
                    onPressed: () => _stopUsing(loaded, alias),
                    child: const Text('Stop using'),
                  ),
                ),
            const SizedBox(height: 20),
            Text('Corrections you made', style: BambooFonts.heading(17, color: BambooInk.ink900)),
            const SizedBox(height: 8),
            if (loaded.corrections.isEmpty)
              Text('None yet.', style: BambooFonts.ui(13.5, color: BambooInk.ink700))
            else
              for (final row in loaded.corrections)
                ListTile(
                  key: ValueKey(row.id),
                  contentPadding: EdgeInsets.zero,
                  title: Text(correctionKindWords(row.kind)),
                  subtitle: Text(
                    [
                      correctionStateWords(row),
                      if (row.detail != null &&
                          row.state != CorrectionState.keptOnPhone)
                        row.detail!,
                    ].join('\n'),
                  ),
                  isThreeLine: row.detail != null &&
                      row.state != CorrectionState.keptOnPhone,
                ),
          ],
        );
      },
    ),
  );
}

class _Loaded {
  const _Loaded({
    required this.namespace,
    required this.corrections,
    required this.aliases,
  });
  final String namespace;
  final List<CorrectionStatusRow> corrections;
  final List<PersonalMerchantAlias> aliases;
}
