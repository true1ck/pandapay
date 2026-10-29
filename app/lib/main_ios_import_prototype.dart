import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'data/ios_import_prototype.dart';
import 'data/ios_import_prototype_fixtures.dart';
import 'data/local_sms_parser.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kDebugMode || !Platform.isIOS) {
    throw UnsupportedError(
      'The iOS import prototype is for Debug simulator builds only.',
    );
  }
  runApp(const MaterialApp(home: IosImportPrototypeScreen()));
}

class IosImportPrototypeScreen extends StatefulWidget {
  const IosImportPrototypeScreen({super.key});

  @override
  State<IosImportPrototypeScreen> createState() =>
      _IosImportPrototypeScreenState();
}

class _IosImportPrototypeScreenState extends State<IosImportPrototypeScreen>
    with WidgetsBindingObserver {
  static const _channel = MethodChannel('pandapay/ios_import_prototype');
  List<IosPrototypeCapture> _captures = [];
  int _historyCount = 0;
  Map<Object?, Object?>? _lastBatch;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_refresh());
  }

  Future<void> _refresh() async {
    try {
      final records =
          await _channel.invokeListMethod<Object?>('readCaptures') ?? [];
      final captures = records
          .map((r) => IosPrototypeCapture.fromMap(r as Map<Object?, Object?>))
          .toList();
      final status = await _channel.invokeMapMethod<Object?, Object?>(
        'readPrototypeStatus',
      );
      if (mounted) {
        setState(() {
          _captures = captures;
          _historyCount = status?['historyCount'] as int? ?? 0;
          _lastBatch = status?['lastBatch'] as Map<Object?, Object?>?;
          _error = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _seedHistory() async {
    try {
      await _channel.invokeMethod<int>(
        'seedHistory',
        jsonEncode(iosPrototypeHistoryFixtures()),
      );
      await _refresh();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _clearResults() async {
    await _channel.invokeMethod<void>('clearCaptures');
    await _refresh();
  }

  void _viewHistory() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => Scaffold(
          appBar: AppBar(title: const Text('100 older demo messages')),
          body: ListView.builder(
            itemCount: 100,
            itemBuilder: (context, index) {
              final message = IosPrototypeCapture.fromMap(
                iosPrototypeHistoryFixtures()[index],
              );
              return ListTile(
                title: Text('${index + 1}. ${message.sender}'),
                subtitle: Text(
                  '${message.receivedAt!.toIso8601String()}\n${message.body}',
                ),
                isThreeLine: true,
              );
            },
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final parsed = _captures.map((c) => c.parse()).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('PandaPay iOS Import Prototype')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            'Synthetic messages only · Local simulator experiment',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          const Text(
            'Seed the older demo inbox, then run “PandaPay Import Demo History” '
            'in Apple Shortcuts. This test inbox is separate from Apple Messages. '
            'Captured inputs use PandaPay’s existing Android financial parser. '
            'No account or server is used.',
          ),
          const SizedBox(height: 12),
          Text('Older demo inbox: $_historyCount messages'),
          FilledButton.tonal(
            onPressed: _seedHistory,
            child: const Text('Seed 100 older demo messages'),
          ),
          if (_historyCount > 0)
            TextButton(
              onPressed: _viewHistory,
              child: const Text('View the 100-message demo inbox'),
            ),
          const SizedBox(height: 18),
          Text(
            'Native captures: ${_captures.length}',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          Text(
            'Financial observations: ${parsed.whereType<LocalSmsObservation>().length}',
          ),
          if (_lastBatch != null)
            Text(
              'Last batch: ${_lastBatch!['scanned']} scanned · '
              '${_lastBatch!['added']} added · '
              '${_lastBatch!['duplicates']} duplicates · '
              '${_lastBatch!['sensitive']} sensitive rejected · '
              '${_lastBatch!['invalid']} invalid',
            ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _refresh,
            child: const Text('Refresh captured messages'),
          ),
          TextButton(
            onPressed: _clearResults,
            child: const Text('Clear imported synthetic results'),
          ),
          if (_error != null)
            SelectableText(_error!, style: const TextStyle(color: Colors.red)),
          const Divider(height: 32),
          for (var i = 0; i < _captures.length; i++)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _title(parsed[i]),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text('Sender: ${_captures[i].sender}'),
                    Text(
                      _captures[i].receivedAt == null
                          ? 'Original message time unavailable; capture time used'
                          : 'Original message time: ${_captures[i].receivedAt!.toIso8601String()}',
                    ),
                    if (parsed[i]?.dueDate != null)
                      Text('Due: ${parsed[i]!.dueDate!.toIso8601String()}'),
                    const SizedBox(height: 8),
                    SelectableText(_captures[i].body),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  String _title(LocalSmsObservation? observation) {
    if (observation == null) return 'Rejected or not recognized';
    final amount =
        observation.transaction?.amount ??
        observation.amountDue ??
        observation.amount;
    final merchant =
        observation.transaction?.merchantName ?? observation.billerName;
    return [
      observation.eventType.wireValue,
      if (amount != null) amount.format(),
      ?merchant,
    ].join(' · ');
  }
}
