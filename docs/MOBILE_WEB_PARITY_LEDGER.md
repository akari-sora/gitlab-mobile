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
| Plan / Work items | Loaded six issues and mobile detail; additional actual project Issue and group Epic details and mobile Activity timeline observed | Existing REST Issues/Tasks/Incidents plus fixed-query GraphQL project cursor list, server type capabilities, project/group details, collapsible description/assignees/labels/hierarchy/dates, seven lazy attribute kinds and read-only activity paging | Remaining widgets, activity filters/order/replies, group lists, filters, Work Item mutations and authenticated/edition acceptance |
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
| Deploy / Package registry | Actual 20-version list and three-asset detail observed | Search/sort/paged list, files, guarded deletion | Type-specific download/publish/policies and live write proof |
| Deploy / Container registry | Loaded empty state, search/order and cleanup explanation | Repository/tag/digest/detail and guarded deletion | Empty project has no live tag example; publish/policies/bulk cleanup |
| Operate / Environments | Loaded empty state and review-app controls | List/detail/create/stop/delete | Full metrics/terminal/rollback/protection and live CRUD |
| Operate / Terraform modules | Loaded module-registry empty state and documentation | Filtered package list/files/guarded deletion | Download/publish, real module instance and live write proof |
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
discussion/reply continuations; filtering/order/replies and other widgets remain open.
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
The repair still requires an installed-build check; the gray error area is not a
successful table-layout validation.

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

## Next implementation lanes

1. Typed REST Tasks/Incidents now have source and regression coverage. Complete
   installed-build checks and disposable-fixture CRUD/lifecycle readback; alert,
   timeline, metrics and on-call workflows remain open.
2. Fixed-query GraphQL Work Items now include server-returned scope/type IDs,
   project cursor paging and exact project/group details with five base widgets
   plus seven independently loaded attributes and read-only activity. Complete remaining
   widgets, activity filtering/order/replies, group lists, filters,
   native mutations and actual authenticated/private/edition validation.
3. Multi-file Snippet blobs now have lazy paths/content, source/Markdown preview
   and guarded file actions with `updatedAt` change detection. Complete
   installed-build and private disposable-fixture validation. Describe a current
   snapshot; do not claim a fixed SHA or infer a ref.
4. Registry safe type-specific download/publish and complete repository graph.
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
