# MR6b-3 lead decisions (2026-10-23, after plan review round 1)

The decisions below answer plan review round 1 of the breakdown v1:
- Opus: `r1-opus.md`, REQUEST CHANGES, 2 Critical, 12 Important;
- OpenCode GLM: `r1-glm.md`, REQUEST CHANGES.

The owner's standing rules apply:
- fully autonomous;
- take the conservative option;
- small MRs;
- merge each as soon as it is green.

## D1. Group Work Items move to their own MR, MR6b-3g (Opus C1)
- **What changes.** MR6b-3 keeps every `groupWorkItem` path denied, as it is today.
  MR6b-3g follows MR6b-3 and carries all of the group work:
  - the group Work Item origin and the "project Work Item opened from a group page" origin (`projectIssueFromGroupPage`);
  - the `_writeScope()` group branch;
  - the four coordinator changes: `_target`, `_scopeSummary`, `_schema`/`_arguments`, and the group side on sub-resources;
  - the binding changes in `_resourceBound`, `_grantAdmits` and `accountTodo`;
  - a minimal GraphQL Work Item read tool, which also updates the read-port allowlist guard;
  - §15 rows 10 and 24.
- **Why.** Group support needs a new origin, a new grant, a new read tool and binding changes. Doing it in MR6b-3 would put all of that into the shared seams that every family packet waits on, and that slowness is what hurt MR6b-2.
- **Plan follow-through.** Record this in plan v6 §24 as an amendment to §14, so MR6b-3 does not claim group delivery.
- **Snooze.** To-do snooze and unsnooze on a to-do whose target is a group Work Item stay in MR6b-3 only if the to-do target binds through `accountTodo` without a project. If it cannot bind, the write is refused as unverifiable. The v2 plan must say which of the two applies, with evidence.

## D2. GraphQL send boundary: adopt Opus C2 as written (Opus C2)
- **Routing.** A ledger flag (`AiCapability.boundary = graph`) selects the path.
- **No early dispatching.** For a graph row the coordinator does **not** call `markDispatching` before `commit`. Instead it passes a `beforeMutation` closure that runs steps 4.1–4.3 (preflight, send ticket, journal critical-section check), then writes and flushes `dispatching`.
- **`mayStart`.** The method calls `mayStart` synchronously immediately before `_send`. The `accepted` flag is set only when it returns true.
- **Interfaces.**
  - `AiWritePrepared` gets a graph variant: `Future<Object?> Function(GraphHooks hooks)`.
  - `_settleGraph(span, outcome)` never goes through REST `_settle` or `safeFailure`.
  - A GraphQL 401 after `mutationSent` is uncertain (§7.5).
- **Span states (five).** The fifth state is `hookReturned` without `mayStart`, where the method then throws. It maps to `dispatching → notExecuted`: refund the budget and restore the pending-confirmation marker.
  - Why: the hook placement rule allows only synchronous checks between the hook and `mayStart`. No network call can happen in that window, so the mutation certainly did not start. This is the same as the step 4.4 failure that §8 already allows.
  - Record it in §24 as an amendment to §8.
- **Hook placement.** Each method's hook goes after all synchronous owner/current checks and before `onMutationSent`. Give file:line for each of the 17 methods.

## D3. Payload `errors` stay uncertain (Opus I7, OQ2 and OQ6; GLM I4)
- A non-empty payload `errors` after `mutationSent` is `writeUncertain`.
- No `failedCertain` relaxation is allowed without per-mutation GitLab evidence. Any such relaxation is a later plan amendment, not part of MR6b-3.
- `_createWorkItemActivityNote` is not changed.

## D4. All method hooks land in one seams packet (Opus I2, GLM C1/C2)
- One packet owns the roughly 15 `lib/core` files that need the optional `GraphHooks? hooks` parameter on the 17 named methods. That includes `work_item_activity_api.dart`.
- Family packets never edit those files.
- Screens keep calling the methods without hooks, so their behaviour does not change.

## D5. HTTP caps are recomputed honestly (Opus I1, GLM I3)
- Use the MR6b-2 formula.
- Where a method pages (labels, assignees, reactions, the snooze ownership lookup), give the method a `maxPages` parameter on the AI path, so the row's cap stays at or below the shared 40-request budget (§4.4).
- Stopping at `maxPages` with more pages left means unverifiable. That is refused, never guessed.
- Show the arithmetic for each row.

## D6. Answers to v1 open questions
Opus's table in `r1-opus.md` "未解問題的意見" stands:
- **Agreed as proposed:** 3, 4, 7, 8, 9, 11 and 12.
- **Q1:** take the modified version, per D2 and D4.
- **Q2 and Q6:** per D3.
- **Q5:** per D5.
- **Q10:** agreed, after checking the GitLab docs for the meaning of `isSnoozed: false`. The query supports `after`, and both passes count toward the cap.

## D7. Split S0 so no single packet is a bottleneck (Opus I12)
- **S0a, dispatch:** the D2 spec plus `write_coordinator.dart` and the `gitlab_write_port.dart` main file. It also covers the per-row "past acceptance" classification tables (Opus I6), written once here.
- **S0b, hooks:** D4.
- **S0c, shared seams:**
  - the shared write registry, an in-flight AI write registration that the screens can see (Opus I4, GLM I2);
  - preview subtypes and imports, solved against Dart's limits and the existing guards (Opus I3);
  - `_freshWrite` and visibility for rows without a `projectId` (Opus I5);
  - the read allowlist for target construction, plus each row's argument table (Opus I8);
  - the hidden edits to shared files (Opus I11, GLM I5), including the catalogue version 3 → 4, its three hard-coded places, and the guard regexes.
- S0a, S0b and S0c may run in parallel if they own disjoint files. Say whether they do.
- **Baseline.** MR6b-3 branches from `main` after MR6b-2 (!104) merges.

## D8. Editing someone else's activity note (Opus I9)
- Follow the REST `updateNote` rule from MR6b-1/MR6b-2 exactly. Find it and cite it.
- If REST does not check the author, the AI path still refuses to edit a note whose author is not the current user. That is the conservative choice.

## D9. T1 argument names (Opus I10)
T1 tool argument names must match the intent vocabulary, so that T1 can run automatically. For example, the emoji toggle uses `add`.

## D10. Packet size
Family packets stay one family each, as in v1 (P1–P13).
- After S0a, S0b and S0c merge, they can run in parallel, because they own disjoint files.
- Each family packet becomes its own small MR, or two closely related families share one MR.

# Round-2 decisions (2026-10-23, after Opus plan review round 2, `r2-opus.md`)

The plan area produced new Critical and Important findings a second time, so each decision below takes the conservative or simplest option.

## D11. Address Work Items by project and iid (N-C1)
- **Model arguments.** `projectId` + `iid` (int, required). Activity sub-resources add a numeric `noteId`. The scope class is `workItem`, declared in the ledger.
- **GID handling.** The port resolves the GID with `projectWorkItem(Project, iid)` and checks that the Work Item belongs to that project. The GID is never a model argument.
- **`expectedUpdatedAt`.** It is not a model argument. The port reads it in prepare, puts it into `bindingDigest`, re-reads it in the dispatch round (`targetChanged`), and passes it to the method.
- **`confirmName`.** It is removed from the argument tables. The card handles typed names, as in MR6b-2.
- **Lists and nullable values.** Option (a): S0a adds `AiArgType.stringList` and both switch branches. A nullable value becomes an explicit clear boolean, or a required enum with a `none` value. Say which, per row.
- **I5.** Visibility is read as usual: rows with `projectId` go through `_freshWrite`. Drop the v2 rule "text fields confirm except at bypass". Only P13 (snooze) stays without the read.

## D12. Honest caps (N-I1)
- **Where `Project` comes from:** option A. `projectWorkItem` verifies the id through GraphQL `project(fullPath)`, so a stale path fails safely.
- **Counting.** Each row gets a per-call count table, which P15 checks with an independent counter (the `test/ai/mr6b2_budget_test.dart` pattern).
- **Rows still over 40:** set `maxPages` to 1 for that row. If it is still over 40, the row is not proposed (D5).
- **Name limits.** At most 5 assignees and 10 labels per proposal, counted in the cap. Labels are matched in one candidate-list read without `search` where possible.

## D13. One seams MR, built in order (N-I2)
- S0a, S0b and S0c depend on each other, so drop the claim that they can run in parallel.
- They are implemented in the order S0a → S0b → S0c on one branch and land as **one** seams MR, before any family packet.
- **File ownership** stays per sub-packet. A file is owned by exactly one sub-packet; `todo_snooze_api.dart` belongs to S0b.
- **Previews** reuse `AiFieldsPreview` and `AiDeletePreview`. MR6b-3 does not touch the sealed preview hierarchy.

## D14. Ownership gaps (N-I3)
- **`maxPages`:** S0b, with the parameter written per method, plus the error thrown when the limit is hit and more pages remain.
- **Registry adapter files:** S0c, and only the adapter section of those files. State the order relative to C1b-2, which is in progress.
- **Note locator:** S0a, in the port main file or a new part file `gitlab_write_port_graphql_locator.dart`.

## D15. Complete allowlist (N-I4)
S0c's read allowlist and guard list every read that any P packet needs at prepare or readback. No P packet edits the guard.

## D16. Group targets stay closed, including snooze (N-I5; revises D1)
- **Snooze.** To-do snooze and unsnooze are refused when the to-do's target is a group Work Item, and in any other case where the target has no project. Base this on the actual code path, with correct evidence and a test that includes an `accountGlobal` grant.
- **Allowlist.** Remove `namespaceWorkItem` from the MR6b-3 read allowlist. Add a guard assertion that it stays off the list until MR6b-3g.
- **Plan text.** Fix the evidence text in §1, §7 item 8 and the §24 amendment.

## D17. Minors
Fold in the round-2 Minors that cost one line each. List the rest under "follow-ups"; they never block.

# Round-3 decisions (2026-10-23, after plan review round 3: `r3-codex.md`, `r3-opus.md`)

The plan area produced new Critical/Important findings a third time, so each decision below cuts scope or takes the most conservative option.

## D18. Whole-field text writes leave MR6b-3 (Codex R3-C1)
- P1 (Work Item content: title and description) and the **edit** half of P10 (activity note body) move to a new MR, **MR6b-3t**. MR6b-3t designs the controller wiring that gives GraphQL text writes `currentFields` and `provenance` before `_prepareText`, so the hidden-span removal check works at every level, bypass included.
- P10 keeps **delete** (refusing other users' notes, D8). P9 (activity note create) stays: it does not overwrite an existing field.
- No MR6b-3 row may write a whole text field.

## D19. P7 (labels) leaves MR6b-3 (Codex R3-I3, Opus R3-I2)
The "one list read without `search`" that P7 needs does not exist in the code, and no packet legally owns adding it. P7 moves to MR6b-3t, which adds that read in its own seams.

## D20. Every remaining row has a fixed, honest `httpCap` (Codex R3-I1, Opus R3-I2)
- Each row states the formula and every input, then the result `L`, and `L ≤ 40`. Recompute every row; do not copy v3 numbers.
- Independent readbacks count (P11a included).
- A per-proposal refusal never replaces the row's static `httpCap` (P6 included). Name limits (5 assignees) are part of the cap arithmetic.
- A row that cannot be kept at or under 40 with `maxPages: 1` is not proposed (D5).
- P15's independent counter checks each row's number.

## D21. The D2 send-boundary spec is written out in full (Opus R3-I1, Codex M1)
v4 contains the spec text itself, not a reference to a section that does not exist:
- the five span states and their journal transitions, including the noop path (which transition is legal from `prepared`; `finish(prepared→succeeded)` is invalid today);
- the method contract when `mayStart` returns false;
- the rule that the hook goes after any noop return and after all synchronous checks, before `onMutationSent`;
- file:line anchors for each of the remaining methods.

## D22. S0a → S0b → S0c ordering is buildable (Opus R3-I3, Codex R3-I2)
- No file that S0a owns may `part`/import a file that S0c creates. Either S0a creates the row part files it references (empty or minimal), or the ledger gains those parts in S0c, with ownership moved accordingly. Pick one and state it.
- The registry interface has one owner: S0a defines the interface; S0c writes the adapter and its injection.
- Each sub-packet's acceptance (`flutter analyze` clean, its tests green) must be achievable at the end of that sub-packet on its own.

## D23. Minors
Fold in the round-3 Minors that cost a line. List the rest under "follow-ups"; they never block.


## D24. Open questions in the family packets
Accept the drafter's proposed answer for every open question (Q-P2-1 … Q-P13-2, listed below). They are the conservative choice in each case: refuse when unclear, reuse the method's own helpers and preflights unchanged, and keep v4's cap numbers verbatim. On m5, refuse both variants: on instances without activity controls, P9b, P10 and P11a stay unavailable to the AI, which affects availability only. Each family packet re-verifies its anchors against the seams-merge head before it starts.

The answers:
- P2: Q-P2-1 `stateNotApplied` vs `stateConflict` mapping → validation-shaped notApplied ⇒ `stateNotApplied`, revision mismatch ⇒ `stateConflict`. Q-P2-2 preview fields unspecified → show final `stateEvent` only.
- P3: Q-P3-1 candidate-drift checkpoint → enforce in both port dispatch and method preflight. Q-P3-2 START token content/timeout unspecified → reuse existing START semantics unchanged.
- P4: Q-P4-1 Mpre=2/Mrb=2 reader mapping → keep v4 numbers verbatim, no re-derivation. Q-P4-2 inherited→manual snapshot edition → base edition; base/probe disagreement ⇒ `datesConflict`.
- P5: Q-P5-1 registry-`tryStart` vs B order → `tryStart` first; refusal ⇒ notHooked. Q-P5-2 `healthUnsupported` trigger → pre-accept unsupported ⇒ refuse; accepted `Failure(false)` ⇒ same code as uncertain.
- P6: Q-P6-1 raw-item validation source → reuse the search method's own validation verbatim. Q-P6-2 readback multiplicity semantics → multiset-of-IDs equality.
- P8: Q-P8-1 `search`+uniqueness with m8 → rule applies to the complete filtered page; hasNextPage ⇒ refuse. Q-P8-2 selection helpers uncited → reuse method's own helpers unchanged.
- P9: Q-P9-1 m5 pre-set cache flag → REFUSE both variants (permanent AI-unavailability on controls-less instances; availability-only consequence). Q-P9-2 writeAccess=1 over-count (review §3.2) → keep v4 numbers verbatim.
- P10: Q-P10-1 m5 scope for `_readActivityEditPreflight` → flag takes effect; follow S0b's actual scope if narrower and note deviation. Q-P10-2 `noteChanged` vs `noteMissing` precedence → pre-accept `noteChanged`, post-accept `noteMissing`.
- P11: Q-P11-1 three-stage↔formula split → opening→P, preflight→Mpre, readback→Mrb; assert per-stage ≤2 pages plus totals. Q-P11-2 `intentUnclear` vs lead confirmation UX → family only refuses unclear booleans; 24-word table marks UI-owned words.
- P12: Q-P12-1 digest key format → `incidentUpdatedAt:<raw>` under existing digest; mismatch ⇒ `targetChanged`. Q-P12-2 escalation/actor checks uncited → reuse `:148` preflight unchanged; add nothing.
- P13: Q-P13-1 expired-snooze unsnooze code → `todoNotFound`. Q-P13-2 `AiAppTarget` kind table → mirror existing kinds read-only; unknown kind ⇒ `todoUnsupportedTarget`, never invent.

## D25. Lead decisions during the family builds (2026-10-23)
- **S0d, a seams follow-up.** P9 (comment create) and P10 (note delete) need four shared contracts the seams lack. They are validated actor evidence (or an AI-only "own note" constraint) for create and delete; parent identity before a missing note in the delete preflight (so drift plus a missing note is `noteChanged`); a continuation note's own reply target; and the controls-support state on the create access. They land as S0d before P9 and P10; the UI paths keep their behaviour.
- **Unsnooze acknowledgement.** `unsnoozeTodo()` accepts a reply only when the to-do carries the `snoozedUntil` key with a null value. An omitted key is an invalid response. The selection already requests the field. Lead-authorised seam repair, landed with P13.
- **Snooze time precision.** The AI's snooze time is normalised to whole seconds (never rounded up) before the preview, the digest and the mutation, and must still be in the future. GitLab's `Time` scalar serialises whole seconds, so an exact comparison with fractional input would turn real successes into uncertain writes.
- **Reaction readback.** GitLab bumps a note's `updatedAt` when a reaction changes, so the readback after a reaction mutation does not compare `updatedAt`. The checks before acceptance still do. This is a separate fix on `main` (it also affected the UI).


## D26. OAuth replay after binding is a refusal path (P15, 2026-10-27)
Breakdown §4.3 asks every family test to include "a 401 refresh replay on every read". For assignees, status and weight (P3, P6, P8b) a replay after the target binds is not a success path: an OAuth refresh runs `_cache.clear(revoke: false)` (`lib/core/gitlab_api.dart`), which advances the read epoch, and those cores refuse a target bound under an older epoch. So the success-path drives withhold the challenge on those reads, and the P15 budget matrix separately drives each of the three ops with every read challenged, asserting the exact refusal, zero mutations and a request count within the static cap. The static `httpCap` still counts a replay of every logical read, so it stays an honest upper bound.

## D27. U-add: where a user-added group work item comes from (MR6b-3g §6.1, 2026-10-28)
The breakdown (§8, U-add row) asks the lead to name the add source, how the numeric Group ID is obtained and its read budget. Lead decision, conservative and smallest:
- **Source: a group work-item URL the user pastes or types into an explicit "add work item" action in the chat.** It is parsed with the account's `GitLabInstance` rules (same origin and installation subpath, HTTPS only), accepting only the group work-item form `/groups/<full path>/-/work_items/<iid>`. Group issue and epic paths are refused, because their numbers are not proven to equal the work item iid. Any other URL, another instance or a project path is refused before any read. No picker or free-text search in U-add; they can come with the full UI wave if needed. The group page entry stays G0f's origin path and is not an add source.
- **Numeric Group ID:** never taken from the URL or the model. A REST group-by-path lookup gives a candidate numeric ID; the strict G0b namespace read (which needs an expected group ID) and the read port's own read must both agree with it, and the G0d read channel verifies the iid and work-item GID inside that group. A stale cached lookup can only cause a refusal. Only a fully verified identity enters G0e's trusted `uiAdded` set.
- **Budget:** these reads count against the conversation's UI/context read budget, not the write's §4 cap; the later write still reserves its full §4 cap. A failed, ambiguous, drifted or foreign result adds nothing.
- **When:** only while the conversation is idle (no run, no pending approval). Adding opens a new segment and asks for consent for the new scope; models and tool results can never trigger it. Removing the item, switching account or generation, a same-iid item in another group and a project descendant are all refused or cleared; a grant never widens to the whole group or project.

## D28. G0g: the trusted group write context is a seam, not a family job (MR6b-3g, 2026-10-28)
The first delivered family (G-P5 health) found that G0e's group resolver (`_resolveGroupWorkItem`) needs the session generation, the group-read epoch and a liveness predicate, while `GitLabAiWritePort` receives only the API and account key, so no production caller can supply them; `_preparedGroupIdentityMatches` also requires the identity's API owner and generation to match the policy. Families must not invent these values or widen their ownership. Lead decision: a small seam MR **G0g** (Codex) adds one trusted, app-owned context channel to the port, wires it in production where the controller builds the port, and gives families one shared accessor that refuses (`workItemUnverifiable`, before any HTTP) when the context is absent, revoked or stale. The values never come from model arguments. G0g also makes the two shared group assertions (`mr6b3g_seams_test.dart` "all group rows empty", `mr6b3g_registry_test.dart` "status/dates/health are unavailable stubs") independent of how many families have landed, so no family edits shared tests. Families delivered before G0g switch to the accessor in a small follow-up after merging main; later families use it directly.

## D29. Group ownership after a send whose payload cannot name the parent (MR6b-3g G0h, 2026-10-28)
G0h's strict owner mode requires every post-send response to prove group ownership. On GitLab 18.11 some mutation payloads cannot: note create/update/delete and reaction add/remove (the `Noteable` union excludes `WorkItem`; `destroyNote` returns no parent), and todo snooze/unsnooze acknowledgements (ID and time only). G0h therefore refused these writes before sending. Lead decision:
- For these mutations the acknowledgement proves only the mutated object itself (note ID / body / reaction / todo ID and time). Group ownership after the send is proven by the **independent strict readback** that each family already performs (a fresh read carrying the verified `strictGroupOwner`: the parent work item, plus the note / reaction / todo state).
- Until that readback proves the owner and the expected state, the outcome is **uncertain, never success**; a readback that cannot run or fails ownership stays uncertain. Pre-send phases (opening, access, preflight) stay strict and refuse.
- The shared note/reaction APIs send in strict mode only when the caller supplies that strict readback; without it they keep refusing before send. No extra request is added: the readback is the one already counted in each family's §4 cap.
- Strict dates no-ops keep refusing (`unsupported`) rather than reporting success from an older snapshot; a follow-up may revisit it.

## D30. Group todo snooze/unsnooze keep no readback (amends D29, 2026-10-28)
G0h FIX1 noted that the §4 todo rows count `Mrb=0` while D29 asks for a post-send ownership read. Lead decision: group todo snooze/unsnooze keep `Mrb=0`. Before the send, the strict ownership reader proves that the exact todo ID belongs to the verified group work item; after the send the acknowledgement must return that same todo ID and the expected `snoozedUntil` (D25 rules), otherwise uncertain. A todo's target never changes, and snoozing only changes the user's own to-do list, not group content, so a separate readback adds a request without protecting group data. Residual: the work item could move to another group between the pre-send proof and the mutation; the effect is limited to the user's own todo state. Note and reaction writes keep D29's strict readback, because they change group content.

## D31. G-P13 registers the G0i selected-todo readers in the shared guards (2026-10-28)
G0i added `selectedTodoForSnooze` and `selectedTodoForUnsnooze` to `lib/core/todo_snooze_api.dart` without registering them in the shared boundary guards, so G-P13 could not call them. Rather than reopen G0i (already approved and landing) for two test-only lines, the lead authorised G-P13 (packet `FIX1.md`) to edit `tool/tests/test_ai_boundaries.py` and `test/ai/mr6b3_guard_test.dart` **additively**: exactly those two named readers join the snooze port's write allowlist and exact graph expectation; the original 35-member contract stays as a separate baseline assertion; generic channels stay forbidden. No other shared file is touched by the family.
