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
