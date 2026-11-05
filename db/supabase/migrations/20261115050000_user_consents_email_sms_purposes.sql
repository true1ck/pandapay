-- Two consent purposes the app now records but the table did not accept.
--
-- `email_import` (the email import disclosure) and `sms_reading` (the
-- standalone SMS disclosure, one row per account) are written through
-- POST /consents. The API list (CONSENT_PURPOSES) already accepts them, but
-- the purpose check last redefined in 20261027150000 only allowed six values,
-- so inserting either purpose failed with a check violation and the app
-- reported a 500. Widen the check; keep every existing purpose.

alter table user_consents
  drop constraint if exists user_consents_purpose_check;

alter table user_consents
  add constraint user_consents_purpose_check
  check (purpose in (
    'terms',
    'crowdsource',
    'marketing',
    'aggregate_insights',
    'partner_sharing',
    'sms_shared_learning',
    'email_import',
    'sms_reading'
  ));

comment on column user_consents.purpose is
  'What was consented to. Constrained rather than free text: this is the '
  'legal record of agreement, and a typo''d purpose would produce a row no '
  'query matches, including a revocation that then silently fails to revoke. '
  '''sms_reading'' is per account (one disclosure per sign-in on a phone); '
  '''email_import'' covers IMAP polling and forwarded email.';
