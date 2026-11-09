'use strict';

// Well-known throwaway-mailbox services. A person who needs a fresh address for
// every account uses one of these, so a sign-up or a recovery email from one is
// refused. This list is a starting point and goes stale: add new services with
// DISPOSABLE_EMAIL_EXTRA_DOMAINS (comma separated) without a code change, and
// keep it reviewed. A domain the person owns can never be caught this way.
module.exports = Object.freeze([
  '10minutemail.co.uk', '10minutemail.com', '10minutemail.net', '20minutemail.com', '33mail.com',
  'anonbox.net', 'anonymbox.com', 'binkmail.com', 'bobmail.info', 'burnermail.io', 'byom.de',
  'cool.fr.nf', 'crazymailing.com', 'deadaddress.com', 'despammed.com', 'discard.email',
  'discardmail.com', 'dispostable.com', 'dodgeit.com', 'dropmail.me', 'e4ward.com', 'einrot.com',
  'email-fake.com', 'emailfake.com', 'emailondeck.com', 'emltmp.com', 'fakeinbox.com',
  'fakemail.net', 'fakemailgenerator.com', 'fastacura.com', 'fivemail.de', 'getnada.com',
  'gishpuppy.com', 'grr.la', 'guerrillamail.biz', 'guerrillamail.com', 'guerrillamail.de',
  'guerrillamail.info', 'guerrillamail.net', 'guerrillamail.org', 'guerrillamailblock.com',
  'harakirimail.com', 'humaility.com', 'imails.info', 'incognitomail.com', 'inboxkitten.com',
  'instantemailaddress.com', 'jetable.org', 'kasmail.com', 'klassmaster.com', 'letthemeatspam.com',
  'linshiyouxiang.net', 'lroid.com', 'luxusmail.org', 'mail-temp.com', 'mailbox.in.ua',
  'mailcatch.com', 'mailforspam.com', 'mailinator.com', 'mailinator.net', 'mailinator2.com',
  'mailmoat.com', 'mailnesia.com', 'mailnull.com', 'mailpoof.com', 'mailsac.com', 'mailtemp.info',
  'mailtothis.com', 'maildrop.cc', 'meltmail.com', 'mintemail.com', 'moakt.cc', 'moakt.com',
  'mohmal.com', 'mt2015.com', 'mvrht.net', 'mytemp.email', 'nada.email', 'nospam.ze.tc',
  'nowmymail.com', 'objectmail.com', 'pokemail.net', 'proxymail.eu', 'rcpt.at', 'safetymail.info',
  'sharklasers.com', 'sogetthis.com', 'spam4.me', 'spambox.us', 'spamevader.com', 'spamex.com',
  'spamfree24.org', 'spamgourmet.com', 'supermailer.jp', 'teleworm.us', 'temp-mail.io',
  'temp-mail.org', 'tempail.com', 'tempinbox.com', 'tempmail.com', 'tempmailaddress.com',
  'tempmailer.com', 'tempmailo.com', 'tempr.email', 'tempsky.com', 'thankyou2010.com',
  'throwam.com', 'throwawaymail.com', 'tmail.ws', 'tmpmail.net', 'tmpmail.org', 'tradermail.info',
  'trash-mail.com', 'trashmail.com', 'trashmail.de', 'trashmail.net', 'trbvm.com', 'vomoto.com',
  'wegwerfmail.de', 'wegwerfmail.net', 'yopmail.com', 'yopmail.fr', 'yopmail.net', 'zippymail.info',
  'zoemail.org',
]);
