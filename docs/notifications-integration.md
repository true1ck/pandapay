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
5. Existing POST /notifications writes the PandaPay inbox row and best-effort
   triggers the private pandapay-notification workflow.
6. The notification service queues FCM delivery through Redis and removes stale
   device tokens when Firebase reports them as invalid.

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
3. Trigger an existing PandaPay event, or create an inbox notification through
   the authenticated API.
4. Confirm the inbox row appears in PandaPay and the push appears on the
   device.

The API and mobile app remain usable if the notification service is temporarily
unconfigured or unavailable. Inbox writes are not rolled back because a push
provider is down.
