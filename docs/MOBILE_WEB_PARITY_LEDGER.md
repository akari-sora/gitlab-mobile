# Full mobile Web parity ledger

Goal: implement all available GitLab workflows with reasonable native mobile UX,
and verify them in the browser and installed App. This ledger does **not** declare
full parity, G0, release readiness, or private/paid-feature acceptance.

On 2026-10-02, the signed-out public project's responsive navigation (390 × 844)
exposed the following 30 project entries. Every menu label and destination was
observed. “Page observed” means the actual page loaded; a menu read is not a
completed page walk. Authenticated, Premium/Ultimate, self-managed and
configuration-dependent entries require additional cataloguing. The README's
referenced 105-spec `docs/plan` package is absent from this checkout; no missing
specification numbers have been invented.

| Web entry | Browser page observation | Current native source | Open functionality/acceptance |
|---|---|---|---|
| Manage / Activity | Prior project walk | Activity feed | Full event-kind/authenticated parity walk |
| Manage / Members | Loaded roles/source/search/sort and member rows | Member list/actions | Custom roles, complete administration and live permissions |
| Manage / Labels | Loaded Active/Archived, search/sort and empty state | List/create/edit/delete | Scoped labels/subscriptions and live CRUD |
| Plan / Work items | Prior issue/MR list walk | Issues and linked work; server filters/order | Typed Task, Epic, OKR, Ticket and unified widget-based work items |
| Plan / Boards | Development board observed | Phone-width columns, card move, board/list management | Paid scope/list creation, touch drag/drop and live mutation readback |
| Plan / Milestones | Loaded empty-state explanation | List/detail/create/edit/delete | Full progress/reporting and live CRUD |
| Plan / Wiki | Loaded empty Wiki explanation | Page list/read/create/edit/delete | History, attachments, tree and live CRUD |
| Code / Merge requests | List/review public walk | Detail/discussion/diff/approval/merge/server draft review | Multi-line comments, viewed-file sync, review policies and live draft CRUD |
| Code / Repository | Loaded tree/ref/find-file/actions and README | Tree, fixed-SHA viewer, blame/history/edit/search | Locked files and complete repository administration |
| Code / Branches | Loaded Overview/Active/Stale/All, search and MR links | List/create/delete/protection controls | Rule completeness and live CRUD |
| Code / Commits | Menu only | List/detail/changes | Full filters/signature/policy parity |
| Code / Tags | Loaded search/order/direction, release and pipeline links | List/create/delete | Full signature/release policy parity |
| Code / Repository graph | Loaded mobile timeline and branch/history controls | Selected-ref parent graph, branch/tag picker, bounded pagination | Web full all-branch/simplified history modes and live large graphs |
| Code / Compare | Fixed-revision comparison observed | Merge-base/direct compare, lazy actual unified diffs | Cross-project compare and complete controls |
| Code / Snippets | Actual empty list | Explicit single-file reader/editor and guarded CRUD | Multi-file tree/preview/edit; immutable snippet HEAD API unresolved |
| Build / Pipelines | List/detail/stage controls observed | Lists/actions/tests plus actual paginated needs graph | Downstream/cross-project graph and pipeline editor |
| Build / Jobs | Prior job/log walk | Incremental ANSI logs/search/actions/artifacts | Full Web filters, large-log physical profiling |
| Build / Pipeline schedules | Menu only | List/create/edit/run/delete | Inputs, ownership, complete policy and live CRUD |
| Build / Artifacts | Menu only | Pipeline/job artifacts browse/download | Project-wide inventory, retention and bulk operations |
| Deploy / Releases | Menu only | List/detail/create/edit/delete | Evidence/assets/milestone workflow parity and live CRUD |
| Deploy / Package registry | Actual 20-version list and three-asset detail observed | Search/sort/paged list, files, guarded deletion | Type-specific download/publish/policies and live write proof |
| Deploy / Container registry | Menu only | Repository/tag/digest/detail and guarded deletion | Empty project has no live tag example; publish/policies/bulk cleanup |
| Operate / Environments | Menu only | List/detail/create/stop/delete | Full metrics/terminal/rollback/protection and live CRUD |
| Operate / Terraform modules | Menu only | Filtered package list/files/guarded deletion | Download/publish, real module instance and live write proof |
| Monitor / Incidents | Actual empty Open/Closed/All view observed | Not implemented | Typed incident list/severity plus alert/status/timeline/metrics |
| Monitor / Service Desk | Loaded email-support explanation and sign-in requirement | Not implemented | Capability/permissions, confidential Ticket widgets and email-aware replies |
| Analyze / Value stream | Loaded six stages, lifecycle metrics and filters | Not implemented | Scope/date/stream/stages/metrics, tier-dependent aggregation |
| Analyze / Contributors | Loaded per-author/day charts, ref selector and 6,000-commit limit | Not implemented | Ref/paged aggregate; complete Web time series API unresolved |
| Analyze / CI/CD | Loaded source/ref/date controls, counts/rates and duration chart | Pipeline operational pages only | Bounded pipeline time series/percentiles and capability-gated job analytics |
| Analyze / Repository | Loaded language/coverage/distribution sections and 2,000-commit limit | Overview languages bar | Coverage summary plus complete commit histograms API unresolved |

## Account and performance acceptance

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

1. Typed REST Tasks and Incidents; reuse existing issue details/filters while
   exposing only the server's actual issue state and severity.
2. Fixed-query GraphQL Work Items: scope-specific available types/type IDs,
   widgets, cursor paging, group Epics and available OKR/Ticket types.
3. Multi-file Snippet blobs: lazy paths/content with `updatedAt` change detection.
   Describe a current snapshot; do not claim a fixed SHA or infer a ref.
4. Registry safe type-specific download/publish and complete repository graph.
5. Analytics: contributor aggregate and coverage summary, CI/CD series, VSA.
   Unverified public APIs for complete histograms/time series remain open.
6. Continue all 30 actual page walks, authenticated/paid/configured cataloguing,
   new Android screens, real private-project integration, disposable-fixture
   CRUD, iOS binary/device and screen-reader verification.

Official contracts: [Issues](https://docs.gitlab.com/api/issues/),
[GraphQL](https://docs.gitlab.com/api/graphql/),
[Work Item migration](https://docs.gitlab.com/api/graphql/epic_work_items_api_migration_guide/),
[Project Snippets](https://docs.gitlab.com/api/project_snippets/),
[CI/CD analytics](https://docs.gitlab.com/user/analytics/ci_cd_analytics/),
[Repository analytics](https://docs.gitlab.com/user/analytics/repository_analytics/).
