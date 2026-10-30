# Changelog

Release history of Mergeline (formerly "GitLab Mobile"). The newest entries come first. Current plans and status live in [docs/PLAN_STATUS.md](docs/PLAN_STATUS.md); verification evidence lives in the ledgers listed in [docs/README.md](docs/README.md).

## Unreleased (on `main`)

- **The AI learns which field a refused write got wrong** (!273). A refused write now tells the model the field and the rule (allowed values, expected type or GitLab's own field error), so small models stop retrying the same call.
- **Placeholder arguments never clear data** (!274). Optional `null`/`""`/`[]` placeholders (and `0` for ids) that small models send are dropped for every model-visible write; a single explicit clear still works.

## 2026-10-30 — v0.6.1: Google Play preparation

- **Report AI answers inside the app** (!270). 回報 on an AI answer posts the report to the developer's Google Form from inside the app, after showing exactly what will be sent; mail or sharing is offered only if the post fails.
- **Demo mode** (!272). 試用 Demo on the sign-in screen runs the whole app on built-in sample data with a scripted, offline AI — no account and no network (except an AI report you choose to send). Used by Play reviewers and for the store screenshots.
- **The Play build carries the AI assistant** (!271); background runs stay off. The privacy policy lists every field an AI report carries.
- GitLab channel: [v0.6.1 release](https://gitlab.com/aa22396584/gitlab-mobile/-/releases/v0.6.1) (versionCode 1658). Google Play: 0.6.1 uploaded, review pending.

## 2026-10-30 — v0.6.0: the AI assistant

- **Bring-your-own-key AI assistant**, on in the GitLab-channel build ([release](https://gitlab.com/aa22396584/gitlab-mobile/-/releases/v0.6.0)). Add a provider under 我的 › AI 助理, then turn on 「允許 GitLab 工具」 in its advanced settings.
- **What the AI can do:** read files, diffs, issues, merge requests, job logs and more, and propose any write the app itself can do.
  - Every write shows a confirmation card first.
  - High-risk writes need the user to type the name.
  - Each write is read back afterwards.
- **Evidence:** both CI lanes (16,424 AI-off and 17,583 AI-on tests), synthetic sandbox suites, and one emulator walkthrough with `gpt-4o-mini` on a private sandbox project: read, create issue, comment, create/delete branch, close issue and a rejected proposal. The in-app update from v0.5.0 was also checked.
- **Not tested:** the per-operation live matrix is **NOT_RUN** by owner decision.
- **Not shipped:** Google Play and iOS. Current state and next steps are in [PLAN_STATUS](docs/PLAN_STATUS.md).

## 2026-10-22 — reviewed AI answers and clearer list actors

- **AI answers stay drafts until reviewed.** A completed, display-safe Work Item answer can be appended to the existing ordinary-comment draft, preserving its Markdown and whitespace. Opening, leaving and reopening the editor sends nothing; posting still requires an explicit Save. Production AI remains disabled by default.
- **Authors and pipeline executors.** GraphQL Work Item lists show each author, with a narrowly matched fallback for older schemas. Pipeline rows add executors progressively while keeping the summary available immediately; requests are cached, bounded and discarded when their owning account or page changes.
- **Android verification.** The final source passed 5,046 Flutter tests and full analysis. A synthetic run on the project-owned API 36 emulator kept the write count at zero through append/reopen, then recorded one acknowledged post after Save and displayed the combined body. The original installed APK was restored and its bytes matched the saved SHA-256. The public receipt is [here](docs/receipts/2026-10-22-ai-comment-qa.json); [MR !98](https://gitlab.com/aa22396584/gitlab-mobile/-/merge_requests/98) carries the exact-head CI and merge record. Local evidence alone is not CI success. Real-provider/private-project, physical-device, publication and G0 acceptance remain open. iOS validation is deferred while Android is the current priority.

## 2026-10-20 — Mergeline, 24 languages and an app lock

- **Markdown media.** README files and descriptions render repository, external HTTPS and HTML images, SVG and animated images, plus tap-to-load in-app audio/video with bounded downloads and account-scoped temporary cleanup; unlike GitLab web, images inside inline raw-text tags render, and audio/video fallback is hidden only for plain text and complete tags within 4096 characters and 16 tags.
- **24 languages.** Traditional and Simplified Chinese, English, Japanese, Korean, Spanish, Brazilian Portuguese, French, German, Italian, Russian, Ukrainian, Polish, Dutch, Swedish, Czech, Romanian, Turkish, Arabic (right-to-left), Hindi, Thai, Vietnamese, Indonesian and Malay. The app follows the device's languages (English when none of them is translated); 我的 › 外觀 › 語言 picks one, and Android 13+ and iOS also offer the choice in the system's per-app language settings. Switching keeps the open pages and drafts.
- **App lock.** 我的 › 安全性 › App 鎖定 (off by default) asks for a fingerprint, face or the screen lock when the app opens and after more than a minute away. Turning it on needs one passing check, so nobody locks themselves out.

- **New name.** The app is called **Mergeline** in the launcher, the title bar and 我的. GitLab's trademark guidelines keep the GitLab marks out of third-party app names and Play removes unofficial clients named after the service, so the store name carries no trademark; `docs/STORE_LISTING.md` has the listing copy and its rules. 我的 shows GitLab's trademark notice.
- **Same app on the GitLab channel.** Releases published here keep the package `io.gitlabmobile.gitlab_mobile`, so installed previews update in place and keep their accounts. The Play build (not yet listed) will be `app.mergeline`.

## 2026-10-19 — smoother switches and polish

- **No more flashing switches.** Changing destination, opening a section or an item and going back no longer blanks the screen for a frame; see the Motion note below.
- **Polish.** Issue, merge request and pipeline headers line up with the content under them and no longer crowd the app bar. The inbox's reason filters are smaller outlined chips under the filled scope pills, and 探索 keeps its sort control on screen on narrow phones, with the scopes fading out beneath it.

## 2026-10-18 — updates, release builds, motion and inbox triage

- **In-app updates.** Android builds come in two flavors.
  - **`gitlab`**, published here: 我的 › 應用程式更新 checks this project's releases anonymously (once at start-up unless turned off). It downloads the newer APK, verifies its size and SHA-256 against GitLab's record, and hands it to Android's installer for the user to confirm.
  - **`play`**, for Google Play (not yet listed): uses Google Play's in-app updates and has no install permission.
- **Release builds.** GitLab previews built from `main` and release tags are now release builds (AOT, R8), about 70 MB instead of 180 MB, and versionCodes now increase with every pipeline.
- **Smoother lists.** Rows no longer rebuild on every frame while the bottom bar slides away; that was 140 row rebuilds per hide on 探索.
- **Skeleton rows.** Lists show placeholder rows in the shape of their content while they first load, instead of a lone spinner; they hold still under reduced motion.
- **Motion.** Destination switches cross-fade, and sections and opened items slide in over the page they came from and slide away again. The page underneath always stays painted, so no switch flashes the bare background; page pushes fade over the canvas colour instead of a lighter surface. Sections fold open, and writes are confirmed with haptics. Reduced motion is honoured, including iOS Reduce Motion.
- **Inbox triage.** Filter chips (審查, 提及, 指派, Pipeline 失敗, 合併請求, 議題) and todo snooze with an 已延後 list (needs GitLab 17.9+, covered by the minimum above).
- **Links from other apps (Android).** Share a GitLab link to GitLab Mobile from any app, or let it open gitlab.com links (Android 12 and later ask once: 我的 › 連結 opens that system setting). The link opens from 探索 for the active account; a link for another instance is explained, not opened.
- **New launcher icon.** It is rendered from `tool/render_icon.py`.

Device review is `NOT_RUN`.

## 2026-10-17 — GitHub Mobile–style layout

The app now looks and navigates like GitHub Mobile: a near-black (or soft
grey) canvas with graphite sections and one blue accent, and four
destinations — 首頁, 收件匣, 探索, 我的. 首頁 gathers 我的工作 (cross-project
issues and merge requests, CI/CD, projects, groups, activity, stars) behind
coloured tiles, plus recently opened and starred projects and shortcuts. A
project opens on an overview with its description, counts, star/fork/share
actions, section rows and the README; the 檔案 / 議題 / MR / CI / 更多 tabs are
one tap away. The inbox uses filter pills and an illustrated empty state.
Material You colours are now opt-in under 我的 › 外觀. Details are in the v0.6
section of [the UX notes](docs/UI_REDESIGN.md); device review is `NOT_RUN`.

## 2026-10-02–03 — mobile parity and performance follow-up

The current development branch adds issue boards and card/list management,
revision comparison, server-backed MR draft review, selected-ref repository
graphs, actual pipeline dependency graphs, package/container/Terraform registries,
native contributor/repository/CI analytics, lazy multi-file Snippets and guarded
file actions, server-discovered GraphQL Work Item types, bounded project/group and descendant
lists with server-side scope/state/search/type/order controls, group-list deep links and project/group details with guarded close/reopen actions, native assignee and label replacement, and lazy status, milestone, weight, iteration, health, time-tracking and
development attributes, a lazy activity timeline with server-side activity/comment/history filters,
oldest/newest ordering, bounded discussion/reply paging and guarded Markdown comments,
replies and ordinary note edits,
collapsed long descriptions, and typed Task/Incident workflows
with separate incident escalation state. Issue/MR filters use server
ordering. Phone board columns, vertical graphs and lazy lists retain native
navigation. The [full-function ledger](docs/MOBILE_WEB_PARITY_LEDGER.md) records
all 30 observed Web project entries and keeps every remaining workflow open;
these additions do not establish complete GitLab parity.

Loading and scroll work adds a bounded, account-client in-memory read cache for project resolution and immutable-SHA text, concurrent request sharing, memoized list derivation and a page-owned syntax-span LRU. Server cache directives, explicit refresh, writes, account/client changes and authorization failures invalidate or disable reuse. See the [current parity and performance report](docs/MOBILE_PARITY_PERFORMANCE.md) for the complete Web navigation matrix, safety boundaries, measured results and remaining NOT_RUN lanes.

Current Diff rendering also builds changed-file rows lazily, parses text over
64 KiB in a background isolate, and reuses bounded parsed rows only for the
same API owner, account, project, MR, head, path and exact source. Repository
raw-source search is debounced, keeps line selection distinct from query
matches, preserves valid same-resource state on refresh, and clears retained
source/index state when account, API, project, ref or path ownership changes.
These changes reduce repeated work; they are not a new FPS or smoothness claim.

Resource details expose direct native link sharing. The project header also
offers Star/Unstar, sharing the same confirmed state with 更多 and refreshing
the project feed after a successful change. Link sharing sends only a canonical
instance-aware URL; repository file links retain the immutable commit and any
selected line. Account changes invalidate pending actions and reaction pickers.

Environment deployment views share the canonical GitLab environment link using
its numeric ID; the deployment website remains a separate action. Pipeline
schedule confirmations and results belong to the account/session that opened
them, and repeated Play taps open one confirmation.

Work Item close/reopen reads the latest lifecycle, identity and update permission,
confirms the current account and scope, writes once and checks an independent
readback. Unsupported servers remain readable; uncertain results require a fresh
read before another action. OPEN/CLOSED remains separate from custom workflow
status. GitLab exposes no timestamp compare-and-swap for this mutation.

Work Item comments and replies use a fresh permission/identity check, one
GraphQL mutation and an independent exact-note readback. Reply targets preserve
the server's opaque `replyId`. Account/resource changes invalidate open editors;
uncertain writes retain secure drafts and block repeat submission.

Ordinary project/group Work Item Markdown notes expose an on-demand edit action.
Their action menu also copies and shares validated instance-aware note permalinks,
including installation subpaths and the exact numeric note fragment.
The App trusts GitLab's fresh `Note.userPermissions.adminNote` result rather than
inferring permission from the author, then checks the displayed revision, scope,
account and API owner again before one `updateNote` mutation. An exact independent
readback confirms the result. A no-op consumes the target without sending the
mutation, and edited Markdown preserves leading and trailing whitespace. Uncertain
writes retain the secure draft and block repeat Save; older servers that reject the
optional capability query remain readable. GitLab's current
[`UpdateNoteInput`](https://docs.gitlab.com/api/graphql/reference/#updatenoteinput)
has no compare-and-swap field, so a race remains between the final preflight and
the update. This is not atomic conflict protection or authenticated private/iOS
acceptance. See the [GraphQL guide](https://docs.gitlab.com/api/graphql/) and the
upstream [`UpdateNote` mutation at the reviewed commit](https://gitlab.com/gitlab-org/gitlab/-/blob/26212baacadb5beea6664f7ef025d753dccfb0d6/app/graphql/mutations/notes/update/base.rb).
Ordinary public notes also expose guarded deletion and on-demand reactions;
internal notes and quick actions remain open. These write flows have source,
synthetic regressions and dedicated-emulator UI evidence; authenticated private
CRUD and iOS acceptance remain separate.

Project and group Work Items independently load the current user's notification
subscription when the notification section is expanded. The dedicated
`workItemSubscribe` mutation accepts an explicit desired state and uses
`update_subscription`, independently of general Work Item editing. GitLab does
not expose that permission in `WorkItem.userPermissions`: an authenticated read
with the notifications widget permits an attempt, and the server authorizes it.
Each attempt binds the actor and exact Work Item scope, sends once and checks a
fresh independent readback. Missing widgets and unsupported schemas stay explicit;
uncertain writes require a manual refresh. Subscription is personal state and is
not inferred from a Work Item type name or an absent widget. GitLab's input has
no atomic compare-and-set field. See the reviewed upstream
[`Subscribe` mutation](https://gitlab.com/gitlab-org/gitlab/-/blob/a011400989c4b7a5b626752dbfc35941e745bf34/app/graphql/mutations/work_items/subscribe.rb).

Project/group Work Items also expose an on-demand title and Markdown description
editor using account-scoped encrypted drafts. Opening reads fresh content and
`updateWorkItem` permission; a missing DESCRIPTION widget permits title-only
editing. Saving sends only changed fields, preserves Markdown whitespace, checks
the actor, exact scope/type and original revision/content, then verifies one
mutation with an independent readback. Any failed attempt requires reopening
with fresh server state. GitLab accepts the nested `descriptionWidget` input and
has no atomic compare-and-swap; this remains distinct from live private/iOS
acceptance. See the reviewed
[`Update` mutation](https://gitlab.com/gitlab-org/gitlab/-/blob/a011400989c4b7a5b626752dbfc35941e745bf34/app/graphql/mutations/work_items/update.rb)
and [current ledger](docs/MOBILE_WEB_PARITY_LEDGER.md).

The existing Work Item milestone row now opens a native selection page. It
preserves the current assignment, including closed and server-expired milestones,
and offers explicit removal, submitted name searches and bounded loading of
active project/group and ancestor milestones. Clearing does not depend on the
candidate query succeeding. Each save uses fresh `readWorkItem` and
`setWorkItemMetadata` permission, exact scope/revision checks, one milestone-only
mutation and an independent readback. A failed save requires closing and
reopening; the preflight/update interval is not atomic conflict protection.

The existing weight row edits only that item's own weight. Null, zero and the
read-only rolled-up totals stay distinct. The editor reads fresh `readWorkItem`
and `adminWorkItem` permission instead of reusing the row that was already on
screen. One save sends the item ID and `weightWidget.weight`; null clears and
zero is stored. GitLab's update has no compare-and-swap. A failed or uncertain
attempt is not replayed and does not replace the row. This describes the local
source shape. Exact-archive, emulator, CI, live private, iOS and TalkBack runs
are **NOT_RUN**. They are not G0 acceptance or a performance claim. See the
[parity ledger](docs/MOBILE_WEB_PARITY_LEDGER.md).

Project and group Work Items replace the whole assignee set from the detail.
The editor opens after a complete fresh connection (`first: 100`, at most 20
pages, stop at 2,000). The parent already shows the first 20 names until a
write starts. Search calls project or group `autocompleteUsers` with the
submitted text and keeps at most 20 users; it does not page candidates.
People already assigned stay in the set when search omits them. Save always
preflights actor, `readWorkItem`, `setWorkItemMetadata`, revision and the full
current set before a write or a no-op. One `workItemUpdate` input is `id` and
`assigneesWidget.assigneeIds` only. `[]` clears.
`allowsMultipleAssignees: false` is one radio choice; `true` is checkboxes.
`adminWorkItem` and `updateWorkItem` do not grant the metadata permission.
The target matches actor, scope and revision, is used once, and has no
compare-and-swap. The mutation does not select `Query.currentUser`; that name
is a query field, not an input. Success is the acknowledgement plus a
separate complete read of the requested set. An uncertain result is not
replayed: close and reopen on fresh server state. Account, API or revision
changes close the editor and block a late save. Settling one item cannot
clear another. During the write and the parent refetch, stale names and a
false 尚未指派 stay hidden behind 更新中. A failed refetch keeps them hidden
and shows 尚未確認最新負責人. The widget test keeps the 48 dp save control above
the keyboard at 320 dp and 2× text. A signed-out 390×844 public page showed
Assignees / None and did not open this editor. The isolated run is 50 passed
tests (20 API, 20 UI, 10 fixture) and scoped analysis. UI final review is
APPROVE with zero required changes. Full suite, archive, new commit, APK,
native, private, iOS, G0, TalkBack and performance for this editor are
**NOT_RUN**. They are not acceptance.

Project and group Work Items also have a native Labels editor. Opening it reads
the complete current connection in 100-label pages, bounded to 20 pages / 2,000
labels; the detail keeps a 50-label preview. Submitted project/group candidate
search retains completed pages and is bounded to five 20-label pages. The
server's dynamic `allowsScopedLabels` value controls scoped-conflict guidance;
conflicting names intentionally use a two-line preview with an ellipsis.

Save preflights the actor, exact scope/revision, `readWorkItem`,
`setWorkItemMetadata` and the complete current opaque label-ID set. A single-use
target sends only the disjoint `addLabelIds` / `removeLabelIds` delta and requires
a separate complete readback. A no-op consumes the target without a mutation;
an uncertain send is never replayed. The parent retains the actual write token
until terminal completion, including when the editor or row is removed, and
manual refresh cannot publish over an active or newer write. GitLab exposes no
compare-and-swap for this mutation.

The exact eight merged Labels source/test files have a 149-case scoped
Labels/API/UI/Graph/Assignee-preservation matrix and clean scoped analysis from
the separate validation worktree. This is not a full-main aggregate run.
Current-main full analysis/test/build, APK/native, authenticated private CRUD,
iOS, accessibility, performance and G0 acceptance are **NOT_RUN**.

`9d9ebb0` adds a guarded, synthetic-only combined emulator QA helper for large
Diff, repository-source, project-list and Labels flows. With the eight Labels
files copied in as prerequisites, an isolated worktree passed 128 scoped
synthetic tests with zero failures/errors/skips, and an independent review
approved it. It is a separate scoped run, not full-main, native or performance
evidence. Pipeline `2910293827` for `a82892e` was last read running with only
`python_checks` passed; it is not a CI pass and does not validate `9d9ebb0` or
`c28bfbe`.

`c28bfbe` integrates the milestone, weight and assignee write fences into
current main. The detail page owns each metadata write token, checked against
account, API client, resource, generation and summary, so a write outlives its
editor and a recreated attributes panel. While the write is pending the affected
row shows 等待讀取 with editing disabled; after the acknowledgement the
recreated panel issues exactly one fresh read instead of stalling. Labels write
gating is unchanged. A scoped 350-test synthetic matrix (metadata API/UI, Labels,
project/group Graph, attributes and emulator fixtures) passed with zero
failures/errors/skips and clean scoped analysis, and an independent review
approved with zero required changes. The 350, 128, 149 and 92 runs are separate
scoped matrices on their own source cuts; they are not summed and are not full
acceptance. Current-source full analysis/test/build, APK/native, CI,
authenticated private CRUD, iOS and G0 remain pending.

## v0.5 — mobile UX overhaul and GitLab parity

Still a development preview. Evidence is in the [v0.5 ledger](docs/V0_5_VERIFICATION.md); anything it does not list is **NOT_RUN**.

- Chrome gives way to content: page headers collapse while scrolling and return on any scroll up, the bottom navigation hides on scroll, and tapping the active destination scrolls its list to the top. The projects tab has a floating search bar; filters, sorting and recent projects scroll away with the list.
- On phones an issue or merge request opened inside a project owns the screen: the project header and tabs step aside instead of stacking a second app bar and tab bar above the detail.
- Dense lists: grouped rows for projects, files, pipelines, jobs and activity; issue and MR rows show GitLab label colours (scoped `scope::value` labels as two segments), assignees, comment and task counts, due dates and conflicts. System notes in discussions are one-line timeline entries. Code rows are text height with a 48 dp line-number column.
- New GitLab features: search across the instance (projects, issues, MRs, milestones, users) and inside a project (code, commits, comments, wiki, plus the same kinds), run when submitted; groups with subgroups, projects, issues and MRs; project and personal activity feeds; emoji reactions; related merge requests and linked issues; due date, time tracking, weight and notification subscription; MR commits, MR pipelines and a draft/ready toggle; file history, blame and find-file; project overview with stars, forks, languages, licence, clone URLs, the viewer's star state and fork; members, wiki, environments, deployments and pipeline schedules (run now); jobs grouped by stage, showing the latest attempt of retried jobs.
- Inbox: a swiped todo is marked done after a 4-second 復原 window (tab paging is off so a sideways swipe always means the row); 全部完成 asks first; assigned, review-requested and created-by-me lists switch between issues and MRs.
- Pasting a GitLab issue, MR, pipeline, job, commit or SHA-pinned file link into 以連結或路徑開啟 opens that resource. A link to a project the account cannot see opens the ambiguous-404 notice (account, instance, target, retry, switch account).

## v0.3 — collaboration preview

This revision continues the v0.2 API-backed collaboration screens. It is a **development preview**, not a claim that every GitLab feature, server edition, permission configuration, or device has passed end-to-end testing. !3, !7, !6, !8, !5 and !4 are merged. `main` is `9183f19`. A behaviour was exercised only on the build named in the [v0.3 ledger](docs/V0_3_VERIFICATION.md).

- PAT sign-in, account identity verification, multiple account isolation, removal of a saved account, GitLab.com and HTTPS self-managed instances. OAuth PKCE is wired and stays inert until a real Application ID is registered for that instance.
- Device appearance (light, dark, or system) stored on the device and restored after a force-kill (!3). The same key stores the Material You dynamic-colour flag (!6).
- Project membership/starred/accessibility search, private project lookup by numeric ID or full namespace, project create/edit/delete, star/unstar, and a pending-deletion badge (!5).
- Branch-aware fixed-SHA repository browsing, Markdown/raw text, file create/read/edit/delete with `last_commit_id`, branch/tag create/read/delete and commit history.
- Issue and merge-request create/read/edit/delete, close/reopen, self-assignment, labels and personal todos. Label, assignee, reviewer and branch pickers (!7).
- Notes and threaded discussions, replies, own-note edit/delete, discussion resolve/reopen, collapsed resolved threads with an unresolved filter and summary (!3), bounded pinned-version diffs, validated single-line review positions, and existing discussions shown on the diff (!4).
- SHA-bound approval/merge requests. The merge dialog offers squash and remove-source-branch, and the MR overview has a review card (!3). GitLab remains authoritative for permissions, review policy, protected branches and mergeability.
- Last-account auto-resume on launch (!4).
- Project pipelines, run/retry/cancel/delete, job status/logs/retry/manual play, bounded foreground log polling, and collapsible log sections (!5). The `db12b41` build opens the artifact page in the system browser. On `main`, job archives download in-app: authenticated first hop, exactly one https redirect, no credential headers on that hop.
- Attachment upload (`POST /projects/:id/uploads`, multipart, 25 MiB) and a Markdown toolbar with 編輯／預覽 (!7).
- Material You dynamic colour, predictive back, edge-to-edge layout, and launcher shortcuts (`inbox`, `search`, `recent:<projectId>:<digest>`) (!6).
- Release, project-label and milestone CRUD. Commits are immutable; branches and tags are not presented as having a fictitious update API.
- Account-scoped encrypted drafts, retained write errors, no automatic retry of uncertain writes, typed confirmation for destructive resource operations.

**Historical v0.3 boundary (at `9183f19`):** OAuth login stayed inert, and push delivery, iOS, a cross-project CI overview and a two-pane wide layout were not in that revision. The current source now contains cross-project CI and retained-state two-pane layouts; see the v0.5 ledger and current parity report for their separate evidence limits. Local Git clone/rebase/terminal and complete enterprise policy management remain outside the tree. App Store / Play signing, an independent human review, a physical-phone run of !4–!8, and a completed live CI job-control suite were **NOT_RUN** for v0.3. Device evidence was one physical Android phone and one Android emulator. The live smoke was not re-run after those merges. Anything this historical section does not tie to the v0.3 ledger stays **NOT_RUN** for that revision.
