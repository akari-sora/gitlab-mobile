# Mobile web parity and performance follow-up

Current implementation baseline: `0e1298e` (`v0.5.0`), reviewed on
2026-10-02. This document describes the source on the mobile parity and
performance branch. It is not a release or G0 acceptance record.

## What was compared

The comparison used three distinct sources of evidence:

- GitLab.com responsive pages at 390 × 844: a public project overview, issue
  boards, merge-request list, pipeline list, repository graph, snippets, package list/detail, incidents,
  Service Desk, four analytics pages and the complete project navigation drawer. The 30-entry ledger
  distinguishes menu observation from a completed page walk.
- The current Flutter source and regression tests. This is the source of truth
  for App capability claims below.
- GitLab's official API documentation for [issue boards][boards-api],
  [board behaviour][boards-user], [draft notes][draft-notes], [issues][issues],
  [merge requests][merge-requests] and [repository comparison][compare-api].

The browser walk was signed out and limited to public pages. It confirms the
responsive information architecture, not authenticated, private, Premium,
Ultimate or self-managed-only behaviour. On a phone, GitLab Web uses a compact
top bar and a deep drawer. Board columns remain horizontally arranged at about
one phone-width each; issue/MR lists retain search, filters and sorting; pipeline
rows stack status, identity and stages vertically.

The App keeps its native phone-first structure: four root destinations and five
project tabs, with less-used project tools grouped under 更多. It does not copy
the Web drawer or wrap GitLab in a WebView.

## Current parity matrix

“Before” means the `0e1298e` v0.5 baseline. “This follow-up” means the current
branch. A blank Web menu entry is not evidence that the signed-out account or
GitLab edition lacks the feature.

| GitLab Web area | Before this follow-up | Added or changed here | Remaining boundary |
|---|---|---|---|
| Global navigation | Projects, groups/subgroups, todos, assigned/review-requested/created work, activity and global search | No structural change | Administration, help and creation workflows remain unimplemented; they are part of the full-function backlog |
| Project overview | Description, stars, forks, languages, licence, clone URLs, star/fork actions | Direct header Star/Unstar and link sharing; shared More state/count and project feed reconciliation | Full Web analytics and settings are not reproduced |
| Manage | Activity, members and labels | No structural change | Access-token, webhook, integration and full member-role administration remain open |
| Plan | Issues, milestones and linked work already existed | Issue boards/card moves; typed REST Tasks/Incidents; server filters; GraphQL project/group-owned and descendant Work Item cursor lists with scope/state/search/type/order controls, server types and exact project/group detail with five base widgets, seven lazy attribute kinds, server-filtered/ordered activity, guarded Markdown comments/replies and close/reopen | Remaining Work Item widgets, note editing/deletion/reactions, custom saved views and remaining list display/sort families, remaining mutations, full iterations/requirements/Epic/OKR workflows remain open |
| Code | Repository tree, README, branches, commits and tags; fixed-SHA file view, history, blame, search, syntax highlighting and line permalinks; MR list/detail/diffs | Compare two refs; selected-ref repository graph; multi-file Snippets with explicit file enumeration, lazy source/preview and guarded file actions | Locked files, cross-project comparison, full all-branch graph and private Snippet CRUD acceptance remain open |
| MR review | Discussions, inline single-line positions, approvals/merge, suggested changes, auto-merge, local viewed-file state and the MR draft/ready toggle | Server draft-note list, add/edit/discard and bulk publish, tied to account/project/MR/head SHA | Viewed-file state is not server-synchronised; multi-line positioning and full desktop review policy administration remain open |
| Build | Pipelines, stage-grouped jobs, controls, incremental ANSI logs and search, JUnit report views, artifacts, cross-project CI overview and schedules | Read-only pipeline dependency graph with paginated actual GraphQL needs | Cross-project/downstream graph and the complete pipeline editor remain open |
| Deploy and operate | Environments and deployment history | Package/Container/Terraform lists, details and guarded deletion; numeric package file downloads with size/SHA-256 validation; Incident severity and a separately modelled escalation lifecycle | Registry publishing/policies and type-specific installation, model registries, complete Incident operations and Service Desk remain open |
| Analyze | Basic project counts and activity | Native contributor aggregates, bounded repository activity/languages/coverage, CI source/ref/date filters and actual aggregate/time-series statistics | Value-stream, complete per-author/distribution charts, code-review/issue analytics, insights and model experiments remain open |
| Adaptive layout | Compact phone navigation and retained-state two-pane layout at the expanded breakpoint | New boards show one active column at a time on phones; filters use a native bottom sheet; long result screens remain lazy | iOS physical-device, VoiceOver/TalkBack and authenticated enterprise-screen walks remain NOT_RUN |

This matrix is a navigation and workflow comparison, not a declaration of full
GitLab parity. GitLab has edition-, permission- and configuration-dependent
features that were not available to the signed-out browser walk.

## Delivered workflows and boundaries

### Issue boards

更多 → 議題看板 loads board definitions and bounded board lists, preserves
GitLab's list order and supports label, assignee and milestone columns. On a
phone, a `PageView` presents one full-width column with a board/column selector
and explicit search. Cards open the existing issue detail, where supported
issue mutations remain available.

Long-pressing a card offers a native move action. It removes only the source
label and preserves other board and unrelated labels, because one issue can
legally belong to several columns. The manager creates/renames/deletes boards,
shows/hides system columns, and adds/reorders/removes lists. Each write uses a
fresh board/issue snapshot and verifies the returned state. Touch drag/drop and
creation of paid assignee/milestone/iteration/weight lists remain open.
After a mutation it refreshes mounted columns. If a returned board scope cannot be translated safely
to the Issues API, the App shows it as unsupported instead of loading an
incorrect fallback list.

### Native work-item filters

Issue and MR lists now submit search explicitly and expose a full-height native
filter sheet. Apply, Cancel and Reset have separate draft state. The final
server query includes supported order, direction, scope and people/label/
milestone filters; client-side mutation reconciliation uses the same criteria.
Successful writes recheck the already-loaded page range against server ordering
and replace its next cursor. Reading a detail does not refresh the resident list.

### Tasks and Incidents

更多 → Tasks / Incidents uses the REST `issue_type` filter and validates numeric
project identity and the returned resource type before displaying rows or details.
Create/edit, severity and issue open/close use the existing native editor and
discussion flows. Ordinary Issue/MR encrypted-draft keys remain compatible;
Task/Incident keys are separated by type. Owned editors and popups close when
the account, project or API client changes.

Incident escalation state is read through a fixed GraphQL query and remains
separate from issue open/close state. A lifecycle change checks a fresh snapshot,
performs one mutation and verifies independent readback, then refreshes REST
detail/list state. Unsupported schemas and missing lifecycle fields stay explicit.
A malformed or lost successful mutation acknowledgement remains unconfirmed;
the editor cannot replay its create request. Complete incident timelines,
escalation policy administration, alerts and authenticated lifecycle acceptance
remain open.

### Compare revisions

更多 → 比較版本 accepts branch names, tags or SHAs and offers GitLab's
merge-base (`from...to`) and direct (`from..to`) modes. Results use lazy commit
and file lists. Opening a file parses the unified diff on demand in a background
isolate, with loading/error feedback and an explicit notice for displayed lines
truncated at 2,000 characters. Editing refs or comparison mode clears the prior
result.

Standard GitLab `---`/`+++` file headers are accepted as non-commentable
metadata. Hunk counts and old/new line anchors remain validated; malformed,
unpaired or header-only input fails explicitly.

GitLab may return `compare_timeout`, `collapsed` or `too_large`. Those states
are shown explicitly. A timeout means the commit list is complete while file
diffs may be incomplete; an empty timed-out response is never presented as
“no changes”. Cross-project `from_project_id` comparison is not implemented.

### Server draft review

An MR review can stage a line comment as a private GitLab draft or open the
server draft list. The list is author-private and bound to the current account,
project, MR and reviewed head SHA. It supports add, edit, typed discard and
publishing all server drafts. Reads are bounded to 20 pages / 600 drafts.

Before publication the App reads the complete list, asks for confirmation,
verifies the MR head and reads the list again. A changed draft snapshot cancels
the write. GitLab's bulk endpoint publishes the current author's complete
server-side draft set; another client can still add a draft in the interval
between the final GET and POST. The confirmation states this race explicitly.
After an accepted write, failed readback is reported as unconfirmed and further
writes stay blocked until refresh.

### Repository and pipeline graphs

更多 → 儲存庫圖 renders actual topological commits and their `parent_ids` as a
vertical mobile timeline. Branch/tag selection is lazy. The page loads 30 commits
at a time, caps the loaded window at 300, and marks parents outside that window.
It explicitly describes the selected ref's reachable history, rather than
claiming GitLab Web's complete all-branch graph.

Pipeline → 工作相依圖 uses a fixed read-only GraphQL query and the returned job
`needs`, scheduling type and stage order. It loads 20 jobs per page, caps the
window at 300, identifies unloaded/ambiguous dependencies, and opens real build
logs. Stage scheduling is described without invented pairwise dependency edges.
The exact instance GraphQL endpoint uses Bearer authentication, no redirects,
response budgets and generation fences; partial GraphQL errors fail explicitly.

### Registries and Snippets

更多 → 套件與容器 Registry offers package, container and Terraform tabs. Package
search/sort is server-side; container loaded-window search is labelled explicitly.
Details expose actual files/digests/sizes. Guarded deletion rechecks permission,
identity and complete bounded pagination before readback. Package-file downloads
now verify fresh metadata, size and SHA-256 before open/share. Type-specific
installation, publishing and full registry policy administration remain unfinished.

更多 → Snippets supports an explicit file list, one selected blob loaded on
demand, virtualized source and Markdown preview. Multi-file metadata editing,
add/update/rename/delete actions and typed whole-Snippet deletion use the native
editor. The last file cannot be deleted. Relative non-upload Markdown links stay
inactive because no immutable Snippet ref is available; project uploads retain
their existing account/project-bound handling.

The read API discovers the opaque Snippet GID from the project's server-returned
connection, validates numeric project/path identity and fences GraphQL reads
with fresh REST metadata before/after each query. REST/GraphQL timestamps must
share a UTC second while their exact per-source versions stay separate. Every
path is explicitly enumerated and validated; `file_name` alone never proves a
complete file set. Binary/null/large/unretrievable/render-error states remain
explicit. The aggregate unretrievable flag does not hide a valid selected blob.

Writes recheck the snapshot, complete path set, selected source and visibility,
then verify actual metadata/file/content readback. Acknowledged or uncertain
writes remain fenced against resubmission if readback fails. GitLab REST has no
conditional Snippet mutation: preflight/readback can detect a server race but
cannot prevent a concurrent change between preflight and PUT. Current official
REST/GraphQL data does not expose a Snippet HEAD SHA, so the App describes a
current snapshot and does not guess `main`, `master` or a project default branch.

Independent source review found no actionable issue; 43 combined API/model/UI
tests and scoped analysis passed. The public three-file fixture
`gitlab-org/gitlab/-/snippets/6030720` passed production-client identity lookup
and lazy reads of README plus a nondefault shell file: expanded public smoke
19 PASS / one Boards authentication GAP / zero writes. Frozen full source passed
analysis and 1,328 JUnit tests with zero failures/errors/skips; Dart file hashes
were unchanged throughout testing. Local coverage is 87.89%
(16,382 / 18,639); 15 bootstrap and 36 CI Python regressions also passed.
Submitted-source CI, installed-build UI and authenticated/private CRUD remain
separate acceptance lanes.

The exact Snippet commit `fd3ac5539be1ee9288df44b9e949fb11a58a4a80`
has fresh successful Python, Flutter (1,328 tests; CI coverage 87.89%,
16,381 / 18,639), native-template and public-read jobs in
[pipeline 2906953486](https://gitlab.com/aa22396584/gitlab-mobile/-/pipelines/2906953486).
All five jobs, including Android development APK build, subsequently succeeded.
This validates the exact submitted Snippet source; it does not validate the newer
Work Item and table-layout follow-up. The normal local release
APK was installed without clearing account data; installed bytes match SHA-256
`0163eb4305cc409d70654e35463491a09ad752f9277a88b59c627e67a8c057c7`,
with its full source marker and backup/cleartext restrictions verified.

That installed public Snippet exposed a further layout issue: a six-column
Markdown table squeezed headers into narrow vertical text, and the long
description kept the file controls below several screenfuls. The follow-up uses
the pinned Markdown package's existing per-table horizontal scroller with
fixed-width columns and large-text scaling. Long multi-file descriptions start
collapsed so the file picker and source/preview controls are reachable. Four
layout regressions failed before the repair; 62 related Markdown, Snippet and
attachment cases pass afterward. Fresh installed-build and frame-performance
verification of this follow-up are still separate lanes.

### GraphQL Work Item reads

更多 → 工作項目 reads project pages and the namespace's actual enabled types
with fixed 20-item cursor queries. Exact project and group Work Item links open
native details with description, assignees, labels, hierarchy and calendar dates.
IDs remain opaque; type display names never choose a REST subtype or route.
Project scope is verified against the numeric REST project identity, while
namespace scope uses its independently returned GraphQL ID. Hierarchy links
preserve those distinct scopes. Date-only start/due fields retain their calendar
day regardless of device timezone.

Fields and nested collections are bounded and distinguish unavailable widgets,
null data, empty collections and truncated pages. Unsupported schema errors
remain explicit; production pages do not fill gaps with mock content. Requests,
already-visible details and ambiguous 403/404 recovery pages are fenced to the
account/client generation and close when that owner changes.

The read-only responsive browser walk observed project Issue `631894` and group
Epic `23883`, including the Epic's group parent and project children. The initial
production-client public smoke passed 23 checks with one anonymous Boards GAP
and zero writes, including project identity, actual base widgets, server type
capabilities and group-owned detail. Those checks used the `0ff2265` local source. Its full-marker release APK was
installed without clearing account data; installed bytes match SHA-256
`24013a1a1311ed5553f93d90fafc82eb073ea29e1b2f0da93a8d3a83185531d1`.
The phone loaded public project `631894`, group `23883` and cross-scope project
child `631872`; the child route survived 2x font scale and the setting was restored.
Exact submitted-source [pipeline 2907138771](https://gitlab.com/aa22396584/gitlab-mobile/-/pipelines/2907138771)
was superseded and canceled after its Python job passed; the new attributes and
parser repair below are a separate source slice.
The final repaired local source passed full analysis and 1,370 JUnit tests with
zero failures/errors/skips. All 215 Dart source/test/tool files and the committed
dependency lock retained their hashes during the run; coverage is 87.67%
(17,260 / 19,687). The 36 CI and 15 bootstrap Python cases also pass. Independent
review approved the API, owner lifecycle, public-query allowlist, table/Snippet
repair and both directions of cross-page Work Item identity validation. An
earlier complete local test run passed, but its optional global Pillow install
was blocked by macOS PEP 668; the final run uses the already installed image
package for the screenshot derivative and exits successfully.
### Lazy Work Item attributes and optional-metadata repair

The native collapsible 屬性 panel reads only kinds advertised by the loaded
Work Item: status, milestone, weight, iteration, health, time tracking and
development. It starts no reads while collapsed, allows two concurrent requests,
retains completed values across collapse/re-expand and isolates failure/retry by
row. Each fixed query uses the server-discovered opaque Work Item ID and verifies
IID, project and namespace identity. Missing widgets, null values, empty data and
zero remain distinct; milestone/iteration ownership uses actual server scope and
date-only values do not shift with the device timezone. Development fetches a
count and auto-close flag without expensive MR/branch connections. Refresh
removes old detail before replacing it so cached attributes cannot survive a
new detail generation.

The physical parent-link failure at public group Epic `18225` was caused by an
absolute-only validator on unused assignee avatar metadata. GitLab legitimately
returns relative avatar references, including installation subpaths. The App
already uses monograms, so this slice removes the unused query/DTO field while
retaining all assignee identity, duplicate and collection validation. Root-path
and installation-subpath regressions failed before repair and pass afterward.

Independent reviews approve the attribute slice and the metadata/query-allowlist
repair. Joint targeted validation passes 46 tests with scoped analysis clean.
The expanded anonymous production-client suite passes 31 checks, one Boards
HTTP 401 GAP and zero writes, including all seven attribute queries and the
actual group parent with a verified namespace ID. This local smoke report has
no submitted-source SHA. The frozen source passes full analysis and 1,388 JUnit tests with
zero failures/errors/skips; 222 Dart/lock hashes remained unchanged.
Local coverage is 87.86% (17,651 / 20,091). The `24b622e` release was installed
without clearing account data; the installed APK SHA-256 is
`167a15bf31e3d6ff8d609ca7f84836a790a73569d469a90efd3e1abef6aa2cf4`.
Public project `631894` showed all seven attribute sections, the actual group-owned
19.5 milestone, zero time values and explicit unset/null fields. The actual group
`23883` parent link now loads `18225` successfully. Its submitted-source
[pipeline 2907264654](https://gitlab.com/aa22396584/gitlab-mobile/-/pipelines/2907264654)
was pending at submission and was subsequently cancelled before any of its five
jobs started. This local and physical evidence does not establish a CI pass.
Activity, remaining widgets,
group lists, filters, native Work Item mutations and authenticated/private/edition
acceptance remain open.

### Markdown disclosure storage repair

The installed `24b622e` public Snippet walk made the three file controls visible
with its long description collapsed. Expanding that description exposed a real
framework error: unkeyed horizontal scroll views in the Markdown package read
the enclosing keyed disclosure's boolean PageStorage value as a double offset.
Both a table and a fenced code block reproduce this failure in a collapsed
ExpansionTile. `MarkdownView` now keeps a state-owned PageStorageBucket around
the complete Markdown/selection subtree, so disclosure state cannot enter its
scroll offset storage. The regressions expand, drag horizontally, collapse and
re-expand; the combined Markdown, Snippet and attachment suite passes 77 cases
and scoped analysis reports no issues. The later `6ff3bf3` installed APK renders
the actual public Snippet table, reveals new columns after horizontal drag and
survives collapse/re-expand. README preview and the non-default VM file show
actual content. Its file and metadata editors were opened and cancelled with no
server write. Fenced-code device verification remains open; no frame-rate
improvement is inferred from widget tests.

### Lazy Work Item activity and long descriptions

The Activity section reads only when expanded and only when NOTES is advertised.
Fixed read-only queries bind the server-discovered opaque ID to the exact IID,
project and namespace. Outer discussion and nested note continuations are issued
by the owning API and validate anchor/discussion identity, cursor progression,
account generation and close state. System events use plain text; user comments
use Markdown, with additional replies disclosed explicitly. Empty and unavailable
connections remain distinct, and empty pages keep usable paging controls.

At most five discussion pages and five reply pages per discussion stay cached.
A global retained limit rejects a candidate response atomically before accepting
more than 2,000 notes or 4 Mi Dart body characters; existing cached navigation
remains usable. Only the active 20-discussion page is built, with a shared
100-body render cap and attachment budget. The controls display explicit limits;
these bounds do not constitute measured frame-rate improvement. Long descriptions
over 800 runes start collapsed. Character counts and previews are cached outside
build, so theme/MediaQuery rebuilds do not normalize the full description again.

An actual detail ListView regression also expands a long description, scrolls it
out of the sliver cache and returns. ExpansionTile exclusively restores its
expansion state; duplicate card state previously caused a build-time setState
error and missing Markdown after restoration. Initial long descriptions still
build no Markdown while collapsed. Combined Activity API/model/UI and description
regressions pass 28 cases.
The expanded anonymous production-client smoke passes 33 checks with one expected
Boards HTTP 401 GAP and zero writes. It reads eight project discussions and group
pages of 20 then one discussion, including 21 real system notes. No public fixture
issued a nested note continuation; that real-server path remains an explicit gap.
The local report identifies participating source with content digest
`f30c135bb981481ba07b7aba67ae3d6d6b24df72cb9f46c704f45bdfd9d05074`,
not a submitted commit SHA. Activity filters/order, replies/mutations, authenticated
private integration and edition-specific widget acceptance remain open.

Final integration analysis reports no issues. The complete suite passes 1,418
JUnit cases with zero failures/errors/skips; all 229 Dart/lock file hashes match
before and after the run. Coverage is 88.02% (18,169 / 20,641). The 36 CI Python
and 15 bootstrap cases and Python/shell syntax checks also pass. Independent
review approves the final source, including the exact eviction reproduction,
Markdown table/code regressions, Activity identity/paging/budget and the anonymous
query allowlist. The interrupted run before the lifecycle repair is not counted.
The `6ff3bf3` release APK and installed bytes match SHA-256
`1b4091db22e17d7efcfa41af50d7b08f2adce98bfed455c8b9534baacba9edc6`.
Its actual group `23883` Activity advances to the second page and returns to the
cached first page. The initially collapsed long description still renders after
expansion, scrolling out of the viewport and returning. During that public walk,
allowlisted own-process log checks found zero occurrences of bool/double storage,
build-time setState and RenderFlex overflow errors. The submitted-source
[pipeline 2907344085](https://gitlab.com/aa22396584/gitlab-mobile/-/pipelines/2907344085)
is running at the latest readback: Python
[16900837654](https://gitlab.com/aa22396584/gitlab-mobile/-/jobs/16900837654), Flutter
[16900837655](https://gitlab.com/aa22396584/gitlab-mobile/-/jobs/16900837655)
(1,418 tests, clean analysis, 88.02% CI coverage) and native templates
[16900837656](https://gitlab.com/aa22396584/gitlab-mobile/-/jobs/16900837656)
succeeded. Public smoke is pending and Android is created behind its dependencies.
These partial CI checks apply to `6ff3bf3`, before the group list changes. No full
pipeline pass, nested-note device path or quantitative jank reduction is inferred.

### Group-owned Work Item list

The group page now has a fifth native Work Items tab with one app bar and an
explicit group-only scope label. The production GraphQL query uses the Group
root, 20-row pages, `CREATED_DESC` and `includeDescendants: false`. First-page
responses discover the opaque owner ID; subsequent pages require it, and every
row must match that group's namespace and have no project owner. Capability
identity is checked against the same owner. Details use the row's returned
namespace path/ID. No REST Project or GraphQL global ID is synthesized.

The mobile Web aggregate list includes descendant project items and has search,
Open-state filters, display options and custom views. Those controls remain
separate follow-up work; this group's own list does not claim aggregate parity.
Existing REST group issues/MR tabs retain their scope. Account/API/path changes
discard list state and owned detail routes, and loading failures preserve already
accepted pages with explicit retry.

The group resolver accepts exact root/subgroup paths through the REST Groups
endpoint, requests no embedded projects, and caches only the small fields used by
the group page. Group and group-list URLs also work beneath an instance installation
subpath. The list link opens Work Items directly; no Project lookup is used.
Both project/group item and type pagination stop after ten pages or 200 resident
records. An issued-cursor cycle stops with retained rows and an explicit error;
empty pages can still advance, and reaching a bound while the server has more
shows a refresh notice. Rows use a lazy SliverList builder so pagination/type
updates do not first construct configurations for every resident row. Headers,
continuation controls, stored scroll position and pull-to-refresh retain their
mobile behavior.

Missing, mismatched or replaced group-page ownership stops the entire tab body
before REST or GraphQL requests. Explicit owner fences are used by isolated
fixtures; failed provider lookup cannot enable a production page. Independent
review verified these ownership/lazy-construction repairs, with zero outstanding
findings.

Final frozen-source validation passes 1,451 JUnit tests with zero
failures/errors/skips, clean full analysis and unchanged hashes for all 232
Dart/lock files. Local coverage is 88.07% (18,419 / 20,914 lines). All 36 CI Python
and 15 bootstrap regressions and Python/shell syntax checks pass. The production
anonymous suite passes 36 checks with one Boards HTTP 401 GAP and zero writes,
including exact group-path resolution, group type capabilities, two disjoint
20-row group-owned pages and issued-cursor continuation. Its local source content
digest is `7cb4d7836d68d7e31f72b473aa64fcd1a00f40fb9d42dfc9b8342d22df124c20`;
this is not a submitted commit SHA. Two earlier frozen-source public runs each
retained a network failure on different repository/compare endpoints; neither is
counted as a passing run. The final complete run is the 36-pass result above.
New installed-build and exact-head CI results
must be read separately; these checks do not close descendant aggregation,
list filters, private/role-specific acceptance or iOS.

The exact `ad49850` release was installed in place with matching APK bytes
(SHA-256 `e637c0192061e56bb65025478a011708b7dcb07250cf8cdbf096dfd89698de3e`),
preserving the saved account. The phone opened the fifth group tab from its list
URL, rendered the actual group-owned rows, opened public `23883`, returned to
retained list state, loaded issued-cursor second-page rows, scrolled back and
refreshed. Every visible row was checked against anonymous public IIDs before
capturing content; zero server writes were submitted. Own-process checks found
zero earlier storage/build/overflow or uncaught/native-crash markers.

At 2x font scale, content remained readable without overflow, but the active
fifth tab moved outside the horizontal viewport after the scale change. The
original font setting was restored. That observed navigation defect requires its
own source regression and installed-build readback; it is not a full large-text
pass for `ad49850`. Its exact-head
[pipeline 2907497989](https://gitlab.com/aa22396584/gitlab-mobile/-/pipelines/2907497989)
was pending with zero started jobs at the readback. No full CI pass follows.

The accessibility follow-up registers the tab container as a text-scaler
dependent and reveals the currently selected tab after layout. It keeps the
user's font size and rechecks the current owner, mounted context and selected
index in the callback. The regression keeps the same mounted group page and
Navigator while changing only inherited text scale from 1x to 2x; the selected
Work Items tab remains inside the 390dp viewport. Independent review has zero
open findings. Fresh full analysis is clean; all 1,452 JUnit tests pass with zero
failures/errors/skips and unchanged hashes for all 232 Dart/lock files. Coverage
is 88.09% (18,438 / 20,932 lines). Installed runtime-scale verification and the
follow-up commit's CI are separate evidence lanes.

ProjectMore and Pipeline owned navigation stacks, board modal editors and snippet
routes are removed on account/project/API replacement. Registry feed identities
include owner generation, so reconnecting the same account clears old rows before
loading from the replacement API.

### Project analytics

更多 → 專案分析 groups contributor, repository and CI data in native tabs. It
loads the active tab, keeps completed data while navigating tabs, and bounds
repository/contributor pagination to 20 pages / 2,000 rows. Contributor records
contain only a display name and aggregate commit/addition/deletion counts;
emails and inferred GitLab-user identities are discarded. Equal author names
remain separate. Contributor aggregates cover the selected ref's history;
the repository and CI date window is explicitly UTC, with an inclusive start
and exclusive end.

Repository activity requests actual commit statistics, excludes multi-parent
merge commits from its local-date aggregate, and retains loaded data after a
later-page failure. GitLab's inclusive REST `until` is converted from the
exclusive App boundary. Canonical timezone spellings in pagination links are
accepted only when they represent the same instant; ref/window/stat filters
and endpoint origin remain fixed.

CI uses a fixed read-only GraphQL query with a verified source enum, project
identity, actual aggregate count/p50/p95 and bounded daily series. Success and
failure rates exclude cancelled/skipped pipelines and require supplied counts.
No overall median is calculated from daily medians. Missing fields, null
coverage and unsupported schemas remain explicit. Language/coverage are
project-scoped repository sections and have independent retries.

The expanded anonymous public smoke read actual contributors/commit activity,
pipeline series, aggregate statistics with Any/Push sources, and the nullable
coverage contract: 17 PASS, one Boards authentication GAP, zero writes.
These reads establish public API compatibility; complete Web chart interactions,
private/paid analytics and installed-build acceptance remain separate lanes.

The final Analytics source passed full analysis and 1,299 JUnit tests with zero
failures/errors/skips on pinned Flutter 3.47.2 / Dart 3.13.2. Local coverage is
88.06% (15,776 / 17,916 lines); the dependency lock is unchanged. The 46 targeted
Analytics cases include delayed same-filter refreshes, unrelated-tab refreshes,
pending project-read sharing, account replacement, pagination failures and
320–840dp / 2x text / keyboard / safe-inset checks. Independent source review
found no actionable defect. Exact submitted-source CI and the installed Android
Analytics walk follow separately; the earlier `1709c0f` evidence below does not
cover these newer screens.

Analytics commit `92288eedc06293d6ee86cbd4486e7892a8b7cbd1` was pushed and
installed from its exact archived source on the S24 Ultra. Its
[Flutter CI job](https://gitlab.com/aa22396584/gitlab-mobile/-/jobs/16896782086)
passed 1,299 tests with zero failures/errors/skips and 88.05% CI coverage
(15,775 / 17,916). Python checks and native template generation also passed;
the native artifact retained disabled Android backup/cleartext and no iOS
arbitrary loads. Public smoke and Android build jobs in
[pipeline 2906821268](https://gitlab.com/aa22396584/gitlab-mobile/-/pipelines/2906821268)
were canceled after the newer push, so that pipeline is not a complete pass.
The in-place development-signed release
APK has SHA-256 `08cc4fbcaf19b7b783f1b9d3e21a6d1f3b207792f40f084f415b5ef8c2711434`,
a verified compiled full source marker and disabled backup/cleartext. Account
data was preserved. Native public reads showed actual contributors, paginated
commit activity, language/coverage and distinct Any/Push CI aggregates.

The physical keyboard walk found a defect beyond those test passes: opening
the keyboard changed the controls' parent/key, lost ref focus and immediately
closed the keyboard. The follow-up keeps a stable controls subtree, bounds
scrollable filters under large text/short landscape, and orders daily CI rows
newest first. Follow-up commit `a078f4b31ff816210ecb573e5e076d18b702f5c0`
passed full analysis and 1,303 tests with zero failures/errors/skips from an
isolated exact source archive. All 205 tracked Dart files/dependency lock matched
that commit after testing; local coverage is 88.06% (15,781 / 17,921).
The 25 targeted UI/race cases and independent review also passed.

Its normal release APK has SHA-256
`abf44b6fab71504cc3bc79ab468e74976c55449e480226fe023aeac9df47ccab`;
the installed package hash matches this artifact, the compiled full commit marker
was verified and backup/cleartext remain disabled. The S24 Ultra walk confirmed
keyboard focus, typed input, Apply dismissal, scrollable 2x-text controls and
newest-first CI dates. Temporary font scale was restored; own-process logs had
no observed Flutter overflow/unhandled/fatal markers. Exact-source
[pipeline 2906882413](https://gitlab.com/aa22396584/gitlab-mobile/-/pipelines/2906882413)
passed Python and full Flutter checks (1,303 tests; CI coverage 88.05%,
15,780 / 17,921). Native/public/Android jobs were canceled after the newer Snippet
push, so that pipeline is not a complete pass. These UI checks do not establish fresh
frame-performance, private/paid Analytics or iOS acceptance.

## Loading, cache and scroll work

The new read cache belongs to one `GitLabApi` account client and exists only in
memory. It shares concurrent identical reads, stores at most 32 entries and an
estimated 6 MiB, and uses LRU eviction. Project resolution is capped at 30
seconds. Raw text is cached for at most five minutes only when the ref is an
immutable 40–64 character SHA; moving branches and tags remain fresh.

Server `Cache-Control`, `Age` and `Expires` can shorten or disable those caps.
Explicitly fresh `must-revalidate` responses are reusable until expiry; stale
responses never fall back offline ([HTTP caching semantics](https://www.rfc-editor.org/rfc/rfc9111.html#section-5.2.2.2)).
Explicit refresh clears the cache. Writes clear it before and after the request,
and old in-flight reads cannot repopulate or return a pre-write value. Client
close, OAuth rotation and authentication/authorization/not-found failures also
clear it. Authentication, failed responses, writes, live logs and moving refs
are never cached.

`RecordsFeed` now derives filtering, ordering and section boundaries only when
its input or derivation callbacks change. Sections are resolved lazily and only
the first/last grouped rows receive clipping. Grouped backgrounds and outlines
are painted within each built row instead of the full scroll extent. Repository
syntax spans are also generated lazily and held in a page-owned LRU capped at 512 rows and 131,072
source characters; changing file language, theme or base style clears it.

These changes reduce repeated work. They do not by themselves prove a frame-rate
improvement, so device measurements stay separate from unit/widget evidence.

## Physical-device profile result

<!-- ROOT:PERF_RESULTS:START -->
Measured on the same physical Samsung S24 Ultra (Android 16, 1080 × 2340,
450 dpi), with Flutter 3.47.2 **profile** builds, the same saved account and dark
theme. The baseline is an isolated archive of `0e1298e` with only the opt-in
frame sampler added. The follow-up profile build includes the list/syntax/cache
changes. Subsequent comparison/account and loaded-window fixes were validated
separately; this is not a measurement of every final screen.

Projects: three force-stop/cold launches, five-second settle, then one upward
and one downward 400 ms gesture per launch, two-second settle per gesture.
Code: the same public `lib/core/gitlab_api.dart` at fixed `0e1298e` SHA, three
up/down pairs after opening. Coordinates and gestures were identical. The
project feed is live, so its data and background-device workload are not fixed.

| Screen / build | Scrolls | Frames | Mean total span | Maximum total span | Build or raster >16.667 ms | Build or raster >8.333 ms |
|---|---:|---:|---:|---:|---:|---:|
| Projects / before | 6 | 535 | 6.891 ms | 24.008 ms | 1 | 29 |
| Projects / after | 6 | 551 | 6.360 ms | 22.660 ms | 2 | 20 |
| Code / before | 6 | 538 | 6.361 ms | 18.939 ms | 0 | 6 |
| Code / after | 6 | 544 | 6.310 ms | 14.774 ms | 0 | 2 |

Means are frame-count-weighted from each gesture's summary. Build/raster budget
exceedances and total frame span measure different things; neither is a count
of display-presented dropped frames. Per-gesture p95 ranges were projects
9.579–14.342 → 8.016–14.388 ms and code 9.020–10.954 → 8.986–11.331 ms.
The samples suggest less repeated work but do not establish a statistically
reliable improvement or remove all cold-scroll stalls. No 5,000-line log/diff,
low-end phone or iOS performance claim follows from them.

Profile APK SHA-256: before
`1ce0ac63626e0fd03c68507f133a08bb4cda2e20413f206497d17120a12c4009`;
after `2f9055fc4464b18d6f7fe1164de45f4a8c5d38f6d97fe9f87df904dc8143cf7f`.
Raw screenshots/frame summaries remain in ignored local `artifacts/`.
The normal build omits the diagnostics listener and emits no profile records.
<!-- ROOT:PERF_RESULTS:END -->

## Verification status

<!-- ROOT:VERIFICATION_RESULTS:START -->
First-slice evidence on submitted commit `a86c0ad` (the subsequent functionality
additions below require their own exact-head validation):

Local evidence on that submitted application source (Flutter 3.47.2 / Dart
3.13.2; committed dependency lock unchanged):

- `flutter analyze --no-pub`: no issues. `flutter test --no-pub --coverage
  --timeout=60s --machine`: JUnit 1,123 tests, zero failures/errors/skips;
  line coverage 87.77%. This includes the final live-response diff regression
  and actual large-text checks at 320/412/840 dp with `TextScaler.linear(2)`.
- Python CI/tool unittest discovery: 51 tests passed; `compileall` and shell
  syntax checks passed. SDK bootstrap check passed. `ci/ui_evidence.py`
  processed the actual synthetic-data Flutter screenshot successfully.
- `dart run tool/public_smoke.dart`: seven anonymous, read-only production
  client checks passed, including real pagination and fixed-revision compare
  with actual unified-diff parsing, rather than only JSON-shape checks.
  The board endpoint returned 401 anonymously; authenticated boards are not
  covered by that suite.
- Android profile APK built; the normal release APK was built from an isolated
  exact-source snapshot using `flutter pub get --enforce-lockfile` followed by
  `flutter build apk --release`. Its SHA-256 is
  `dca237e3632cf7b4f1b3fb1992f1920594d5cb1e4dcdc13f6d0fcced2e450ab6`.
  It is non-debuggable, disallows backup and cleartext traffic, and uses the
  existing development signing configuration; it is not store-signed.
- Independent final delta review found no blocking defect. Checks covered
  account-generation fences, draft snapshots/readback, compare result identity,
  cache expiry/invalidation, server ordering and refreshed pagination cursors.
  The final shared-parser review also parsed all 41 non-collapsed diffs from
  the real public comparison response with validated commentable anchors.

The all-in-one local `ci/check.sh` wrapper reached its Homebrew-managed Python
pip restriction after tests. Analyzer/test/report and screenshot processing
were therefore verified as separate commands; the local wrapper itself is not
claimed as passing. The pinned Flutter release tool also requires normal pub
tooling to regenerate a release plugin registrant after profile/test use;
`--no-pub` left a stale dev-plugin entry. No tracked source was rewritten.

Physical Android checks used the saved account without extracting a credential:
the real Development board and issue cards, Closed empty state, native filters,
and MR !31's empty server draft list rendered successfully. The normal release
also loaded a real comparison from `911a953e` to `main` (seven commits / 45
files); `lib/core/workspace_api.dart` displayed its standard file headers,
validated hunk line numbers and additions/removals after the live parser fix.
No server content
was created, edited, discarded or published during this walk. Normal release
installation preserves the existing app/account data and removes the opt-in
profile listener.

The delivery response and MR record identify the source commit and matching
pipeline/job evidence. Remote CI status must be read from that exact head;
the prior main pipeline is not acceptance evidence for this branch.

**NOT_RUN:** live draft add/edit/discard/publish, board mutations, newly submitted
private-project integration, iOS binary/device tests, screen readers, low-end
hardware, secure-storage backup/restore, OAuth login, push and store signing.
No G0 or complete GitLab parity acceptance is claimed.
<!-- ROOT:VERIFICATION_RESULTS:END -->

## Graph/registry/snippet/board-management validation

Submitted application commit `9515c91e9d9a7cd5306ab8a5a59132f99aaad1a8` has
fresh local validation: 1,197 JUnit tests, zero failures/errors/skips, 87.43% local
line coverage, clean full analysis, 51 Python tests, shell/compileall and SDK
checks. Exact-head [pipeline 2906348213](https://gitlab.com/aa22396584/gitlab-mobile/-/pipelines/2906348213)
finished successfully with all five jobs:

- Python [16893375828](https://gitlab.com/aa22396584/gitlab-mobile/-/jobs/16893375828).
- Flutter [16893375829](https://gitlab.com/aa22396584/gitlab-mobile/-/jobs/16893375829):
  1,197 tests, zero failures/errors/skips, clean analyzer, 87.42% CI line coverage.
- Native templates [16893375830](https://gitlab.com/aa22396584/gitlab-mobile/-/jobs/16893375830):
  Android backup/cleartext restrictions and iOS keychain/ATS restrictions retained.
- Public API [16893375831](https://gitlab.com/aa22396584/gitlab-mobile/-/jobs/16893375831):
  11 anonymous read checks passed; Boards' anonymous HTTP 401 recorded as GAP;
  zero writes. Actual topology, needs, registry files and multi-file snippet
  metadata were parsed.
- Android [16893375832](https://gitlab.com/aa22396584/gitlab-mobile/-/jobs/16893375832):
  debug APK checksum, signature, compiled source marker and manifest restrictions
  verified. This CI APK was not installed because its signer differs from the
  existing physical-phone preview.

A separate normal release APK from an isolated exact `9515c91e` source archive
was installed in place on the S24 Ultra, preserving its saved account. SHA-256:
`e0317dfee2cd6caefb0d23839d4ad2be5ebb7742a4e48d57edcf874c6ba5fbb6`.
It uses the existing development signer and is not store-signed. The phone
rendered branch/tag repository graphs and actual commit parents; Development
board management/card-move controls; the 20-package registry and three real
asset records; empty Container/Terraform/Snippet states; and the exact CI
pipeline needs graph with a dependency jump into its actual job log. Editors and
mutation dialogs were cancelled; no server writes were performed.

That phone walk exposed two UX defects: the Snippet visibility text field was
not a constrained choice and retained issue-specific description commands;
the standalone pipeline graph overlapped the status bar. The follow-up source
adds labelled visibility choices, removes those description commands, and
respects status-bar/gesture insets with large-text regression checks. Its source
also adds typed REST Tasks/Incidents and a separately modelled GraphQL escalation
lifecycle, with account-switch and ambiguous-write regressions. These newer
changes require their own exact-head CI and installed-build evidence; the
`9515c91e` results above do not cover them.

The Task/Incident and UX follow-up has final local full-source validation on
Flutter 3.47.2 with the committed dependency lock unchanged: clean analysis,
1,253 JUnit tests, zero failures/errors/skips, and 87.74% line coverage
(14,901 / 16,983 lines). The complete run was repeated after repairing four
synthetic Issue fixtures to include GitLab's actual numeric `project_id`;
production identity validation remains strict. Independent bounded review
found no outstanding actionable defect. Submitted commit
`1709c0f922938e213d52b71a65b1327f5c76497e` has exact-head CI evidence in
[pipeline 2906606845](https://gitlab.com/aa22396584/gitlab-mobile/-/pipelines/2906606845):
all five jobs finished successfully. Flutter
[16895165988](https://gitlab.com/aa22396584/gitlab-mobile/-/jobs/16895165988)
passed 1,253 tests with zero failures/errors/skips and 87.73% CI coverage
(14,900 / 16,983). Native templates
[16895165989](https://gitlab.com/aa22396584/gitlab-mobile/-/jobs/16895165989)
retained Android backup/cleartext and iOS ATS/keychain restrictions. Public API
[16895165990](https://gitlab.com/aa22396584/gitlab-mobile/-/jobs/16895165990)
passed 13 checks with one anonymous Boards GAP and zero writes. Android
[16895165991](https://gitlab.com/aa22396584/gitlab-mobile/-/jobs/16895165991)
produced a checksum/signature-verified debug APK with the compiled source marker
and restricted manifest. Its signer differs from the installed preview, so it
was not installed. Python
[16895165987](https://gitlab.com/aa22396584/gitlab-mobile/-/jobs/16895165987)
also passed. This CI evidence applies to `1709c0f`, before the analytics slice.

A normal release APK built from an isolated exact `1709c0f` archive was
installed in place on the S24 Ultra, preserving its account. SHA-256:
`9e85b213d8faaa1e0e5b57b9ee70c6e7611c92e287108b915da89d15d5c707d6`.
Its development signer matches the previous preview; it is not store-signed.
The App showed Task/Incident empty lists and cancelled create editors, Incident
severity choices, the corrected Snippet editor and private/public visibility
choices, and actual pipeline #286 dependencies with corrected status-bar and
gesture insets. The own-process log sample contained no Flutter overflow,
uncaught exception or native crash marker. No server writes were performed.
Authenticated nonempty CRUD and lifecycle mutations remain NOT_RUN.

An isolated exact-source iOS bootstrap preserved the committed lock and native
security settings. Both simulator and unsigned-device builds stopped before
compilation with missing Xcode build settings. Installing the official iOS 26.2
simulator runtime did not resolve Xcode's first-launch prerequisite; its
component installer is waiting for macOS administrator authentication. No iOS
binary or device pass follows from bootstrap or runtime installation.

The expanded local public suite additionally verifies typed Task/Incident
lists and the fixed incident query schema: 13 PASS, one anonymous Boards GAP,
zero writes. The public project has no Incident fixture, so an empty filtered
connection establishes schema compatibility only. It does not establish actual
lifecycle mutation, private access or role-based acceptance.

See [MOBILE_WEB_PARITY_LEDGER.md](MOBILE_WEB_PARITY_LEDGER.md) for the full public
navigation ledger and outstanding functional acceptance lanes.

## Verified package-file download follow-up (2026-10-03)

The public package `71215360` was observed at 390 × 844 in the browser. Its
three assets use stacked mobile rows; expanding `SHA256SUMS` exposes the actual
SHA-256 and copy action. Native package and Terraform file rows now offer
full SHA-256 copy, download with progress, cancellation, retry and open/share
after verification. Reader-only users can copy the checksum without receiving
destructive controls; narrow-screen / large-text rows retain the download action.

The production client uses GitLab's numeric
`/projects/:project/packages/:package/package_files/:file/download` endpoint.
It re-reads the package identity and file name/size/SHA-256 before streaming,
stops metadata paging after fully validating the target page, and rejects
changed metadata. Search is bounded to ten pages / 200 inspected files.
Missing canonical SHA-256, invalid sizes and files above 256 MiB remain blocked.
This universal endpoint avoids guessing type-specific protocol coordinates;
an older instance's ambiguous 404 retains retry and account-switch options.
The [official package-read route catalogue](https://docs.gitlab.com/auth/tokens/fine_grained_access_tokens_rest/)
documents the endpoint. Compatibility on other instance versions remains open.

Downloads use the existing account/project attempt directory, a partial file,
bounded streaming and atomic promotion. Size is verified before SHA-256 runs
in a separate isolate. Account/session changes, widget replacement and closing
the sheet cancel ownership and delete stale files. Progress reuses the existing
100 ms notifier throttle. Redirects reuse the single-hop HTTPS artifact policy
and strip all authorization/cookie headers, including same-origin redirects.
No dependencies or package publishing operations were added.

The frozen-source anonymous production-client suite passed 37 checks with zero
failures, one Boards HTTP 401 GAP and zero writes. It downloaded exactly 185
bytes through the numeric endpoint and verified the saved file's SHA-256.
The run uses local source-content digest
`3dfeb32215f5723ccb5966e0ed98e732391f3078d87ed693bcf189ae3ac2cc4f`;
the commit-binding receipt is retained with its ignored evidence artifacts.
CI/bootstrap Python tests passed 36 + 15 cases and syntax checks. Independent
writer/reviewer passes have no open finding.

Full pinned Flutter analysis has no issues; the frozen-source run passed 1,479
JUnit tests with zero failures/errors/skips. All 236 Dart/lock hashes remained
unchanged. Local line coverage is 88.02% (18,844 / 21,408). Exact commit binding,
installed-build readback and exact-head CI are separate receipts tracked in the
draft MR and ignored evidence directory; local tests do not establish device,
CI, private-project or G0 acceptance.
The live fixture is only the public 185-byte `SHA256SUMS`
file `361672601`; the 170 MiB APK asset is not fetched or executed. Container
image pulls, type-specific installation, publishing/policies, real Terraform
downloads, private/role-based acceptance and iOS remain separate gaps.

## Direct resource actions (2026-10-03)

A focused signed-out Web recheck at 390 × 844 confirmed that project Star is
visible beside the project identity; project and issue overflow menus expose
copy-reference/ID actions. The App now places Star/Unstar and native link Share
in the project header. Star has an explicit unknown/retry state, one state owner
for the header and 更多, shared confirmed counts, account/session generation
fences and feed reconciliation after successful writes, including HTTP 304.
Its synthetic mutation tests do not establish live account Star acceptance.

Direct link sharing is available in group, issue/MR, project/group Work Item,
commit, repository file, MR file diff, pipeline/dependency graph, job log,
Snippet, package, Wiki, Release and Milestone details. Existing share_plus 13.3.0
presents the system chooser with text-only canonical URLs and a button popover origin; it does not
attach tokens, repository content, files or metadata-fetch URIs. Repeated taps,
unsafe URLs and stale owner completions are fenced. Repository links pin the
commit SHA and selected line; pipeline links use the global ID, and job retry
links follow the current attempt. Wiki links retain the nested page slug;
Milestone links use the positive project IID rather than the database ID, and
Release tags remain one encoded path segment, including tags containing `/`.
Missing identifiers omit the share action rather than inventing a URL. Metadata
detail routes are removed when the account, API or session changes; their old
list rows and actions are hidden until a matching owner loads them. No dependency
or publishing operation was added. The chosen plugin contract was checked against its
[versioned maintainer documentation](https://pub.dev/packages/share_plus/versions/13.3.0).
Resource routing was checked against the [GitLab Release API](https://docs.gitlab.com/api/releases/),
[GitLab slash-tag routing example](https://gitlab.com/gitlab-org/gitlab/-/issues/362696)
and [milestone ID/IID example](https://docs.gitlab.com/api/resource_milestone_events/).

Reaction loading, picker results and add/remove completion now snapshot their
account/API/project/resource/item/note owner. Replacement or session ending
invalidates stale results and dismisses the old picker; invalid owners cannot
leave enabled reaction controls or a stale refresh button. The add chip explicitly
says 新增表情回應. Subscription writes apply the confirmed switch state before
refresh, so a failed refresh cannot misreport a completed write as failure.
New tests first reproduced the three reaction ownership defects before repair;
additional tests cover API replacement/closure, session ending, subscription
refresh failure, numeric/canonical share routes, metadata session invalidation
and 320dp/two-times text action layouts. Frozen-source suite, exact commit/device and CI receipts are recorded separately with the draft MR.

## Environment and schedule actions; emulator lane (2026-10-03)

A signed-out mobile Web walk at 390 × 844 observed the project's environment
and schedule empty states. No fixture was created on GitLab to turn an empty
page into a success claim. The current upstream route source confirms
[environment show and nested deployment routes](https://gitlab.com/gitlab-org/gitlab/-/blob/a59174e6b212fcc5ef2263f80d4e0319f46e92b9/config/routes/project.rb#L334-352)
and [schedules without an individual show route](https://gitlab.com/gitlab-org/gitlab/-/blob/a59174e6b212fcc5ef2263f80d4e0319f46e92b9/config/routes/pipelines.rb#L35-40).
Filtered deployment views now provide native Share and GitLab Open for a
positive environment database ID, preserving the installation path and port.
Environment names still filter deployment records; they are not URL IDs.
Missing/nonpositive IDs omit canonical actions. A validated deployment website
has its own labelled action rather than replacing the GitLab environment link.

Environment and deployment feeds bind their account/API/project/path/session
generation. Invalid owners hide old content and dismiss owned child routes,
including a Job or ambiguous-access notice opened from a deployment. Schedule
Play captures the owner and positive schedule ID before confirmation, locks
repeated taps before opening a dialog, and checks ownership after confirmation
and write completion. A confirmation first built after owner invalidation is
also removed. Stale success/failure cannot update a replacement owner's UI.
Regression cases reproduced the dialog timing and repeated-tap failures before
the repairs; focused tests also cover nested routes, closed clients and large
text. No dependency or automatic write retry was added.

The user reserved the physical phone for another session. All subsequent
Android input, installation and QA uses the isolated
`GitLabMobile_API36_Codex_20261003` AVD, API 36, with an explicit emulator serial
and qemu/AVD identity checks. Production APK cold login, synthetic native UI and
anonymous production-client API checks have separate evidence receipts. The
QA-only target requires an explicit opt-in, keeps all API/CDN requests in the
existing fixture transport, and labels every route as synthetic data. It uses
the production widgets and real Android Share plugin; opening and dismissing
a native chooser is separate from sending a link. Numeric profile scroll
summaries on the fixture emulator do not establish physical-device FPS, live
Star/schedule writes, private-resource acceptance, iOS or G0 acceptance.

## Work Item completion and Inbox measurement (2026-10-03)

A signed-out 390 × 844 Web walk observed the project Work Item list's Open
filter, Display/sort controls and public Task
[631946](https://gitlab.com/gitlab-org/gitlab/-/work_items/631946). Its OPEN
lifecycle and New custom workflow status are separate. The App now has a
permission-bearing state read and native close/reopen confirmation for exact
project and group-owned Work Items. It preserves the server's opaque item/type
and parent IDs, checks the displayed timestamp against a fresh preflight,
performs one `workItemUpdate(stateEvent: CLOSE|REOPEN)` and independently reads
back the state. It never changes the custom STATUS widget to mark completion.

Schema capability errors preserve the existing detail reader. Denied access,
stale snapshots and uncertain acknowledgements have explicit read/retry states;
uncertain writes are not replayed. Account/client changes invalidate reads,
confirmations and write completions. GitLab has no expected-timestamp/lock input
for this mutation, so a concurrent-change interval remains between preflight and
the write. The [current input contract](https://docs.gitlab.com/api/graphql/reference/experimental/input_objects/)
and [state-event enum](https://docs.gitlab.com/api/graphql/reference/experimental/enums/)
remain experimental; authenticated/private and older-instance acceptance are
separate from synthetic tests and anonymous permission reads.

The bottom navigation previously measured 108dp because its parent context
reintroduced a 36dp top status inset. Removing that duplicated inset preserves
the intended 72dp content area plus one bottom gesture inset. Exact `3904651`
emulator readback covered all four roots, scroll hide/reveal and 320dp with 2x
text; the production APK was restored after that verification.

An exact `3904651` Inbox profile baseline uses three fresh launches, two excluded
warmups and six measured alternating gestures per launch on the isolated AVD.
Each gesture has one positive, nontruncated summary. Across 18 gestures it
records 266 frames and 128 stage-budget-overrun proxies; per-run maximum raster
times are 204,800, 220,421 and 265,619 microseconds. All three runs reproduce
stalls with zero allowlisted App error markers. These values are emulator timing
proxies, not dropped-frame counts, FPS, physical-phone acceptance or proof of a
particular widget's cost. The raster-heavy results justify further profiling;
no uniform scroll-performance improvement is claimed.

The opt-in sampler now binds completion to the same scroll context and depth,
so unrelated nested end notifications cannot prematurely finish a sample.
Duplicate completion is idempotent; a bounded late-batch settling policy replaces
the fixed 350ms flush. Its legacy numeric output is unchanged. Flutter's
[timing callback delivery](https://api.flutter.dev/flutter/scheduler/SchedulerBinding/addTimingsCallback.html)
is approximate, so this grace period reduces likely batch loss without proving
complete capture. The sampler change improves measurement correctness and does
not itself fix raster stalls.

## Work Item activity filters and ordering (2026-10-03)

A fresh 390 × 844 signed-out browser walk of public project Work Item `631946`
confirmed All activity / Comments only / History only and Oldest first / Newest
first. Comments-only removed its three system events; history-only preserved them,
and newest-first reversed their visible chronological order. The browser viewport
was restored after observation; no GitLab content was written.

The native Activity reader now sends `ALL_NOTES`, `ONLY_COMMENTS` or
`ONLY_ACTIVITY` and `CREATED_ASC` or `CREATED_DESC` to the server. It keeps the
existing all/oldest default and uses only `first: 20` plus `after: endCursor`.
Filter/order is bound into each opaque continuation; the client does not locally
sort or filter a partially loaded page. Selection changes clear retained pages,
reply handles, note/body and attachment budgets, while a new epoch rejects late
initial, page and reply completions. Account/client/resource changes also reset
selections and collapse the section.

The controls wrap vertically at narrow/large-text sizes and preserve 48dp minimum
menu targets. Their explicit above-field labels remain outside the filled border;
the dropdown carries the label in semantics without a duplicated visual label.
Actual light/dark App themes at default and 320dp/2× text have geometry and
semantics regressions after native QA exposed clipped floating labels.
Refresh starts a fresh stream with the current selection. Explicit
schema rejection of the controls triggers one initial-only legacy read, scoped to
that API client, then displays all/oldest with disabled controls and an explanation.
Authentication, network, malformed data and unrelated validation errors do not
trigger that downgrade, and a newer cursor is never replayed with a legacy query.

The [official widget arguments](https://docs.gitlab.com/api/graphql/reference/experimental/objects/#workitemwidgetnotes)
and [ordering enum](https://docs.gitlab.com/api/graphql/reference/experimental/enums/#workitemdiscussionssort)
are experimental. Current GitLab.com query-only validation confirmed the
`argumentNotAccepted` extension shape and newest-first forward continuation.
The upstream Web reader loads all pages before local filtering/reversal; the App
uses server filtering to preserve bounded loading instead. Five discussion/reply
pages, 100 rendered bodies, 2,000 retained notes and the 4 Mi-character budget
remain in force. Reply creation, authenticated/older-instance acceptance and the
remaining widgets remain open. Exact-source tests, live anonymous reads and
Android synthetic readback are recorded as separate evidence lanes.

The frozen Dart/lock source passes pinned full analysis and 1,609 Flutter tests
with zero failures/errors/skips (20,329/22,719 covered lines, 89.48%). The anonymous
production-client suite records 39 PASS / 0 FAIL / 1 expected GAP and zero writes.
Both actual public scopes exercise all six configurations (12 initial queries),
and the group newest-first cursor advances successfully. The public sample did
not issue a nested-note continuation, so that live case remains a gap. Native
readback and exact-head CI require their separate commit-bound receipts.

## Work Item Markdown comments and replies (2026-10-03)

The 390 × 844 public browser walk of project Task `631946`, project Issue
`631759` and group Epic `14501` observed the activity selection/order controls,
per-thread reply buttons, expand/collapse replies and signed-out reply prompts.
The native reader keeps bounded pages and builds Markdown only for the selected
page and expanded replies. History offers an explicit switch to Comments before
composing so the resulting comment belongs to the visible activity selection.

The [GraphQL mutation reference](https://docs.gitlab.com/api/graphql/reference/#mutationcreatenote)
and the [upstream Work Item note operation](https://gitlab.com/gitlab-org/gitlab/-/blob/a9f5833581f63b54b623c7025fc33d11c16b92e2/app/assets/javascripts/work_items/graphql/notes/create_work_item_note.mutation.graphql)
identify `createNote` and the server-provided discussion `replyId`. The client
uses the queried Work Item identity and opaque reply target; it does not invent
a discussion or convert an IID into a GraphQL ID. A fresh read checks account,
scope, author and create permission before one mutation. An independent query
then verifies the exact returned Note ID, body, author, scope and discussion.
Malformed acknowledgements, timeouts and unavailable readback produce an
uncertain result without automatic replay.

Comment/reply editors reuse encrypted, instance/account/resource-scoped drafts
and Markdown formatting. Group-owned items expose plain Markdown tools; project
mention/upload tools require a separately verified numeric Project and full path.
Namespace-opened project descendants resolve that context explicitly and retain
readable detail if resolution fails. Owner/resource changes close pending
editors and prevent late results from changing the new view. An uncertain write
disables further Save in that editor while keeping the draft editable and
recoverable. Local validation failures permit correction before a write.

Draft clearing advances an account generation before asynchronous deletion and
waits for pending writes. Existing editor timers and disposal cannot recreate a
removed account's draft; a fresh editor captures the newer generation. A
failing-before disposal regression and an invalid-owner timer regression cover
this boundary. Nullable lock metadata remains readable, and an anonymous
`currentUser: null` never permits a write even when the server advertises
`createNote: true`.

Targets are single-use and consumed immediately before sending. Reusing or
concurrently submitting the same target cannot send a second mutation. This
slice accepts ordinary Markdown; standalone slash commands are rejected before
a write, while code examples remain allowed. It does not implement internal
notes, note editing/deletion, reactions or quick actions. Authenticated live
project/group writes, older-instance schema support and private/iOS acceptance
remain open. Synthetic API/widget tests, anonymous production reads, exact-source
APK metadata, native emulator receipts and CI are recorded independently.

## Remaining product priorities

The largest mobile workflow gaps are OAuth application registration and live
login validation, push delivery, server-synchronised viewed-file state, GraphQL
work items/epics/OKR, full repository graph and private Snippet CRUD, registry
publishing/policies and type-specific installation, complete incident operations, Service Desk and analytics families. These are open
requirements under the all-function goal, not features delegated permanently to Web. Store signing, iOS physical-device evidence, accessibility
screen-reader walks, real private-project integration on the submitted build
and live draft/board writes are separate acceptance lanes.

[boards-api]: https://docs.gitlab.com/api/boards/
[boards-user]: https://docs.gitlab.com/user/project/issue_board/
[draft-notes]: https://docs.gitlab.com/api/draft_notes/
[issues]: https://docs.gitlab.com/api/issues/
[merge-requests]: https://docs.gitlab.com/api/merge_requests/
[compare-api]: https://docs.gitlab.com/api/repositories/#compare-branches-tags-or-commits
