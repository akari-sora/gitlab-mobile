# v0.5 verification ledger

Recorded on 2026-10-02 for branch `feat/v05-mobile-ux-overhaul` (version `0.5.0+5`). It does not accept G0 or v0.5. Synthetic tests, live API reads, live writes and physical-device runs are listed separately; anything not listed here is **NOT_RUN**. The CI pipeline and its JUnit count are recorded in the merge request, not inferred from this file.

## Local checks on the submitted source

- `dart analyze lib test` (pinned SDK 3.47.2 / Dart 3.13.2): no issues, including infos.
- `flutter test --no-pub`: the full suite passed on macOS on the head before this ledger (947 tests in that run). New coverage: `test/v05_api_test.dart` (search, groups, events, award emoji, subscribe with 304, mark-all-done, languages, blame, starrers, file history, fork, schedule play, GitLab link parsing) and `test/v05_ui_test.dart` (scroll chrome, collapsing header, scroll-to-top signal, scoped labels, stage order, activity sentences, find-file matching, draft titles, reactions toggle, focus mode on a phone, issue details and subscription, inbox swipe-to-done, global search scopes, group page, stage-grouped jobs).
- The earlier local-only failure `attachment_limit_test.dart: discardPickedCopy keeps a file outside /cache/` appeared once on unmodified `main` on macOS and passed in later runs; CI runs on Linux.
- Python: `ci/tests` 36 OK, `tool/tests` 15 OK, `compileall` clean.

Existing tests were updated where they encoded the old layout, not the behaviour: recent-project chips are now labelled with the project name (finders scope to the project row), the account row moved into the app-bar account button, the projects scroll view is keyed `projects`, project rows are no longer `Card`s, controls in 更多 can sit above the scroll position, a phone back-stack scenario closes the focused issue before switching project tabs, the pagination stress test uses a 520 dp viewport because rows are denser, and code line numbers assert a 48 dp width with the 24 dp WCAG 2.5.8 height.

## Physical device

Samsung **SM-S9280** (Galaxy S24 Ultra), Android 16, 1080×2340 at 450 dpi (≈384×832 dp). Release APK built locally from this branch with the pinned SDK and the local debug key, installed in place over the 0.4.0 build (`adb install -r`), so the saved account was kept. 我的 showed 「版本 0.5.0 (5) · commit dev」 (local builds have no CI commit define).

Walked in dark and light appearance, portrait, and landscape (NavigationRail at 832 dp):

- Projects: floating search bar returns on scroll up; filter, sort and recent rows scroll away; the bottom navigation hides on scroll and returns on scroll up and when a project opens; the status bar keeps an opaque strip. Groups scope → group page with 專案／子群組／議題／合併請求 tabs.
- Project: collapsing app bar with pinned tabs; dense file tree with breadcrumbs, branch menu, pinned SHA and README; find-file indexed 1056 files and filtered `pubspec`; file viewer with text-height code rows, syntax colours, 檔案歷史 and Blame on real history.
- Issues and MRs: coloured and scoped labels, task and comment counts; opening one hides the project header and tabs (one app bar); the detail header collapses on scroll; system back closes the detail, then the project. MR overview, 變更 file list, 提交紀錄 and Pipelines pages. Related merge requests on an issue. Discussions show system notes as one-line entries.
- CI: pipeline rows with source and age; pipeline page with jobs under their stage; job log page with the collapsing header and failure banner.
- 更多: overview with stars, forks, open issues, language bar and clone URLs; 專案動態, 成員, 環境 (empty state), Pipeline 排程 (empty state), Wiki (GitLab answered 403 for a project with the wiki disabled; the failure notice showed account, instance and target).
- Inbox: collapsing title; 待辦 with the swipe hint and 全部完成; 指派給我 and 我建立的 with the 議題／合併請求 switch (real data).
- Search: 專案 and 議題 scopes against gitlab.com. Link open: pasting `https://gitlab.com/aa22396584/telltale/-/merge_requests/79` opened that merge request.
- 我的: account card, quick links, 我的動態 with project names resolved.

Live writes from the phone, each reversed and checked through the API with `glab api` afterwards:

- Emoji reaction 👍 added to and removed from `aa22396584/telltale!79`; `award_emoji` read back `[]`.
- Star added to and removed from `aa22396584/personal-media-archiver`; `star_count` read back 1, then 0.
- Notification subscription on `aa22396584/telltale#106` turned off, then on; `subscribed` read back `false`, then `true`.

## NOT_RUN

- On the phone: swiping a todo or 全部完成 (would clear real todos), the MR draft toggle, merge, fork, running a pipeline schedule, wiki page rendering (no project with an enabled wiki was used), deployments with data, the two-pane layout at ≥840 dp, TalkBack.
- iOS, store signing, OAuth login, push, the live CRUD smoke on this branch.
