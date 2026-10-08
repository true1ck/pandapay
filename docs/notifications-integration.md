# PandaPay notification service integration

PandaPay keeps authentication, notification preferences, the in-app inbox, and
notification history in its own API/Postgres database. The lightweight
notification service is used only for queued FCM delivery.

## Runtime flow

1. Flutter authenticates to PandaPay with the normal bearer access token.
2. Firebase Messaging obtains an FCM token on Android/iOS.
3. Flutter sends that token to POST /notification-devices.
4. PandaPay API registers the token as the subscriber whose id is the JWT
   sub. The notification-service project key never reaches Flutter.
5. Existing POST /notifications writes the PandaPay inbox row. App-triggered
   events also show a local OS alert; they do not remotely send a second FCM
   alert. Remote delivery is explicit through the self-test or an admin
   broadcast, so one event cannot produce duplicate banners.
6. The notification service queues FCM delivery through Redis and removes stale
   device tokens when Firebase reports them as invalid.

## Authenticated physical-device self-test

Notification Settings includes **Send test notification**. It calls
`POST /notifications/test` with the normal PandaPay access token. The API
derives the recipient from that token and never accepts a user id, subscriber
id, or device id from the app, so a user can only test their own registered
devices.

The route waits for the notification service to accept the request and returns
`202` only then. A `503` means the production API has no notification-service
configuration, `502` means the provider could not be reached, and `429` means
the one-minute self-test cooldown is active. A successful `202` confirms
provider acceptance; Android may still take a short time to display the push,
and the device must have signed in, obtained an FCM token, granted notification
permission, and have network access.

## Global announcements

An authenticated PandaPay admin can call `POST /admin/notifications/broadcast`
with `title`, optional `body`, `category`, `severity`, and `deepLink`. The API
uses Novu's `/v1/events/trigger/broadcast` endpoint to fan out through the
configured workflow to every registered subscriber/device. The mobile app
cannot call this route, and the Novu project key never leaves the API server.

## API configuration

Set these variables in the PandaPay API container. For local Docker Desktop
development, the compose default points at host.docker.internal:3100,
assuming the lightweight service is running in its own compose project.

    NOTIFICATION_SERVICE_URL=http://host.docker.internal:3100
    NOTIFICATION_SERVICE_API_KEY=<the PandaPay notification project key>
    NOTIFICATION_SERVICE_TIMEOUT_MS=4000

For staging/production, use the private notification-service HTTPS URL and
store the project key in the deployment secret store. Do not put the project
key in Flutter, --dart-define, an APK, or an IPA.

## Firebase requirements

The Firebase project notification-fd639 contains PandaPay Android
registrations for:

- app.pandapay.pandapay (production)
- app.pandapay.pandapay.dev2 (dev)
- app.pandapay.pandapay.staging (staging)

The Android and iOS client config files are in the app project. They contain
client identifiers, not the Firebase Admin private key. The Admin service
account remains only in the notification-service deployment.

For iOS production delivery, an Apple APNs key/certificate must also be
configured in Firebase Console. Android delivery can be tested immediately on
an Android device with Google Play services.

## Smoke test

After setting the API variables and signing in on a real mobile build:

1. Allow notifications when prompted.
2. Check the notification-service dashboard for the PandaPay subscriber and
   device.
3. Open Settings → Notifications and tap **Send test notification**.
4. Confirm the success message and the push appear on the same physical device.
5. If the API reports `503`, configure the production notification-service URL
   and project key; the app cannot fix a missing server-side secret.

The API and mobile app remain usable if the notification service is temporarily
unconfigured or unavailable. Inbox writes are not rolled back because a push
provider is down.
