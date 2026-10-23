# MR6b-2 decisions (2026-10-23, owner away: 「全自動，別再問」)

These resolve "未解問題與正文裡的衝突" (open questions) 1–18 in `mr6b2-breakdown.md`. Rule used: keep every feature the owner asked for (plan v6 §0 item 1, "everything the app can do") and pick the conservative implementation.

## Base has moved
The base is now `main` @ `e35db41`: MR6b-1 merged, including its review fix round. The breakdown was written against an older tree. Where its description of the current code differs from the code, **follow the code** and note the difference in RESULT.md. Known differences:
- **HTTP budget.** It is per operation: `aiWriteRequestAllowance` in `write_coordinator.dart`, no longer a flat 39 (`_requestAllowance` is gone). Each new row's `httpCap` must follow the same counted-worst-case method, and its test compares against an independently counted table.
- **Upload placeholders.** `redactOutgoing` and `_freshWrite` provenance **are wired** (MR6b-1 placeholder packet), so the second half of open question 10 is done.
- **Holds pause cards instead of ending them.** This applies to account removal, background and Retry-After (`pausedReason`, `AiWritePause`).
- **Settled edits** are kept (`settledEdits`).
- **Write rows** carry the target and link (`AiWriteOutcome.targetName`, `webLink`, `AiWriteRow`).
- **Closing keywords** are detected in `write_text.dart`; `closingRefs` sits on the proposal.
- **Hidden-span counting** uses `Redactor.redactSourceRanges`. A field the AI saw only cut is refused with `fieldTooLong`.
- **Uploads.** `AiScopeClass.projectUpload` exists for `upload_attachment`.

## Decisions
1. **Port split into part files:** adopt the breakdown's recommendation. The guard scans every part file, forbids `GitLabApi` declarations and passing `_api`, and forbids the text `gitlab_api.dart` inside part files.
2. **Merge HTTP budget:** adopt (a), (b) and (c).
   - (c) At dispatch, if the MR's `sha` and all three `diff_refs` SHAs are unchanged, do not re-paginate diffs and commits; they are determined by those SHAs.
   - Still re-read `closes_issues`, `ci_config_path` and the target branch's protection.
   - This deviates from plan §3's "re-check before dispatch" in letter, not in effect, because the diff content is fixed by those SHAs. Record it in the ledger.
3. **405/406/409/422 checked against GitLab's docs (2026-10-23).** `PUT …/merge_requests/:iid/merge` returns:
   - 405 "cannot be merged";
   - 409 "SHA does not match HEAD of source branch";
   - 422 "Branch cannot be merged";
   - 406 is no longer documented, but older instances return it for conflicts.

   For the merge, approve, unapprove, rebase and cancel-auto-merge mutations, 405, 406, 409 and 422 are **certain-not-executed** (`failedCertain`), not unknown. Amend plan §7.5 accordingly.

   Cancel auto-merge:
   - The new endpoint (GitLab 19.5+) returns 409 "Can't cancel the automatic merge" when the MR is not set to auto-merge. Classify that as `noChange`.
   - The deprecated `cancel_merge_when_pipeline_succeeds` returns 201 with `"status":"error"` for the same case.
   - Use the new endpoint. On 404 or 405, fall back to the deprecated one, and count both requests in `httpCap`.
4. **`confirmName` vs `releaseName`:** split them as packets 1 and 2 say.
5. **Release notes and snippet descriptions are text class (B):** the ledger declares each field's class (packets 1 and 2).
6. **Decision-level reads live in the port:** as packet 2 says. `_freshWrite` keeps only the MR6b-1 visibility and pollution checks.
7. **`saveFile`:** split into create and update wrappers (packet 3), rewire the screen (packet 14), delete `saveFile` (packet 17).
8. **`deleteDiscussionNote`:** add it as its own ledger row; the screen's path stays the same.
9. **`isAutoMergeEnabled` and `_effectiveAccess`:** move them to core (packet 3). `work_item_page.dart` keeps a re-export.
10. **Read tools for Release, milestone and snippet:** build packet 16 (`get_release`, `get_milestone`, `get_snippet`).
    - `get_snippet` may use `snippetText`. The read-port whitelist gains exactly `snippetText`, with a guard test.
    - Reason: owner decision §0.1 ("everything the app can do"). The app already reads snippet text on screen, so this adds no new exposure.
11. **`markAllTodosDone`:** add `AiInboxOrigin` (packet 17, logic); Claude adds the Inbox AI entry (UI). It creates an `accountGlobal` grant.
12. **`createProject` and `forkProject`:**
    - `createProject` is offered only when the conversation has at least one project grant.
    - `forkProject` is offered only when the source project is in scope.
    - Both are hard lines: type the destination's full path.
13. **Prefix-match lock scope:** accept the conservative behaviour and write it into the ledger.
14. **Confirm names:** the AI follows plan §3, with one change.
    - **Snippets use `#id`, not the title, because titles can repeat.** Amend plan §3.
    - Screens keep their own confirm names (the rewiring changes only the call).
15. **CI path edges:**
    - `x.yml@group/project` and URLs have no local file, but `.gitlab-ci.yml` is still checked.
    - CODEOWNERS is checked in its three locations: root, `docs/`, `.gitlab/`.
    - Adopt packet 5's reading.
16. **§7.8 state:** held in the port instance, one per conversation (packet 8); it resets when the coordinator is rebuilt.
17. **Category-4 binding:** applies to the whole target only. Use it for pipelines (job binding) and review drafts only.
18. **Old GitLab instances:** a missing `…/merge_requests/:iid/diffs` or `repository/compare` endpoint (404) means "version not supported, no proposal". Accept it.

## Workers
- Non-UI packets go to **Codex** (`gpt-6.1-sol`), each in its own worktree on its own branch, with no commits.
- Claude reviews each packet, re-runs its acceptance commands and commits the result.
- Claude does all UI: cards, previews, warnings, l10n and the Inbox entry.
