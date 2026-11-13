import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/design/saved_offline.dart';

void main() {
  testWidgets('snack helper shows the shared copy and the what variant', (t) async {
    late BuildContext ctx;
    await t.pumpWidget(MaterialApp(
      home: Scaffold(body: Builder(builder: (c) { ctx = c; return const SizedBox(); })),
    ));
    showSavedOfflineSnack(ctx);
    await t.pump();
    expect(find.text(savedOfflineCopy), findsOneWidget);
    expect(savedOfflineCopy, "Saved on this phone. It will sync when you're online.");
    ScaffoldMessenger.of(ctx).clearSnackBars();
    await t.pump();
    showSavedOfflineSnack(ctx, what: 'Note');
    await t.pump();
    expect(find.text("Note saved on this phone. It will sync when you're online."), findsOneWidget);
    ScaffoldMessenger.of(ctx).clearSnackBars();
    await t.pumpAndSettle();
  });
}
