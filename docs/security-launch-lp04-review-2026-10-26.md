# LP04 OTP source review — 26 October 2026

## Result

Reviewed the bounded OTP issuance and verification service, its local admission, and the legacy/V2 request and delivery paths. **No additional narrow source defect was established in this slice**, so no OTP behavior was changed. Existing B01 admission and durable abuse quotas remain intact.

The relevant path has immediate bounded work admission before bcrypt/database operations; shared dummy-hash initialization; atomic, one-use challenge consumption with expiry, purpose, protocol and device binding; and request-ID-scoped active-marker cleanup. Legacy and V2 use separate challenge predicates and code formats, while the active marker is shared by identifier and purpose. Failed provider acceptance tombstones the exact challenge and clears its marker. SMTP success requires the exact recipient in the provider's accepted list; SMS success reflects Twilio API acceptance. Neither response proves handset/mailbox delivery.

## Reviewed source and coverage

- `auth/src/services/otpWorkAdmission.js`: strict per-process work/email/SMS bounds; immediate rejection; slot held through operation settlement.
- `auth/src/services/otpService.js`: legacy and V2 issue/verify/discard paths, challenge bindings, expiry, attempt caps, single-use consume, and cleanup.
- `auth/src/routes/authRoutes.js` and `auth/src/routes/versionedOtpRoutes.js` (read-only): request/verify dispatch, provider sends, and undelivered cleanup.
- `auth/src/services/emailService.js` and `auth/src/services/smsService.js` (read-only): provider acceptance behavior.
- `auth/test/otp_work_admission.test.js`, `auth/test/otp_single_use.test.js`, and `auth/test/otp_delivery.test.js`: synthetic concurrency stalls, no-work-on-rejection, single-use/purpose behavior, and legacy/V2 phone/email delivery failure cleanup. Parent integration owns full verification; no real provider send was performed for this review.

## Remaining LP04 acceptance gates

Source and synthetic tests do not establish the operator's aggregate sender budget or real delivery behavior. Before launch, bind `OTP_WORK_MAX_CONCURRENT`, `OTP_EMAIL_MAX_CONCURRENT`, and `OTP_SMS_MAX_CONCURRENT` to the exact candidate and replica count; independently verify the account's SMS and SMTP quotas, sender/service configuration, geographic restrictions and approved spend limits; then record the exact-candidate `otp_capacity_acceptance` proof with an agreed arrival mix, burst and shared-NAT envelope, provider outage/rejection cases, and offered/admitted/rejected/completed results. Confirm accepted messages arrive on intended test-controlled phone/email destinations without exposing OTPs in evidence. Do not count provider API acceptance as end-user receipt.

Until these gates are independently evidenced, the local limits and mocked delivery tests remain source-level safeguards; they do not close LP04 or authorize deployment/activation.
