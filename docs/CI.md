# CI and development preview delivery

## Workflow

The repository uses project-locked private runners on the two-host CI fleet, with tags `grok-box`, `ondemand`, and `gitlab-mobile`. Each host executes at most one CI job at a time; its dispatcher rotates between projects with eligible pending jobs after each job finishes. Jobs can therefore wait for a fleet turn, but do not consume GitLab-hosted runner compute quota. Pushes, merge-request events, tags and manually started branch pipelines run checks. A branch push with an open MR is suppressed to avoid duplicate branch/MR pipelines. All required jobs use `allow_failure: false` by default.

New projects require explicit runner registration and dispatcher onboarding on each host; adding tags alone does not grant access. For this project, both registrations are locked to `gitlab-mobile` and reject untagged jobs. The existing `python:3.13-slim` job image, toolchain pins, checks and artifact delivery remain in use. A pipeline created before the routing change retains its old job tags; verify a new pipeline for the updated commit rather than retrying the old quota-failed jobs.

1. `python_checks`: report-converter, local-smoke runner, package-installer and native-bootstrap regressions, Python compilation, shell syntax.
2. `flutter_checks`: dependency-lock enforcement, Flutter analysis, 68 Flutter unit/widget/smoke tests in the initial CI baseline, JUnit and LCOV. The current test count is read from the job report, not inferred from this document.
3. `native_templates`: generate/review Android and iOS runner configuration from the pinned SDK. Linux generation is not an iOS build or device test.
4. `android_debug`: needs all three checks, reuses their dependency lock and native templates, and builds an Android debug APK.
5. `publish_preview`: main/default branch only, verifies checksums and uploads APK/metadata/checksums to the same project's Generic Package Registry.

No tests or analyzer failures are ignored. A missing/unsuccessful Flutter completion event makes the JUnit conversion fail. Tests emit compact live progress, per-test limits and an overall test-process deadline. CI does not silently fix or reformat the source and claim the changed code was tested.

## Toolchains and reproducibility

- Flutter 3.47.2 from its exact Git source tag; `flutter --version --machine` is checked before use.
- `pubspec.lock` versions and hosted-package SHA-256 values are committed. Both analysis and Android jobs use `flutter pub get --enforce-lockfile`.
- Android command-line tools build 15859902; the official Linux archive SHA-256 is pinned in `ci/install_android.sh`.
- The compile SDK is read from the pinned Flutter Gradle extension. The first build may install additional plugin-required platforms/NDK versions through the accepted Android SDK licenses.
- JDK 21, Python 3.13 and a Debian-based container. The container/OS patch packages and downloaded Android platform revisions are not fully byte-for-byte hermetic. Build metadata identifies the actual Flutter/Dart revision and source commit; do not claim bit-reproducible APKs.

Caches accelerate Flutter, Pub and Android/Gradle downloads. Only infrastructure failures are retried automatically. No unrelated VPS or project runner is enabled or reconfigured.

Package setup uses Debian HTTPS sources, three download retries and 30-second connection timeouts. An incomplete package-index update or failed installation stops the job immediately; signature and TLS checks remain enabled. This avoids the HTTP mirror 502 failure observed during private-runner onboarding, which previously left `git` unavailable for SDK installation.

Flutter jobs append `--no-same-owner` to `TAR_OPTIONS`, keeping extracted SDK files owned by the container's current user. Flutter's Gradle wrapper archive contains ownership IDs outside the rootless user mapping; restoring those archive IDs would fail. Jobs continue to run through the unprivileged container executor.

## Artifacts and credentials

JUnit, raw test JSON, analyzer output and LCOV remain attached to the check job even after failure where available. Android APKs, `SHA256SUMS` and `build-metadata.json` are retained as job artifacts for 14 days. Default-branch delivery creates a registry version named after the full commit SHA, not a mutable `latest` label.

Delivery uses `CI_JOB_TOKEN`, not a personal token. No credentials are committed, printed deliberately, embedded into the APK or sent in URL query strings. CI fixtures contain only synthetic API identities. The pipeline does not enable CI job-token repository pushes.

## Android preview versus production

The output is a **debug development preview**. The preview records the commit in the app's 我的 tab. Ephemeral debug signing keys differ between runners and from a developer machine; updating between such previews then fails with `INSTALL_FAILED_UPDATE_INCOMPATIBLE` (silently under `adb install -r`) and requires uninstalling the old one, losing its local accounts and drafts. To make previews update in place, set the masked, protected CI variable `ANDROID_DEBUG_KEYSTORE_B64` to the base64 of one debug keystore (alias `androiddebugkey`, passwords `android`); `ci/build_android.sh` restores it to `~/.android/debug.keystore` before the build and records the choice in `build-metadata.json` (`signing`). That is still a debug signature. Production/updatable distribution requires a separately managed stable signing key and release configuration. Neither Play publication nor a production release is configured by this pipeline.

## iOS and product acceptance

An iOS binary needs a macOS runner with an appropriate Xcode toolchain. App Store/TestFlight deployment also needs signing and distribution credentials. Neither has been assumed or enabled. G0 acceptance additionally needs actual private-project access, device secure-storage/backup tests, account switching, network failure and accessibility evidence on Android/iOS. These remain separate from green CI.

## Isolated Android emulator UI QA

The QA-only target `tool/emulator_ui.dart` renders the production project,
environment/deployment, schedule and project/group Work Item pages through the existing synthetic
transport. It requires `EMULATOR_UI_QA=true` and displays a persistent synthetic
data banner. Its memory-only accounts use test credentials; every API request
stays in the fixture adapter. Normal `lib/main.dart` has no fixture fallback.

Use a project-owned AVD with an already installed official Android image and
an explicit `emulator-*` serial. Confirm `ro.kernel.qemu=1` and the AVD name
before installation or input. Do not use an unqualified `adb` command or copy
accounts from a physical phone. For the current isolated AVD:

```sh
.fvm/flutter_sdk/bin/flutter run --profile --no-pub -d emulator-5580 \
  -t tool/emulator_ui.dart --dart-define=EMULATOR_UI_QA=true \
  --dart-define=PERF_LABEL=synthetic-emulator
```

Observe the actual Android Share chooser, verify its canonical URL and dismiss
it without selecting a recipient. Cover Star/Unstar, environment navigation,
schedule confirmation/cancellation, session invalidation and narrow/large-text
layouts. Work Item QA also covers cancellation, close/reopen with fresh readback,
and removing a confirmation after session ending. Activity QA covers both scopes,
all six filter/order combinations, continuation, refresh and session invalidation.
Check the complete above-field activity labels in screenshots at both default
size and 320dp/2× text; passing geometry tests or a successful tap alone does
not establish correct label painting. Restore any emulator font/display changes
after the run. The existing
scroll sampler emits numeric frame summaries only; emulator fixture timings
do not establish physical-device performance or live GitLab acceptance.
Production APK login/cold-start and the anonymous `public_api_smoke` suite are
recorded separately. This manual lane is not a new CI emulator job.

Official references:
- <https://docs.gitlab.com/ci/yaml/workflow/>
- <https://docs.gitlab.com/ci/testing/unit_test_reports/>
- <https://docs.gitlab.com/user/packages/generic_packages/>
- <https://docs.gitlab.com/ci/jobs/ci_job_token/>
- <https://developer.android.com/studio>
