'use strict';

// How long a sign-in or recovery code stays valid, in seconds. One value for
// every code the service sends (email, SMS, recovery and contact replacement),
// so the server, the replies it gives clients and the console proxy cannot
// drift apart. Codes go to email, which arrives within seconds, so one minute
// is enough and keeps the guessing window short.
const OTP_LIFETIME_SECONDS = 60;

module.exports = { OTP_LIFETIME_SECONDS };
