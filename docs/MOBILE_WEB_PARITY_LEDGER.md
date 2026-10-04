# Full mobile Web parity ledger

Goal: implement all available GitLab workflows with reasonable native mobile UX,
and verify them in the browser and installed App. This ledger does **not** declare
full parity, G0, release readiness, or private/paid-feature acceptance.

On 2026-10-02, the signed-out public project's responsive navigation (390 × 844)
exposed the following 30 project entries. Every menu label, destination and actual public page was
observed. Work-item creation redirects to sign-in and was not authenticated;
public empty states do not establish configured-feature or mutation acceptance. Authenticated, Premium/Ultimate, self-managed and
configuration-dependent entries require additional cataloguing. The README's
referenced 105-spec `docs/plan` package is absent from this checkout; no missing
specification numbers have been invented.

| Web entry | Browser page observation | Current native source | Open functionality/acceptance |
|---|---|---|---|
| Manage / Activity | Loaded timeline and eight event filters at phone width | Activity feed | Full event-kind/authenticated parity walk |
| Manage / Members | Loaded roles/source/search/sort and member rows | Member list/actions | Custom roles, complete administration and live permissions |
| Manage / Labels | Loaded Active/Archived, search/sort and empty state | List/create/edit/delete | Scoped labels/subscriptions and live CRUD |
| Plan / Work items | Loaded six issues and mobile detail; additional actual project Issue and group Epic details, mobile Activity timeline and group aggregate list observed | Existing REST Issues/Tasks/Incidents plus fixed-query GraphQL project/group-owned and descendant cursor lists with scope/state/search/type/order controls, server type capabilities, project/group details, collapsible description/assignees/labels/hierarchy/dates, project/group assignee and label replacement, seven lazy attribute kinds, server-filtered/ordered activity paging, guarded Markdown comments/replies, ordinary note editing/deletion, on-demand emoji reactions, lazy personal notification subscription and close/reopen | Remaining widgets, internal-note workflows, custom saved views and remaining list display/sort families, remaining Work Item mutations and authenticated/edition acceptance |
| Plan / Boards | Development board observed | Phone-width columns, card move, board/list management | Paid scope/list creation, touch drag/drop and live mutation readback |
| Plan / Milestones | Loaded empty-state explanation | List/detail/create/edit/delete | Full progress/reporting and live CRUD |
| Plan / Wiki | Loaded empty Wiki explanation | Page list/read/create/edit/delete | History, attachments, tree and live CRUD |
| Code / Merge requests | List/review public walk | Detail/discussion/diff/approval/merge/server draft review | Multi-line comments, viewed-file sync, review policies and live draft CRUD |
| Code / Repository | Loaded tree/ref/find-file/actions and README | Tree, fixed-SHA viewer, blame/history/edit/search | Locked files and complete repository administration |
| Code / Branches | Loaded Overview/Active/Stale/All, search and MR links | List/create/delete/protection controls | Rule completeness and live CRUD |
| Code / Commits | Loaded ref/search, date groups, tags and MR badges | List/detail/changes | Full filters/signature/policy parity |
| Code / Tags | Loaded search/order/direction, release and pipeline links | List/create/delete | Full signature/release policy parity |
| Code / Repository graph | Loaded mobile timeline and branch/history controls | Selected-ref parent graph, branch/tag picker, bounded pagination | Web full all-branch/simplified history modes and live large graphs |
| Code / Compare | Fixed-revision comparison observed | Merge-base/direct compare, lazy actual unified diffs | Cross-project compare and complete controls |
| Code / Snippets | Empty project list plus a real three-file public Snippet; README source/preview toggle verified at phone width | Explicit file list, lazy selected blob, source/Markdown preview and guarded metadata/file CRUD | Authenticated/private mutation and installed-build acceptance; current snapshots use change detection because no immutable HEAD is exposed |
| Build / Pipelines | List/detail/stage controls observed | Lists/actions/tests plus actual paginated needs graph | Downstream/cross-project graph and pipeline editor |
| Build / Jobs | Loaded kind/state filters, stacked job/pipeline/stage rows and runner tags | Incremental ANSI logs/search/actions/artifacts | Full Web filters, large-log physical profiling |
| Build / Pipeline schedules | Loaded periodic-run empty state and owner/variable explanation | List/create/edit/run/delete | Inputs, ownership, complete policy and live CRUD |
| Build / Artifacts | Loaded 53 records, archive/trace expansion, sizes and created dates | Pipeline/job artifacts browse/download | Project-wide inventory, retention and bulk operations |
| Deploy / Releases | Loaded release cards, order, archives, assets and evidence | List/detail/create/edit/delete | Evidence/assets/milestone workflow parity and live CRUD |
| Deploy / Package registry | Actual 20-version list and three-asset detail observed; mobile asset expansion exposes SHA-256 | Search/sort/paged list, files, verified numeric file download/open/share, guarded deletion | Older-instance download capability, type-specific installation/publish/policies and live write proof |
| Deploy / Container registry | Loaded empty state, search/order and cleanup explanation | Repository/tag/digest/detail and guarded deletion | Empty project has no live tag example; publish/policies/bulk cleanup |
| Operate / Environments | Loaded empty state and review-app controls | List/detail/create/stop/delete | Full metrics/terminal/rollback/protection and live CRUD |
| Operate / Terraform modules | Loaded module-registry empty state and documentation | Filtered package list/files/verified numeric download/guarded deletion | Real module download proof, installation/publish and live write proof |
| Monitor / Incidents | Actual empty Open/Closed/All view observed | Typed list/create/edit/severity; separate issue state and GraphQL escalation lifecycle | Actual Incident fixture CRUD/lifecycle, alerts, timeline, metrics and on-call capabilities |
| Monitor / Service Desk | Loaded email-support explanation and sign-in requirement | Not implemented | Capability/permissions, confidential Ticket widgets and email-aware replies |
| Analyze / Value stream | Loaded six stages, lifecycle metrics and filters | Not implemented | Scope/date/stream/stages/metrics, tier-dependent aggregation |
| Analyze / Contributors | Loaded per-author/day charts, ref selector and 6,000-commit limit | Native ref-scoped contributor aggregate with bounded pagination; no author email or inferred GitLab identity | Complete per-author Web time series and authenticated acceptance |
| Analyze / CI/CD | Loaded source/ref/date controls, counts/rates and duration chart; actual Push filter readback | Native source/ref/date filters, actual aggregate counts/median and daily counts/p50/p95 | Capability-gated job analytics, full chart interactions and authenticated/edition acceptance |
| Analyze / Repository | Loaded language/coverage/distribution sections and 2,000-commit limit | Native languages, nullable coverage summary and paged non-merge commit activity | Full Web distribution histograms and authenticated coverage acceptance |

## Account and performance acceptance

The additional read-only Snippet walk used
[GitLab's public three-file fixture](https://gitlab.com/gitlab-org/gitlab/-/snippets/6030720).
Its README and two shell-file headers, source/preview toggle and server-provided
raw URLs were observed. The GraphQL lookup obtains an opaque Snippet GID through
project-scoped enumeration; it does not construct one from a REST numeric ID.
Native multi-file source and regression coverage now exist; this browser observation
does not establish installed-build or write acceptance.

The later 390 × 844 walk also loaded project Work Item
[631894](https://gitlab.com/gitlab-org/gitlab/-/work_items/631894) and group Epic
[23883](https://gitlab.com/groups/gitlab-org/-/work_items/23883). Both place
attributes below the description. The group Epic has a group parent and ten
project children, so hierarchy navigation must preserve each server-returned
scope. Status, milestone, weight, iteration, health, time tracking, development
and activity were observed separately. Seven attribute kinds now have native lazy
reads and per-row retries. Read-only activity now loads on expansion with opaque
discussion/reply continuations; reply creation and other widgets remain open.
Type names are configurable and opaque IDs are not REST route discriminators.

The installed `0ff2265` Android release loaded project `631894`, group `23883`
and its project child `631872`; the cross-scope child remained accessible at 2x
font scale and the original device setting was restored. Opening group parent
`18225` exposed a legitimate relative assignee avatar URL that the old parser
rejected. The unused avatar query/DTO field is now omitted, with failing-before
regressions and anonymous production-client parent readback. A further 390 x 844
browser walk loaded that actual parent, its assignee, dates, hierarchy and activity.
The later `24b622e` Android release was installed without clearing account data;
the installed APK bytes match SHA-256
`167a15bf31e3d6ff8d609ca7f84836a790a73569d469a90efd3e1abef6aa2cf4`.
Its project `631894` attributes show the actual New status, group-owned milestone
19.5 and zero time values. Opening `18225` from the actual group parent link now
loads Board Saved Views successfully. Null weight, iteration and health values
remain explicit. These are public read checks, not private or write acceptance.

That same installed build exposed a separate Snippet description failure:
expanding the description of public `6030720` made Markdown horizontal scroll
views read the ancestor disclosure's boolean storage as a double. Table and
fenced-code regressions both fail before the repair. `MarkdownView` now owns its
own storage bucket; the joint Markdown/Snippet/attachment suite passes 77 tests.
The `6ff3bf3` release was then installed with matching APK bytes
(`1b4091db22e17d7efcfa41af50d7b08f2adce98bfed455c8b9534baacba9edc6`).
Its actual Snippet description table renders, horizontal drag reveals additional
columns, and collapse/re-expand works. README Markdown preview and selection of
the non-default VM file also show actual content. File and metadata editors were
opened and cancelled; no server write was submitted. The fenced-code repair has
widget regression coverage; that separate physical path was not exercised.

A further 390 × 844 browser walk reached group `23883`'s actual Activity section:
parent/label/child additions and description/title changes appear in a timeline,
with activity-kind and order controls. Native read-only activity is the current
implementation slice. It retains at most five discussion pages and five note pages
per discussion, with a total 2,000-note / 4 Mi-character retained-payload budget.
Only the active discussion page is built, with at most 100 activity bodies laid out.
Over-budget responses leave the existing cache usable and show the limit. Empty
pages retain pagination controls. Descriptions over 800 runes start collapsed,
with their character count and preview cached between rebuilds. Filtering/order,
editing and server-write acceptance remain separate work.

That same `6ff3bf3` installed build reads the actual group `23883` activity,
advances to the second page and returns to the cached first page. The long
description initially stays collapsed, and after expansion it still renders
when scrolled out of the viewport and back. Allowlisted checks of this App's own
process logs find zero occurrences of the earlier bool/double storage error,
build-time setState failure or RenderFlex overflow during this walk. These read
checks do not establish nested-note continuation, private writes, iOS or measured
frame-rate acceptance.

The 2026-10-03 group-list browser walk at 390 × 844 showed the actual GitLab.org
aggregate list, its Open-state filter, row type/path/state and 20-item next-page
controls. That Web default includes descendant project items. The native fifth
group tab now defaults to open items including descendant groups and projects,
and provides explicit root-only scope, state, submitted search, server-provided
type and created/updated order controls. Filters apply on the server before
bounded 20-row pagination. Changing conditions clears the previous rows and
cursors; late responses cannot refill the new query. Continuations retain the
exact normalized filter and opaque group identity. Type selection is bound to
the root namespace that returned its capabilities, and unsupported schema
controls remain explicit failures rather than silently changing scope.
Rows open through their returned namespace scope rather than a fabricated
Project. The same IID in different descendant namespaces remains distinct.
Custom saved views and the remaining list display/sort families remain open;
the existing REST issues/MR tabs are separate workflows. The group-list controls
and inbox transient-action regression receipts live under
`artifacts/mobile-parity/group-list-controls/` and
`artifacts/mobile-parity/inbox-action-rebuild/`. Installed-build and private/iOS
acceptance must be read from their actual receipts rather than inferred from
these source changes.

Each new page binds responses and modal closures to account/instance, numeric
project identity, API generation and request epoch. ProjectMore/Pipeline remove
owned roots and their descendants on replacement. Boards preserves legal
coexisting labels during card movement. Registry replacement clears old rows
before the new response. Snippet `file_name` alone never proves complete content.
These contracts have synthetic regression coverage; synthetic passes are not
real private-project or server-write acceptance.

The first-slice cache and rendering changes, exact `a86c0ad` CI evidence, and
physical profile measurements are documented in
[MOBILE_PARITY_PERFORMANCE.md](MOBILE_PARITY_PERFORMANCE.md). New feature screens
require their own installed-build readback. Frame-count-weighted profile samples
on one S24 Ultra do not establish statistical improvement on every screen.

The current merged Diff/repository slice lazily builds 120-file change-list
fixtures, bounds large-Diff isolate parsing and exact-source API-owned cache
reuse, debounces raw-source search over a 20,000-line fixture, preserves
intentional line selection separately from matches, and verifies distant line
anchors and owner invalidation. Its 92 passing scoped synthetic tests and clean
scoped analysis came from a separate worktree, not a full-main aggregate.
Current-main full analysis/test/build, APK/native and quantitative performance
are **NOT_RUN**; no FPS or smoothness result is inferred.

## Next implementation lanes

The later 390 × 844 public walk of project Task
[631946](https://gitlab.com/gitlab-org/gitlab/-/work_items/631946), project Issue
[631759](https://gitlab.com/gitlab-org/gitlab/-/work_items/631759) and group Epic
[14501](https://gitlab.com/groups/gitlab-org/-/work_items/14501) confirmed
comments/history controls, newest-first order, per-thread Reply to comment,
Expand/Collapse replies and a signed-out register/sign-in prompt. Collapsing a
thread retained its reply count and last-reply summary. No comment was posted.
Native Markdown comment/reply creation now has guarded API/editor source and
synthetic project/group regression coverage. Exact-source APK, installed native
checks and CI evidence belong to the commit-bound delivery receipts; this does
not establish authenticated live GitLab write acceptance.

A fresh 390 × 844 signed-out walk of Issue 631759 opened an existing note's
More actions menu: Copy link and Report abuse were visible; authenticated Edit
was not observed. Native note actions now also provide copy and native sharing
of validated project/group permalinks, preserving instance ports/subpaths and
the numeric `#note_` fragment. Edit permission remains independently checked
on demand. This browser observation does not establish live edit acceptance.

Ordinary project/group Markdown notes now expose an on-demand edit action. The
capability query uses GitLab's fresh `Note.userPermissions.adminNote` value; it
does not infer permission from author identity. Before writing, the App checks
the displayed revision, exact note/discussion and project/group scope, current
actor, account and API owner. It sends one `updateNote` mutation and requires an
exact independent readback. A no-op consumes the edit target without a mutation,
while real edits preserve Markdown whitespace. Uncertain results retain the draft
and block repeat Save. Unsupported optional edit queries do not break the normal
activity reader. GitLab's current
[`UpdateNoteInput`](https://docs.gitlab.com/api/graphql/reference/#updatenoteinput)
has no compare-and-swap field, so the last preflight and update are not atomic.
These source and synthetic checks do not establish authenticated private, live
server-write or iOS acceptance. See the [GraphQL documentation](https://docs.gitlab.com/api/graphql/)
and the reviewed upstream [`UpdateNote` mutation](https://gitlab.com/gitlab-org/gitlab/-/blob/26212baacadb5beea6664f7ef025d753dccfb0d6/app/graphql/mutations/notes/update/base.rb).

Ordinary project/group public-note deletion and reactions now have guarded
native source and synthetic API/widget coverage. Delete uses the same server
`adminNote` permission as Edit and displays the current note and resource before
explicit confirmation. Its acknowledgement requires `destroyNote.errors: []`
plus an independent same-actor/same-parent read with an explicitly absent note;
a missing parent, authorization/read failure or changed actor remains uncertain.
Reactions use the separate `awardEmoji` permission, complete cursor paging before
inferring absence, and explicit add/remove followed by independent readback.
Targets are owner/revision bound and single use; uncertain results cannot replay.
Opening the action menu does not fetch awards, and activity reading remains
independent of optional mutation schemas. The shared native picker offers 26
existing emoji choices, counts and current-user highlighting. Owned menus close
when account, API, resource or feed identity changes. A fresh signed-out
390 × 844 browser walk again observed Copy link and Report abuse; authenticated
Delete/reaction controls were not observed. Four anonymous production-client
reads of the actual existing public note successfully parsed both optional
capability queries and granted neither write target. This is read-only evidence,
not live authenticated delete/reaction acceptance. Commit-bound APK, emulator,
review and CI receipts are stored under `artifacts/mobile-parity/work-item-note-actions`.
GitLab's current mutations provide no CAS field. Reviewed source:
[`DestroyNote`](https://gitlab.com/gitlab-org/gitlab/-/blob/26212baacadb5beea6664f7ef025d753dccfb0d6/app/graphql/mutations/notes/destroy.rb),
[`AwardEmoji` permission/input](https://gitlab.com/gitlab-org/gitlab/-/blob/26212baacadb5beea6664f7ef025d753dccfb0d6/app/graphql/mutations/award_emojis/base.rb),
and [GraphQL pagination](https://docs.gitlab.com/api/graphql/getting_started/#pagination).

1. Typed REST Tasks/Incidents now have source and regression coverage. Complete
   installed-build checks and disposable-fixture CRUD/lifecycle readback; alert,
   timeline, metrics and on-call workflows remain open.
2. Fixed-query GraphQL Work Items now include server-returned scope/type IDs,
   project cursor paging and exact project/group details with five base widgets
   plus seven independently loaded attributes, project/group assignee replacement, guarded Markdown activity comments/replies,
   ordinary note edits/deletion and emoji reactions. Complete remaining
   widgets and internal-note workflows, custom saved views and remaining list display/sort families,
   remaining native mutations and actual authenticated/private/edition validation.
3. Multi-file Snippet blobs now have lazy paths/content, source/Markdown preview
   and guarded file actions with `updatedAt` change detection. Complete
   installed-build and private disposable-fixture validation. Describe a current
   snapshot; do not claim a fixed SHA or infer a ref.
4. Registry type-specific installation/publish/policies and complete repository graph.
5. Contributor aggregate, coverage summary and CI/CD series now have native
   implementation work. Complete installed-build/CI readback; VSA, complete
   histograms, per-author time series and capability-gated job analytics remain
   open. Null/unavailable analytics do not become zero-valued charts.
6. All 30 public page walks are recorded. Continue authenticated/paid/configured cataloguing,
   new Android screens, real private-project integration, disposable-fixture
   CRUD, iOS binary/device and screen-reader verification.

Incident lifecycle changes use a fixed GraphQL mutation, numeric project/IID
preflight, an owner check immediately before the mutation, timestamp conflict
check and independent readback. Mutation timeouts or malformed acknowledgements
remain uncertain and are never automatically replayed. Issue open/closed state
and triggered/acknowledged/resolved escalation state have separate controls.

Official contracts: [Incident management](https://docs.gitlab.com/operations/incident_management/manage_incidents/),
[Issues](https://docs.gitlab.com/api/issues/),
[GraphQL](https://docs.gitlab.com/api/graphql/),
[Work Item migration](https://docs.gitlab.com/api/graphql/epic_work_items_api_migration_guide/),
[Project Snippets](https://docs.gitlab.com/api/project_snippets/),
[CI/CD analytics](https://docs.gitlab.com/user/analytics/ci_cd_analytics/),
[Repository analytics](https://docs.gitlab.com/user/analytics/repository_analytics/).

## Work Item notification follow-up

A fresh signed-out 390 x 844 browser walk actually paints Subscription / None on
project Issue [631759](https://gitlab.com/gitlab-org/gitlab/-/work_items/631759) and
group Epic [23883](https://gitlab.com/groups/gitlab-org/-/work_items/23883). The
authenticated toggle was not observed. The owned tab closed and viewport reset;
no live subscription changed.

Native notification state loads only when expanded. The exact server-owned GID,
project/group scope, type and actor bind an explicit subscribe/unsubscribe
attempt, independent of general editing. The backend's dedicated subscription
authorization is not exposed in WorkItem.userPermissions; widget presence plus
an authenticated readable item permits an attempt, not a claim that write
permission was pre-approved. One send and an independent state readback are
required. Missing widgets remain distinct from unsubscribed, and uncertain
results require manual refresh before another attempt. Delivery receipts live
under `artifacts/mobile-parity/work-item-notifications/`; read their actual
commit and executed cases before attributing installed-build or CI acceptance.
Private/edition/iOS and other Work Item widgets and mutations remain open.

## Work Item content editor follow-up

The same project/group pages were actually viewed at 390 x 844 in a signed-out
browser: titles wrap, Markdown headings/lists/links render, tables scroll within
their area and long descriptions offer Read more. More actions offers Copy
reference, Report abuse and Truncate descriptions. The authenticated edit flow
was not observed. The owned tab closed and temporary viewport reset.

The native title action opens a fresh permission/content read only when tapped.
It reuses encrypted account drafts, Markdown preview and existing project tools.
The server's DESCRIPTION widget determines whether the description is editable;
an absent or unavailable widget does not invent that capability. Title-only
editing remains available with update permission. The opaque single-use target
binds actor, API owner, exact project/group scope/type, updatedAt and original
title/raw Markdown. Preflight rejection sends no mutation; a no-op also sends
none. A change sends only changed fields once and verifies acknowledgement plus
independent readback. Every failed save blocks reuse until the user closes and
reopens the editor. Unsupported optional queries preserve ordinary reading.

The upstream
[`Update` mutation](https://gitlab.com/gitlab-org/gitlab/-/blob/a011400989c4b7a5b626752dbfc35941e745bf34/app/graphql/mutations/work_items/update.rb)
and
[`DescriptionInputType`](https://gitlab.com/gitlab-org/gitlab/-/blob/a011400989c4b7a5b626752dbfc35941e745bf34/app/graphql/types/work_items/widgets/description_input_type.rb)
accept direct title and nested descriptionWidget; neither provides a content
compare-and-swap input. A concurrent write can still race after final preflight.
Receipts under `artifacts/mobile-parity/work-item-content/` identify actual
source, tests, installed emulator cases and CI; absent receipts are NOT_RUN.
Authenticated private edits, quick-action side effects, older-server editions,
iOS and remaining Work Item mutations remain open.

## Work Item milestone follow-up

A signed-out 390 x 844 browser walk actually painted Milestone / None in the
project Issue and group Epic attribute rows above, and the project's milestone
list with state tabs, title filter and due/start/name sort choices. It did not
observe an authenticated editing picker or change a live milestone.

The native milestone action belongs to the existing attribute row. Its full-page
picker keeps the current closed/expired assignment visible, offers removal even
when candidate loading fails, and stages one explicit selection before Save.
Active candidates come from a fresh identity-checked project/group connection
including ancestors; path prefixes never establish eligibility. Search submits
explicitly. Pages contain at most 50 rows and stop at 200; duplicate IDs and
cursor cycles fail closed. Expiry comes from the server rather than a client
timezone calculation.

Fresh `readWorkItem` and `setWorkItemMetadata` permission bind a single-use
milestone target independently of general title/description editing. The exact
update input contains only the item ID and nested `milestoneWidget.milestoneId`;
inner null clears. Preflight checks the original revision and milestone, and
acknowledgement plus an independent readback must confirm the desired state
before replacing the existing row. Every failed attempt requires reopening.
GitLab's update has no atomic compare-and-swap, so a final concurrent-change
interval remains. Source/browser/build/native/CI receipts belong to
`artifacts/mobile-parity/work-item-milestone/`; absent cases remain NOT_RUN.
Other widget mutations and authenticated/private/edition/iOS acceptance remain
open.

## Work Item weight follow-up

A signed-out 390 x 844 browser walk painted Weight / None on public project
Work Item `631759` and group Work Item `23883`. The project accessibility file
saved with that walk is a sidebar diff and does not contain the Weight row;
the screenshot is the visual record and a full project tree was not invented.
The group accessibility tree is complete and shows Weight / None. Signed-in
editing and live mutations were not run. This tree has no weight
`browser-observation.json`. The screenshots from that walk are the visual
record; this ledger does not invent a metadata hash. The prior frozen checkout
`d745b81369dddda6186414d598d2026dbd9569ad` (short `d745b81`) is not the
repository remote default `main`. It records 2,133 full tests and 339 tracked
files whose bytes matched the tested archive.
`native-cases-d745b81-attempt-4.json` matched the installed package SHA,
passed startup QA, then failed the first case on a bounded `uiautomator dump`
timeout of 1.1856 seconds: 0 PASS and 9 NOT_RUN.
`native-final-release-d745b81-attempt-4.json` is PASS for Android package uid
`10213`, matching hash and development certificate, restored default geometry
and a blank login. Earlier transport-guard stalls stay in their own receipts.
Those receipts are not this assignee source and are not a native pass for
weight.

The native action stays on the existing lazy attribute row. Own weight, zero
and null remain distinct from `rolledUpWeight` and `rolledUpCompletedWeight`.
Opening the editor performs a fresh `readWorkItem` plus `adminWorkItem` read.
An earlier attribute response cannot authorize the write. The mutation input is
only the item ID and `weightWidget.weight`. Null clears. There is no
compare-and-swap. Acknowledgement and an independent readback must show that
own value before the row is replaced. A lost acknowledgement, a consumed
target, a denied permission, a missing widget or a revision change does not
send the mutation again.

Provisional local synthetic tests are separate from exact submitted-source
archive builds, the owned emulator, CI, authenticated private writes, iOS and
TalkBack. Those remain **NOT_RUN**. This slice does not close the ledger gaps
above and does not claim full Web parity, G0 acceptance or measured
performance. Receipts belong under `artifacts/mobile-parity/work-item-weight/`.

## Work Item assignees

Project and group detail can replace the assignee set. The editor opens after
`workItemAssignees` returns a complete fresh connection at `first: 100` for at
most 20 pages, stopping at 2,000 people, with the same actor, scope, revision
and a boolean `allowsMultipleAssignees`. The parent already shows the first 20
names until a write starts. Search calls `autocompleteUsers` on the project,
or on the group when the item has no project, with the submitted query and no
candidate cursor. The client keeps at most 20 names. Inactive people already
assigned stay in the saved set. Save always preflights actor, `readWorkItem`,
`setWorkItemMetadata`, revision and the full current set before a write or a
no-op. The input is `id` and `assigneesWidget.assigneeIds` only. An empty
array clears the set. False `allowsMultipleAssignees` is one radio selection;
true is checkboxes. `adminWorkItem` and `updateWorkItem` do not grant the
metadata permission. The target is single use, sends no mutation when the set
is unchanged, and GitLab's input has no compare-and-swap field. The mutation
does not select `Query.currentUser`; that field is not an input. Success
requires `workItemUpdate.errors: []` and an independent complete read of the
same desired set. Uncertain transport or a mismatched readback is not
replayed: close and reopen on fresh server state. Account, API or revision
invalidation removes the editor and ignores a late save. One item's settle
cannot clear another item. During the write and the parent refetch, stale
chips and a false 尚未指派 stay hidden behind 更新中. A failed refetch keeps
the chips hidden and shows 尚未確認最新負責人. Widget tests check the 48 dp footer
at 320 dp and 2× text. That is test proof only.

A signed-out 390×844 public observation recorded Assignees / None in main
`AssigneesRoot/browser-observation.json` and did not authenticate or write.
Current evidence is the isolated 50-test run (20 API, 20 UI, 10 fixture) and
scoped analysis. An earlier 39-test fixture run, including weight and
milestone, passed separately. API and fixture review approved with zero
must-fix items. UI final review is APPROVE with zero required changes in
`artifacts/mobile-parity/work-item-assignees/ui-final-review.json`. Full
suite, archive, new commit, APK, native, private, iOS, G0, TalkBack and
performance for assignees are **NOT_RUN**. The other parity gaps stay open.
Walking all 30 menus does not mean every function is complete. Pin
[`a011400989c4b7a5b626752dbfc35941e745bf34`](https://gitlab.com/gitlab-org/gitlab/-/blob/a011400989c4b7a5b626752dbfc35941e745bf34/doc/api/graphql/reference/_index.md)
documents
[`workItemUpdate.assigneesWidget`](https://gitlab.com/gitlab-org/gitlab/-/blob/a011400989c4b7a5b626752dbfc35941e745bf34/doc/api/graphql/reference/_index.md#mutation-workitemupdate-assigneeswidget),
[`assigneeIds`](https://gitlab.com/gitlab-org/gitlab/-/blob/a011400989c4b7a5b626752dbfc35941e745bf34/doc/api/graphql/reference/_index.md#workitemwidgetassigneesinput-assigneeids),
[`readWorkItem`](https://gitlab.com/gitlab-org/gitlab/-/blob/a011400989c4b7a5b626752dbfc35941e745bf34/doc/api/graphql/reference/_index.md#workitempermissions-readworkitem),
[`setWorkItemMetadata`](https://gitlab.com/gitlab-org/gitlab/-/blob/a011400989c4b7a5b626752dbfc35941e745bf34/doc/api/graphql/reference/_index.md#workitempermissions-setworkitemmetadata),
[`Project.autocompleteUsers` search](https://gitlab.com/gitlab-org/gitlab/-/blob/a011400989c4b7a5b626752dbfc35941e745bf34/doc/api/graphql/reference/_index.md#project-autocompleteusers-search)
and
[`Group.autocompleteUsers` search](https://gitlab.com/gitlab-org/gitlab/-/blob/a011400989c4b7a5b626752dbfc35941e745bf34/doc/api/graphql/reference/_index.md#group-autocompleteusers-search).
[`update.rb`](https://gitlab.com/gitlab-org/gitlab/-/raw/a011400989c4b7a5b626752dbfc35941e745bf34/app/graphql/mutations/work_items/update.rb),
[`mutation_type.rb`](https://gitlab.com/gitlab-org/gitlab/-/raw/a011400989c4b7a5b626752dbfc35941e745bf34/app/graphql/types/mutation_type.rb)
and
[`query_type.rb`](https://gitlab.com/gitlab-org/gitlab/-/raw/a011400989c4b7a5b626752dbfc35941e745bf34/app/graphql/types/query_type.rb)
are the checked primary files: the mutation payload has no actor field, and
`currentUser` is only `Query.currentUser`. The pin marks widget
[`allowsMultipleAssignees`](https://gitlab.com/gitlab-org/gitlab/-/blob/a011400989c4b7a5b626752dbfc35941e745bf34/doc/api/graphql/reference/_index.md#workitemwidgetassignees-allowsmultipleassignees)
deprecated; this client still reads that boolean and does not read the type
definition instead. Root full-suite, new commit, archive, build and native
evidence remain separate receipts. This does not promise acceptance.

## Work Item Labels editor

Project and group Work Item detail now edits the complete current label set in a
native sheet/page. It reads 100 labels per page to a terminal connection, bounded
at 20 pages / 2,000 opaque IDs, while the parent preview remains capped at 50.
Submitted project candidate search includes ancestor-group labels; group search
is group-only. Both retain completed 20-row pages and stop after five pages.
Selected current labels remain available when search omits them.

Fresh `readWorkItem` and `setWorkItemMetadata`, actor, exact scope, revision and
the complete current set bind a single-use target. Desired additions must come
from the current set or completed candidate pages. A no-op consumes the target
without writing. A change sends only the disjoint opaque-ID `addLabelIds` and
`removeLabelIds` once, then requires a separate complete readback at the
acknowledged revision. Uncertain sends are not replayed. There is no
compare-and-swap, so this is conflict detection around a non-atomic
preflight/write interval, not CAS.

Dynamic `allowsScopedLabels` controls scoped-conflict guidance. Conflict names
are intentionally bounded to two lines with an ellipsis. The actual async write
token remains active until terminal settle even when the route or outer row is
removed; manual refresh and old reads cannot publish over it, and owner
replacement rejects late results.

The exact eight merged files have a separate 149-case
Labels/API/UI/Graph/Assignee-preservation run with zero
failures/errors/skips, clean scoped analysis and an approving final review.
That is scoped worktree evidence, not current-main aggregate proof. Full-main
analysis/test/build, APK/native, authenticated private/live CRUD, iOS,
accessibility, performance and G0 acceptance are **NOT_RUN**. Exact-head pipeline
`2910293827` was pending in the retained snapshot. Historical native evidence
stays attached to `2ccff57`; it does not validate Labels.
