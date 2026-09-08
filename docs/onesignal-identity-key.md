# OneSignal Identity Verification key — upload to SSM (NTF-BE-008)

The ES256 private key OneSignal issues under **Settings → Keys & IDs → Identity
Verification**. GoGo-BE signs the identity JWT with it so a mobile subscription
can be bound to `external_id = users.id`.

It is not the REST/App API key, and it is not something GoGo mints. There is one
key per OneSignal app, so one per environment.

## Where the file lives

Outside every Git working tree. `scripts/secrets/put-identity-key.sh` refuses a
path inside one — `.gitignore` covers `*.pem`, but a rename or `git add -f` does
not care, and a signing key in a working tree is one careless `git add -A` from
a public repository.

```sh
mkdir -p ~/.config/gogo/secrets/dev
chmod 700 ~/.config/gogo ~/.config/gogo/secrets ~/.config/gogo/secrets/dev
# save the downloaded key as:
#   ~/.config/gogo/secrets/dev/onesignal-identity.pem
chmod 600 ~/.config/gogo/secrets/dev/onesignal-identity.pem
```

The directory is `0700` and the file `0600`; the script refuses anything looser.

## Upload

```sh
cd GoGo-Infra
./scripts/secrets/put-identity-key.sh \
  ~/.config/gogo/secrets/dev/onesignal-identity.pem dev --profile gogo-bootstrap
```

Writes `/gogo/dev/backend/onesignal/identity-verification-key` as a
`SecureString` in `ap-southeast-1`, in account `477020169756`. Path, type and
`ONESIGNAL_IDENTITY_VERIFICATION_KEY` come from
`config/secrets.manifest.yml`; account and region from `config/global.tfvars` —
the script reads both rather than restating them.

Output is three lines: validation status, parameter path, version. Nothing else.

### `--overwrite`

A second upload to an existing path is refused without it. Rotation invalidates
every token already signed, so it is a decision, not a default:

```sh
./scripts/secrets/put-identity-key.sh <pem> dev --profile gogo-bootstrap --overwrite
```

## Why base64 rather than the raw PEM

Both renderers write one line per variable — `scripts/deploy/render-env.sh:42`
and `scripts/secrets/pull.sh:82` are the same `printf '%s=%s\n'`. A raw PEM
would arrive as `ONESIGNAL_IDENTITY_VERIFICATION_KEY=-----BEGIN…` followed by
four orphan lines that no env parser can attach to anything.

GoGo-BE's `parseIdentitySigningKey`
(`libs/modules/notifications/application/push-identity.service.ts`) accepts raw
PEM, `\n`-escaped PEM, or base64 of the whole file. Base64 is used because its
alphabet `[A-Za-z0-9+/=]` holds no character that is special to a shell, to
JSON, to an env-file parser, or to `docker compose --env-file`; `\n`-escaping
survives only while nothing in the chain expands escapes. `openssl base64 -A`
keeps it on one line — wrapped base64 would reintroduce the problem it solves.

The encoding is applied once, at upload, rather than left for whoever renders
the value next to notice.

## What the script checks, and what it never does

Refused **before** anything reaches AWS:

| Refused | Because |
| --- | --- |
| Path inside a Git working tree | one `git add -A` from publication |
| Mode other than `0600`/`0400` | a signing key readable by other local users |
| Public key, or a passphrase-protected key | cannot sign; `-passin pass:` refuses rather than prompting, so this cannot hang in CI |
| RSA, P-384, or any non-P-256 key | signs ES256 tokens OneSignal rejects; GoGo-BE refuses it at boot |
| The REST API key pasted by mistake | not a PEM at all |
| A session in another AWS account | the path is identical in every account; a live key would land somewhere nobody watches |
| An existing parameter, without `--overwrite` | rotation invalidates issued tokens |
| `set -x` in the calling shell | tracing would print the encoded key into whatever is capturing the shell |

The curve is checked by deriving the SubjectPublicKeyInfo and matching the
algorithm OID `2a8648ce3d030107` (prime256v1). The OID rather than `-text_pub`
output, because the text format differs between OpenSSL and LibreSSL — macOS
ships the latter at `/usr/bin/openssl` — while the DER encoding does not.

The key never reaches a command line (`--cli-input-json` file under `umask 077`,
mode `0600`, removed straight after — an `--value` argument would put it in this
process's `argv`, where any local user's `ps` can read it), never an exported
variable, never the terminal, never a file that outlives the call.

## Verification

Two comparisons, both in memory:

- **Fingerprint** — SHA-256 of the *public* SPKI derived locally, against the
  same derived from the stored value. Proves the stored bytes are this key. The
  private half only ever exists inside an `openssl` pipe.
- **Digest** — SHA-256 of the encoded string on each side. Proves the round trip
  was byte-exact; a truncated base64 string can still decode to a valid-looking
  prefix.

Either mismatch is fatal and says not to rely on the parameter.

## After the upload

1. Restart the API so it reads the new value. `parseIdentitySigningKey` runs at
   boot: a wrong key fails there, not on a phone.
2. **Identity Verification stays OFF in the OneSignal dashboard** until the
   authenticated client flow passes (NTF-APP-004). Enabling it first
   unsubscribes every named user — see `docs/onesignal-environments.md`.

## Rotation

1. Generate the new key in the OneSignal dashboard.
2. Upload it with `--overwrite`.
3. Restart the API.
4. Clients refresh within the token TTL (≤ 1 h, `IDENTITY_TOKEN_MAX_TTL_SECONDS`).

Tokens signed with the previous key stop verifying as soon as the dashboard is
updated to match, so steps 2–3 are one maintenance window, not two.

## Rollback

SSM keeps parameter versions. `aws ssm get-parameter --name <path> --version <n>`
retrieves an earlier one, but the dashboard is the authority: if OneSignal has
already been rotated, restoring the old value in SSM restores a key the provider
no longer trusts. Roll back the dashboard first, then SSM.

## Tests

`./scripts/secrets/put-identity-key.test.sh` — 27 assertions, run in CI by
`.github/workflows/validate.yml`. Every key it uses is generated by the test and
discarded with its sandbox; a real key is never needed to test this, and must
never be used to.
