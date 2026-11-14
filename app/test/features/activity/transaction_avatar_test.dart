import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/design/merchant_brand.dart';
import 'package:pandapay/app/design/merchant_brand_tile.dart';
import 'package:pandapay/app/design/party_avatar.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/activity/transaction_avatar.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

TransactionEntry _txn(
  String merchant, {
  TxnEntryKind kind = TxnEntryKind.spend,
  String? transferType,
  String? categoryName,
  String status = 'active',
  String? note,
}) => TransactionEntry(
  id: merchant,
  transferType: transferType,
  amount: Money.fromRupees(100),
  occurredAt: DateTime(2026, 11, 10, 10),
  merchantName: merchant,
  categoryName: categoryName,
  tags: const [],
  userCardId: 'uc1',
  entryKind: kind,
  source: 'sms',
  status: status,
  note: note,
);

void main() {
  group('what the leading tile stands for', () {
    test(
      'a P2P transfer is a person, never a brand, even if the name matches',
      () {
        for (final name in [
          'Transfer to RAMESH KUMAR',
          'Transfer to Swiggy Delivery',
        ]) {
          final entry = _txn(name);
          expect(transactionAvatarKind(entry), AvatarKind.person, reason: name);
          expect(transactionBrand(entry), isNull, reason: name);
        }
      },
    );

    test('a known merchant gets its logo', () {
      final entry = _txn('Swiggy Instamart');
      expect(transactionBrand(entry), MerchantBrand.swiggy);
      expect(transactionAvatarKind(entry), AvatarKind.business);
    });

    test('a company or shop with no logo gets the shop, not a person', () {
      for (final name in [
        'SHREE GANESH KIRANA STORES',
        'ACME TECHNOLOGIES PVT LTD',
        'Dr Mehta Clinic',
      ]) {
        final entry = _txn(name);
        expect(transactionBrand(entry), isNull, reason: name);
        expect(transactionAvatarKind(entry), AvatarKind.business, reason: name);
      }
    });

    test(
      'card bills, wallet top-ups and own-account moves say how money moved',
      () {
        expect(
          transactionAvatarKind(
            _txn(
              'HDFC Credit Card Bill',
              kind: TxnEntryKind.transfer,
              transferType: 'card_bill',
            ),
          ),
          AvatarKind.card,
        );
        expect(
          transactionAvatarKind(
            _txn(
              'Paytm Wallet',
              kind: TxnEntryKind.transfer,
              transferType: 'wallet',
            ),
          ),
          AvatarKind.wallet,
        );
        expect(
          transactionAvatarKind(_txn('Savings', kind: TxnEntryKind.transfer)),
          AvatarKind.transfer,
        );
      },
    );

    test('income is money in, an investment keeps its own mark', () {
      expect(
        transactionAvatarKind(_txn('ACME PVT LTD', kind: TxnEntryKind.income)),
        AvatarKind.moneyIn,
      );
      final invest = _txn('Zerodha', kind: TxnEntryKind.investment);
      expect(transactionAvatarKind(invest), AvatarKind.investment);
      expect(transactionBrand(invest), isNull);
    });

    test('a refund, a reversal and an ignored row show their status', () {
      expect(
        transactionAvatarKind(_txn('Amazon', note: '[ignored: refund]')),
        AvatarKind.refund,
      );
      expect(
        transactionAvatarKind(_txn('Amazon', note: '[ignored: reversal]')),
        AvatarKind.reversal,
      );
      expect(
        transactionAvatarKind(_txn('Amazon', status: 'ignored')),
        AvatarKind.ignored,
      );
      // ...and are not dressed as a purchase from the brand.
      expect(
        transactionBrand(_txn('Amazon', note: '[ignored: refund]')),
        isNull,
      );
    });
  });

  group('the leading tile widget', () {
    Future<void> pumpTile(WidgetTester tester, TransactionEntry entry) =>
        tester.pumpWidget(
          MaterialApp(home: Scaffold(body: transactionLeading(entry))),
        );

    testWidgets('a person row shows the person avatar', (tester) async {
      await pumpTile(tester, _txn('Transfer to RAMESH KUMAR'));
      final avatar = tester.widget<PartyAvatar>(find.byType(PartyAvatar));
      expect(avatar.kind, AvatarKind.person);
    });

    testWidgets('an unknown shop shows the shop avatar', (tester) async {
      await pumpTile(tester, _txn('SHREE GANESH KIRANA STORES'));
      final avatar = tester.widget<PartyAvatar>(find.byType(PartyAvatar));
      expect(avatar.kind, AvatarKind.business);
    });

    testWidgets('a known brand shows its logo tile instead', (tester) async {
      await pumpTile(tester, _txn('Swiggy'));
      expect(find.byType(MerchantBrandTile), findsOneWidget);
      expect(
        tester.widget<MerchantBrandTile>(find.byType(MerchantBrandTile)).brand,
        MerchantBrand.swiggy,
      );
    });
  });
}
