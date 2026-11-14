// Refreshing data must not make a loaded screen flash a spinner.
//
// Riverpod keeps the previous value while a provider reloads, but `.when()`
// shows `loading:` anyway when the rebuild came from a changed dependency
// unless `skipLoadingOnReload: true` is passed, and `isLoading` is true during
// any refresh. Both made loaded screens blink after a save or a sync. This
// guard keeps new screens from bringing it back.
//
// A deliberate exception (a different list, such as a new filter) opts out with
// a `reload-ok: <reason>` comment inside the call.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/async_first_load.dart';

void main() {
  test('every AsyncValue.when with a loading branch keeps data on reload', () {
    final offenders = <String>[];
    final call = RegExp(r'\.(when|maybeWhen|whenOrNull)\(');
    for (final file in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      final text = file.readAsStringSync();
      for (final m in call.allMatches(text)) {
        var depth = 1;
        var i = m.end;
        while (i < text.length && depth > 0) {
          final c = text[i++];
          if (c == '(') depth++;
          if (c == ')') depth--;
        }
        final body = text.substring(m.start, i);
        if (!body.contains('loading:')) continue;
        final ok =
            RegExp(r'skipLoadingOnReload:\s*true').hasMatch(body) ||
            body.contains('reload-ok:');
        if (!ok) {
          final line = '\n'.allMatches(text.substring(0, m.start)).length + 1;
          offenders.add('${file.path.replaceAll('\\', '/')}:$line');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'Add `skipLoadingOnReload: true` (or a `reload-ok: why` comment) so a '
          'refresh does not flash a spinner over loaded data:\n'
          '${offenders.join('\n')}',
    );
  });

  test('isFirstLoad is true only before any data exists', () {
    expect(const AsyncLoading<int>().isFirstLoad, isTrue);
    expect(const AsyncData<int>(1).isFirstLoad, isFalse);
    expect(
      const AsyncLoading<int>().copyWithPrevious(const AsyncData<int>(1)).isFirstLoad,
      isFalse,
      reason: 'a refresh with data on screen is not a first load',
    );
  });

  testWidgets('a refresh and a dependency change never show the spinner again',
      (tester) async {
    final version = StateProvider<int>((ref) => 1);
    final data = FutureProvider<int>((ref) async {
      final v = ref.watch(version); // a changed dependency = a "reload"
      await Future<void>.delayed(const Duration(milliseconds: 50));
      return v;
    });
    var spinnerFrames = 0;
    late WidgetRef captured;

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) {
              captured = ref;
              return ref
                  .watch(data)
                  .when(
                    skipLoadingOnReload: true,
                    loading: () {
                      spinnerFrames++;
                      return const Text('loading');
                    },
                    error: (e, _) => Text('error $e'),
                    data: (v) => Text('value $v'),
                  );
            },
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('value 1'), findsOneWidget);
    final firstLoadFrames = spinnerFrames; // the very first load may show it

    captured.invalidate(data); // refresh (a save)
    await tester.pump();
    expect(find.text('value 1'), findsOneWidget, reason: 'old data stays');
    await tester.pump(const Duration(milliseconds: 100));

    captured.read(version.notifier).state = 2; // reload (dependency change)
    await tester.pump();
    expect(find.text('value 1'), findsOneWidget, reason: 'old data stays');
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('value 2'), findsOneWidget);

    expect(spinnerFrames, firstLoadFrames, reason: 'no spinner after first load');
  });
}
