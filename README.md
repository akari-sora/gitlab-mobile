# GitLab Mobile

[![pipeline status](https://gitlab.com/aa22396584/gitlab-mobile/badges/main/pipeline.svg)](https://gitlab.com/aa22396584/gitlab-mobile/-/pipelines)
[![coverage](https://gitlab.com/aa22396584/gitlab-mobile/badges/main/coverage.svg)](https://gitlab.com/aa22396584/gitlab-mobile/-/pipelines)

Mobile-first Flutter GitLab client for **Android and iOS**. Independent and unofficial; not a WebView wrapper and not a desktop UI squeezed onto a phone.

## Current implementation

G0 development preview: PAT sign-in verified with `/user`, account-scoped sessions, member/starred/accessible project discovery, private-project URL/path/ID resolution, distinct 401/403/404/429 states, fixed-commit repository browsing and bounded text-file preview. Switching accounts cancels old requests. Repository content is memory-only in this milestone.

The Inbox and CI app tabs explicitly show pending implementation. OAuth PKCE, MR/Issue collaboration, pipeline controls, push notifications and offline drafts are **not implemented**. A green software pipeline does not mean G0 private-instance/device acceptance is complete.

## Build and run

Use **Flutter 3.47.2** (recorded in `.fvmrc`), Python 3 and the required Android/iOS platform tooling.

```sh
python3 tool/bootstrap.py
flutter pub get --enforce-lockfile
flutter analyze --no-pub
flutter test --no-pub --coverage
flutter run
```

The bootstrap generates Android/iOS runners without overwriting `lib/` or tests, sets the Android backup/cleartext restrictions and iOS keychain entitlements, and refuses to overwrite existing native work. Platform runners are generated, not checked into this initial repository. Native template changes must be reviewed when upgrading Flutter. iOS execution/building still requires Xcode on macOS; distribution signing is not configured.

Use a dedicated, least-privileged PAT on the login screen. Never place a token in source code or public issues. The App verifies its own account independently of any browser login.

## CI/CD

Pushes and merge requests run Python helper tests, Flutter analysis/tests with JUnit and coverage, and native-template verification. Only successful checks can produce an Android debug APK. Main-branch APKs are then uploaded automatically to this project's Generic Package Registry using the short-lived `CI_JOB_TOKEN`.

- [Pipelines and test results](https://gitlab.com/aa22396584/gitlab-mobile/-/pipelines)
- [Development APK package registry](https://gitlab.com/aa22396584/gitlab-mobile/-/packages)
- [CI implementation and limitations](docs/CI.md)
- [Roadmap and acceptance boundaries](docs/ROADMAP.md)
- [Security notes](SECURITY.md)

APK job artifacts expire after 14 days. Registry previews are versioned by their full commit SHA and include `SHA256SUMS` and `build-metadata.json`. These are **debug development builds, not production-signed releases**. Ephemeral debug keys can differ between runs; installing a different preview may require removing the previous preview and its local data.

CI uses the hosted `saas-linux-small-amd64` runner. No unrelated project runner is reconfigured. No personal token is required for CI, no automatic repository-write privilege is enabled for jobs, and nothing is published to Google Play or TestFlight.
