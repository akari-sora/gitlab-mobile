# CI and development preview delivery

The repository uses GitLab-hosted `saas-linux-small-amd64` runners. It does not depend on, unpause, or reconfigure an unrelated project runner.

## Toolchains

- Flutter 3.47.2, installed from its exact source tag and checked using `flutter --version --machine`.
- Android command-line tools build 15859902. The Linux ZIP SHA-256 is pinned to the value published at <https://developer.android.com/studio> on 2026-09-19.
- The Android compile SDK is read from the pinned Flutter Gradle extension, not guessed.
- Dependencies resolved for a check are reused for its Android build. A committed `pubspec.lock` is the intended reproducibility boundary.

## Checks and artifacts

`flutter_checks` analyzes the exact checkout and runs the Flutter test suite with coverage. JUnit is derived from actual Flutter JSON events; a missing completion event fails the report. During initial import, suggested lint/format changes are emitted AFTER the checks as `ci-output/suggested.patch`; those suggestions are not represented as tested commits.

`native_templates` verifies Android/iOS template generation and backup/keychain configuration. Generating an iOS Xcode project on Linux is not an iOS build or device test.

The Android build produces a **debug development preview**, SHA-256 checksums and metadata identifying its commit, pipeline, Flutter/Dart versions, and unperformed device acceptance. It is not a signed production release. Debug signing keys on ephemeral runners can change between builds, so installing a different CI preview may require uninstalling the prior preview (which removes its local data).

The default-branch delivery job uploads previews to this project's Generic Package Registry with `CI_JOB_TOKEN`. It uses no personal access token and does not publish to Google Play or TestFlight.

## Remaining platform requirements

An iOS binary requires a macOS runner with an appropriate Xcode toolchain. App Store/TestFlight deployment also needs separately configured signing and distribution credentials. No such runner or credentials have been assumed or enabled.

A green pipeline establishes only the checks actually present in that pipeline. Real private-repository integration, Android/iOS device acceptance, accessibility review, and the remaining product gates must be reported independently.

Official references: <https://docs.gitlab.com/ci/yaml/workflow/>, <https://docs.gitlab.com/ci/testing/unit_test_reports/>, <https://docs.gitlab.com/user/packages/generic_packages/>, <https://docs.gitlab.com/ci/jobs/ci_job_token/>.
