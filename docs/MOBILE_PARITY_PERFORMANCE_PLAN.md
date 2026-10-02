# Mobile parity and performance follow-up

Started 2026-10-02 from `0e1298e` (v0.5.0). This is an implementation plan,
not acceptance evidence. Keep the native mobile UI, pinned SDK and dependency
lock; add no dependencies. Never persist private read caches to disk.

## Comparison method

Compare GitLab.com at 390 × 844 with current Flutter sources and the physical
S24 Ultra. Check project navigation, repository, work items, MR review, CI,
groups, inbox and account flows. Official GitLab documentation establishes API
contracts; screenshots establish actual responsive layout. Reconcile the
September audit against v0.5 before classifying anything as missing.

## Delivery slices

1. Add project issue boards with a board selector, one active column on phones,
   bounded issue pagination, scoped filters and existing issue details/actions.
2. Add server-backed MR draft review: list, add/edit/discard private drafts,
   submit a review, preserve errors and never automatically retry uncertain writes.
3. Optimize project resolution with a bounded, client-local read cache and
   concurrent request sharing. Clear it on client close and before/after writes;
   prevent pre-write requests from repopulating it. Explicit refresh must bypass
   stored results. Do not cache authentication, failures, live logs or writes.
4. Add native revision comparison with explicit from/to refs, comparison mode,
   bounded responses and lazy diff reading.
5. Reduce list rendering work: derive filtering/sorting once per data change,
   keep lazy rows, avoid unnecessary clips and whole-list work during scroll.
6. Improve mobile discoverability and loading/error/empty feedback while
   preserving keyboard, large-text, gesture-inset and account-switch behaviour.

## Regression and evidence sequence

Before refactoring, add meaningful transport-count, cache invalidation and
list-derivation regression cases. Capture the existing physical-device profile
baseline from an isolated source snapshot. After implementation run targeted
tests, full analysis/tests, Python CI regressions and Android build. Repeat the
same profile-mode gestures on the same device; keep raw/private evidence ignored
locally, commit only aggregate measurements and synthetic tests.

Record a current parity matrix, changes, commit, executed checks and remaining
NOT_RUN cases. CI, synthetic transport, live reads, live writes and physical
performance remain separate proof lanes. No global GitLab feature-parity or
G0 acceptance claim follows from this work.
