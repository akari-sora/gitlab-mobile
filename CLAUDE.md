# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

`AGENTS.md` is the binding development contract (identity model, ambiguous 404 handling, credential and validation rules, evidence reporting). It is loaded alongside this file; nothing from it is repeated here. Read `README.md`, `docs/CI.md` and `docs/ROADMAP.md` before working. `docs/V0_2_VERIFICATION.md`, `docs/V0_3_VERIFICATION.md` and `docs/V0_5_VERIFICATION.md` are the evidence ledgers, `docs/UI_REDESIGN.md` the UX rules, and `docs/AUDIT_REPORT.md` the defect inventory (`ISSUE-H*` / `ISSUE-M*`). The audit body is the 2026-09-21 text; the 2026-09-22 status block at the top of that file lists what has since landed. Cross-check an issue against that block and `git log` before treating it as open.

## Toolchain and commands

Flutter is pinned to **3.47.2** (Dart 3.13.2) through `.fvmrc`; always use the `fvm` prefix so the system `flutter` cannot drift. `pubspec.lock` is committed and enforced.

```sh
fvm flutter pub get --enforce-lockfile
fvm flutter analyze --no-pub
fvm flutter test --no-pub
fvm flutter test --no-pub test/session_test.dart                       # one file
fvm flutter test --no-pub test/session_test.dart --plain-name 'select'  # one test by name substring
fvm exec bash ci/check.sh   # CI-equivalent: analyze + tests with coverage + JUnit; needs GNU timeout (brew coreutils)
```

The `ci/*.sh` scripts call bare `flutter` / `dart`, and this machine has no system Flutter on `PATH`, so run them through `fvm exec`. Locally `ci/check.sh` exits 1 after a green analyze/test run because its final screenshot-thumbnail step runs `pip install Pillow` against Homebrew's externally-managed Python; the real verdict is in `ci-output/check-status.txt` (`analysis_exit` / `test_exit` / `report_exit`).

Python-side checks (also run in CI):

```sh
python3 -m unittest discover -s ci/tests -p '*_test.py' -v
python3 -m unittest discover -s tool/tests -p test_bootstrap.py -v
python3 -m compileall -q ci tool
```

Native runners (`android/`, `ios/`, `.metadata`) are **not committed**. `tool/bootstrap.py` generates them with `flutter create` and then hardens them (no cleartext HTTP, no backup, keychain entitlements, OAuth URL scheme `io.gitlabmobile.app://oauth/callback`). It refuses to overwrite existing native directories and rejects any Flutter that is not 3.47.2, so pass the fvm binary:

```sh
python3 tool/bootstrap.py --flutter .fvm/flutter_sdk/bin/flutter   # required before flutter run / build apk locally
python3 tool/bootstrap.py --flutter .fvm/flutter_sdk/bin/flutter --check-sdk
fvm exec bash ci/build_android.sh                                    # debug APK + build-metadata.json + SHA256SUMS
```

Smoke tools use the production `GitLabApi`:

```sh
fvm dart run tool/public_smoke.dart   # anonymous public reads against gitlab.com, no token, zero writes
python3 tool/run_live_smoke.py        # prompts a PAT without echo, creates and cleans one isolated private sandbox project
```

`run_live_smoke.py` finds `dart` through `PATH`, so put `.fvm/flutter_sdk/bin` on `PATH` first. Never pass a token on the command line or as a Dart define.

Analyzer settings are strict (`strict-casts`, `strict-inference`, `strict-raw-types`, `unawaited_futures`, `avoid_print`) and CI treats analyzer **info** diagnostics as failures (an unused import has already broken a pipeline). More than half of the Dart files differ from `dart format` output; do not mass-format the repository, format only the lines you touch.

## Architecture

### Layering

- `lib/core/` is plain Dart (only `providers.dart` imports Flutter/Riverpod): instance parsing, HTTP client, failures, pagination, models, OAuth PKCE, unified-diff parsing.
- `lib/features/auth/` owns the session lifecycle. Disk writes are only the secure-storage keys and the artifact temp directory listed under Persistence.
- `lib/features/projects/` holds typed list controllers; `lib/features/workspace/` holds the screens; `lib/features/shell/` is the bottom-nav shell; `lib/shared/` is theme, Markdown and reusable widgets/helpers.
- `lib/core/workspace_api.dart` is `part of 'gitlab_api.dart'`: it adds generic `record` / `records` / `writeRecord` / `removeRecord` over untyped `Json` maps plus typed wrappers (issues, MRs, notes, files, branches, tags, pipelines, jobs, releases, todos). Most workspace screens consume these `Json` maps directly through the `valueText` / `valueInt` / `valueObject` helpers in `lib/shared/workspace_ui.dart`.

### Identity and the API client

`GitLabInstance.parse` accepts HTTPS only and keeps scheme, host, port and installation subpath; `Account.key` is `instance.key#userId`; projects are addressed by numeric ID after resolution. Every cache, draft and controller is bound to one `Account`.

`GitLabApi` invariants (keep them when adding endpoints):

- One immutable account per client. `instance.allowsApi(uri)` gates every request: same origin, `/api/v4` prefix, no `.`/`..` segments, no token-like query keys. Redirects are never followed (`redirectBlocked`). The !5 artifact download is the exception: authenticated first hop with `followRedirects: false`, exactly one https `Location`, fetched by an isolated bare Dio with no credential headers, 256 MiB budget, throttled progress.
- Responses are streamed against a byte budget (4 MiB default, `maxTextBytes` 2 MiB / `maxTextLines` 20000 for text); overruns become `tooLarge`, binary bytes become `unsupported`.
- A 429 `Retry-After` is remembered in `_retryAt` and later calls fail fast with `rateLimited` until it passes.
- Writes are never retried automatically. A transport error on a non-GET/HEAD request is `writeUncertain`, and an OAuth 401 refresh only replays GET/HEAD.
- `close()` cancels all in-flight requests; a closed client only ever throws `cancelled`.

`ApiFailure` / `FailureKind` (`lib/core/failure.dart`) is the single error surface. `safeFailure()` wraps anything unknown as `invalidResponse`. User-facing Traditional Chinese `title` / `detail` strings live on the failure itself. HTTP 404 maps to `invisible`, which the UI must present as ambiguous (see `AGENTS.md`).

Pagination (`lib/core/pagination.dart`): `nextPageUri` parses `Link` / `X-Next-Page`, and `checkedPageUri` rejects any cursor that changes path, drops or alters the caller's non-pagination query, adds scope filters, or does not progress. GitLab expands omitted `false` defaults into the `Link` header, which is why `_falseDefaults` exists. `GitLabApi._validateContinuation` re-checks a caller-supplied `next` against the first-page URL on every call.

### Session, generation and cancellation

`SessionController` (`ChangeNotifier`, exposed only through `sessionProvider`) holds the saved accounts, the `active` account and its `api`. `connect` / `select` / `connectOAuth` take an `_operation` ticket and drop their result if the ticket is stale; `select` re-validates `/user` and rejects a mismatched user ID. Every `_activate` and `endSession` increments `generation`, and `main.dart` keys `AuthenticatedApp` on `ValueKey(session.generation)`, so the entire authenticated widget tree is rebuilt on account switch and the previous `GitLabApi` is closed. `endSession` is local only and does not revoke tokens.

OAuth PKCE is fully wired, but `oauthApplicationIdFor` in `lib/core/oauth.dart` is an intentionally empty map: the OAuth path stays inert until a real application ID is registered per instance. Do not invent one.

### Controller pattern

List/detail state uses `ChangeNotifier` plus an integer epoch (`_epoch` / `_generation`): bump it at the start of each refresh, check `_current(epoch)` after **every** `await`, and guard `notifyListeners` with `_disposed`. A failing later page goes to `pageError` / `failedMore` and keeps the rows already loaded. `RecordController` is the generic `Json` list controller used by workspace screens; `ProjectController` and `RepositoryController` are the typed ones (the latter also caches directory snapshots in memory, bound to one commit SHA). Follow the same shape for new screens.

Riverpod is used only for `sessionProvider`. Screens receive `api` and `account` explicitly through constructors; do not introduce widget-tree providers for per-screen state without a reason.

### Persistence

These are the only disk writes. No repository content, logs or search history is persisted. `clearSecureDrafts(account)` runs before an account is removed. The `db12b41` phone build predates the appearance, last-account, sign-out, recent-project and artifact-cache entries.

Through `flutter_secure_storage`:

- Account list (`SecureAccountStore`, key `gitlab_mobile_accounts_v2`; v1 is read for migration, then deleted).
- Editor drafts keyed `draft.v2.<base64url(account.key)>.<base64url(resource)>`.
- Appearance, key `gitlab_mobile_appearance_v1`, value `<ThemeMode.name>|<0|1>` (theme mode and the dynamic-colour flag). A bare mode name from !3 still decodes. Device-scoped, shared by every account.
- Last active account, key `gitlab_mobile_last_account_v1`. Auto-resume re-validates `/user`. This key is cleared only on a 401. Sign-out marker `gitlab_mobile_sign_out_pending_v1`: auto-resume never runs while the marker is set.
- Recent project, one record per account, key `recent_project.v1.<base64url(account.key)>`: numeric project id and the name shown on the launcher shortcut. Cleared with the account.

Outside secure storage: artifact cache `getTemporaryDirectory()/artifacts/<sha256(account.key) first 32 hex>/<projectId>-<jobId>/<stamp>-<attempt>/`. Removed on account removal. A failed removal keeps the account and reports 無法清除產物. The operating system may purge the directory. Two plugin copies are transient: share_plus copies a shared archive into `<cache>/share_plus/` (deleted at once after a dismissed, unavailable or failed share; after a successful share on the next resume after the app left the foreground; always before the next share and on account removal, best-effort), and image_picker / file_picker copies of a picked attachment are deleted right after their bytes are read (`discardPickedCopy`, cache paths only).

### Shell and UI conventions

Bottom navigation (Inbox / Projects / CI / Me) is an `IndexedStack` whose panes are created lazily on first visit and keep their list state; project, code, review and log screens are pushed as full-screen routes. `lib/shared/scroll_chrome.dart` hides headers (`CollapsingChrome`) and the bottom navigation while the user scrolls down; pages own a `ScrollChromeController` fed by a `NotificationListener`, and `StatusBarInset` keeps nested pages from reserving the status bar twice. Lists kept alive out of sight (inactive panes, the list behind an open detail) run under `TickerMode(enabled: false)`, and both the chrome and `ScrollToTopOnSignal` (re-tap scroll-to-top) ignore them, so keep that `TickerMode` wrapping when adding offstage content. An in-place compact detail reports through `DetailFocus` (`list_detail_scaffold.dart`) so `ProjectPage` drops its own header and tabs. `RecordsFeed` is a sliver list: put search fields and filters in `leading` (scrolls away) or `topSlivers`, and pass `storageId` when `identity` varies with input that lives inside the scroll view. All UI strings are inline Traditional Chinese (no `.arb` / l10n pipeline). Status is always icon plus label, destructive actions go through `confirmAction` (resource deletions pass `requiredText` so the user must type the exact name), and failures are shown through `showFailure` / the failure-notice widgets in `lib/shared/workspace_ui.dart`.

## Testing conventions

- HTTP is faked at the Dio adapter level: `FakeAdapter` / `testApi` / `jsonResponse` in `test/support/fake_adapter.dart`. `WorkspaceFixture` (`test/support/workspace_fixture.dart`) is a stateful synthetic server: unknown endpoints return 404 rather than blanket success, and `failWrites` forces 422 on mutations.
- Widget tests that trigger requests must use `settleNetworkWidgets` (`test/support/widget_settle.dart`) or `settleWorkspace`; `pumpAndSettle` alone does not wait for Dio work or cancellation.
- Session tests build controllers with `MemoryAccountStore` and `controllerFor` from `test/session_test.dart`.
- `test/visual_evidence_test.dart` always writes PNGs to `ci-output/screenshots/`. It loads the Noto CJK font from `/usr/share/fonts/opentype/noto/`, which does not exist on macOS, so local screenshots render text as placeholder glyphs and are not evidence; the glyph-check test skips itself locally and CI throws when the font is missing.
- Do not hard-code a test count anywhere; CI reads it from the JUnit report.

## CI facts that affect contributors

- `.gitlab-ci.yml` runs on project-locked private runners (tags `grok-box`, `ondemand`, `gitlab-mobile`). A branch push with an open MR is suppressed in favour of the MR pipeline. Only successful `main` pipelines publish a preview APK to the package registry.
- Regular pipelines include `public_api_smoke`, so they need outbound access to gitlab.com. `RESOLVE_LOCK=1`, `LIVE_SMOKE=1` and `PUBLIC_SMOKE=1` are API-triggered pipeline variables, not normal pushes.
- Commit messages follow Conventional Commits (`feat(auth):`, `fix(ui):`, `ci:`, `test:`, `docs:`, `refactor:`, `build:`); `[skip ci]` appears on intermediate commits in the history; the commit you hand off must have run the pipeline.
- Evidence vocabulary: synthetic tests, public live reads, authenticated connector checks and physical-device runs are distinct. Anything not executed is reported as `NOT_RUN`, never inferred as passing.
