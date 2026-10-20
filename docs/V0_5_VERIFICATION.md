# v0.5 verification ledger

Recorded on 2026-10-02 for branch `feat/v05-mobile-ux-overhaul` (version `0.5.0+5`). It does not accept G0 or v0.5. Synthetic tests, live API reads, live writes and physical-device runs are listed separately; anything not listed here is **NOT_RUN**. Test counts come from the CI JUnit report and are recorded in the merge request and the release, not in this file.

## Local checks on the submitted source

Run on macOS with the pinned SDK (Flutter 3.47.2 / Dart 3.13.2) against code commit `72c3e37`:

- `dart analyze lib test`: no issues, including infos.
- `flutter test --no-pub`: the full suite passed. v0.5 coverage lives in `test/v05_api_test.dart` (search, groups, events, award emoji, subscribe and star with 304, starrers paging, mark-all-done, languages, blame, file history, fork, schedule play, GitLab link parsing, external-link filtering, label contrast, system-note text, stage order with retried jobs, draft prefixes, the activity name cache) and `test/v05_ui_test.dart` (scroll chrome thresholds, out-of-sight lists, short-list hysteresis, collapsing header, screen-reader and reduced-motion chrome, scroll-to-top signal, focus mode on a phone, reactions, issue details and subscription, linked issues, related-items failure, unresolved cross-project links, inbox swipe with undo, tab switch during undo, refused and uncertain writes, global search on submit, group page, draft toggle and stale copy, fork and schedule confirmation, star state, blame at 320 dp / 2x, stage-grouped jobs). `test/workspace_widget_test.dart` adds issue detail, inbox, search, group page and 更多 to the 320/412/840 dp × 1x/2x × light/dark matrix; `test/authenticated_app_test.dart` checks every shell destination at 320 dp / 2x and that the gesture inset is reserved once.
- Python: `ci/tests`, `tool/tests` and `compileall` passed.
- The earlier local-only failure `attachment_limit_test.dart: discardPickedCopy keeps a file outside /cache/` appeared once on unmodified `main` on macOS and passed in later runs; CI runs on Linux.

Existing tests were changed where the layout or behaviour changed on purpose:

- Layout only: recent-project chips are labelled with the project name (finders scope to the project row), the account row moved into the app-bar account button, the projects scroll view is keyed `projects`, project rows are no longer `Card`s, controls in 更多 can sit above the scroll position, and the pagination stress test uses a 520 dp viewport because rows are denser.
- Behaviour: an open issue no longer survives switching project tabs on a phone, because the detail now owns the screen and the tabs are hidden while it is open (`challenger2_stress_test` closes it first); code line numbers are 48 dp wide and 24 dp tall (WCAG 2.5.8) instead of 48 dp tall; the bottom navigation no longer sets `maintainBottomViewPadding` because the shell reserves the gesture inset below it; global search runs on submit instead of on every keystroke; a swiped todo is written after the undo window instead of immediately.

## Code review

Three Grok reviewers (state and lifecycle; security and API contract; UI, accessibility and tests) and one Opus reviewer reviewed `911a953..549c388`, then each re-checked the fixes in `76773a5` and `72c3e37`. Every reviewer's final verdict on `72c3e37` had no Critical or Important findings; Opus left only this ledger and the CI run on the final commit. Fixed after review: inbox swipes conflicting with tab paging and writing without undo, offstage lists moving the chrome, re-tap scrolling hidden lists, an older refresh restoring a removed todo, offset paging skipping a todo, a todo dropped by a tab switch during undo, star 304 and unknown star state, award and starrer paging, retried jobs reordering stages, draft prefixes, related items and cross-project links hiding ambiguous 404s, overflow at 320 dp / 2x, label contrast, English labels, and search spending the rate limit. Rejected with evidence: the claim that `GET /projects/:id/issues/:iid/links` returns `source_issue`/`target_issue` wrappers (an authenticated read-only GET on `gitlab-org/gitlab#629525` returned flat issue objects with `iid`, `project_id`, `link_type` and `issue_link_id`).

## Physical device

Samsung **SM-S9280** (Galaxy S24 Ultra), Android 16, 1080×2340 at 450 dpi (≈384×832 dp).

**Run 1 (before review).** Release APK built locally with the pinned SDK from the branch while the walkthrough fixes of `2da8452` were made, signed with the local debug key and installed in place over 0.4.0 (`adb install -r`), so the saved account was kept. Walked in dark and light appearance, portrait, and landscape (NavigationRail at 832 dp):

- Projects: floating search bar returns on scroll up; filter, sort and recent rows scroll away; the bottom navigation hides on scroll and returns on scroll up and when a project opens; the status bar keeps an opaque strip. Groups scope → group page with 專案／子群組／議題／合併請求 tabs.
- Project: collapsing app bar with pinned tabs; dense file tree with breadcrumbs, branch menu, pinned SHA and README; find-file on a 1056-file tree; file viewer with text-height code rows, syntax colours, 檔案歷史 and blame on real history.
- Issues and MRs: coloured and scoped labels, task and comment counts; opening one hides the project header and tabs (one app bar); the detail header collapses on scroll; system back closes the detail, then the project. MR overview, 變更 file list, 提交紀錄 and pipelines pages. Related merge requests on an issue.
- CI: pipeline rows with source and age; pipeline page with jobs under their stage; job log page with the collapsing header and failure banner.
- 更多: overview with stars, forks, open issues, language bar and clone URLs; 專案動態, 成員, 環境 (empty state), Pipeline 排程 (empty state), Wiki (GitLab answered 403 for a project with the wiki disabled; the failure notice showed account, instance and target).
- Inbox, search, link open (`https://gitlab.com/aa22396584/telltale/-/merge_requests/79` opened that merge request) and 我的 with 我的動態.

Live writes in run 1, each reversed and checked through the API with `glab api`: 👍 added to and removed from `aa22396584/telltale!79` (`award_emoji` read back `[]`); star added to and removed from `aa22396584/personal-media-archiver` (`star_count` 1, then 0); notification subscription on `aa22396584/telltale#106` off, then on (`subscribed` `false`, then `true`).

**Run 2 (review fixes).** Release APK built locally from code commit `72c3e37` with the pinned SDK, SHA-256 `f2ae76c6ceaa558f0b6e5437f723382849514c50582fb8dd14a98e6f92e3fafa`, installed in place (我的 showed 「版本 0.5.0 (5) · commit dev」; local builds have no CI commit define). The commit after it changes only documentation and one doc comment. Checked:

- Projects list: header and bottom navigation hide on scroll and return on scroll back.
- Inbox, on two todos created for the test with `POST /projects/86385809/issues/106/todo` (action `marked`): a swipe hid the row, the count dropped by one and 「已標示為完成 / 復原」 appeared above the navigation; 復原 brought the row back and the API still listed the todo as pending. A second swipe left to time out removed the row, and the API listed that todo as `done`. A third swipe followed by switching to 指派給我 kept the bar on screen and the todo was marked `done` once. A sideways swipe on 指派給我 stayed on that tab. The 32 pre-existing todos were not touched (pending count 32 before and after).
- 我的: content shorter than 200 dp of scroll keeps the navigation; re-tapping 我的 scrolled back to the top.
- Link open of `gitlab-mobile!38`, back to the projects tab with the navigation visible; `telltale!65` discussions show 「added 1 commit」 without the HTML list or compare link.
- Pipeline `2903147150` titled 「Pipeline #278」 with an 「ID 2903147150」 chip; pipeline `2890534227`, which has retried `native_templates`, `public_api_smoke` and `publish_preview`, lists verify → build → deliver with only the latest (successful) attempt of each job.
- Global search did not query while typing (the hint says to press search) and listed results after the keyboard search action.
- `telltale` 更多: licence 「GNU General …」 and 「移除星標」, matching the API (`license` = GNU General Public License v3.0 or later; starred by the signed-in user).
- Find-file on a 756-file tree: the empty query explains that it lists the first 200; 「README」 reported 27 matches. Blame on `README.md` is titled 逐行作者 with readable commit headers.

## Authenticated live smoke, 2026-10-18

`tool/live_smoke.dart` ran from this container against GitLab.com with the owner's PAT through a 0600 temporary credential file, which was removed after each run. The app code under test is `main` `1158ca89`, which has the same `lib/` as release `v0.5.0-dev.4e4d2979`. The suite creates one private sandbox project and deletes it at the end. The new release-asset check only reads the app's own project.

The final run had 37 PASS, 1 NOT_RUN and 0 FAIL. The new checks are:

- The newest release of `aa22396584/gitlab-mobile` that links `SHA256SUMS` resolves to `gitlab-mobile-preview@4e4d2979…` through `releasePackageFile`. It downloads through `packageFileForDownload` and `downloadPackageFile`, and the bytes match the size and SHA-256 GitLab records.
- A milestone's issues and a label-filtered issue list contain the fixture issue, with the label's colour. A tag carries its release object.
- MR, commit, pipeline and job `web_url`s map to their in-app targets. A job's JSON carries `pipeline.id`, `pipeline.project_id`, `stage` and `ref`.

`jobs.read_trace_retry_new_attempt_and_manual_play` is NOT_RUN because the sandbox pipeline hit `ci_quota_exceeded` on GitLab.com shared runners.

The suite also recorded these observations:

- GitLab.com returns `/-/work_items/N` as an issue's `web_url`. Such a link opens the work item page in the app, not the REST issue page.
- Project events carry no `target_url`. Issue events still have `target_type` `Issue`, so they open through `project_id` and `target_iid`.
- A stale `last_commit_id` file write was rejected with HTTP 400 and the content was kept.

Three earlier runs each stopped at a single check, and each run created and deleted its own sandbox.
- **Run 1:** an assertion that expected `/-/issues/N` failed; the assertion was corrected.
- **Run 2:** the stale-write check failed once with no recorded detail; the check now records its outcome.
- **Run 3:** a transport error while creating the tag was reported as `writeUncertain`.

## Emulator with the owner's account, 2026-10-20

Release `v0.5.0-dev.c13b280d` (versionCode 537, SHA-256 `471e9473…` read back from the installed `base.apk`) on an Android 16 emulator (1080×2424), signed in with the owner's PAT. The token was piped from the password manager into `adb input` and never printed; the account was removed in the app afterwards. Reads only: no write was made with the account.

Worked: sign-in, Home (starred projects), 我的工作 merge requests with the 我建立的 scope and state filter, CI/CD overview, Inbox (3 real to-dos, none marked), Explore → `gitlab-mobile` overview, MR `!44` summary and diff, pipeline `2966275092` jobs and test report (2892/2892), the `android_debug` log, job artifacts download (37.8 MB, with progress and 開啟／分享), the release page and a verified download of `build-metadata.json` (652 B, SHA-256 `7f59e07e…`, equal to the published file), 應用程式更新 「已是最新版」, language switches in the app (Arabic) and from system settings (Japanese, German, Russian) while a page stayed open, and account removal back to an empty sign-in screen.

Found, all invisible to the fixtures:

- The job log showed the runner's per-line header (`2026-10-20T06:56:59.174912Z 01O`), which runners write when timestamps are on (`FF_TIMESTAMPS`, GitLab ≥ 17.1, as on gitlab.com) and GitLab's own log view hides.
- A long description's summary showed HTML comments and Markdown markers (`<!-- CURSOR_AGENT_PR_BODY_BEGIN --> ## What I found`).
- In Arabic, `!44` read `44!`, `@<owner>` read `<owner>@` and an English description's full stop moved to its start; 「منذ 6 يوم」 used the singular after 6.

Fixed in merge request !84. Synthetic tests: `test/job_sections_test.dart` (headers, `+` continuations, the job log page), `test/rest_work_item_description_test.dart` (the description preview) and `test/bidi_test.dart` (the laid-out order of `!44`, `#12` and `@user` in Arabic text, `markdownSummary` edge cases and its bounded time on hostile single lines): `JobTrace.parse` removes the headers and joins `+` continuation lines as GitLab's `Gitlab::Ci::Ansi2json::Converter` does; summaries come from `markdownSummary`, which keeps code and drops comments, tags and markers; Arabic messages isolate each value with its sigil and GitLab text shown on its own is isolated piece by piece; the day count uses 「ي」 like minutes 「د」 and hours 「س」.

### The fixed builds on the same emulator

Merge-request debug APKs (signed with each pipeline's throwaway key, so the release was uninstalled first), same emulator and account, reads only, the account removed afterwards:

- `c8505ac` (`gitlab-mobile-c8505ac3-debug.apk`, SHA-256 `f949f60e…`): the `android_debug` log of its own pipeline starts with `Running with gitlab-runner 19.4.1 (3c39fceb)`, with no header on any line, and lists its sections with durations (`prepare executor · 0 seconds` … `upload artifacts on success · 11 seconds`). MR `!44`'s collapsed summary reads `What I found Job artifact saves in lib/features/workspace/ci_page.dart …`. In Arabic the MR header reads `!44`, the author line `@<owner>` with `@` on its left and 「منذ 6 ي」, and the inbox 「منذ 1 ي」.
- `dc814b7` (`…dc814b73-debug.apk`, `7ce0c9b8…`): the editor for `.gitlab-ci.yml` on `main`, switched to Arabic while open, shows the subtitle `.gitlab-ci.yml · main` in order (closed without saving). This run found the file page title reading `gitlab-ci.yml.`.
- `a41f1de` (`…a41f1de8-debug.apk`, `79a99bfc…`): the file page title reads `.gitlab-ci.yml` in Arabic.

- Release `v0.5.0-dev.a3b83b60` (versionCode 552, `80f9c7e4…`, the merge of these commits): the `android_debug` log of its own pipeline shows no header, MR `!44`'s summary is readable text, and the Arabic MR header reads `!44`. The summary changes after `a41f1de` (`590652e`) ran on a device only in this release build.

Still seen and not fixed here: a page opened before a language switch keeps the title it was opened with (the editor's 「Edit file」), like the error messages noted for the 24-language release.

## NOT_RUN

- On the phone: swiping or 全部完成 on real todos (only the two test todos above were written), the MR draft toggle, merge, fork, running a pipeline schedule, wiki page rendering (no project with an enabled wiki was used), linked issues with real links, deployments with data, the unresolved-project page against a real 404, the two-pane layout at ≥840 dp, TalkBack, reduced motion, 2x system font size (covered only by widget tests).
- iOS, store signing, OAuth login, push, the live CRUD smoke on this branch.
- A physical phone, TalkBack with Arabic text, a native Arabic speaker's review of 「ي」, and the remaining fixed screens (editor subtitle, file title, inbox) on the release build itself (they ran on the merge-request builds above).
