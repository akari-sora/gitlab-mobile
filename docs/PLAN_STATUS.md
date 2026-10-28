# Plan and status

Last updated: 2026-10-29.

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
| MR6b-3g | Group Work Items: shared identity seams G0a–G0j, thirteen family MRs, the group UI, visibility and consent (G14) and cross-family acceptance (G15) | Merged 2026-10-28. Plan v5 (!157); seams G0a–G0f (!160, !164, !167, !168, !173, !176), G0g–G0j (!181, !184, !197, !199; decisions D27–D31); U0 labels (!177) and U-add (!183); the thirteen families (!186–!196, !198, !200); follow-ups (!207); the group UI wave (!212); G14-pre, the string-list text policy and the account-global to-do epoch (!214, decision D32); G14, the fifteen group aliases model-visible, the production group-target gate on and the scoped group read tool, with renewed consent: catalogue **4 → 5**, write policy **3 → 4**, disclosure **2** (!219); G15, the cross-family acceptance tests against the opened gate (!221). The app-wide AI flag stays off until MR7. Real-model long upload token, emulator reject-only QA, live group CRUD and iOS are NOT_RUN. Follow-ups #46, #51 | [breakdown](plans/mr6b3g-breakdown.md), [decisions](plans/mr6b3-decisions.md) |
| **MR6c** | Background runs: Android foreground service, notifications, app lock, stop protocol | **Code merged; device evidence open.** Plan v3 (!155). C1 (!161), C2a (!171), C2b (!174), C3 (!178), C4 (!182), C5 (!201), C6 (!203; decision C-D10), C7, remove task, engine detach and the next start (!209), and C8, the host tooling: artifact readback, AVD checks, QA fixtures and the run-book `docs/MR6C_RUNBOOK.md` (!213), merged by 2026-10-28; decisions C-D3…C-D10. The first device run on new sandbox AVDs `Pixel_9_MR6c_API35/36` (2026-10-28) stopped before install because the APK validator did not accept aapt2 36's `minSdkVersion` field; a tooling fix and a V9/R8 rerun are in progress. V9 Task Manager Stop is the only wired device case: V1–V8 and V10–V12 are NOT_RUN, API 34 is NOT_RUN (no system image), iOS is NOT_RUN. Follow-ups #41, #44, #49, #52 | plan v6 §12, §14; [breakdown](plans/mr6c-breakdown.md), [decisions](plans/mr6c-decisions.md), [run-book](MR6C_RUNBOOK.md) |
| MR7 | Open the AI gate: full CI on the release commit, sandbox writes, Play declarations, listing | Plan merged 2026-10-28 (!217): entry gate, packets 7A–7D and 7R, per-capability closure, the sandbox live-write contract, Play declarations and the §15 coverage table. **Building.** Every entry-gate MR is merged with a green source pipeline; the integration pipeline on main `3034a2c1` ([3000661080](https://gitlab.com/aa22396584/gitlab-mobile/-/pipelines/3000661080)) was still running when this was written, so the gate is NOT_VERIFIED until it is green. 7A1, the runtime release allowlists (default deny), started on that base | plan v6 §13, §14; [breakdown](plans/mr7-breakdown.md) |
| Play listing | Store listing, screenshots, data safety | After MR7 | [Store listing](STORE_LISTING.md) |
| Cache C1a | Opt-in read cache (`CachedRead<T>`), scope versions and write barrier, pinned entries, per-class rate limits, request meter, AI run leases, binding after validation | Merged 2026-10-23 after four review rounds (full-path sub-resources are not cached, plan v3 V21) | !103; follow-ups #14 |
| Cache C1b-1 prerequisites | Fixes from #14 needed before screens adopt the cache: dropped background reads, uncacheable reads bypass admission, archive 429 class, confidential-marker saturation | Merged 2026-10-23 | !106; follow-ups #14 |
| Cache C1b-1a | Cached first pages with stale-while-revalidate in `RecordsFeed` (activity, CI, file history, groups, inbox, my work, project extras, projects, search) and the freshness strip (refreshing, offline, rate limited, refresh failed) | Merged 2026-10-23 after three review rounds. Emulator self-test passed (offline strip over cached rows, refresh clears it) | !107 |
| Cache C1b-1b | Hot spots: project overview, pipeline detail, CI overview queue, job-log polling by rate budget | Merged 2026-10-23 after three review rounds. Emulator self-test passed | !115 |
| Cache C1b-2a | Boards and project metadata lists (branches, tags, commits, releases, labels, milestones, and the label and milestone Work Item lists) read cached first pages | Merged 2026-10-23 (!111, board fix !114). Board follow-ups in !120 | follow-ups #16 |
| Cache C1b-2b | Remaining screens (project more, work item, discussions, repository; snippets and registries once their list paths are in the read-class table) | Merged 2026-10-23 after four review rounds (!122). The detail pages' freshness strip (pipeline and overview, then work item and repository) is in !136 | cache plan v3 V9 |
| Cache C1b-2c | AI side: cached reads within 60 s, read-port and tool-catalogue metering, AI budget leases, and the send-paused card | Merged 2026-10-23 (!112, follow-ups !118). Emulator self-test passed. The #17 N-2/N-4 follow-up (per-read budget admission, fresh delivery) is re-reviewed and awaiting CI in !138 | follow-ups #17 |
| Cache C2 prerequisites | The six "before C2" items from #14 and GraphQL 403/404 scope | Merged 2026-10-23 | !109 |
| Cache C2 | Encrypted disk cache, clear markers, startup order | Merged 2026-10-28. C2a (!140); C2b (!149, follow-ups !159); C2-D6 (!153); C2c (!156, follow-ups !162); C2d1 (!166); C2d2 (!172); C2d3 (!175); C2e, the settings, cleanup notices, adoption and the formal enable (!185). Android device acceptance on the project AVD `GitLabMobile_API36_Codex_20261003` (run-as readback of `files/read_cache/`, gitlab debug APK from main `09604cfd`, 2026-10-28): fresh install, population, Settings clear, turning the cache off, sign-out, account removal, resume after each (32 s idle) and no AI or GitLab writes all pass. It found that a relaunch after Settings → Clear created a new key and an empty index without any read; fixed in !218 (no key or index until the first real write; covered by host regressions). On the device, the relaunch after the fix left no index or entries; the first post-clear read of a pinned file did not repopulate the cache (cause not confirmed), and a repeated clear, resume and Files read did (index 1, entries 1). Secure-storage key absence was not read back on the device (NOT_RUN). Account switch (needs a second valid account) and the terminal-401 fence (no safe way to provoke it) are NOT_RUN; iOS is NOT_RUN. Follow-ups #45 | cache plan v3 §4, V13, V14, V17; [breakdown](plans/cache-c2-breakdown.md), [decisions](plans/cache-c2-decisions.md) |
| Cache C3 | Offline repository saving (archive fetch, verified blobs) and an offline read-only mode | Merged 2026-10-29. The C3 prerequisites, the C2 namespace items B1–B11 (!204), and C3a, the offline snapshot core (!211), merged 2026-10-28. C3b, the save and browse UI: consent explainer, save sheet, offline projects page, snapshot browser with snapshot-only Markdown media, `NetworkBoundary`, leave and L1 clear confirmations (!216), merged 2026-10-28 after five review rounds. C3c-1, the offline read-only session, eligibility gate and identity check (only GitLab JSON 401/403 and `invalid_grant` refuse; a refusal-marker failure keeps online sign-in but blocks offline) (!215), merged 2026-10-28 after four review rounds. C3c-2, the offline shell (`OfflineApp`, banner, resume-screen entry, D1 confirmations, AI startup recovery fenced before offline entry) that turns offline entry on (!220), merged 2026-10-29. CI fixes found on the way: stale clear-dialog taps that hung the suite (!225, which also raised `ci/check.sh`'s whole-suite limit to 22 minutes and the `flutter_checks` job to 25) and slow emulator-harness cases (!222). Device acceptance of saving and offline mode is NOT_RUN. C3d (cached lists offline) is optional and not planned yet. Follow-ups #53 | [C3 plan](plans/cache-c3-offline-plan-v2.md) |

## Next steps
1. Cache C3: device acceptance of saving and offline mode on the project AVD.
2. MR6c: finish the C8 tooling fix and the V9/R8 device rerun; the unwired device cases stay NOT_RUN, and MR7 keeps background runs off unless their evidence exists (MR7 plan §3).
3. MR7 per its breakdown: 7A gate and release evidence, 7B sandbox writes, 7C Play declarations, 7D listing hand-off, 7R the release commit.
4. The Play listing.

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
| [MR7 breakdown](plans/mr7-breakdown.md) | Opening the AI gate: entry gate, packets 7A–7D and 7R, per-capability closure, sandbox live writes, Play declarations, §15 coverage |
