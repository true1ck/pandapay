import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/design/party_avatar.dart';
import 'package:pandapay/features/account/member_avatar.dart';
import 'package:pandapay/features/shared_expenses/ui/shared_components.dart';

void main() {
  Future<void> show(WidgetTester t, SharedAvatar a) =>
      t.pumpWidget(MaterialApp(home: Scaffold(body: a)));

  testWidgets('joined person gets their avatar, others keep the tile', (t) async {
    await show(t, const SharedAvatar(name: 'Asha', profileId: 'p1'));
    expect(find.byType(MemberAvatar), findsOneWidget);
    expect(find.byType(PartyAvatar), findsNothing);

    await show(t, const SharedAvatar(name: 'Asha'));
    expect(find.byType(PartyAvatar), findsOneWidget);
    expect(find.byType(MemberAvatar), findsNothing);

    await show(t, const SharedAvatar(name: 'Trip', group: true, profileId: 'p1'));
    expect(find.byType(MemberAvatar), findsNothing);
  });
}
