# OneSignal environment contract (INF-013)

DEV, STAGING and PROD use the same SDK/runtime path. DEV is mini-production.
Supply separate App IDs, send keys and identity signing keys under
`/gogo/<dev|staging|prod>/backend/onesignal/` using the existing manifest/put tooling.
Never copy DEV credentials to another environment.

GoGo-BE reads three values (GoGo-BE#193/#199, rendered by `render-env.sh`):
`ONESIGNAL_APP_ID`, `ONESIGNAL_REST_API_KEY`, and
`ONESIGNAL_IDENTITY_VERIFICATION_KEY` (PEM, `\n`-escaped or base64 so it fits
one line — upload it with `scripts/secrets/put-identity-key.sh`, which encodes
and verifies it: [onesignal-identity-key.md](onesignal-identity-key.md)). `PUSH_PROVIDER_MODE` is not set in a deployed environment — the
production build selects OneSignal; a missing value makes the process refuse
sends and log `push provider NOT ready`, it never falls back to the fake.
Before enabling Identity Verification in the dashboard, confirm the mobile
client sends tokens (NTF-APP-004); enabling it first unsubscribes every
named user.

Mobile needs only the public App ID. Generate its build environment:

```sh
python3 scripts/secrets/mobile-env.py dev --profile gogo-bootstrap \
  --api-url https://api-dev.gogo.id.vn/v1 --web-url https://go-dev.gogo.id.vn \
  --apns-mode development --out <mobile-checkout>/.env
```

This replaces the destination; use a dedicated generated file/checkout if it
contains other local configuration. The command requests only the App ID and
never fetches REST/signing secrets. Missing input fails before replacing output.
For staging/prod change environment, URLs and values in SSM; the code is identical.
`staging` maps to the established mobile flavor `stag`.

APNs mode describes signing: a development-signed build uses `development`;
TestFlight/store/ad-hoc distribution uses `production`, even for the DEV app.
It is explicit configuration, not inferred from the GoGo environment.

## Verification boundary, 2026-09-05

DEV app-scoped notification-list probe returned HTTP 200 using the SSM App API
key. This proves authorization only, not delivery to a device. No push was sent.
SSM currently has App ID and REST key; identity signing key was not present.

OneSignal's current React Native 5.5.9 wrapper exposes `login(externalId)` only;
the official identity-verification page lists native SDK support and says wrapper
support is pending. Do not call an unverified login or enable user-targeted push
as a substitute for GoGo's identity requirement. Authenticated delivery needs a
verified native bridge/supported wrapper plus the account-generated signing key.
The API key is not an identity key. Do not generate an unrelated local key and
assume OneSignal trusts it.

Sources checked 2026-09-05:
- https://documentation.onesignal.com/docs/en/identity-verification
- https://github.com/OneSignal/react-native-onesignal

Before claiming complete: native build, explicit test-device permission,
subscription observed, targeted test receipt, login/logout/account-switch and
identity enforcement checks. Run these identically for each environment.
