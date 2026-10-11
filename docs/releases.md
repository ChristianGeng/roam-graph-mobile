# Releases and installing with Obtainium

Every push to `main` builds a signed APK on GitHub Actions
(`.github/workflows/build.yml`) and publishes it as a GitHub release named
`v0.1.<run number>`. Pull requests only test and build; they publish nothing.

## The signing key

Android installs an update only if it is signed with the same key as the
installed app. So every release is signed with one release key, stored as
four repository secrets (Settings → Secrets and variables → Actions):

| Secret | Value |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | the `.jks` file, base64-encoded on one line |
| `ANDROID_KEYSTORE_PASSWORD` | the keystore password |
| `ANDROID_KEY_ALIAS` | `release` |
| `ANDROID_KEY_PASSWORD` | the key password |

The key is never in the repo; the repo is public. Keep a private copy of the
`.jks` file and the password. If the key is lost, the app cannot be updated
any more; it must be uninstalled and installed again with a new key.

Without the secrets, the build on `main` fails with an error that names the
missing secret.

## Install with Obtainium

1. In Obtainium, tap **Add App**.
2. App source URL: `https://github.com/ChristianGeng/roam-graph-mobile`
3. Tap **Add**, then **Install**.

Obtainium checks the releases for new versions and updates in one tap. The
repo is public, so no GitHub token is needed; a token only raises GitHub's
rate limit for frequent update checks.
