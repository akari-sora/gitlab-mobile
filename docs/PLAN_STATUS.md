# Plan and status

Last updated: 2026-10-23 (late night, before a reboot).

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
- Claude does all UI/UX. Non-UI implementation is handed to Codex in written packets (to Claude subagents or OpenCode while Codex is out of quota, as from 2026-10-23 to 10-30), and Claude re-runs the acceptance itself before committing.
- Keep MRs small. When a fix area produces a new Important finding twice, take the conservative option.

## Status

| Piece | What it is | Status | Where |
|---|---|---|---|
| MR1–MR5 | Endpoint policy, adapters, provider settings, consent, read-only tools, runner | Merged 2026-10-20/21 | !87, !88, !89, !91, !92 |
| MR6a | Chat page and entry points, draft append and preview, report | Merged 2026-10-21/22 | !96, !97, !98, !99, !100 |
| MR6b-1 | AI writes, first batch: T1 and T2 REST writes, consent v2, autonomy levels, coordinator, journal, approval cards | Merged 2026-10-22 | !102; follow-ups #12 |
| MR6b-2 | AI writes, second batch: files and suggestions, branches/tags/releases, merge requests, CI, snippets, content deletes, mark-all to-dos, registry and project hard lines, read tools for releases/milestones/snippets. Also structured previews, card titles, refusal reasons and the Inbox AI entry | Merged 2026-10-23 after four review rounds and three emulator rounds (every write proposed and rejected; GitLab unchanged) | !104; follow-ups #13 |
| **MR6b-3** | GraphQL writes for project Work Items (state, status, dates, health, assignees, milestone, weight, activity notes create/delete), reactions and notifications, incidents and to-do snooze, split into small MRs (shared seams S0a–S0c, then one family per MR) | **Building.** The seams merged 2026-10-23 (!116). P2, P5 and P12 are in MRs !125–!127 (reviewed). P3, P4, P6, P8 and P13 are built and reviewed, their MRs are next. P9 and P10 are built on the seams follow-up S0d (reviewed). P11 waits for the reaction readback fix (!123). P14 (opening the families to the model) is not started. Group Work Items move to MR6b-3g (D1); whole-field text writes and labels move to MR6b-3t (D18, D19) | plan v6 §14; [breakdown](plans/mr6b3-breakdown.md), [decisions](plans/mr6b3-decisions.md) |
| MR6c | Background runs: Android foreground service, notifications, app lock, stop protocol | Not started | plan v6 §12, §14 |
| MR7 | Open the AI gate: full CI on the release commit, sandbox writes, Play declarations, listing | Not started | plan v6 §13, §14 |
| Play listing | Store listing, screenshots, data safety | After MR7 | [Store listing](STORE_LISTING.md) |
| Cache C1a | Opt-in read cache (`CachedRead<T>`), scope versions and write barrier, pinned entries, per-class rate limits, request meter, AI run leases, binding after validation | Merged 2026-10-23 after four review rounds (full-path sub-resources are not cached, plan v3 V21) | !103; follow-ups #14 |
| Cache C1b-1 prerequisites | Fixes from #14 needed before screens adopt the cache: dropped background reads, uncacheable reads bypass admission, archive 429 class, confidential-marker saturation | Merged 2026-10-23 | !106; follow-ups #14 |
| Cache C1b-1a | Cached first pages with stale-while-revalidate in `RecordsFeed` (activity, CI, file history, groups, inbox, my work, project extras, projects, search) and the freshness strip (refreshing, offline, rate limited, refresh failed) | Merged 2026-10-23 after three review rounds. Emulator self-test passed (offline strip over cached rows, refresh clears it) | !107 |
| Cache C1b-1b | Hot spots: project overview, pipeline detail, CI overview queue, job-log polling by rate budget | Merged 2026-10-23 after three review rounds. Emulator self-test passed | !115 |
| Cache C1b-2a | Boards and project metadata lists (branches, tags, commits, releases, labels, milestones, and the label and milestone Work Item lists) read cached first pages | Merged 2026-10-23 (!111, board fix !114). Board follow-ups in !120 | follow-ups #16 |
| Cache C1b-2b | Remaining screens (project more, work item, discussions, repository; snippets and registries once their list paths are in the read-class table) | Merged 2026-10-23 after four review rounds (!122). The freshness strip on the detail pages is in progress (UI) | cache plan v3 V9 |
| Cache C1b-2c | AI side: cached reads within 60 s, read-port and tool-catalogue metering, AI budget leases, and the send-paused card | Merged 2026-10-23 (!112, follow-ups !118). Emulator self-test passed | follow-ups #17 |
| Cache C2 prerequisites | The six "before C2" items from #14 and GraphQL 403/404 scope | Merged 2026-10-23 | !109 |
| **Cache C2** | Encrypted disk cache, clear markers, startup order | **Building.** P-C2a (contracts and projections) is in its first fix round: both reviewers found that real GitLab shapes are rejected (non-issue objects, pipeline objects) and that the guard tests miss mutations; one more lead decision (C2-D4, nullable fields against real shapes) is due. P-C2b follows | cache plan v3 §4, V13, V14, V17; [breakdown](plans/cache-c2-breakdown.md), [decisions](plans/cache-c2-decisions.md) |
| Cache C3 | Offline repository saving (archive fetch, verified blobs) and an offline read-only mode | Plan approved in two review rounds (v2.1); not started; C3a needs C1a, C1b-2 and C2. Split: C3a core, C3b save and browse UI, C3c offline mode, C3d optional | [C3 plan](plans/cache-c3-offline-plan-v2.md) |

## Next steps
1. Merge the reviewed MRs (!121, !125–!127), finish the review checks on !123, !124 and !128, then open the MRs for S0d, P3, P4, P6, P8, P9, P10, P13 and the #12/#13/#17 follow-ups; P11 after !123; then P14.
2. C2: P-C2a fix round and decision C2-D4, then P-C2b to e in order; then C3 (C3a core, C3b UI, C3c offline mode, C3d optional).
3. MR6b-3t (text fields, labels), MR6b-3g (group Work Items), MR6c, MR7, Play listing.

## Plan documents
| Document | Covers |
|---|---|
| [AI writes plan v6](plans/ai-writes-plan-v6.md) | Authorization model, write catalogue, autonomy levels, text safety, execution model, journal, background runs, delivery split (§14), tests (§15). v6.10 amendments in §24 |
| [MR6b-1 breakdown](plans/mr6b1-breakdown.md) | Packet split for the first write batch |
| [MR6b-2 breakdown](plans/mr6b2-breakdown.md) | Packet split (waves A–C), shared-file ownership, per-family operation tables |
| [MR6b-2 decisions](plans/mr6b2-decisions.md) | Lead decisions on the breakdown's open questions |
| [Cache plan v3](plans/cache-plan-v3.md) | Memory cache, rate limits, disk cache. The "v3 修訂" (V1–V16), "v3.1 補充" (V17–V20) and V21 sections override the older text |
| [C3 offline plan v2.1](plans/cache-c3-offline-plan-v2.md) | Offline repository saving and the offline read-only mode, including the proposed AGENTS.md wording |
