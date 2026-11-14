# PandaPay issue backlog

Reported on 12 November 2026.

## 1. Splits

Review the Splits feature. See item 16 for the requested flow for splitting an existing transaction and item 17 for the Quick Add navigation issue.

## 2. Markdown documentation review and build

Review the Markdown documentation and verify the build. Confirm which document and build the note refers to, and what was reported complete in the original note “unknwon done.”

## 3. Exclude transactions from spending

Let users exclude an individual transaction from spending totals. After they choose to exclude it, ask whether to apply the same choice to other matching transactions. Offer relevant matches by merchant or tag, such as `Family`, and apply the change to those matches only after the user confirms.

## 4. Profile page

Address the Profile page. Confirm the requested changes before implementation.

## 5. Detect cheques, NEFT, and other payment types

Detect additional transaction types, including cheques and NEFT transfers. Use the detected payment type and category to offer relevant actions or adjust the spending treatment automatically where appropriate. Confirm which cases should trigger an automatic reduction and which should prompt the user.

## 6. Deploy and verify the release

Deploy the release and verify that the affected app and backend flows work in the deployed environment.

## 7. Mark required fields and validate every form

Mark required fields with an asterisk across the app. If a user attempts to submit or continue with missing required input, keep the action from proceeding and highlight the missing fields with a red border. Show the feedback even when the action appears inactive so users can tell what they need to fill in.

## 8. Fix the Subscriptions page UI and accuracy

Compare the standalone Subscriptions page with the screen opened from the subscription icon on Home. Bring the standalone page up to at least the same data accuracy and verify that both views label active, paused, and historical subscriptions consistently.

## 9. Make the Home Money Out transaction list collapsible

Let users expand or collapse the transaction list in the Money Out section of Home.

## 10. Test bank statement detection across banks

Run representative bank statements from multiple banks through the import flow. Compare the detected transactions and their details against the source statements and record any misses, duplicates, or incorrect results by bank.

## 11. Redesign the “Accounts and cards we found” page

Redesign the page while preserving its existing actions and behavior.

## 12. Add themed icons for known brands

Show recognizable icons for known brands. Integrate them with the app theme and keep the palette restrained. [Screenshot](https://media.discordapp.net/attachments/1254147327153799222/1570176201606045858/Screenshot_2026-11-12_at_2.08.31_AM.png?ex=6af6ccca&is=6af57b4a&hm=816db031e031c6af7b30567611e1f5c51a6896caf109d6ab061eca02a5cec455&=&format=webp&quality=lossless&width=294&height=640)

## 13. Add verified transactions from in-app QR payments

When a user scans a payment QR code from PandaPay, identify the merchant accurately and show relevant payment recommendations. Verify the payment outcome and add the transaction automatically only after confirmed success. A failed or unconfirmed payment should create no transaction. If the same successful payment is captured again, it should still appear only once.

## 14. Reflect edits immediately and verify background sync

Show a loading indicator when a user saves an edit from any form, and keep it visible until the change appears in every affected view on the device. Sync the change to the server in the background. Verify which requests are queued on the phone and what happens if connectivity drops mid-request or a transaction is created offline. Confirm that pending changes reach the server when connectivity returns without lost or duplicate records.

## 15. Show proof for bills

Bills currently lack proof. Make supporting evidence, such as a receipt or proof of payment, available from the bill.

## 16. Split an existing transaction and fix both share options

Design a dedicated split screen that opens from an existing transaction. Verify that users can complete the split and that both share options work end to end.

## 17. Restore iPhone swipe-back navigation

Check back-swipe navigation across iPhone screens. Fix screens where the gesture fails, including Quick Add when opened from Splits. [Screenshot](https://media.discordapp.net/attachments/1254147327153799222/1570186565534220498/Screenshot_2026-11-12_at_2.50.33_AM.png?ex=6af62db1&is=6af4dc31&hm=94bc478a71786f32c6af51f7234d9a1bbcf7ba28ea8ff8f1833d7a3f00a03ab5&=&format=webp&quality=lossless&width=294&height=640)

## 18. Align payment method fields with transaction category

Adjust the width and alignment of the payment card and payment type fields. They look smaller than the transaction category control because they sit inside the Payment Method card. [Screenshot](https://media.discordapp.net/attachments/1254147327153799222/1570190161420099645/Screenshot_2026-11-12_at_2.59.22_AM.png?ex=6af6310b&is=6af4df8b&hm=b80544527cd2ed617938f62d3cc8367b9ac02a9d2534a41145c05f20b3fff266&=&format=webp&quality=lossless&width=294&height=640)

## 19. Preserve evidence after applying a new ruleset

Reproduce the reported loss of evidence when a new ruleset is applied. Verify that previously available evidence stays accessible after the ruleset update.

## 20. Make the app usable offline

The app currently depends on the server to work. Allow users to access data already on the phone and add transactions without connectivity. Verify that the app remains usable while the server is unreachable and that offline changes sync when it becomes available again. See item 14 for queue and retry verification.

## 21. Optimize the backend

Measure backend performance, identify the slowest or most resource-intensive operations, and verify improvements against the baseline.

## Additional screenshots from the original notes

The original notes included these two screenshots alongside items 1–11. [1:41 a.m. screenshot](https://media.discordapp.net/attachments/1254147327153799222/1570170380184985610/Screenshot_2026-11-12_at_1.41.58_AM.png?ex=6af6c75e&is=6af575de&hm=32878fa32bd3a9f1467fff1f3cccddac792495f779e51f0dcb4a1ae8cd045b52&=&format=webp&quality=lossless&width=294&height=640), [1:59 a.m. screenshot](https://media.discordapp.net/attachments/1254147327153799222/1570173774572032103/Screenshot_2026-11-12_at_1.59.42_AM.png?ex=6af6ca88&is=6af57908&hm=2b4c34df7ee525f9de6bd08eb935cdcfbf6ac190c10c605984b19451ab191ecf&=&format=webp&quality=lossless&width=294&height=640)
