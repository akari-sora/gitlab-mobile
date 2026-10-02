# Mobile web parity and performance follow-up

Current implementation baseline: `0e1298e` (`v0.5.0`), reviewed on
2026-10-02. This document describes the source on the mobile parity and
performance branch. It is not a release or G0 acceptance record.

## What was compared

The comparison used three distinct sources of evidence:

- GitLab.com responsive pages at 390 × 844: a public project overview, issue
  boards, merge-request list, pipeline list and the project navigation drawer.
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
| Global navigation | Projects, groups/subgroups, todos, assigned/review-requested/created work, activity and global search | No structural change | Web administration, help and create menus are outside the native client scope |
| Project overview | Description, stars, forks, languages, licence, clone URLs, star/fork actions | No structural change | Full Web analytics and settings are not reproduced |
| Manage | Activity, members and labels | No structural change | Access-token, webhook, integration and full member-role administration remain on Web |
| Plan | Issues, milestones and linked work already existed | Issue boards; native issue/MR filters and server ordering for date, direction, scope, labels, milestone, assignee, author and reviewer | Iterations, requirements, epics and GraphQL polymorphic work items remain open |
| Code | Repository tree, README, branches, commits and tags; fixed-SHA file view, history, blame, search, syntax highlighting and line permalinks; MR list/detail/diffs | Compare two refs using merge-base or direct mode, with lazy commit/file lists and unified diff viewing | Repository graph, snippets, locked files and cross-project comparison remain open |
| MR review | Discussions, inline single-line positions, approvals/merge, suggested changes, auto-merge, local viewed-file state and the MR draft/ready toggle | Server draft-note list, add/edit/discard and bulk publish, tied to account/project/MR/head SHA | Viewed-file state is not server-synchronised; multi-line positioning and full desktop review policy administration remain open |
| Build | Pipelines, stage-grouped jobs, controls, incremental ANSI logs and search, JUnit report views, artifacts, cross-project CI overview and schedules | List rendering work is reduced; no new CI surface | Pipeline DAG/graph editing and the complete Web pipeline editor remain open |
| Deploy and operate | Environments and deployment history | No structural change | Package, container and model registries; Terraform modules; incidents and Service Desk remain on Web |
| Analyze | Basic project counts and activity | No structural change | Value-stream, contributor, repository, code-review and issue analytics, insights and model experiments remain on Web |
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

The App does not expose drag/drop, list reordering or direct “move card” writes.
After a mutation it refreshes all mounted columns because one issue can belong
to several label columns. If a returned board scope cannot be translated safely
to the Issues API, the App shows it as unsupported instead of loading an
incorrect fallback list.

### Native work-item filters

Issue and MR lists now submit search explicitly and expose a full-height native
filter sheet. Apply, Cancel and Reset have separate draft state. The final
server query includes supported order, direction, scope and people/label/
milestone filters; client-side mutation reconciliation uses the same criteria.
Successful writes recheck the already-loaded page range against server ordering
and replace its next cursor. Reading a detail does not refresh the resident list.

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
the first/last grouped rows receive clipping. Repository syntax spans are also
generated lazily and held in a page-owned LRU capped at 512 rows and 131,072
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
Local evidence on the submitted application source (Flutter 3.47.2 / Dart
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

## Remaining product priorities

The largest mobile workflow gaps are OAuth application registration and live
login validation, push delivery, server-synchronised viewed-file state, GraphQL
work items/epics, pipeline DAG, repository graph and the registry/operate/
analytics families. Store signing, iOS physical-device evidence, accessibility
screen-reader walks, real private-project integration on the submitted build
and live draft/board writes are separate acceptance lanes.

[boards-api]: https://docs.gitlab.com/api/boards/
[boards-user]: https://docs.gitlab.com/user/project/issue_board/
[draft-notes]: https://docs.gitlab.com/api/draft_notes/
[issues]: https://docs.gitlab.com/api/issues/
[merge-requests]: https://docs.gitlab.com/api/merge_requests/
[compare-api]: https://docs.gitlab.com/api/repositories/#compare-branches-tags-or-commits
