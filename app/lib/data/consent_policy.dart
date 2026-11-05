/// The one policy version every consent screen records with `POST /consents`.
///
/// It is the date the privacy policy and terms were published (the hosted
/// pages in `deploy/legal/` and the in-app copy in `legal_screen.dart` carry
/// the same date). Change it here, in one place, when the policy changes: the
/// next time a screen asks, a consent given against an older version no longer
/// counts, so people are asked again.
///
/// Exception: `sms_shared_learning` keeps its own purpose-specific version
/// (`smsSharedLearningPolicyVersion`) because database functions match that
/// exact string.
const consentPolicyVersion = '2026-11-15';
