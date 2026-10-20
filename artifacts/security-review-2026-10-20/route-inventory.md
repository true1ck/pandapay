# Backend API authentication inventory

Source snapshot: 2026-10-20, HEAD c2e41d8. Runtime guard behavior is discussed in the security report; a JWT middleware label is not proof that session revocation or ownership checks are complete.

## api — 170 method/path pairs

| Method | Path | Access control | Source |
|---|---|---|---|
| POST | `/acceptance-reports` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:1948](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:1948) |
| GET | `/account-summaries` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:5120](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:5120) |
| DELETE | `/account/delete-request` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:7633](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:7633) |
| POST | `/account/delete-request` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:7615](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:7615) |
| GET | `/admin/abuse-signals` | JWT + product admin DB membership | [api/src/index.js:7986](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:7986) |
| POST | `/admin/abuse-signals/:id/block` | JWT + product admin DB membership | [api/src/index.js:8009](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:8009) |
| GET | `/admin/acceptance-summary` | JWT + product admin DB membership | [api/src/index.js:8057](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:8057) |
| GET | `/admin/acceptance-summary/:merchantId` | JWT + product admin DB membership | [api/src/index.js:8098](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:8098) |
| POST | `/admin/acceptance-summary/publish` | JWT + product admin DB membership | [api/src/index.js:8137](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:8137) |
| GET | `/admin/alerts` | JWT + product admin DB membership | [api/src/index.js:2293](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:2293) |
| GET | `/admin/alerts/:id` | JWT + product admin DB membership | [api/src/index.js:2319](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:2319) |
| POST | `/admin/alerts/:id/decide` | JWT + product admin DB membership | [api/src/index.js:2364](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:2364) |
| GET | `/admin/anonymization-audit-runs` | JWT + product admin DB membership | [api/src/index.js:8492](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:8492) |
| GET | `/admin/anonymization-audit-runs/latest` | JWT + product admin DB membership | [api/src/index.js:8509](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:8509) |
| POST | `/admin/anonymization-audit-runs/run` | JWT + product admin DB membership | [api/src/index.js:8528](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:8528) |
| PUT | `/admin/billing-cycle-rules/by-card/:cardProductId` | JWT + product admin DB membership | [api/src/index.js:618](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:618) |
| POST | `/admin/cap-rules` | JWT + product admin DB membership | [api/src/index.js:519](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:519) |
| DELETE | `/admin/cap-rules/:id` | JWT + product admin DB membership | [api/src/index.js:519](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:519) |
| PUT | `/admin/cap-rules/:id` | JWT + product admin DB membership | [api/src/index.js:519](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:519) |
| POST | `/admin/card-benefits` | JWT + product admin DB membership | [api/src/index.js:564](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:564) |
| DELETE | `/admin/card-benefits/:id` | JWT + product admin DB membership | [api/src/index.js:564](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:564) |
| PUT | `/admin/card-benefits/:id` | JWT + product admin DB membership | [api/src/index.js:564](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:564) |
| GET | `/admin/card-requests` | JWT + product admin DB membership | [api/src/index.js:2066](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:2066) |
| POST | `/admin/card-requests/start-scraping` | JWT + product admin DB membership | [api/src/index.js:2100](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:2100) |
| GET | `/admin/cards` | JWT + product admin DB membership | [api/src/index.js:300](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:300) |
| POST | `/admin/cards` | JWT + product admin DB membership | [api/src/index.js:388](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:388) |
| POST | `/admin/cards/:id/status` | JWT + product admin DB membership | [api/src/index.js:841](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:841) |
| GET | `/admin/data-quality-dashboard` | JWT + product admin DB membership | [api/src/index.js:8470](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:8470) |
| GET | `/admin/effective-rate-summary` | JWT + product admin DB membership | [api/src/index.js:8190](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:8190) |
| GET | `/admin/effective-rate-summary/:cardProductId/:categoryId/samples` | JWT + product admin DB membership | [api/src/index.js:8235](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:8235) |
| GET | `/admin/error-reports` | JWT + product admin DB membership | [api/src/index.js:2150](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:2150) |
| POST | `/admin/error-reports/:id/approve` | JWT + product admin DB membership | [api/src/index.js:2183](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:2183) |
| POST | `/admin/error-reports/:id/reject` | JWT + product admin DB membership | [api/src/index.js:2265](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:2265) |
| POST | `/admin/fee-waiver-rules` | JWT + product admin DB membership | [api/src/index.js:552](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:552) |
| DELETE | `/admin/fee-waiver-rules/:id` | JWT + product admin DB membership | [api/src/index.js:552](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:552) |
| PUT | `/admin/fee-waiver-rules/:id` | JWT + product admin DB membership | [api/src/index.js:552](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:552) |
| PUT | `/admin/forex-rules/by-card/:cardProductId` | JWT + product admin DB membership | [api/src/index.js:592](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:592) |
| PUT | `/admin/fuel-surcharge-rules/by-card/:cardProductId` | JWT + product admin DB membership | [api/src/index.js:604](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:604) |
| POST | `/admin/issuers` | JWT + product admin DB membership | [api/src/index.js:323](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:323) |
| GET | `/admin/me` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:283](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:283) |
| GET | `/admin/merchant-conflicts` | JWT + product admin DB membership | [api/src/index.js:7899](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:7899) |
| POST | `/admin/merchant-conflicts/:id/resolve` | JWT + product admin DB membership | [api/src/index.js:7926](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:7926) |
| GET | `/admin/merchants` | JWT + product admin DB membership | [api/src/index.js:7715](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:7715) |
| GET | `/admin/merchants/:id` | JWT + product admin DB membership | [api/src/index.js:7770](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:7770) |
| POST | `/admin/merchants/:id/override` | JWT + product admin DB membership | [api/src/index.js:7819](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:7819) |
| POST | `/admin/merchants/:id/unpublish` | JWT + product admin DB membership | [api/src/index.js:7862](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:7862) |
| POST | `/admin/milestone-rules` | JWT + product admin DB membership | [api/src/index.js:536](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:536) |
| DELETE | `/admin/milestone-rules/:id` | JWT + product admin DB membership | [api/src/index.js:536](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:536) |
| PUT | `/admin/milestone-rules/:id` | JWT + product admin DB membership | [api/src/index.js:536](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:536) |
| POST | `/admin/notifications/broadcast` | JWT + product admin DB membership | [api/src/index.js:7053](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:7053) |
| GET | `/admin/parser-patterns` | JWT + product admin DB membership | [api/src/index.js:638](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:638) |
| POST | `/admin/parser-patterns` | JWT + product admin DB membership | [api/src/index.js:675](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:675) |
| DELETE | `/admin/parser-patterns/:id` | JWT + product admin DB membership | [api/src/index.js:798](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:798) |
| PUT | `/admin/parser-patterns/:id` | JWT + product admin DB membership | [api/src/index.js:723](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:723) |
| POST | `/admin/redemption-options` | JWT + product admin DB membership | [api/src/index.js:579](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:579) |
| DELETE | `/admin/redemption-options/:id` | JWT + product admin DB membership | [api/src/index.js:579](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:579) |
| PUT | `/admin/redemption-options/:id` | JWT + product admin DB membership | [api/src/index.js:579](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:579) |
| PUT | `/admin/reward-rules/:id` | JWT + product admin DB membership | [api/src/index.js:458](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:458) |
| GET | `/admin/scrape-runs` | JWT + product admin DB membership | [api/src/index.js:8409](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:8409) |
| GET | `/admin/source-pages/:id/snapshots` | JWT + product admin DB membership | [api/src/index.js:8436](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:8436) |
| GET | `/admin/sources` | JWT + product admin DB membership | [api/src/index.js:8286](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:8286) |
| POST | `/admin/sources` | JWT + product admin DB membership | [api/src/index.js:8315](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:8315) |
| PATCH | `/admin/sources/:id` | JWT + product admin DB membership | [api/src/index.js:8359](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:8359) |
| GET | `/admin/sources/:id/pages` | JWT + product admin DB membership | [api/src/index.js:8454](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:8454) |
| POST | `/analytics/events` | Anonymous write allowed / optional JWT | [api/src/index.js:1767](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:1767) |
| GET | `/app-status` | Public read / optional JWT | [api/src/index.js:946](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:946) |
| GET | `/assistant/spending-summary` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:6264](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:6264) |
| POST | `/backup-runs` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:9066](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:9066) |
| GET | `/backup-status` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:9022](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:9022) |
| GET | `/budgets` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:6388](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:6388) |
| POST | `/budgets` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:6455](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:6455) |
| DELETE | `/budgets/:id` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:6522](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:6522) |
| POST | `/card-discovery` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:6727](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:6727) |
| GET | `/card-overrides` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:2878](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:2878) |
| POST | `/card-overrides` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:2909](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:2909) |
| DELETE | `/card-overrides/:id` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:3016](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:3016) |
| PATCH | `/card-overrides/:id` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:2961](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:2961) |
| POST | `/card-requests` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:1264](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:1264) |
| GET | `/catalogue` | Public read / optional JWT | [api/src/index.js:239](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:239) |
| GET | `/categories` | Public read / optional JWT | [api/src/index.js:905](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:905) |
| GET | `/changelog` | Public read / optional JWT | [api/src/index.js:7687](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:7687) |
| GET | `/consents` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:7290](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:7290) |
| POST | `/consents` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:7336](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:7336) |
| GET | `/consents/history` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:7312](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:7312) |
| POST | `/data-error-reports` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:1325](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:1325) |
| GET | `/duplicate-candidates` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:5416](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:5416) |
| POST | `/duplicate-candidates/:id/resolve` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:5469](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:5469) |
| GET | `/export` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:9096](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:9096) |
| GET | `/export/transactions.csv` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:6324](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:6324) |
| POST | `/forwarding-addresses` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:8582](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:8582) |
| GET | `/forwarding-addresses/me` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:8616](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:8616) |
| GET | `/forwarding-addresses/verification` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:8798](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:8798) |
| GET | `/health` | Public read / optional JWT | [api/src/index.js:161](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:161) |
| GET | `/home-summary` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:7129](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:7129) |
| POST | `/imap-connections` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:9174](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:9174) |
| POST | `/imap-connections/:id/test` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:9246](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:9246) |
| GET | `/imap-connections/me` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:9215](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:9215) |
| POST | `/inbound-emails/:id/create-transaction` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:8867](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:8867) |
| GET | `/inbound-emails/me` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:8841](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:8841) |
| POST | `/inbound-emails/webhook` | Shared webhook secret inside handler | [api/src/index.js:8657](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:8657) |
| GET | `/issuer-emergency-contacts` | Public read / optional JWT | [api/src/index.js:9310](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:9310) |
| GET | `/lounge-usage` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:5896](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:5896) |
| POST | `/lounge-usage` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:5914](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:5914) |
| GET | `/merchants/nearby` | Public read / optional JWT | [api/src/index.js:987](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:987) |
| GET | `/merchants/nearby/discover` | Public read / optional JWT | [api/src/index.js:1155](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:1155) |
| POST | `/merchants/nearby/discover` | Public read / optional JWT | [api/src/index.js:1156](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:1156) |
| POST | `/merchants/nearby/google` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:1042](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:1042) |
| GET | `/merchants/nearby/search` | Public read / optional JWT | [api/src/index.js:1249](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:1249) |
| POST | `/merchants/nearby/search` | Public read / optional JWT | [api/src/index.js:1250](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:1250) |
| GET | `/merchants/resolve` | Public read / optional JWT | [api/src/index.js:2031](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:2031) |
| GET | `/merchants/search` | Public read / optional JWT | [api/src/index.js:1996](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:1996) |
| GET | `/monthly-reports` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:5960](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:5960) |
| GET | `/my-contributions` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:7219](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:7219) |
| POST | `/notification-devices` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:1416](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:1416) |
| GET | `/notification-preferences` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:7399](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:7399) |
| PUT | `/notification-preferences` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:7417](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:7417) |
| GET | `/notification-preferences/muted-merchants` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:7451](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:7451) |
| POST | `/notification-preferences/muted-merchants` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:7470](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:7470) |
| DELETE | `/notification-preferences/muted-merchants/:merchantId` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:7488](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:7488) |
| GET | `/notifications` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:6902](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:6902) |
| POST | `/notifications` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:6967](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:6967) |
| POST | `/notifications/read` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:6930](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:6930) |
| POST | `/notifications/test` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:1474](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:1474) |
| POST | `/partner-clicks` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:1817](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:1817) |
| POST | `/partner-conversions/webhook` | Shared webhook secret inside handler | [api/src/index.js:1861](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:1861) |
| GET | `/profile` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:181](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:181) |
| POST | `/profile` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:200](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:200) |
| POST | `/profile/contributions-opt-in` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:7243](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:7243) |
| GET | `/ready` | Public read / optional JWT | [api/src/index.js:166](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:166) |
| GET | `/recurring` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:6555](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:6555) |
| PATCH | `/recurring/:id` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:6658](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:6658) |
| POST | `/recurring/:id/dismiss` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:6688](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:6688) |
| GET | `/referrals` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:6836](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:6836) |
| GET | `/sms-import-batches` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:8994](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:8994) |
| POST | `/sms-import-batches` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:8976](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:8976) |
| GET | `/spend-by-category` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:6124](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:6124) |
| GET | `/spend-report` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:6179](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:6179) |
| GET | `/statement-imports` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:8952](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:8952) |
| POST | `/statement-imports` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:8947](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:8947) |
| POST | `/support-tickets` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:7658](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:7658) |
| POST | `/sync/ack` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:1709](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:1709) |
| POST | `/sync/conflicts/:id/acknowledge` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:1726](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:1726) |
| GET | `/sync/pull` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:1670](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:1670) |
| POST | `/sync/push` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:1549](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:1549) |
| POST | `/sync/register-device` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:1391](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:1391) |
| GET | `/transactions` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:5220](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:5220) |
| POST | `/transactions` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:4558](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:4558) |
| GET | `/transactions/:id` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:5343](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:5343) |
| PATCH | `/transactions/:id` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:5613](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:5613) |
| POST | `/transactions/:id/ignore` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:5844](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:5844) |
| PATCH | `/transactions/:id/note` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:5794](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:5794) |
| GET | `/transactions/:id/splits` | JWT (signature/issuer/audience/expiry only) | [api/src/transaction_splits.js:54](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/transaction_splits.js:54) |
| PUT | `/transactions/:id/splits` | JWT (signature/issuer/audience/expiry only) | [api/src/transaction_splits.js:99](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/transaction_splits.js:99) |
| POST | `/transactions/from-sms` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:4694](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:4694) |
| POST | `/transactions/from-sms/batch` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:4895](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:4895) |
| POST | `/transactions/reconcile-sms` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:5070](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:5070) |
| GET | `/transactions/sms-import-state` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:5088](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:5088) |
| GET | `/user-cards` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:2406](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:2406) |
| POST | `/user-cards` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:2505](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:2505) |
| PATCH | `/user-cards/:id` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:3150](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:3150) |
| POST | `/user-cards/:id/archive` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:2820](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:2820) |
| POST | `/user-cards/:id/default` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:2848](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:2848) |
| POST | `/user-cards/:id/points-adjustment` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:3265](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:3265) |
| GET | `/user-cards/:id/points-ledger` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:3231](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:3231) |
| POST | `/user-cards/:id/unarchive` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:3037](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:3037) |
| POST | `/user-cards/import` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:2652](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:2652) |
| POST | `/user-cards/reorder` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:3099](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:3099) |
| GET | `/user-categories` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:918](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:918) |
| GET | `/user-settings` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:7513](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:7513) |
| PUT | `/user-settings` | JWT (signature/issuer/audience/expiry only) | [api/src/index.js:7555](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/api/src/index.js:7555) |

## auth — 28 method/path pairs

| Method | Path | Access control | Source |
|---|---|---|---|
| GET | `/admin/security-dashboard` | JWT + security_admin (feature flag) | [auth/src/index.js:166](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/auth/src/index.js:166) |
| GET | `/admin/security-events` | JWT + security_admin (feature flag) | [auth/src/routes/adminRoutes.js:53](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/auth/src/routes/adminRoutes.js:53) |
| POST | `/auth/check-user` | Public legacy endpoint — review finding | [auth/src/routes/authRoutes.js:278](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/auth/src/routes/authRoutes.js:278) |
| POST | `/auth/google` | Google ID-token proof | [auth/src/routes/authRoutes.js:1104](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/auth/src/routes/authRoutes.js:1104) |
| POST | `/auth/guest-login` | Public legacy endpoint — review finding | [auth/src/routes/authRoutes.js:370](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/auth/src/routes/authRoutes.js:370) |
| POST | `/auth/logout` | Refresh-token proof | [auth/src/routes/authRoutes.js:1405](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/auth/src/routes/authRoutes.js:1405) |
| POST | `/auth/refresh` | Refresh-token proof | [auth/src/routes/authRoutes.js:1237](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/auth/src/routes/authRoutes.js:1237) |
| POST | `/auth/request-email-otp` | Public login: delivery/rate-limit checks | [auth/src/routes/authRoutes.js:764](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/auth/src/routes/authRoutes.js:764) |
| POST | `/auth/request-otp` | Public login: delivery/rate-limit checks | [auth/src/routes/authRoutes.js:144](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/auth/src/routes/authRoutes.js:144) |
| POST | `/auth/signup` | Public legacy endpoint — review finding | [auth/src/routes/authRoutes.js:1460](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/auth/src/routes/authRoutes.js:1460) |
| POST | `/auth/validate-token` | Public token introspection (token in body) | [auth/src/routes/authRoutes.js:1894](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/auth/src/routes/authRoutes.js:1894) |
| POST | `/auth/verify-email-otp` | OTP proof + rate limit (no existing JWT) | [auth/src/routes/authRoutes.js:879](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/auth/src/routes/authRoutes.js:879) |
| POST | `/auth/verify-otp` | OTP proof + rate limit (no existing JWT) | [auth/src/routes/authRoutes.js:450](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/auth/src/routes/authRoutes.js:450) |
| GET | `/health` | Public health/debug page | [auth/src/index.js:119](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/auth/src/index.js:119) |
| GET | `/ready` | Public health/debug page | [auth/src/index.js:125](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/auth/src/index.js:125) |
| GET | `/test` | Public health/debug page | [auth/src/index.js:111](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/auth/src/index.js:111) |
| GET | `/testpage` | Public health/debug page | [auth/src/index.js:115](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/auth/src/index.js:115) |
| GET | `/users/me` | JWT | [auth/src/routes/userRoutes.js:29](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/auth/src/routes/userRoutes.js:29) |
| PUT | `/users/me` | JWT + step-up | [auth/src/routes/userRoutes.js:184](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/auth/src/routes/userRoutes.js:184) |
| PUT | `/users/me/device/fcm-token` | JWT | [auth/src/routes/userRoutes.js:425](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/auth/src/routes/userRoutes.js:425) |
| GET | `/users/me/devices` | JWT | [auth/src/routes/userRoutes.js:227](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/auth/src/routes/userRoutes.js:227) |
| DELETE | `/users/me/devices/:device_id` | JWT + step-up | [auth/src/routes/userRoutes.js:259](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/auth/src/routes/userRoutes.js:259) |
| POST | `/users/me/logout-all-devices` | JWT + step-up | [auth/src/routes/userRoutes.js:381](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/auth/src/routes/userRoutes.js:381) |
| POST | `/users/me/logout-all-other-devices` | JWT + step-up | [auth/src/routes/userRoutes.js:311](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/auth/src/routes/userRoutes.js:311) |
| POST | `/users/me/recovery-contact-check` | JWT | [auth/src/routes/userRoutes.js:142](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/auth/src/routes/userRoutes.js:142) |
| POST | `/users/me/recovery-contact/request` | JWT + recent recovery proof + rate limit | [auth/src/routes/recoveryContactRoutes.js:58](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/auth/src/routes/recoveryContactRoutes.js:58) |
| POST | `/users/me/recovery-contact/verify` | JWT + recent recovery proof + rate limit | [auth/src/routes/recoveryContactRoutes.js:92](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/auth/src/routes/recoveryContactRoutes.js:92) |
| GET | `/users/me/recovery-status` | JWT | [auth/src/routes/userRoutes.js:98](/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs/auth/src/routes/userRoutes.js:98) |

## Boundaries

The auth service also mounts `express.static('public')` before the protected admin dashboard route. Thus `/test.html`, `/security-dashboard.html`, and any other files in `auth/public/` are public. These static resources are not included in the method/path count. Automatic Express HEAD/OPTIONS handling is also not counted separately.

Product API global `optionalAuth` verifies the JWT before route guards. Auth `/admin/*` inherits `authMiddleware`, `adminAuth`, and `adminRateLimit` from its feature-gated mount. Recovery-contact routes inherit `auth`, a sensitive-operation limiter, and a recent recovery-proof guard from `router.use`.

Duplicate explicit method/path registrations detected: 0.
