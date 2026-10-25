import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/needs_review_repository.dart';
import 'package:pandapay/features/activity/needs_review_clustering.dart';

void main() {
  group('NeedsReviewClustering', () {
    test('cleanReviewSender strips carrier prefix and route suffixes', () {
      expect(cleanReviewSender('AX-axioFS-S'), 'axioFS');
      expect(cleanReviewSender('VM-HDFCBK'), 'HDFCBK');
      expect(cleanReviewSender('VK-KOTAKB-T'), 'KOTAKB');
      expect(cleanReviewSender('AD-Amazon'), 'Amazon');
      expect(cleanReviewSender('axioFS'), 'axioFS');
    });

    test('formatBundleDateSpan formats single month, multi-month and cross-year spans', () {
      expect(
        formatBundleDateSpan(DateTime(2026, 3, 1), DateTime(2026, 3, 20)),
        'Mar 2026',
      );
      expect(
        formatBundleDateSpan(DateTime(2026, 2, 10), DateTime(2026, 3, 15)),
        'Feb – Mar 2026',
      );
      expect(
        formatBundleDateSpan(DateTime(2025, 12, 1), DateTime(2026, 1, 10)),
        'Dec 2025 – Jan 2026',
      );
    });

    test('grouping 3 Axio Pay Later drawdowns produces a BundleReviewGroup with total amount and count 3', () {
      final items = [
        NeedsReviewItem(
          id: 'item-1',
          sender: 'AX-axioFS-S',
          body: 'You have availed Amazon Pay Later credit of Rs. 250.00 for order on Amazon.',
          receivedAt: DateTime(2026, 3, 10),
          kind: NeedsReviewKind.payLaterDrawdown,
        ),
        NeedsReviewItem(
          id: 'item-2',
          sender: 'AX-axioFS-S',
          body: 'You have availed Amazon Pay Later credit of Rs. 450.00 for order on Swiggy.',
          receivedAt: DateTime(2026, 3, 25),
          kind: NeedsReviewKind.payLaterDrawdown,
        ),
        NeedsReviewItem(
          id: 'item-3',
          sender: 'AX-axioFS-S',
          body: 'You have availed Amazon Pay Later credit of Rs. 100.00 for order on Uber.',
          receivedAt: DateTime(2026, 3, 5),
          kind: NeedsReviewKind.payLaterDrawdown,
        ),
      ];

      final groups = clusterReviewItems(items);

      expect(groups, hasLength(1));
      expect(groups.first, isA<BundleReviewGroup>());
      final bundle = groups.first as BundleReviewGroup;
      expect(bundle.title, 'Amazon Pay Later (Axio)');
      expect(bundle.subtitle, 'Credit line drawdowns (billed in monthly AutoPay)');
      expect(bundle.items, hasLength(3));
      expect(bundle.totalAmount, isNotNull);
      expect(bundle.totalAmount!.paise, 80000); // 250 + 450 + 100 = 800.00
      expect(bundle.isPayLater, isTrue);
      expect(bundle.earliest, DateTime(2026, 3, 5));
      expect(bundle.latest, DateTime(2026, 3, 25));

      // Items within the bundle are sorted newest first
      expect(bundle.items[0].id, 'item-2'); // Mar 25
      expect(bundle.items[1].id, 'item-1'); // Mar 10
      expect(bundle.items[2].id, 'item-3'); // Mar 5
    });

    test('single distinct message remains a SingleReviewGroup', () {
      final items = [
        NeedsReviewItem(
          id: 'single-1',
          sender: 'VM-HDFCBK',
          body: 'Rs. 999 spent on HDFC Card ending 1234 at RELIANCE DIGITAL.',
          receivedAt: DateTime(2026, 3, 15),
        ),
      ];

      final groups = clusterReviewItems(items);

      expect(groups, hasLength(1));
      expect(groups.first, isA<SingleReviewGroup>());
      final single = groups.first as SingleReviewGroup;
      expect(single.item.id, 'single-1');
    });

    test('repeating non-PayLater messages cluster into a BundleReviewGroup', () {
      final items = [
        NeedsReviewItem(
          id: 'alert-1',
          sender: 'VM-HDFCBK',
          body: 'Your weekly alert: Rs. 500 debited for mutual fund SIP. Ref 112233.',
          receivedAt: DateTime(2026, 3, 1),
        ),
        NeedsReviewItem(
          id: 'alert-2',
          sender: 'VM-HDFCBK',
          body: 'Your weekly alert: Rs. 500 debited for mutual fund SIP. Ref 445566.',
          receivedAt: DateTime(2026, 3, 8),
        ),
      ];

      final groups = clusterReviewItems(items);

      expect(groups, hasLength(1));
      expect(groups.first, isA<BundleReviewGroup>());
      final bundle = groups.first as BundleReviewGroup;
      expect(bundle.title, 'HDFCBK messages');
      expect(bundle.subtitle, 'Repeating message pattern');
      expect(bundle.isPayLater, isFalse);
      expect(bundle.items, hasLength(2));
      expect(bundle.totalAmount, isNotNull);
      expect(bundle.totalAmount!.paise, 100000);
    });

    test('overall list groups are ordered newest item first', () {
      final items = [
        // Older bundle
        NeedsReviewItem(
          id: 'b-1',
          sender: 'AX-axioFS-S',
          body: 'You have availed Amazon Pay Later credit of Rs. 100.00.',
          receivedAt: DateTime(2026, 2, 1),
          kind: NeedsReviewKind.payLaterDrawdown,
        ),
        NeedsReviewItem(
          id: 'b-2',
          sender: 'AX-axioFS-S',
          body: 'You have availed Amazon Pay Later credit of Rs. 200.00.',
          receivedAt: DateTime(2026, 2, 5),
          kind: NeedsReviewKind.payLaterDrawdown,
        ),
        // Newer single item
        NeedsReviewItem(
          id: 's-1',
          sender: 'VM-HDFCBK',
          body: 'Rs. 500 spent on Card ending 1234 on 15/03/2026.',
          receivedAt: DateTime(2026, 3, 15),
        ),
      ];

      final groups = clusterReviewItems(items);

      expect(groups, hasLength(2));
      expect(groups[0], isA<SingleReviewGroup>());
      expect((groups[0] as SingleReviewGroup).item.id, 's-1');
      expect(groups[1], isA<BundleReviewGroup>());
      expect((groups[1] as BundleReviewGroup).items, hasLength(2));
    });
  });
}
