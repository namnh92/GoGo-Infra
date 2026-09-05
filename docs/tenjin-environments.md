# Tenjin build configuration (INF-014)

DEV is mini-production: identical integration, independent environment values.
The SDK keys already supplied in bootstrap.env are public per-app build config.
They are not a server API credential. Keep them out of the backend namespace.

After generating the mobile environment with mobile-env.py:

```sh
python3 scripts/secrets/tenjin-mobile-env.py dev \
  --bootstrap config/bootstrap.env --out <mobile-checkout>/.env
```

Use TENJIN_IOS_SDK_KEY_DEV / _STAGING / _PROD and the matching
TENJIN_ANDROID_SDK_KEY suffix for each environment. Existing bare values are
accepted only for UNSUFFIXED_VALUES_BELONG_TO, never inherited by another env.
An explicit empty suffixed value refuses the build rather than taking a bare
value. `staging` maps to mobile flavor `stag`.

The SDK client receives only its current platform's key. No key values appear
in command output. Generated file is mode 0600 and replaced atomically.

## Store-dependent acceptance

Owner confirmed 2026-09-05: App Store Connect app has not been created; store
URLs are not yet available. Keep URLs absent, never manufacture a listing.
SDK initialization/connection and native build can be tested independently.
Full click → store → install → deferred-link recovery requires real app
listings and a configured Tenjin campaign tracking template. It remains pending
until those values exist; lack of a URL is not a successful fallback test.

Canonical slug resolution is BE#205. The mobile SDK must use the existing GoGo
router and must not mistake provider callback success for resource resolution.
GoGo-WebApp remains pending by owner instruction.
