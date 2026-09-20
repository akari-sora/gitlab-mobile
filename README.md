# GitLab Mobile

A mobile-first Flutter client for Android and iOS. Independent third-party software, not an official GitLab application. The interface is Traditional Chinese and supports light/dark appearance and large text.

## v0.2 — collaboration preview

This revision replaces the initial G0 interface and adds working API-backed collaboration screens. It is a **development preview**, not a claim that every GitLab feature, server edition, permission configuration, or device has passed end-to-end testing.

- PAT sign-in, account identity verification, multiple account isolation, GitLab.com and HTTPS self-managed instances.
- Project membership/starred/accessibility search, private project lookup by numeric ID or full namespace, project create/edit/delete, star/unstar.
- Branch-aware fixed-SHA repository browsing, Markdown/raw text, file create/read/edit/delete with `last_commit_id`, branch/tag create/read/delete and commit history.
- Issue and merge-request create/read/edit/delete, close/reopen, self-assignment, labels and personal todos.
- Notes and threaded discussions, replies, own-note edit/delete, discussion resolve/reopen, bounded pinned-version diffs and validated single-line review positions.
- SHA-bound approval/merge requests; GitLab remains authoritative for permissions, review policy, protected branches and mergeability.
- Project pipelines, run/retry/cancel/delete, job status/logs/retry/manual play, bounded foreground log polling. Artifact downloads currently open GitLab in the system browser.
- Release, project-label and milestone CRUD. Commits are immutable; branches and tags are not presented as having a fictitious update API.
- Account-scoped encrypted drafts, retained write errors, no automatic retry of uncertain writes, typed confirmation for destructive resource operations.

**Not yet implemented:** OAuth sign-in, native artifact downloading, attachment uploads, push delivery, local Git clone/rebase/terminal, complete enterprise policy management. iOS binaries, store signing, Android/iOS device validation and the supplied-PAT full live CRUD suite are **NOT_RUN** unless a newer evidence record explicitly states otherwise.

## Verification

See [v0.2 verification](docs/V0_2_VERIFICATION.md) and [mobile UX changes](docs/UI_REDESIGN.md). CI executes the actual Dart/Flutter code; synthetic transport tests are kept distinct from live server checks and physical-device tests.

A real GitLab `Link` header expanded omitted `false` defaults and caused the original project-list failure. The parser now validates immutable scope, preserves the caller's query, and extracts only a safe pagination cursor. Valid first-page data is no longer rejected because GitLab expanded defaults.

## Build and CI

Pinned Flutter **3.47.2** / Dart **3.13.2**; committed `pubspec.lock`. Normal pipelines enforce the lock, run analysis and unit/widget tests, capture actual Flutter-rendered synthetic-data screenshots, generate/check Android/iOS templates, then build an Android debug APK. Only successful `main` pipelines publish commit-addressed preview packages using `CI_JOB_TOKEN`.

```sh
flutter pub get --enforce-lockfile
flutter analyze --no-pub
flutter test --no-pub
python3 tool/bootstrap.py
flutter build apk --debug
```

Screenshots: `flutter_checks` job artifacts → `ci-output/screenshots/`. They are real Flutter host-rendered screens with synthetic data, not an Android/iOS device run or a generated design mock-up. Android APKs: `android_debug` artifacts; main previews: project Package Registry. Debug signing may differ across clean builds; these are not store-signed releases.

## Live CRUD smoke

`tool/live_smoke.dart` uses the production Dart API client and a unique, isolated **private** project. It validates the expected account, performs read-after-write checks and cleans up only its exact synthetic project. Credentials are read from a runtime file; never commit a PAT or use a Dart compile-time define for one.

The `live_crud_smoke` job runs only in an explicit API-triggered pipeline with `LIVE_SMOKE=1`. The credential must be supplied through a secure mechanism approved for the execution environment. The previous attempted credential injection was blocked before pipeline creation; do not bypass that boundary. Until actually executed, its status remains **NOT_RUN**. The normal APK does not include a test PAT.

## Historical specifications

`docs/plan/` preserves the original 105-operation design and acceptance plan. It is a **target specification**, not proof that every operation has been implemented or verified. Earlier G0/R1 documents and package manifests are historical handoffs; the current Git history, CI results and v0.2 verification matrix supersede their status statements.

## License

MIT. See [LICENSE](LICENSE).
