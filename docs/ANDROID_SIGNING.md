# Android local signing

This repository uses one stable, self-managed **development** signing identity
for local Android debug, profile and release APKs. Keeping the signer stable
lets local builds update one another while preserving accounts and drafts.

This identity is not Play App Signing and is not evidence of a production or
store release.

## Canonical location

Every agent on a host uses the same directory:

```text
~/.config/gitlab-mobile/android-signing/
├── gitlab-mobile.p12
└── signing.properties
```

On the current macOS host, the absolute directory is:

```text
/Users/iml1s/.config/gitlab-mobile/android-signing
```

The directory must have mode `0700`; `gitlab-mobile.p12` and
`signing.properties` must have mode `0600`. Both files stay outside the
repository and outside `artifacts/`.

`signing.properties` contains private configuration. Never print it, paste it
into a prompt, issue, merge request or memory, or copy it into a build artifact.
Evidence may record the public signing-certificate SHA-256 only.

## Current public identity

The current host identity has been created and verified. Its public certificate
SHA-256 is:

```text
a15c11c804bd8b40cebf052747bfea91542568989af0b7a092efcfcb7ebff434
```

Use the fingerprint to compare build evidence without exposing the keystore or
properties. A different fingerprint is an identity change and must stop the
build or review. The current identity's files have been checked as mode `0600`
inside the mode `0700` canonical directory.

## Create the identity once

Initialization is an explicit setup operation:

```sh
python3 tool/android_signing.py init
```

The command creates the canonical directory and identity only when no identity
exists. It refuses to replace an existing key, properties file or incomplete
identity. Do not delete or rotate either file to make a build pass: a new key
cannot update APKs signed by the old key.

The current host is already initialized. Running `init` again must fail without
changing either private file. Check an existing identity without printing its
secrets with:

```sh
python3 tool/android_signing.py verify
```

Ordinary builds never generate a fallback debug key. If the identity is absent,
the build must stop and report the missing setup.

## Configure generated Android files

Generating or refreshing the native templates installs the signing loader:

```sh
python3 tool/bootstrap.py
```

The generated Android templates are ignored build inputs. Configuration applies
the same signer to local debug, profile and release variants. To install or
check the loader in an existing Android template without regenerating it, run:

```sh
python3 tool/android_signing.py configure android/app/build.gradle.kts
```

The command is idempotent and stops on incomplete signing markers or an unknown
Gradle template.

Another host or worktree may use a different absolute properties path without
copying secrets into the repository:

```sh
export GITLAB_MOBILE_SIGNING_PROPERTIES=/absolute/path/to/signing.properties
python3 tool/android_signing.py configure android/app/build.gradle.kts
```

Keep that environment variable available to the Flutter build. The referenced
properties file and keystore must follow the same private-file rules.

## Build local APKs

Use the pinned Flutter SDK and committed dependency lock:

```sh
./.fvm/flutter_sdk/bin/flutter pub get --enforce-lockfile
./.fvm/flutter_sdk/bin/flutter build apk --debug --no-pub
./.fvm/flutter_sdk/bin/flutter build apk --profile --no-pub
./.fvm/flutter_sdk/bin/flutter build apk --release --no-pub
```

Build only the variant required for the current task. A successful release build
is a locally signed development release APK; it is not a Play release.

## Update compatibility

Android accepts an in-place update only when all of these conditions hold:

- The installed and incoming APKs use the same application ID.
- Their signing identities are compatible.
- The incoming `versionCode` is at least as high as the installed version.

Without an Android signing lineage that explicitly authorizes the change, an APK
signed by an unrelated historical debug key fails with
`INSTALL_FAILED_UPDATE_INCOMPATIBLE`. Do not automatically uninstall the app or
clear its data. Preserve the installed accounts and drafts; use the matching
historical signer when available, or record that a deliberate fresh install
would lose local data.

Device validation for this project uses its dedicated Android emulator. The
physical phone remains reserved for the charging session.

## One-time API 33+ migration bridge

The emulator's earlier local APK used public certificate SHA-256
`64500eefad1aeb8e163c2ceeaa78b39ce013849f1a75596dd1b477fc5d023736`.
When that old private key is available, a one-time APK Signature Scheme v3.1
lineage can authorize migration to the current stable identity on Android 13
(API 33) and later.

This is a limited migration procedure, not an ordinary product build command:

- The bridge starts from the normal release APK and changes only its signature.
- The lineage names the known old signer and current signer, grants the new
  signer access to installed data, disables rollback capability and uses
  rotation minimum SDK 33.
- The bridge artifact is named
  `gitlab-mobile-<sha>-legacy-local-bridge.apk`. The subsequent ordinary artifact
  is `gitlab-mobile-<sha>-release.apk` and is signed only by the stable identity.
- The lineage and both private keys remain outside Git in the canonical private
  signing directory. They never enter `artifacts/`, prompts, merge requests or
  memory.
- The bridge cannot migrate an APK signed by an arbitrary CI or unknown debug
  key. Android 12L (API 32) and earlier cannot complete this bridge-to-new-only
  sequence.

Do not mark migration complete from signature inspection alone. Validation must
record the installed package and old certificate, create identifiable local app
data, install the bridge in place, verify that data remains, then install the
ordinary stable-signed release in place and verify the same data again. No step
may uninstall the app or clear its data. Until that native sequence has a
receipt, the bridge remains pending evidence.

## CI boundary

The current CI debug job keeps its legacy `ANDROID_DEBUG_KEYSTORE_B64` support
and ephemeral fallback until a stable key and properties file are provisioned as
protected project CI variables. The local private identity is not copied into CI,
and this setup does not claim that any CI secret was uploaded.

CI debug APKs with a different signer cannot update locally signed APKs in place.
Treat local development signing, CI preview signing and Play production signing
as separate evidence lanes.

## References

- [Android app signing](https://developer.android.com/studio/publish/app-signing)
- [Flutter Android deployment](https://docs.flutter.dev/deployment/android)
