# CI and development preview delivery

## Workflow

The repository uses GitLab-hosted `saas-linux-small-amd64` runners. Pushes, merge-request events, tags and manually started branch pipelines run checks. A branch push with an open MR is suppressed to avoid duplicate branch/MR pipelines. All required jobs use `allow_failure: false` by default.

1. `python_checks`: 10 report-converter regressions, 6 native-bootstrap regressions, Python compilation, shell syntax.
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

## Artifacts and credentials

JUnit, raw test JSON, analyzer output and LCOV remain attached to the check job even after failure where available. Android APKs, `SHA256SUMS` and `build-metadata.json` are retained as job artifacts for 14 days. Default-branch delivery creates a registry version named after the full commit SHA, not a mutable `latest` label.

Delivery uses `CI_JOB_TOKEN`, not a personal token. No credentials are committed, printed deliberately, embedded into the APK or sent in URL query strings. CI fixtures contain only synthetic API identities. The pipeline does not enable CI job-token repository pushes.

## Android preview versus production

The output is a **debug development preview**. Ephemeral debug signing keys may differ between jobs; updating between such previews may require uninstalling the old one and losing its local data. Production/updatable distribution requires a separately managed stable signing key and release configuration. Neither Play publication nor a production release is configured by this pipeline.

## iOS and product acceptance

An iOS binary needs a macOS runner with an appropriate Xcode toolchain. App Store/TestFlight deployment also needs signing and distribution credentials. Neither has been assumed or enabled. G0 acceptance additionally needs actual private-project access, device secure-storage/backup tests, account switching, network failure and accessibility evidence on Android/iOS. These remain separate from green CI.

Official references:
- <https://docs.gitlab.com/ci/yaml/workflow/>
- <https://docs.gitlab.com/ci/testing/unit_test_reports/>
- <https://docs.gitlab.com/user/packages/generic_packages/>
- <https://docs.gitlab.com/ci/jobs/ci_job_token/>
- <https://developer.android.com/studio>
