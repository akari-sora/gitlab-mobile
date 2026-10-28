# Plan and status

Last updated: 2026-10-28.

This page is the single place for **what we are building, in what order, and where each piece stands**.
- Update it in the same MR that changes a status.
- The detailed designs live in [`docs/plans/`](plans/). They are the working plans in their original language (Traditional Chinese).
- The evidence for each delivered piece lives in the verification ledgers, mainly [v0.6 AI verification](V0_6_AI_VERIFICATION.md).
- The plans also cite review reports, surveys and earlier drafts (e.g. `review-opus.md`, `survey.md`, `ai-assistant-plan-v5.md`). Those are working files outside the repository; the review outcomes they record are folded into the plans.

## Scope and order (owner decisions)

There are two tracks.

**AI assistant ("Mergeline Copilot").**
- **Model:** bring-your-own-key, with OpenAI-compatible Chat Completions, the Responses API and Anthropic Messages.
- **Writes:** the AI may perform every write the app itself can do. Autonomy is selectable, from read-only through confirm-each and low-risk-automatic to a conversation grant and bypass. Hard limits always need the user to type a name.
- **Release:** the AI gate stays off in releases until MR7.
- **Play listing:** Play only, at US$3.99. The listing is prepared after the AI assistant ships.

**Read cache.**
- **Scope:** a memory cache, rate-limit awareness and an encrypted disk cache. On top of those comes offline repository viewing, which GitHub Mobile does not offer.
- **Sign-out:** signing out or leaving a session clears the disk cache.

**Order of work:** MR6b-2 → MR6b-3 → MR6c → MR7 → Play listing. The cache MRs run alongside where files do not overlap: C1a → C1b-1 → C1b-2 (after MR6b-2) → C2 → C3 (C3a, C3b, C3c; C3d optional). This follows the C3 plan §7.1.

**Working rules.**
- One MR per change.
- Self-test on the project's Android emulator, using public projects only and rejecting every AI write.
- Review: the first round is a full panel; later rounds have Opus check only the Critical and Important fixes. Minor findings go to a follow-up issue and never block.
- Merge, then fast-forward the GitHub mirror.
- Claude does all UI/UX. Non-UI implementation is handed to Codex in written packets (to Claude subagents or OpenCode when Codex is out of quota), and Claude re-runs the acceptance itself before committing. Inside Claude Code, the Opus reviewer and any Claude worker run as built-in subagents, not as headless `claude -p`.
- Keep MRs small. When a fix area produces a new Important finding twice, take the conservative option.

## Status

| Piece | What it is | Status | Where |
|---|---|---|---|
| MR1–MR5 | Endpoint policy, adapters, provider settings, consent, read-only tools, runner | Merged 2026-10-20/21 | !87, !88, !89, !91, !92 |
| MR6a | Chat page and entry points, draft append and preview, report | Merged 2026-10-21/22 | !96, !97, !98, !99, !100 |
| MR6b-1 | AI writes, first batch: T1 and T2 REST writes, consent v2, autonomy levels, coordinator, journal, approval cards | Merged 2026-10-22 | !102; follow-ups #12 (in !139) |
| MR6b-2 | AI writes, second batch: files and suggestions, branches/tags/releases, merge requests, CI, snippets, content deletes, mark-all to-dos, registry and project hard lines, read tools for releases/milestones/snippets. Also structured previews, card titles, refusal reasons and the Inbox AI entry | Merged 2026-10-23 after four review rounds and three emulator rounds (every write proposed and rejected; GitLab unchanged) | !104; follow-ups #13 |
| MR6b-3 | GraphQL writes for project Work Items (state, status, dates, health, assignees, milestone, weight, activity notes create/delete), reactions and notifications, incidents and to-do snooze, split into small MRs (shared seams S0a–S0c, then one family per MR) | Merged 2026-10-27. Seams (!116); the eleven families (!130, !132–!135, !137, !123, !141, !143, !144) with the #12 and #13 follow-ups (!139, !131); approval-card wording (!146); P14, which opens the fifteen graph writes to the model (!147); the P15 cross-family acceptance matrix (!148, !151, follow-ups !154); MR6b-3t, whole-field title/description, note body edit and labels (!150) with the edited-card fix (!152); follow-ups #24/#25/#27 (!158), #30 (!163) and #33 (!165). The emulator self-test of the graph writes is NOT_RUN (it needs a gate-on build and a provider key). Group Work Items moved to MR6b-3g (D1) | plan v6 §14; [breakdown](plans/mr6b3-breakdown.md), [decisions](plans/mr6b3-decisions.md) |
| **MR6b-3g** | Group Work Items: shared identity seams G0a–G0f, then thirteen family MRs, the UI, visibility and consent (G14) and cross-family acceptance (G15) | **Building.** Plan v5 merged 2026-10-27 (!157). G0a, group identity and field provenance (!160), and G0b, the strict namespace reader, group label candidates and to-do ownership (!164), merged 2026-10-27; G0b also removed two GraphQL fields GitLab does not have (`Issue.project`, `Label.project`/`group`). G0c, group origins and context (!167), merged 2026-10-27. G0d, the group read tool and freshness (!168), merged 2026-10-27. G0e, single-item grants, the group freshness merge (source unknown is never cleared by a target read) and the sole group port resolver with the production group gate off (!173), merged 2026-10-27. G0f, the fresh group-page chat origin, controller freshness wiring and the AppBar AI entry on group-opened work-item details (!176), merged 2026-10-27; the shared seams are complete. U0, the labels for the fifteen group operations in 24 languages (!177), merged 2026-10-28. The first family wave stopped on two shared gaps; G0g, the trusted group write context, group key spelling and stage-independent seam tests (!181, decision D28), merged 2026-10-28; G0h, strict group-owner evidence in the shared core reads, with note and reaction ownership proven by the strict readback (!184, decisions D29, D30), merged 2026-10-28. U-add, adding a verified group work item to the conversation scope from a pasted URL (!183, decision D27; also fixes #48), merged 2026-10-28. Next the thirteen family MRs on top of G0g and G0h. Follow-ups #32, #35, #37, #39, #43, #46 | [breakdown](plans/mr6b3g-breakdown.md) |
| **MR6c** | Background runs: Android foreground service, notifications, app lock, stop protocol | **Building.** Plan v3 merged 2026-10-27 (!155). C1, the bootstrap-generated `AgentRunService` with the `agent_runs` v1 channel (!161), merged 2026-10-27; the channel table is in the decisions file. C2a, the ticket seam and the three send boundaries (!171), and C2b, the MethodChannel bridge, registry ownership, controller injection and the C3 lookup/notification-event APIs (!174), merged 2026-10-27; decisions C-D3…C-D6. C3, the pinned run notifications (flutter_local_notifications 22.3.3), private generic notifications, unlock-then-open taps and the first-send permission ask (!178), merged 2026-10-28; decisions C-D7, C-D8. Next C4. Follow-ups #41, #44, #49 | plan v6 §12, §14; [breakdown](plans/mr6c-breakdown.md), [decisions](plans/mr6c-decisions.md) |
| MR7 | Open the AI gate: full CI on the release commit, sandbox writes, Play declarations, listing | Not started | plan v6 §13, §14 |
| Play listing | Store listing, screenshots, data safety | After MR7 | [Store listing](STORE_LISTING.md) |
| Cache C1a | Opt-in read cache (`CachedRead<T>`), scope versions and write barrier, pinned entries, per-class rate limits, request meter, AI run leases, binding after validation | Merged 2026-10-23 after four review rounds (full-path sub-resources are not cached, plan v3 V21) | !103; follow-ups #14 |
| Cache C1b-1 prerequisites | Fixes from #14 needed before screens adopt the cache: dropped background reads, uncacheable reads bypass admission, archive 429 class, confidential-marker saturation | Merged 2026-10-23 | !106; follow-ups #14 |
| Cache C1b-1a | Cached first pages with stale-while-revalidate in `RecordsFeed` (activity, CI, file history, groups, inbox, my work, project extras, projects, search) and the freshness strip (refreshing, offline, rate limited, refresh failed) | Merged 2026-10-23 after three review rounds. Emulator self-test passed (offline strip over cached rows, refresh clears it) | !107 |
| Cache C1b-1b | Hot spots: project overview, pipeline detail, CI overview queue, job-log polling by rate budget | Merged 2026-10-23 after three review rounds. Emulator self-test passed | !115 |
| Cache C1b-2a | Boards and project metadata lists (branches, tags, commits, releases, labels, milestones, and the label and milestone Work Item lists) read cached first pages | Merged 2026-10-23 (!111, board fix !114). Board follow-ups in !120 | follow-ups #16 |
| Cache C1b-2b | Remaining screens (project more, work item, discussions, repository; snippets and registries once their list paths are in the read-class table) | Merged 2026-10-23 after four review rounds (!122). The detail pages' freshness strip (pipeline and overview, then work item and repository) is in !136 | cache plan v3 V9 |
| Cache C1b-2c | AI side: cached reads within 60 s, read-port and tool-catalogue metering, AI budget leases, and the send-paused card | Merged 2026-10-23 (!112, follow-ups !118). Emulator self-test passed. The #17 N-2/N-4 follow-up (per-read budget admission, fresh delivery) is re-reviewed and awaiting CI in !138 | follow-ups #17 |
| Cache C2 prerequisites | The six "before C2" items from #14 and GraphQL 403/404 scope | Merged 2026-10-23 | !109 |
| **Cache C2** | Encrypted disk cache, clear markers, startup order | **Building.** Merged by 2026-10-27: C2a, contracts and projections (!140); C2b, cipher, files and key store (!149, follow-ups !159); C2-D6, commits on the caller's isolate (!153); C2c, the coordinator, clearing and the removal step (!156); the C2c follow-ups #29/#31 (!162). C2d1, the disk backend with publication, hydration and failures (!166); under C2-D7/C2-D8 it also carries the pre-send barrier result through the GraphQL writes. C2d2, the startup and session fence, candidate 401 and the recovery order (!172). C2d3, the typed pinned API (immutable MR versions and terminal job logs) and the real AI boundary (!175), merged 2026-10-28; an observed job erase retires the stored log. Next C2e. Follow-ups #45, #47 | cache plan v3 §4, V13, V14, V17; [breakdown](plans/cache-c2-breakdown.md), [decisions](plans/cache-c2-decisions.md) |
| Cache C3 | Offline repository saving (archive fetch, verified blobs) and an offline read-only mode | Plan approved in two review rounds (v2.1); not started; C3a needs C1a, C1b-2 and C2. Split: C3a core, C3b save and browse UI, C3c offline mode, C3d optional | [C3 plan](plans/cache-c3-offline-plan-v2.md) |

## Next steps
1. Finish review and merge: !166 (C2d1, decisions C2-D7 and C2-D8), !168 (G0d).
2. MR6b-3g: the thirteen family MRs, then the UI, G14, G15.
3. MR6c: C4, then the rest of the breakdown.
4. Cache: C2e; then C3 (C3a core, C3b UI, C3c offline mode, C3d optional).
5. MR7, then the Play listing.

## Plan documents
| Document | Covers |
|---|---|
| [AI writes plan v6](plans/ai-writes-plan-v6.md) | Authorization model, write catalogue, autonomy levels, text safety, execution model, journal, background runs, delivery split (§14), tests (§15). v6.10 amendments in §24 |
| [MR6b-1 breakdown](plans/mr6b1-breakdown.md) | Packet split for the first write batch |
| [MR6b-2 breakdown](plans/mr6b2-breakdown.md) | Packet split (waves A–C), shared-file ownership, per-family operation tables |
| [MR6b-2 decisions](plans/mr6b2-decisions.md) | Lead decisions on the breakdown's open questions |
| [MR6b-3 breakdown](plans/mr6b3-breakdown.md), [decisions](plans/mr6b3-decisions.md) | Project Work Item graph writes: seams, families, P14/P15, MR6b-3t |
| [MR6b-3g breakdown](plans/mr6b3g-breakdown.md) | Group Work Items: seams G0a–G0f, families, D20 caps, UI, G14/G15 |
| [MR6c breakdown](plans/mr6c-breakdown.md), [decisions](plans/mr6c-decisions.md) | Background runs: foreground service, permits and tickets, notifications, stop protocol; the `agent_runs` v1 channel table |
| [Cache plan v3](plans/cache-plan-v3.md) | Memory cache, rate limits, disk cache. The "v3 修訂" (V1–V16), "v3.1 補充" (V17–V20) and V21 sections override the older text |
| [Cache C2 breakdown](plans/cache-c2-breakdown.md), [decisions](plans/cache-c2-decisions.md) | Disk cache packets C2a–C2e and the lead decisions C2-D1…C2-D7 |
| [C3 offline plan v2.1](plans/cache-c3-offline-plan-v2.md) | Offline repository saving and the offline read-only mode, including the proposed AGENTS.md wording |
