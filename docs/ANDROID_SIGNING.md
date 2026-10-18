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
├── gitlab-mobile.p12               # current stable signer (a15c11c8...)
├── signing.properties              # current build configuration
├── legacy-local-debug.p12          # recovered earlier local signer (64500eef...), bridge only
└── legacy-local-rotation.lineage   # v3.1 lineage 64500eef... -> a15c11c8...
```

On the current macOS host, the absolute directory is:

```text
/Users/iml1s/.config/gitlab-mobile/android-signing
```

The directory must have mode `0700`; all four files must have mode `0600`.
They stay outside the repository and outside `artifacts/`. The names above are
locators only; their contents are never printed, logged or copied.

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
./.fvm/flutter_sdk/bin/flutter build apk --debug
./.fvm/flutter_sdk/bin/flutter build apk --profile
./.fvm/flutter_sdk/bin/flutter build apk --release
```

Build only the variant required for the current task. A successful release build
is a locally signed development release APK; it is not a Play release. Keep the
initial locked dependency resolution and confirm `pubspec.lock` remains
unchanged, but do not add `--no-pub` to APK builds: Flutter 3.47.2 must regenerate
plugin registration for the selected debug, profile or release mode.

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

## Recovery and lookup

[`ANDROID_RELEASE_INVENTORY.json`](ANDROID_RELEASE_INVENTORY.json) is the
public, versioned index of known signers, the lineage and retained APKs. It
holds public certificate and APK SHA-256 digests, source commits, versions,
local paths and public download URLs only. It is not a private key backup.

### Signer matrix

| Inventory ID | Certificate SHA-256 | Private key locator (current host, 2026-10-09) |
| --- | --- | --- |
| `CURRENT_LOCAL` | `a15c11c804bd8b40cebf052747bfea91542568989af0b7a092efcfcb7ebff434` | `gitlab-mobile.p12`, present |
| `LEGACY_LOCAL` | `64500eefad1aeb8e163c2ceeaa78b39ce013849f1a75596dd1b477fc5d023736` | `legacy-local-debug.p12`, present |
| `HISTORICAL_CI23` | `23c9890d05dd84772921793313fb2a9ea34a4e03fbabb66027395a4bf10b4241` | not found in the selected scope; elsewhere unknown |
| `CI_EPHEMERAL_ADCB7D4D` | `d933f0e79237d5ce08d9c71c4dcbe214a5d1e75711070379c6d7192ace7e1438` | none: generated inside CI job 17125541131 and discarded with it |
| `CI_EPHEMERAL_630E20D5` | `2740d039aee0c5d5839ff0f5f532b1cbf76ac0ca4452764239847e5e36d6bdc7` | none: generated inside CI job 17260932740 and discarded with it |
| `CI_EPHEMERAL_A2EB7BA6` | `0a964b2c8938d9eaddd036d3c051d4c0ced5603ffa55e17b10e7903ba21e917e` | none: generated inside CI job 17264418104 and discarded with it |
| `CI_EPHEMERAL_4E4D2979` | `21bf28fab5cc8b13fcebe097f4268de34178c5afefb9ac2896afdb5179e30484` | none: generated inside CI job 17265303483 and discarded with it |
| `STABLE_CI_DEBUG` | `5bec28281b4c1405f9ee47590c40665a24b0f984fc0d6b8854a3458e8db0a71d` | CI variable `ANDROID_DEBUG_KEYSTORE_B64` (protected, masked); `ci-debug.p12`, reported present |

`LEGACY_LOCAL` is a host-generated historical debug key: the Android build
tools create a separate debug key per host, so its certificate is specific to
the host that produced it. On the current host, the default
`~/.android/debug.keystore` copy has the same public certificate fingerprint,
but the canonical `legacy-local-debug.p12` is authoritative. Key presence was verified
only on the current host on 2026-10-09; nothing is implied for other hosts.
The `HISTORICAL_CI23` key was searched in the local key inventory, related
runner project scopes and the project CI variable (404). That is a scoped
negative result, not a claim that the key is lost everywhere. The lineage does
not cover it.

### Known APKs

- Last documented phone install (2026-10-02): local release `ad49850`,
  `artifacts/gitlab-mobile-ad49850-release.apk`, SHA-256
  `e637c0192061e56bb65025478a011708b7dcb07250cf8cdbf096dfd89698de3e`, signer
  `LEGACY_LOCAL`. What the phone has installed now is unknown.
- Ordinary current release, source `987aa727`, signer `CURRENT_LOCAL` (v2 only):
  [gitlab-mobile-987aa727-release.apk](https://gitlab.com/aa22396584/gitlab-mobile/-/releases/v0.5.0-dev.987aa727/downloads/gitlab-mobile-987aa727-release.apk).
- Migration bridge for the same build, payload unchanged, only signatures
  added. Verified schemes: v2 and v3 `LEGACY_LOCAL` (API 24-32), v3.1
  `CURRENT_LOCAL` (API 33+). The bridge also carries v1 `META-INF` signature
  files with the `LEGACY_LOCAL` certificate, but the retained minSdk 24
  `apksigner --verify` reports v1 as not verified, so v1 verification is not
  established:
  [gitlab-mobile-987aa727-legacy-local-bridge.apk](https://gitlab.com/aa22396584/gitlab-mobile/-/releases/v0.5.0-dev.987aa727/downloads/gitlab-mobile-987aa727-legacy-local-bridge.apk).
- GitLab `v0.5.0` CI debug APK, source `0e1298e3`, signer `HISTORICAL_CI23`.
  No receipt shows it was installed on the phone.
- GitLab `v0.5.0-dev.adcb7d4d` CI debug APK, source `adcb7d4d`, signer
  `CI_EPHEMERAL_ADCB7D4D` (v2 only), SHA-256
  `124dd9c0b03fdfc9cd1faedf8caf7c81bb37b525bddfc45a42fe0c95a79ca176`:
  [gitlab-mobile-adcb7d4d-debug.apk](https://gitlab.com/api/v4/projects/86648389/packages/generic/gitlab-mobile-preview/adcb7d4d4f8f191fd045e6f0228a4a8f1db5bbd2/gitlab-mobile-adcb7d4d-debug.apk).
  Its key was discarded with the CI job, so it cannot update any other install
  and nothing can update it in place. No receipt shows it was installed.
- GitLab `v0.5.0-dev.630e20d5` CI debug APK, source `630e20d5`, signer
  `CI_EPHEMERAL_630E20D5` (v2 only), SHA-256
  `9ab1b198f7bf638c4a8ebb40f8aca7ae7171bfeab879a7ea0aecbfee1f3ed782`:
  [gitlab-mobile-630e20d5-debug.apk](https://gitlab.com/api/v4/projects/86648389/packages/generic/gitlab-mobile-preview/630e20d5566a6fd48ef100cec999e724741cf256/gitlab-mobile-630e20d5-debug.apk).
  Its key was discarded with the CI job, so it cannot update any other install
  and nothing can update it in place. No receipt shows it was installed.
- GitLab `v0.5.0-dev.a2eb7ba6` CI debug APK, source `a2eb7ba6`, signer
  `CI_EPHEMERAL_A2EB7BA6` (v2 only), SHA-256
  `b2a5edbb09897821f2395bdb6c5ae4208cc43b51e0622889e1aaae38e38b99fa`:
  [gitlab-mobile-a2eb7ba6-debug.apk](https://gitlab.com/api/v4/projects/86648389/packages/generic/gitlab-mobile-preview/a2eb7ba689d9bdcdf67adc5f5efaf6ed063723fd/gitlab-mobile-a2eb7ba6-debug.apk).
  Its key was discarded with the CI job, so it cannot update any other install
  and nothing can update it in place. No receipt shows it was installed.
- GitLab `v0.5.0-dev.4e4d2979` CI debug APK, source `4e4d2979`, signer
  `CI_EPHEMERAL_4E4D2979` (v2 only), SHA-256
  `b0a0c1377935be20df6a025ac27e19796c4de31cd686e24b4cf87986712f9417`:
  [gitlab-mobile-4e4d2979-debug.apk](https://gitlab.com/api/v4/projects/86648389/packages/generic/gitlab-mobile-preview/4e4d2979b6f5ae1b5cf2e6fd4718314bec5d18b6/gitlab-mobile-4e4d2979-debug.apk).
  Its key was discarded with the CI job, so it cannot update any other install
  and nothing can update it in place. No receipt shows it was installed.
- Package registry APK for `main` `1158ca89`, signer `STABLE_CI_DEBUG`, SHA-256
  `a9d973e00326b9e184a73443550313939d178ff315a2c7fa7b0b3c9b7f996a62`, no GitLab
  release. The same package also holds an earlier upload with the same file name,
  signed by an ephemeral key (SHA-256 `a21d2860…7d4a`); the file-name URL serves
  the newer, stable-signed one.
- GitLab `v0.5.0-dev.6c1a1033` CI debug APK, source `6c1a1033`, signer
  `STABLE_CI_DEBUG` (v2 only), SHA-256
  `116498e2067a91cbdc523a4ad90b6b093316495dce65192dd9b821dac8bd9a49`:
  [gitlab-mobile-6c1a1033-debug.apk](https://gitlab.com/api/v4/projects/86648389/packages/generic/gitlab-mobile-preview/6c1a103330065b80fb6d93f21eec15512a442a95/gitlab-mobile-6c1a1033-debug.apk).
  Later `main` previews use the same signer and are expected to update it in
  place; a device update is NOT_RUN. No receipt shows it was installed.

On Android 13 (API 33) and later, a `LEGACY_LOCAL` install updates in place to
the bridge and then to the ordinary release. That chain passed natively on an
owned API 36 emulator (`ad49850` to bridge to ordinary) with the same UID,
data-directory inodes and synthetic CE/DE data retained
(`artifacts/key-recovery-20261009/bridge-native-upgrade-and-own-sdk-closure-root-proof.json`).
It did not test the phone, real accounts or draft decryption. On API 24-32
the bridge stays on the old signer and cannot continue to the ordinary
release; a bridge install there has not been run. The bridge does not apply
to `HISTORICAL_CI23` installs.

### Lookup order

Before concluding that a signer or APK is missing, check in this order:

1. The public inventory and the canonical directory: file names, sizes and
   modes only. Never open or log private content.
2. Retained APKs under `artifacts/`: compare their public certificate SHA-256
   with the inventory.
3. This project's own worktrees and packaging receipts.
4. Current-project CI metadata (job, pipeline, release links, variable
   metadata), recording which scope was searched.

A file missing from one path means "not found at that path", not "lost".
Private files are never copied between hosts or created by an ordinary build.

The installed signer on a device is unknown until that device is read
directly; the phone is reserved and stays untouched. A generic "install
failed" message in a UI does not prove a signer mismatch. Never uninstall,
clear data or generate a random key to get past a mismatch.

Ordinary local APKs must carry the current stable certificate above. Only a
special migration artifact may use the legacy key, and only with the existing
lineage. Migration or data-retention claims need a native install receipt.

### Recording new APKs

Every future packaging or release step adds an entry to the inventory, or a
receipt that it links to, with: APK SHA-256 and size, certificate SHA-256 per
signature scheme, application ID, `versionName`/`versionCode`, `debuggable`
and min/target SDK, source commit, build lane and variant, Dart entrypoint
(for example `lib/main.dart`), whether QA or benchmark flags were enabled,
and either a durable download URL or an explicit `local-only`. Private files stay outside
Git and `artifacts/`.

## CI boundary

Since 2026-10-18, `ANDROID_DEBUG_KEYSTORE_B64` is a protected, masked project
CI variable, and `v*` tags are protected. Pipelines on protected refs (`main`,
`v*` tags) sign the debug APK with that stable CI identity (`STABLE_CI_DEBUG`,
`CN=GitLab Mobile CI Debug`, certificate SHA-256
`5bec28281b4c1405f9ee47590c40665a24b0f984fc0d6b8854a3458e8db0a71d`). Its
private keystore is also kept as `ci-debug.p12` in the canonical directory
(mode `0600`); it is a CI preview key, not used for ordinary local builds.
Unprotected pipelines keep the ephemeral fallback. The CI identity differs
from `CURRENT_LOCAL`, `LEGACY_LOCAL` and `HISTORICAL_CI23`, and the local
private identity is not copied into CI.

CI debug APKs with a different signer cannot update locally signed APKs in place.
Treat local development signing, CI preview signing and Play production signing
as separate evidence lanes.

## References

- [Android app signing](https://developer.android.com/studio/publish/app-signing)
- [Flutter Android deployment](https://docs.flutter.dev/deployment/android)
