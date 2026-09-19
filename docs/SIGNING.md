# Android release signing

The signing keystore is **never committed to this repository**. It is stored
base64-encoded in GitHub Actions secrets and decoded at build time.

> Historical note: an earlier `android/app/release-keystore.p12` blob was
> committed in the past and remains in git history. Treat that keystore and
> its password as compromised — use a **new** keystore generated locally
> (or reset the upload key in Play Console if Play App Signing is enabled).

## 1. GitHub Actions secrets (Settings → Secrets and variables → Actions)

| Secret | Value |
|---|---|
| `KEYSTORE_BASE64` | The keystore file, base64-encoded: `base64 -w0 release-keystore.p12` |
| `KEYSTORE_PASSWORD` | The keystore (store) password |
| `KEY_PASSWORD` | The key password — **for PKCS12 this equals `KEYSTORE_PASSWORD`** |
| `KEY_ALIAS` | The key alias inside the keystore |

All four must exist **before** the PR that wires them ("chore/keystore-from-secrets")
is merged. Until then every release build fails loudly with a clear error.

## 2. How CI signs builds

Both workflows (`.github/workflows/build.yml`, `.github/workflows/flutter-ci.yml`)
decode the keystore before building:

```
$KEYSTORE_BASE64  →  base64 -d  →  $RUNNER_TEMP/release-keystore.p12
KEYSTORE_PATH     →  $RUNNER_TEMP/release-keystore.p12   (picked up by android/app/build.gradle.kts)
```

`$RUNNER_TEMP` lives outside the checkout, so the keystore can never be
committed by accident. `*.p12` / `**/*.p12` are git-ignored as a second net.

## 3. Verify the first release AAB

After the first successful "Build Release AAB" run, download the
`release-aab` artifact and check the signature:

```bash
jarsigner -verify -verbose -certs app-release.aab
# Expect: "jar verified." and the signing certificate matching the new key,
#         alias shown by: keytool -list -keystore release-keystore.p12
```

## 4. Generating a new keystore (if needed)

```bash
keytool -genkeypair -v \
  -keystore release-keystore.p12 \
  -storetype PKCS12 \
  -alias fivebirr \
  -keyalg RSA -keysize 4096 -validity 10000
```

Keep the file and passwords out of git, cloud repos, and chat. If the app is
live on Google Play with Play App Signing, prefer the console's
"reset upload key" flow over replacing the app signing key.
