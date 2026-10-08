# PandaPay remote notifications

PandaPay owns the application API and uses the separately hosted Novu project as
the notification provider. The app does not talk to Novu directly. The API
registers FCM device tokens and triggers Novu workflows, so the same Novu
deployment can serve multiple applications.

## Production configuration

Configure these values in the production host's PandaPay `.env` file. The
current deployed notification service is
`https://novu-notifications-test.onrender.com`. Do not commit the API key or
put it in the mobile app.

The repository's production auto-deploy workflow also accepts these same two
values as GitHub Actions `production` environment secrets named
`NOTIFICATION_SERVICE_URL` and `NOTIFICATION_SERVICE_API_KEY`. When supplied,
the workflow updates only those allow-listed keys in the host `.env` before
restarting the API; all other host secrets remain untouched.

```dotenv
NOTIFICATION_SERVICE_URL=https://novu-notifications-test.onrender.com
NOTIFICATION_SERVICE_API_KEY=<novu-api-key>
NOTIFICATION_SERVICE_TIMEOUT_MS=4000
NOTIFICATION_SERVICE_FCM_INTEGRATION_IDENTIFIER=
NOTIFICATION_SERVICE_WORKFLOW_IDENTIFIER=pandapay-push-notification
NOTIFICATION_SERVICE_WORKFLOW_NAME=PandaPay push notification
```

`NOTIFICATION_SERVICE_URL` must be the hosted service root; the adapter adds
the `/v1` route paths itself. The adapter uses the deployed service's
subscriber, credential, workflow, trigger, and broadcast routes. A separately
deployed instance must use a URL reachable from the PandaPay API container.

In Novu, configure the FCM provider for the Firebase project used by PandaPay
(`notification-fd639`) and make sure the provider is active. The PandaPay
adapter uses the configured workflow identifier. It first checks
`GET /v1/workflows` and creates or repairs the workflow through the hosted
wrapper's schema when it is absent or malformed. The workflow contains one
push template with `{{payload.title}}` and `{{payload.body}}`, so no manual
workflow setup is required.

After changing the host environment, restart/recreate the API container so the
new values are loaded. No manual device registration is required: after login,
Firebase obtains the token and PandaPay registers it automatically. Token
refresh, app updates, transient provider failures, and duplicate registration
requests are handled safely by the app/API integration.

## Expected behavior

- `201` from `POST /notification-devices`: token registered.
- `202` from `POST /notifications/test`: delivery accepted by Novu.
- `409`: the user has no registered device yet.
- `503`: the API has no valid Novu configuration.
- `502`/`504`: Novu is configured but unavailable or timed out; the request can
  be retried without creating duplicate provider events.

The app can still show local notifications when remote delivery is unavailable;
that must not be interpreted as proof that Novu/FCM delivery succeeded. The
Settings test action is the end-to-end check once Novu is reachable.
