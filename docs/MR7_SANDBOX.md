# MR7 sandbox: host contract (7B0)

The default transport uses synthetic GitLab and provider fixtures. The explicit
`--transport live` mode contacts GitLab.com and the configured AI provider: it
creates one private project in the verified personal namespace, runs the selected
bounded scenarios, and attempts to delete that project after a verified run.
GitLab.com never deletes it at once: each run's project stays pending deletion
for 30 days (see [GitLab.com deletion and rate limits](#gitlabcom-deletion-and-rate-limits)).
An interruption or uncertain result retains the project and quarantine state for
manual reconciliation. Live receipts are candidates, not final 7R evidence;
device, OAuth, release, billing and publication acceptance remain separate.

Run from the repository, after `fvm flutter pub get --enforce-lockfile`:

```sh
python3 tool/run_mr7_sandbox.py --output /session/scratch/production.json
python3 tool/run_mr7_sandbox.py --policy candidate --output /session/scratch/candidate.json
```

The parent directory must exist. Outputs are private (0600), created without
overwriting an existing receipt. The pinned SDK is used via `fvm flutter test
--no-pub tool/mr7_sandbox.dart`: the production journal imports Flutter stores,
so this is a host test process, not app lifecycle or emulator evidence.

Production is the default and uses `productionAiReleasePolicy` unchanged.
Its currently closed operations appear individually as `NOT_RUN/releaseClosed`.
Candidate selection is constructed only in `tool/mr7/`; it injects the same
view into the real catalogue and coordinator. A scripted wire provider calls
the real `AiRunner`, `PolicyAiWriteCoordinator`, encrypted journal and
`GitLabAiWritePort`. Synthetic candidate receipts say `CANDIDATE_ONLY`; live
receipts say `live-candidate`. Every receipt says `finalEligible: false` and
none qualifies as 7R final evidence.

## Live configuration and credential delivery

The owner supplies the expected numeric user ID and personal namespace through
the secure session's `MR7_EXPECTED_USER_ID` and `MR7_OWNER_NAMESPACE` environment
variables. Synthetic defaults are user 7 and `synthetic-owner`; these have no
relationship to an owner account. The nonce, new project ID and path are owned
by this run. There are no existing-project or resume options.

Live mode requires `--suite`, a `--provider-config` file, and explicit owner
identity environment variables. `--only` optionally restricts the scenario IDs.
For example, after setting the nonsecret owner variables and securely supplying
the credentials through the named environment variables:

```sh
python3 tool/run_mr7_sandbox.py --transport live --policy candidate \
  --suite rest --only b0-star --provider-config /session/scratch/provider.json \
  --pat-env MR7_GITLAB_PAT --output /session/scratch/live.json
```

The provider config contains the following nonsecret fields. Prices shown here
are illustrative; replace them with the provider's applicable prices before a
run. `keyEnv` is the **name** of an environment variable, never the key itself.

```json
{
  "endpoint": "https://provider.example/v1",
  "format": "chat_completions",
  "model": "example-model",
  "caps": {"tools": true, "maxTokens": 4096},
  "maxCost": 1.0,
  "maxCalls": 4,
  "keyEnv": "MR7_PROVIDER_KEY",
  "priceInputPerMTok": 1.0,
  "priceOutputPerMTok": 2.0
}
```

Live formats are `chat_completions` and `anthropic_messages`; `responses` is
synthetic configuration metadata only. The optional `preset` is `custom`
(default) or `opencode-go`, the latter only with `chat_completions`. The HTTPS
endpoint cannot include user info, a query or fragment. The model is explicit;
no private model list is discovered. `caps` must contain exactly `tools: true`
and integer `maxTokens` from 512 to 1,000,000. Both per-million-token prices
and `maxCost` must be positive and finite; `maxCalls` must be a positive integer.
The shared run budget reserves the estimated worst-case cost before each
provider request and refuses a request that would exceed either cap. Actual
usage is settled only after successful decoding; missing or invalid usage,
malformed streams and cancellations retain the worst-case reservation. These
limits depend on accurate configured prices and do not establish the provider's
actual invoice. The synthetic transport uses fixed Responses/model fixtures and
spends zero provider money. Custom/router recipients and retention remain
unknown until independently established.

Live credential delivery accepts `--pat-env` and the provider config's `keyEnv`
as environment variable names. Omitting `--pat-env` requests the PAT through
hidden input; a named but absent PAT variable is rejected. If `keyEnv` is not
set, the wrapper requests the provider key through hidden input. It uses
separate exclusive 0600 temporary
files in a 0700 directory and removes them on exit. Synthetic runs never call
this helper. The shell-free child receives credential-file paths; the GitLab PAT
is not sent to the provider. Child environments are allowlisted, stdout/stderr
is suppressed, parser errors do not echo unknown arguments, and receipts are
scanned for known secrets. Disable shell tracing and HTTP dumps. Do not paste
credentials into commands, logs, source, receipts or reports.

Live confirmation is explicit and may wait up to five minutes, bounded by the
whole-run ten-minute deadline. The deadline includes network and cleanup time.
Failure, timeout or interruption leaves quarantine state for reconciliation;
unproven cleanup is not attempted.

Answer approvals in the terminal that launched the wrapper. For example, this
synthetic proposal displays the operation, tier, numeric project ID, payload
digest and bounded preview:

```text
Approve sandbox write setStar tier T1 project 9 digest aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
Preview: Synthetic sandbox only.
Type yes to approve:
```

Review those values, then type lowercase `yes` and press Enter to approve.
Input is hidden, so the letters do not appear. Any other answer, including an
empty line, denies approval. No answer is supplied automatically. When the
product requires a typed target, the same proposal also shows
`Typed target required: <target name>` before the approval question. After
`yes`, a second prompt says `Type the target name: `; type that exact displayed
name and press Enter. The second answer is hidden too, and must be entered
explicitly. Both questions share the same confirmation deadline.

An unanswered prompt is cancelled when the child exits, withdraws its request,
or reaches the confirmation/run deadline. Ctrl-C interrupts the run. Terminal
settings, including echo, are restored before control returns; cancellation
of input publishes no answer. The child also rechecks cancellation and its
deadline before accepting a response. It retains its bounded shutdown grace
after the run deadline to preserve quarantine state.

## Reconcile an interrupted run

Find `stateDirectory` in the failed or interrupted output receipt. The private
state records the run nonce and intended full project path before creation, and
records the project ID as soon as known. It also keeps the encrypted journal and
its key in the 0700 state directory with a 0600 key file. Keep the directory
private and do not copy its key into a receipt, log, argument or report.

Read the saved journal in a fresh process without contacting a service:

```sh
python3 tool/run_mr7_sandbox.py --reconcile /session/scratch/mr7-live-state-...
```

The read-only output contains write metadata, including operation, target IDs,
state and timestamps, without bodies. A missing, foreign or unreadable key is
reported; preserve the state for investigation rather than deleting or
replacing it. To locate the exact run project when a creation response was
lost, explicitly request a read-only GitLab lookup with the same account:

```sh
python3 tool/run_mr7_sandbox.py --reconcile /session/scratch/mr7-live-state-... \
  --lookup-project --pat-env MR7_GITLAB_PAT
```

The lookup validates `/user` and fetches only the saved URL-encoded full project
path. It does not enumerate or delete projects. A 404 may mean inaccessible or
absent; inspect the result and reconcile uncertain writes manually before any
separate cleanup. Do not infer permission to touch other `mr7-*` projects.

A passed run with `cleanup.status: scheduledForDeletion` needs no
reconciliation: the wrapper removes its state directory, and the receipt's
`identity.projectId` and `cleanup.markedForDeletionOn` identify the project,
which is in the account's projects pending deletion in the GitLab web UI for
30 days. A quarantined run whose DELETE was accepted but whose cleanup stayed
`PENDING` keeps its state. GitLab.com has renamed that project to
`<path>-deletion_scheduled-<id>` and answers the saved path with a 301 to the
numeric ID, which `--lookup-project` does not follow, so it reports
`Reconciliation failed; quarantine preserved.` (`NOT_VISIBLE` on an instance
that answers 404); treat both as unverified and check the recorded project ID
in the web UI. For an interrupted run whose cleanup never ran, the project is
still under the saved path; delete it by hand only after the journal shows no
uncertain write, then expect the same 30-day retention.

## Isolation and stop contract

Setup first validates `/user` and personal namespace ownership, then collects
an events baseline **before** its one administrative project creation. Setup
is not AI `createProject` evidence. Existing fixtures, protected project
86648389, group namespaces, forks, mirrors and imports are refused. GitLab.com
Free omits `mirror` and `forked_from_project` from a personal project: an
absent or null `mirror`, `forked_from_project` or `import_url` means none,
while `mirror` with any value other than `false`, any fork link and any import
URL refuse the sandbox.

Each mutation re-reads the sandbox by numeric ID and URL-encoded full path.
Both must match the recorded numeric ID, full path, owner, namespace, nonce,
private visibility and full instance including installation subpath. A closed
permit also binds operation, resource project, method/path, confirmation and
send count. Forbidden account/group/fork operations and external project
targets are rejected at the transport. Mutation preparation is fenced before
its asynchronous checks so concurrent cleanup cannot race it.

The explicit synthetic confirmation hook is additional to the production
autonomy policy, including bypass. Product hard-line/typed confirmation still
requires a separate explicit typed-input hook; the runner does not supply the
required name automatically. A rejected positive case is `NOT_RUN`; a negative
case explicitly expecting zero mutations can pass. No-op outcomes may continue.
Certain scenario failures do not become successful operations. Uncertain send,
late reply, boundary/identity drift, or unverified readback stops subsequent
cases and leaves them `NOT_RUN`; there is no reset, unlock, retry or resume.

Independent observation uses another uncached read-only adapter. Scenario
readback gets a restricted target-bound observer, checks exact returned IDs and
cannot use the mutation response as field evidence. The simulated server is
necessarily in memory; only distinct serialized requests are proved by the
synthetic tests. A live run must establish its own server readback.

Events are read in complete bounded pagination with a second delayed pass
(10 ms in the synthetic fixture, with a one-second wait ceiling),
date coarse filters and precise UTC timestamps/event IDs. The final window
includes setup and the last cleanup mutation. Foreign project, missing project,
duplicate event IDs within a pass, noncontiguous pages, changing totals,
unreadable/malformed/incomplete pages or 429 makes isolation `NOT_VERIFIED` and
fences new writes. Later successful reads cannot erase that failure. The
request ledger and observer complement events; events are not a complete audit
log and cannot by themselves prove absence of all external effects.

Cleanup revalidates only the project created by this run. It never enumerates
projects for deletion or deletes a namespace. Pending/uncertain writes,
interruption, owner retention and identity/boundary failure prevent cleanup.
Accepted DELETE and verified deletion are separate: verification also checks
owner identity and the parent project inventory; 404 alone proves nothing.
The inventory requires every well-formed row and every contiguous page, with
stable `x-total`, `x-total-pages`, `x-per-page`, matching `x-page`/`x-next-page`
and exact row counts (at most 20 pages). Missing metadata, malformed rows or
duplicate IDs leave deletion unverified and the session quarantined.
After an accepted DELETE there are two verified terminal states. A 404 for the
numeric ID with the ID absent from the inventory is `PASS` with
`deletionVerified: true` (instances that delete immediately). GitLab.com's
retention is `scheduledForDeletion` with `deletionVerified: false` and
`markedForDeletionOn`: the same numeric ID must answer with the same owner,
creator and personal namespace, private visibility, a `marked_for_deletion_on`
(or deprecated `marked_for_deletion_at`) date and the full path
`<original path>-deletion_scheduled-<id>`; the inventory may list it only
under that renamed path. The date must be a real `YYYY-MM-DD` calendar date
(`2026-02-30` is refused), and `marked_for_deletion_at` counts only when
`marked_for_deletion_on` is absent or null. The original path must stop
resolving: a 404, or GitLab.com's redirect (301, 302, 307 or 308, never
followed) whose single `Location` is exactly
`<instance>/api/v4/projects/<this run's ID>`, with the same scheme, host and
installation path and no query or fragment. Any other retention, including a
missing or impossible date, another ID, owner or suffix, an original path that
still answers, or a redirect to another ID or origin, is `PENDING` and
quarantined.
The harness never requests `permanently_remove`. A terminal AI project deletion
is not deleted again by the finalizer. Post-cleanup event failure invalidates
isolation even if deletion was independently verified. Failed receipts remain
preserved. A durable provisional quarantine receipt survives an abrupt parent
termination.

## GitLab.com deletion and rate limits

`DELETE /projects/:id` on GitLab.com answers `202 Accepted` and only marks the
project for deletion. GitLab keeps it for 30 days, renames its `path`, `name`
and `path_with_namespace` to `<path>-deletion_scheduled-<id>`, and sets
`marked_for_deletion_on` to the date; permanent removal is disabled on
GitLab.com. The original path keeps answering with a 301 to
`/api/v4/projects/<id>` (verified on GitLab.com on 2026-10-29). Every live run
therefore leaves one private, renamed project in the personal namespace for 30
days, and a passing live receipt records `cleanup.status: scheduledForDeletion`
rather than a deletion. Do not restore it; GitLab removes it when the
retention ends.

GitLab.com Free accounts share one per-user API burst limit
(`RateLimit-Name: burst_traffic_per_user_free_plan`, currently
`RateLimit-Limit: 100`) between every API client of that user. A live run
spends tens of requests on setup, observation and cleanup, so pause other
clients of the same account first: watchers, CLI polling, CI scripts that use
the same token, and other sandbox runs. Any 429 the harness sees, on a setup,
identity, observer, scenario or cleanup request, read or write, stops the
session with `stopReason: rateLimited` and quarantines it. It is never reported
as an identity failure, and no request is retried, writes included. The receipt's
`rateLimit` keeps only the numeric `Retry-After`, `RateLimit-Limit`,
`RateLimit-Observed`, `RateLimit-Remaining` and `RateLimit-Reset` values;
names, dates and paths are dropped. It appears only on a failed receipt whose
`stopReason` is `rateLimited`: a 429 after an earlier stop keeps that reason
and records no `rateLimit`, and the wrapper rejects any other combination.
Reconcile a rate-limited run like any other quarantined run (above); wait at
least `retryAfter` seconds, and until other clients are paused, before a new
run with a new nonce.

## Scenario interface and receipt schema 1

7B1–7B3 define `Mr7Scenario` lists and pass them to `runMr7Sandbox`; their own
entrypoint can call that function without changing this runner. Definitions
carry suite, operation/variant/tier, fixture call, utterance, resource,
freshness reader, optional API-bound work-item registry, closed mutation paths,
sealed GraphQL document/variables digests, expected count, and exact readback
paths/checks. They may configure synthetic server routes, but cannot replace
the production write port, final guarded transport or production coordinator.
GraphQL resource GIDs require `bindGraphResource` with a fresh project-bound
REST read; nested foreign project/group variables are refused even when their
digest was registered. GraphQL resource targets require typed GIDs; numeric
target IDs cannot reuse a binding by numeric suffix. Bindings use a closed
Project/Issue/MergeRequest/Note/Label/Milestone-to-REST mapping; unsupported
resource types are refused. Read-only classification selects exactly one query
using `operationName` (required with multiple operations). Target checks resolve
that operation's actual argument usage, including aliases and nested inputs;
every root needs a bound selector, except `currentUser { id username }` identity
projections of the current account.
Inline type fragments are traversed with all argument and target checks. Named
fragments, directives, defaults, block strings and secondary request overrides
stay closed. Nested namespace identity selects only id/fullPath; foreign roots
remain refused.
Writer reads and observer
reads share target and account
fences; quarantine permits only bounded observation. No generic live
REST/GraphQL executor is exposed.

The supplied CLI registers only the 7B0 star contract fixture. `--suite all`
uses that fixture; REST/GraphQL/advanced operation coverage belongs to later
packets. Selecting an empty suite fails with `noScenarios`, with its coverage
`NOT_RUN`. A later composed entrypoint must register all three suite lists and
execute them serially in one session with one finalizer. The schema and API
extension seams do not prove that those future scenarios work.

Top-level fields are `schema`, aggregate harness `status`, `transport`, `policy`,
`evidenceClass`, `finalEligible`, `live`, baseline `releaseSha`, actual source
provenance/digests, `capabilityDigest`, foreground/background markers, hashed
identity coordinates, `requestLedger`/request count, `events`, `scenarios`,
`stoppedCount`, `cleanup`, `quarantined`, stop reason, `coverage` and leak scan.
The wrapper records HEAD and file digests before and after execution, including
all production Dart sources, candidate policy and dependency configuration; these
uncommitted files are working-tree synthetic evidence, not an exact release
commit. A changed HEAD or exercised source invalidates that run.

Each scenario records identity metadata, operation/variant/tier/scope, fixture
and payload digests, preread metadata, proposal/confirmation timestamps,
mutation count, core outcome, observer request count/result, provider protocol,
model/capability/count/leak summary and status/reason. Receipts contain no
bodies, source files, auth, raw HTTP dumps or provider replay. The event section
contains scrubbed ID/time/action/project-ID items and page/window completeness.
An aggregate synthetic `PASS` proves the harness completed its stated checks;
only per-scenario `PASS` proves that synthetic variant, and it never authorizes
production capabilities. Keep private locators and receipts outside public
source; this document contains no live identities or paths.

## Wave 1 observation seams

`Mr7Readback.result` exposes immutable response selectors (status, numeric ID,
iid, project ID and opaque/string ID). They do not establish an effect.
`observe(Mr7Observation<T>)` accepts only the sealed observation vocabulary in
the contract. Every observation runs after dispatch, uses the separate uncached
read-only adapter, revalidates actor and the full sandbox identity before and
after reading, consumes the shared HTTP cap, and requires exact allowlisted
`readbackPaths`. Resource selectors are checked against the actual dispatched
route, rather than another resource in the same project. Quarantine observation
cannot reopen the writer or settle an uncertain core journal result.
Snapshot verification applies those exact paths and the 2 MiB JSON response
bound to every snapshot kind, including WorkItem REST identity and GraphQL
projection reads. Unselected response fields still count toward the bound.

| Seam | Scenario API and required evidence |
|---|---|
| D | `Mr7DiscussionObservation`: use the returned opaque discussion ID for creation, the dispatched parent/thread for updates, the complete exact note-ID set and each note's resolution and parent. |
| M | `Mr7MilestoneObservation(id: ..., iid: ...)`: route by global ID and compare both identifiers. Legacy numeric `read` also routes milestones by ID. |
| P | `Mr7ApprovalObservation`: reread the dispatched MR and `/approvals`; validate the full `approved_by` user set against the fresh actor. Approve requires that actor present and `approved: true`; unapprove requires absence and `approved: false`. Unknown operations and opposite specifications are refused. |
| A, S3 | `Mr7ListObservation`: choose a typed parent and closed collection, supply the exact complete global-ID/name set, and read every counted page (maximum 20 pages of 100). Recheck the parent afterwards. For removal, derive the removed selector from the dispatched route and require its absence even if the supplied expected set includes it. Issue/MR removal compares the route iid with validated unique row iids, independently of global IDs. A 404, truncated page, duplicate or changed total proves nothing. Awards additionally validate user and awardable relationships. |
| S2 | `Mr7FileObservation`, `Mr7RefObservation`, `Mr7ReleaseObservation`: bind dispatched encoded path/name and requested content, SHA and exact independent content/ref/release fields. File observations require the dispatched branch in `readbackPaths`, read its name/head before and after the immutable-SHA file read, and require both heads to match. Branch/tag creation also requires the dispatched resolved source `ref` to equal the observed SHA. |
| S4 | `Mr7SnippetObservation`: bind the returned/dispatched project snippet, exact file set, metadata revision and per-file refs. Validate same-instance web raw URLs but fetch only constructed API raw paths; compare raw bytes exactly. Revalidate metadata after all content reads. |
| B2-S3 | `Mr7Scenario.observerQueries(identity, result)`: register documents and every variables digest after the response. `Mr7GraphObservation` verifies currentUser, parent and project separately from returned child IDs. Child operations and every absence claim require a complete connection; parent identity alone never proves deletion. The closed operation mapping binds the dispatched parent, schema collection field (including aliases), child GID type and specific target. Created/updated children must appear; removed children must be the exact `absentIds` target. Filtered connections and an initial continuation cursor are refused. Connections require stable `totalCount`, unique nodes, terminal pageInfo and sealed continuations (at most 20 pages / 2,000 nodes); query aliases can project a supported count field as `totalCount`. Note awards require the actual Note as the bound parent plus matching `noteId` and child relationship. `bindReturnedResource` can freshly bind a returned GID through the existing closed REST mapping. Unsupported operation mappings, GID types and GraphQL syntax remain refused. |
| N, S8 | `Mr7Scenario.noChangeObservation`: a typed parent-state witness matching the prepared tool arguments (approval edits included, never the original model call) is mandatory for a 304 star/subscription, core 409 `noChange`, or zero-dispatch core `noChange`. Response no-ops require exactly one attempted mutation; zero-dispatch no-ops require none. Auto-merge checks both supported indicators and rejects contradictory enabled state. Missing/mismatched evidence stops later scenarios and cleanup. |
| S5 | `Mr7RebaseObservation`: bind the dispatched MR and fresh pre-send head, then poll with `include_rebase_in_progress=true`. A completed exact changed head with no merge error can verify on the first poll; observing pending first is optional. An idle unchanged head stays unverified even if pending was observed. Poll at most 20 times, with intervals at most 100 ms and a total polling deadline at most two seconds; never resend. A late read cannot verify completion or trigger additional polls. |

For example, a scenario can call
`observer.observe(Mr7MilestoneObservation(id: observer.result.id!, iid: observer.result.iid!))`
and inspect the returned fields. Include `projects/<sandbox>/milestones/<id>`
in `readbackPaths`; never substitute iid for the global route ID. List and
GraphQL observers likewise return independently checked records so scenario
code can verify operation-specific fields.

Existing Issue/MR GraphQL collection targets require an independently bound
global GID for the exact dispatched iid route, captured before dispatch;
conflicting response selectors are refused. Note bindings also recheck their
owning issue/MR and `noteable_id`. Parent-only GraphQL observations are limited
to the closed star, subscription and auto-merge state operations. Unsupported
child operations and GraphQL reaction removal without a specific prebound child
remain unverified.

These synthetic GraphQL fixtures do not validate a live schema. In particular,
the synthetic AwardEmoji GID and `note { id }` relationship are host-test
projections; the production reaction API uses name/user selectors. Live schema
compatibility and scenario integration remain `NOT_RUN`.

Verified response no-ops record `classification=verifiedNoOp`, original
`coreOutcome`/`coreNoChange`, `responseStatus`, one attempted mutation and fresh
`parentStateVerified`/observer counts. The Python wrapper rejects inconsistent
verified-no-op receipts, including dispatched no-op claims with missing or
renamed classifications and 409 claims outside `cancelAutoMerge`.
Zero-dispatch core no-ops require the same sealed independent state witness,
record zero mutations and omit `responseStatus`. Core acknowledgements,
failed-certain responses and uncertain
results keep their original semantics; all evidence remains synthetic and
candidate evidence remains ineligible for final release acceptance.

## Wave 2 seams

| Code | API and scenario use |
|---|---|
| S1 | `Mr7Scenario.targetKinds` declares the full owning/prepared-child set, such as project/pipeline or mergeRequest/merge. Each coordinator/catalogue receives only that immutable scenario view. Other scenarios cannot widen it. Omission means the original singleton targetKind. |
| B2-S1/S2 | `fixture(session, identity)` runs after initialization, before provider creation. Return `Mr7ScenarioFixtures` with exact read documents/variable digests, mutation seals and optional scripted calls. `bindWorkItemGraphResource(gid, path:)` freshly binds the WorkItem to its project-owned issue ID/iid, retaining its type. Seals never bypass argument or foreign-scope validation. |
| FIX1 | `preRead(identity)` returns bounded `Mr7SnapshotSpec(path:, fields:, unchangedFields:)`. Capture name/description for a name edit and preserve description. Receipt preread retains original actor/project/resource ID/iid and presence-sensitive field digests, without bodies. Final send rechecks all fields; the independent observer automatically verifies original identities and unchanged fields. `observer.snapshot` exposes the immutable witness. Custom freshness cannot overwrite it; absence/null/empty remain distinct. |
| E | `editConfirm` returns text for the product proposal's editable field. The runner confirms the original, calls production approve(editedText:), then reconfirms the updated digest/preview before send. Rejecting that edit sends nothing. Receipts retain digests/decisions only. |
| U | Fixture attachments use a real memory-only AiAttachmentSession with matching account/conversation. Catalogue/coordinator share the UploadPlaceholderTable and production delivery provenance. Only metadataForModel enters the provider turn; bindingUtterance is the user's text. The byte leak scan is an additional check, not proof against arbitrary transformed partial content. Sessions are discarded after completion/refusal. Mr7UploadObservation(byteCount:, sha256:) independently observes the actual bounded multipart stream at the synthetic-only projects/id/uploads/mr7-observation endpoint. No bytes enter receipts. |
| U script | providerScript allows 12 batches, four calls per batch and 12 calls total, unique IDs, one declared write and declared reads. Later scenarios reuse attachments/placeholders in one explicit conversation; provider transcripts stay per scenario. onProviderRequest observes bounded in-memory metadata, never persisted bodies. |
| Row 19 | Inject sharedBudget, journal, conversationId and now for 39/40/41, account-window and restart cases. All injected budget limits cannot exceed the corresponding product defaults. The caller must recover an injected journal with the complete successfully loaded account set before running; the runner does not perform inventory recovery for it. An owned temporary journal is recovered for the current synthetic account. Injected journals retain files/keys and are never reset/deleted. Restart with the same caller-owned temporary directory and memory key store, recover the complete account set, then clean that synthetic directory. Missing/unreadable/uncertain state stays closed. Defaults keep per-scenario tool budgets; the session physical HTTP cap covers every request. |
| T | createTodo freshly verifies the final project issue/MR. markTodoDone stays wholly closed. Snooze/unsnooze require projectTodo:true and bindProjectTodo(todoId:, parentPath:, snoozedUntil:), exact production read/mutation seals and final actor/project/parent ID/iid/Todo proof. Mr7TodoObservation independently reads the synthetic-only projects/id/todos/todoId/mr7-observation endpoint. Group/account-global/foreign targets remain closed; core results remain ack-only and uncertainty stays uncertain. |
| S7 | closedVariants takes Mr7ClosedVariant; an executable definition can set closed:Mr7ClosedRefusal. Typed causes: releasePolicy, fixtureUnavailable, unsupportedServer, ownershipUnproven, observerUnavailable, scopeExcluded. Explicit candidate rows are NOT_RUN, zero provider calls/mutations. The wrapper rejects forged/malformed closed rows. |
| S6 | Registry fixtures stay fixtureUnavailable: no honest package publish/container push/ownership/inventory lifecycle is modeled. Owner packages and global registry paths cannot substitute for run-created fixtures. |

### Attachment payload scan

The scanner follows the request encoders in `lib/core/ai/wire/`. It examines
provider-visible free text, not every JSON value. The recognised payload fields
are:

| Encoder | Free-text payload fields |
|---|---|
| Responses (`responses.dart`) | `instructions`; `input[].content` strings and text parts (`text`); replayed message/refusal/reasoning text and summary parts; `input[].arguments` (function-call JSON strings); `input[].output` (tool results); `tools[].description` and schema descriptions. |
| Chat Completions (`chat_completions.dart`) | `messages[].content` (system/user/assistant/tool text and content text parts), `refusal` and replay extras; `messages[].tool_calls[].function.arguments` and legacy `function_call.arguments`; `tools[].function.description` and schema descriptions. |
| Anthropic Messages (`anthropic_messages.dart`) | `system`; `messages[].content[].text`, tool-result `content`, replayed thinking text and other replay payloads; tool-use `input` values; `tools[].description` and `input_schema` descriptions. |

At the corresponding wire positions, JSON keys, `role`, `type`, `model`,
tool/function `name`, IDs (`id`, `call_id`, `tool_call_id`, `tool_use_id`),
`status`/`index`, token/stream/store controls, Responses `include`, tool-choice
enums, cache-control type, and schema `type`/`enum`/`const`/`required`/`format`/
`nullable`/`$schema`/`$ref` are protocol/schema values and are excluded. Schema
properties/items/combinators remain traversed so their descriptions are scanned.
Unrecognised fields default to payload, including unknown replay fields. Once
inside a payload object or decoded argument/result JSON, all values are scanned;
an argument key named `role` or `type` does not gain a protocol exemption.

For attachments of **16 bytes or more**, the scanner searches free-text values
for raw UTF-8, base64 and JSON numeric-array encodings, including substrings.
Actual numeric/byte arrays and JSON-encoded nested objects/arrays are checked as
well. The exact host-appended `\n\nmetadataForModel` suffix is exempt only in the
first user message's single text value; repeated blocks elsewhere are scanned.

For attachments of **1–15 bytes**, common words and identifiers are too easy to
collide with ordinary prose, so no attachment substring scan is performed.
Instead the first user turn must have exactly the host-built text (the utterance
plus its exact metadata block), with one text value in the encoder's user-message
shape. Missing, extra or changed user text refuses before accepting the request.
That verified projection is excluded from short-content comparisons; every other
free-text value must match a source projection registered by the host before
wire encoding: the system/tool definitions, the host-selected scenario write's
arguments, numeric-only scripted arguments, or the closed successful-upload
summary reconstructed independently from project/attachment IDs, filename,
SHA-256 and fixed outcome enums. Fixture-script text that differs from the
host-selected arguments, dynamic read/result text, and decoded request values
are never used to expand this set; unproven content stays closed for short
attachments.
The registered values are also checked for exact raw/base64/numeric encodings,
including values inside JSON argument/result strings. An added
`prefix:user:suffix` field therefore refuses without searching for the short
substring, while independently supplied ordinary host prose can contain `user`.
Tool-result content remains payload even in nested objects/lists whose keys
look like protocol fields. Thus a short attachment copied into another
free-text field refuses, while protocol values such as `user` and the configured
model/tool name remain valid. Sixteen bytes is a conservative
distinctiveness cutoff, not an entropy estimate. These synthetic checks do not
prove absence of arbitrary transformed or partial attachment content.

Typed closed rows accept each of `outcome` and `coreOutcome` only when absent or
exactly `notExecuted`; both present therefore agree. Legacy schema-1 rows retain
their previous interpretation.

Codes I/F and unbound multi-effect operations remain closed. These synthetic
hooks do not establish live/provider/device/CI/release acceptance. Synthetic
candidate receipts stay CANDIDATE_ONLY and all receipts have finalEligible=false.

## Wave 3a seams

Zero-dispatch `noChange` cannot establish its own result. The runner invokes
only `noChangeObservation`, checks its operation, arguments, route and parent,
and independently reads the exact state with actor/project checks on both sides.
Issue/MR numeric parent IDs are captured from actual production preparation
reads and must remain stable; a later object with the same iid is insufficient.
An absent or mismatched witness produces `NOT_VERIFIED` with a refusal code,
quarantines the session and prevents later writes and cleanup. A matching
witness with zero expected mutations records `classification=verifiedNoOp`,
`parentStateVerified=true`, positive observer request count and no fabricated
HTTP response. Wave 3b extends these witnesses to project WorkItems below.

Executable rows separate `declaredTier` from the actual `tier`, `decision` and
`confirmationReasons` captured from the production coordinator's proposal,
including automatic execution and edited proposals. These fixed reason names
contain no model text. `decisionProjection=observed` identifies that source.
A tier disagreement fails with `tierMismatch` before dispatch. An early refusal
without a proposal records null tier/decision, an empty reason list and
`decisionProjection=unavailable`, `decisionUnavailable=proposalUnavailable`.
Closed rows keep their inventory tier and make no observed-decision claim.

The guarded writer admits bodyless file metadata `HEAD` requests only at
`projects/<sandbox-id>/repository/files/<encoded-file-path>` with one bounded
`ref` in the final URI query, including URI-embedded parameters. Extra
parameters and duplicate `ref` values are refused.
They consume the shared HTTP cap, retain account/project/path fences,
and never consume a mutation permit or enter the mutation ledger. Request and
response bodies, foreign projects, other HEAD endpoints and quarantined writer
reads remain refused. The coordinator uses production
`exact.checkFragments` through `checkFragmentsWithCount`, with the existing
known-secret set and visibility/target fences; checker refusal codes are retained.

Typed `Mr7SnapshotSpec.board`, `.milestone`, `.label` and `.draftNote` accept
only their corresponding project paths and snapshot their closed field sets.
Boards retain name and both system-list flags; milestones retain title,
description, dates and state; labels retain name, color and description; drafts
retain note text (`note`, plus presence of `body`), position, `commit_id` and
author. Their routes bind numeric global IDs; milestone iid and optional global
ID projections stay separate and presence-sensitive. Boards bind nested
`project.id`; project labels bind the verified sandbox project route and label
ID and require `is_project_label=true` to exclude inherited group labels.
Drafts bind `author_id` to the current actor and `merge_request_id` to the
original MR's numeric ID, independently of its route iid. These identity rules
apply at capture, immediately before dispatch and at independent readback.
Before dispatch all captured fields are reread. Afterwards all typed fields
omitted from the actual dispatched payload are automatically preserved, in
addition to `unchangedFields`; an empty declared set cannot skip preservation.
`state_event` maps to milestone state, label `new_name` maps to `name`, and
draft `note` maps to text. A draft's `body` value may follow a text update,
but its presence must always match the pre-read snapshot: appearing or
disappearing is refused, even when `note` was dispatched. Receipt
metadata contains digests and `preserveOmittedFields=true`, never field bodies.
Scenario write ledger entries carry `scenarioId` so repeated operations remain
distinct. A projected `deny` must have zero mutations, no admitted request for
that scenario, no response status and no successful write result; an unbound
same-operation ledger entry cannot establish a zero-dispatch denial.

`Mr7CreatedTodoObservation(parent:, id:)` observes only `createTodo` under an
exact Issue/MR dispatch. The synthetic-only
`projects/<sandbox-id>/todos/mr7-observation` inventory is completely paged
before send and after acknowledgement (at most 20 pages of 100, counted stable
totals and unique IDs). A selected to-do must be new, pending, and match the
returned ID, actor, author, project, original parent ID/iid and target type.
The parent and actor are checked again around inventory reads. Both the parent
path and inventory path must be in `readbackPaths`. This synthetic endpoint is
not a claim about a live GitLab API. Missing/partial/foreign observations remain
unverified. Account-global/group paths and `markTodoDone` remain closed; the
production acknowledgement remains ack-only and uncertain core outcomes stay
uncertain. Secondary B3 effect witnesses are supplied by wave 3c below; scenario wiring remains separate.


## Wave 3b WorkItem observers

These are synthetic observer seams for B2-O1/O2/O3. Scenario definitions are
unchanged: the scenario owner must wire the 26 widget effects, six activity
effects and 11 zero-dispatch cases before their inventory rows can execute.
No observer opens health/weight, other members, group aliases or shared to-do
scopes. Candidate output remains `CANDIDATE_ONLY`, `finalEligible=false`.

`Mr7WorkItemObservation(workItemId:, iid:, operation:, arguments:)` reads a
closed, operation-specific GraphQL selection using the independent observer
adapter. Arguments use the production tool keys, including projectId and iid.
The actual dispatched input must match: workItemUpdate/workItemSubscribe use
input.id; issueSetEscalationStatus uses input.projectPath plus its string iid.
Both routes bind the WorkItem GID to the sandbox's numeric Issue ID and route
iid. Actor, installation subpath, project ID/fullPath and parent are checked
around readback. A mutation response supplies identity, never effect evidence.

Changed widgets require `Mr7SnapshotSpec.workItem(path:, workItemId:)`. Its
fixed field set covers state, title, description, status, all eight date fields,
assignees, milestone, labels and subscribed. Supplying an incomplete field set
is refused. Widget absence and explicit null remain distinct. Reads capture
complete assignee/label node sets, with at most 20 pages of 100 nodes, unique IDs,
nonrepeating bounded cursors and stable WorkItem updatedAt across the reads.
The snapshot is reread immediately before send; every field omitted from the
actual dispatched input is preserved at independent readback. This also applies
to incident escalation's projectPath+iid selector. Only snapshot digests are
projected into receipts; full values remain private in memory.

Date witnesses independently probe isFixed and sourcing fields. They retry the
base CE selection only for a response without data whose errors are exclusively
precise undefinedField errors for the EE date fields, including isFixed.
Permission, mixed, unrelated and partial-data errors are refused. Manual EE
requires isFixed=true; inherited requires isFixed=false; manual CE has no
isFixed field. Callers cannot declare the edition to weaken this check.
Manual clear/preserve behavior is compared with the actual input and snapshot.

`Mr7WorkItemActivityObservation` maps createWorkItemActivityComment,
createWorkItemActivityReply, editWorkItemActivityNote,
deleteWorkItemActivityNote and setWorkItemActivityNoteReaction. It binds the
exact Note to its WorkItem, project and actor; requires an ordinary public note;
and uses server-provided opaque discussion/reply identities. Created Note IDs
must equal the returned ID and their REST paths must be in readbackPaths before
binding. The runner copies the actual call arguments immutably into the permit.
Replies independently read that call's bound anchorNoteId and require its
opaque discussion/reply IDs to match both dispatch and the created note. Text
is compared byte-for-byte with the effective dispatched body, which may have
been normalized or approved with an edit by production preparation.

Discussion connections and nested note connections are read to completion,
with at most 20 pages of 20 per connection. Continuations use a bound anchor
Note's discussion, never a manufactured Discussion selector. Duplicated IDs,
missing/null connections, bad cursors and exhausted page/request caps refuse.
Delete requires fresh own-note/parent proof before dispatch and exact-note
absence from the complete connection. A single missing Note lookup is never
proof. Reactions read the exact Note's awardEmoji connection (20 pages of 50),
use unique name+user.id pairs and require the actor's matching award present
for add or absent for remove. Awards belonging to other actors do not prove
removal. No AwardEmoji ID or connection totalCount is invented.

`Mr7StateObservation` is the sealed shared no-op vocabulary.
`Mr7Scenario.noChangeObservation` accepts WorkItem and activity witnesses.
The runner supplies the actual arguments to observeNoChange; the witness must
match them and an independently read prepared parent, with zero mutations and
no fabricated HTTP response. Preparation captures actual production WorkItem
queries and the incident project.issues(iids: ..., types: [INCIDENT], first: 2)
query. The latter does not need a made-up project.fullPath response or extra
preparation REST read. Milestone witnesses can additionally require its current
closed state or expired flag. Supported edit/reaction no-ops bind the exact
prepared Note and parent selected by an exact production Note read under the
current permit. Fixture bindings, activity connection membership, observer reads
and earlier permits cannot establish that preparation. No-op argument matching
uses the effective request on the production preparation recorded by that permit,
including approval edits and shared text processing, for every write operation.
The original model call cannot supply the approved text. Missing/mismatched proof
quarantines the session; uncertain core
outcomes remain uncertain. The Python receipt validator admits this closed
operation set only with positive observer counts and parent-state proof.

The independent selections below intersect the production documents in
lib/core/work_item_*_api.dart and lib/core/incident_api.dart with the generated
[GitLab GraphQL schema reference](https://docs.gitlab.com/api/graphql/reference/).
Each observer has a positive real-shape fixture in
`test/ai/mr7_sandbox_wave3b_test.dart`.

| Observer | Selected effect fields (in addition to actor/parent identity) |
|---|---|
| State | WorkItem state, updatedAt. |
| Status | WorkItemWidgetStatus.status.id. |
| Dates | startDate, dueDate, rollUp, isFixed and startDateSourcingWorkItem, dueDateSourcingWorkItem, startDateSourcingMilestone, dueDateSourcingMilestone (each source id). |
| Assignees | assignees.nodes(id, name, username), pageInfo(hasNextPage, endCursor). |
| Milestone | milestone(id, iid, title, state, expired, dueDate, startDate, webPath, project(id, fullPath)). |
| Content | WorkItem.title; WorkItemWidgetDescription.description and widget presence. |
| Labels | labels.nodes(id, title, color, textColor), pageInfo(hasNextPage, endCursor). |
| Notifications | WorkItemWidgetNotifications.subscribed. |
| Incident | project.id; issues.nodes(id, iid, projectId, state, severity, escalationStatus, updatedAt), pageInfo.hasNextPage. |
| Activity | WorkItemWidgetNotes.discussions nodes(id, replyId, notes nodes(id, body, system, author.id)); both pageInfo(hasNextPage, endCursor). Exact Note also supplies internal, noteableType, noteableId, author.id, project(id, fullPath), discussion(id, replyId). |
| Reactions | Exact Note identity plus awardEmoji.nodes(name, unicode, user.id), pageInfo(hasNextPage, endCursor). |

Schema pages read: [WorkItem and widget objects](https://docs.gitlab.com/api/graphql/reference/objects/#workitem),
[date widget](https://docs.gitlab.com/api/graphql/reference/objects/#workitemwidgetstartandduedate),
[Note](https://docs.gitlab.com/api/graphql/reference/objects/#note),
[Discussion](https://docs.gitlab.com/api/graphql/reference/objects/#discussion),
[AwardEmoji](https://docs.gitlab.com/api/graphql/reference/objects/#awardemoji),
[Issue escalation mutation](https://docs.gitlab.com/api/graphql/reference/mutations/#issuesetescalationstatus),
[Note interface](https://docs.gitlab.com/api/graphql/reference/interfaces/#basenoteinterface),
[WorkItem API examples](https://docs.gitlab.com/api/graphql/epic_work_items_api_migration_guide/)
and [pagination](https://docs.gitlab.com/api/graphql/getting_started/#pagination).
The object reference was read in bounded extracted sections because the full
rendered page exceeds the browser reader's size limit. This documents schema
compatibility, not a live instance/tier acceptance result.


## Wave 3d production request compatibility

The WorkItem state witness compares the tool's lowercase `close`/`reopen`
argument with the production `CLOSE`/`REOPEN` dispatch enum and separately checks
the resulting lifecycle. Label witnesses interpret an omitted delta side as an
empty list. Explicit nulls and malformed lists remain refused; complete label
sets, disjoint deltas, exact dispatch and snapshot preservation remain required.

Only the three sealed production project milestone documents (current read,
project picker and milestone mutation response) may select the nullable
`group { id fullPath }` owner projection. Both writer and independent observer
validate returned owners: null, or exactly the sandbox namespace ID and path.
Changed documents, other group fields, group selectors and group writes remain
closed. Changing a production document requires updating its seal and running
the production-request regressions in `mr7_sandbox_wave3d_test.dart`.

After a successful comment/reply dispatch, the guard captures only its exact
returned Note GID and freshly reads that Note and its already bound WorkItem
parent before returning the acknowledgement to core. The author must be the
actor, the parent and project must match the dispatched WorkItem, and the Note
must be ordinary and public. The binding rechecks session identity and the
current permit after those reads. A previously bound Note, another returned GID,
missing ownership evidence or a changed account/permit cannot authorize core
readback. The later independent activity witness still verifies content and
opaque discussion/reply relationships.

These repairs supplied the four 7B2j seams. 7B2k then opened the 11 variants
they blocked: state close and reopen; milestone set, clear, closed-current and
expired-current; labels add, remove and clear; comment; opaque reply. Each runs
through the production runner with independent readback: nine writes and two
verified no-ops. Project GraphQL now has 43 executable variants out of 58 and
15 typed-closed ones (health 4, weight 4, other members 1, shared to-do scopes
6). With the 60 group-alias refusals the candidate receipt has 118 rows, 75 of
them closed. The fixture gives a created comment and a created reply different
Note IDs, as GitLab does, because one session runs both and the guard refuses
a returned Note that is already bound.

The milestone owner check and the created-note binding run only for scenario
writes, never for the harness setup or cleanup request, so a permit still set at
`finish()` cannot fail cleanup. The guarded writer reads the server clock before
it counts or dispatches a write; if the clock cannot be read it stops the
session as `serverTimeUnverified` and sends nothing. This is defensive: live
runs set the clock during the reads before the first write, and the request
ledger reads it first.
All evidence remains synthetic.

## Wave 3c effect witnesses

Set `Mr7Scenario.captureEffects: true` (or the same property on a direct-test
`Mr7MutationPermit`) before preparation. The guarded transport captures the
original effect baseline through the independent observer and records actual
dispatch method, path, time and status. This flag grants no endpoint or write
authority. Missing baselines refuse the witness. Existing acknowledgement-only
probes do not opt in automatically. Global suggestion PUTs always require the
independent MR → discussion → note → suggestion ownership check, including when
`captureEffects` is false. Supply every effect path in `readbackPaths`
and call `observer.observe` with the sealed observation below. Actor, full
sandbox identity, original parent IDs, boundary, shared request cap and quarantine
fences apply. Bodies and expected bytes stay private in memory, outside receipts.
The witnesses open no production capability; 7B3j wires them into the advanced
catalogue (below).

| Witness | Required independent evidence and paths |
|---|---|
| `Mr7DeletedFileObservation(path:, ref:, sha:)` | Bind actual DELETE path, branch and last_commit_id to the original file at the old branch commit. Require a changed commit; check the branch before/after complete recursive-tree pagination at that exact SHA. Validate id/name/type/path/mode and exact-path absence. Allow branch and repository/tree paths. A 404 or partial tree proves nothing. |
| `Mr7SuggestionObservation(parent:, discussionId:, noteId:, suggestionId:, path:, ref:, sha:, blobSha:, bytes:)` | Bind actual arguments to the original same-project MR source branch and exact discussion/note/suggestion before admitting global PUT suggestions/:id/apply. Read the original file at its immutable commit and derive the full expected UTF-8 result from absolute inclusive from_line/to_line and exact from_content/to_content. Check original position SHAs, applied state, unchanged position, changed branch commit, exact result bytes and computed Git blob SHA. Allow MR, discussion, branch and encoded file paths. |
| `Mr7DeletedBoardListObservation(boardId:, listId:)` | Capture original board/list membership. Recheck the exact board around complete list pagination with unique numeric IDs and require exact list absence. Allow boards/:board and boards/:board/lists. The board-specific route establishes the parent; no board_id is invented. |
| `Mr7PublishedDraftsObservation(parent:, drafts:)` | Capture complete original draft IDs/texts/actor/MR/discussion/position and existing discussion IDs. Completely page both notes and discussions, require one distinct new ordinary public own note per original draft with exact text and position shape. New-discussion drafts must land as the root (first note) of distinct new discussions absent from the baseline; replies must land in their named existing thread. Both individual notes and new non-individual discussions are supported. Require complete draft absence afterwards. Allow MR and its draft_notes, notes and discussions. No public draft_id field is invented. |
| `Mr7SchedulePipelineObservation(scheduleId:, ref:, pipelineId:, maxAttempts:, interval:, timeout:)` | Closed as `observerUnavailable/scheduleParametersUnproven`. A production-prepared empty detail can become stale; the schedule-pipelines metadata cannot attest current stored inputs. Refuse before effect reads or play dispatch, for either `captureEffects` value. The sealed observation also refuses; no schedule collection, detail or parameter read is issued by the observer. |
| `Mr7LegacyCancelObservation(parent:)` | Require actual current POST failure (404/405), actual deprecated POST success, and original MR identity. Refuse an ineligible fallback before send. Independently require documented merge_when_pipeline_succeeds=false; optional auto_merge_enabled cannot contradict it. Allow the original MR path. |
| `Mr7ProjectDeletionObservation()` | Require actual scenario DELETE/202 and a complete pre-delete personal inventory containing the project. Recheck actor and complete users/:actor/projects, then numeric-ID and full-path lookups. projectDeletionState is absent only with inventory absence and both 404s, or pending with the same owned project and marked_for_deletion_on in inventory and both lookups. Declare project and inventory paths; full-path lookup is internal identity checking. The finalizer never supplies evidence. Accepted terminal deletion fences every later mutation, including during retention. |
| `Mr7SnippetObservation(..., visibility:)` | S4 binds private/internal/public visibility to actual dispatch and independent metadata. New non-private creation additionally checks the actual dispatched UTF-8 file set/bytes. Existing exact raw bytes, file set, raw refs and updated_at checks run before/after content reads. Default-private fixtures remain compatible. |

Unsupported suggestion CR/encoding/range shapes stay
`observerUnavailable/observerSuggestionRange`, rather than guessing replacement
bytes. Published-note matching is one-to-one correlation, not a documented
note-to-draft provenance link. Normalized text, concurrent identical notes and
unsupported publication shapes must remain `observerUnavailable`. Positioned drafts
require complete single-line text coordinates and revision SHAs. Multiline
`line_range`, image and incomplete positions stay closed before dispatch; a
published range cannot silently stand in for a single-line draft. An ordinary
draft has no anchor: `null`, `{}` and the documented `text` position whose
SHAs, paths, lines and range are all null are one shape, in preflight and when
matched against the published note's absent position; any populated field
makes it a positioned draft. A draft without `discussion_id` matches only the
first note of a new discussion, so an own reply under a foreign root in a new
thread is not credited.

GitLab's [schedule collection](https://docs.gitlab.com/api/pipeline_schedules/#list-all-pipeline-schedules)
returns stored input names and values for owners and privileged users, including
other schedules. The [schedule-pipelines response](https://docs.gitlab.com/api/pipeline_schedules/#list-all-pipelines-triggered-by-a-pipeline-schedule)
documents pipeline metadata, but cannot attest current schedule parameters.
Inputs can [change after preparation](https://docs.gitlab.com/api/pipeline_schedules/#update-a-pipeline-schedule).
Consequently, empty-parameters schedule play stays closed with the explicit
reason `scheduleParametersUnproven`; discarding returned values would still read
them. Plan §22.3 remains open. These docs were checked on 2026-10-29.

`Mr7Readback(timeout: ...)` optionally bounds an entire observation, including
its initial/final identity checks, each request, response-body read and pagination
page. The limit must be positive and at most two seconds. Each request inherits
the remaining receive timeout and one cancellation token; expiry returns
`observerTimeout`, cancels the outstanding request and fences later reads. The
removed schedule poll has no remaining requests or waits. Delayed, never-ending
and later-page regressions exercise this deadline on reachable board-list reads.

S4's revision is rechecked metadata updated_at plus exact per-file raw refs and
bytes. GitLab metadata raw_url uses the mutable repository root ref. Neither
updated_at nor that URL proves an immutable Git commit. A scenario requiring
commit-level snippet proof stays `observerUnavailable`; do not invent a commit
SHA in a real-shape metadata URL.

These APIs can support file-delete/suggestion branch variants, owned board-list
deletion, whole-batch draft publication (up to 20), deprecated cancellation, terminal deletion/retention and new
non-private snippet content. Refusal,
drift, stored parameters, registry, external scope and unsupported revision
variants keep typed closed dispositions through
`Mr7ClosedRefusal(Mr7ClosureCause.observerUnavailable, code)` or
`Mr7ClosureCause.fixtureUnavailable` with a specific reason. Candidate receipts
remain CANDIDATE_ONLY and finalEligible=false.

### 7B3j: advanced variants on the wave 3c witnesses

7B3j opened the 15 advanced variants these witnesses cover. Each sets
`captureEffects: true`, lists its effect paths in `readbackPaths` and passes
only if the sealed observation succeeds after the production runner's write:

| Witness | Opened variants (tier) |
|---|---|
| Deleted file | deleteFile ordinary-ref, default-ref, protected-ref (T4), ci-config (hardLine) |
| Suggestion | applySuggestion ordinary-ref (T3), default-ref, protected-ref (T4), ci-config (hardLine) |
| Deleted board list | deleteBoardList owned-fixture (T4) |
| Published drafts | publishDraftNotes whole-batch, external-drafts, batch-20 (T3) |
| Legacy cancel | cancelAutoMerge deprecated-fallback (T3, two dispatches) |
| Project deletion | deleteProject terminal-deleted (hardLine) |
| Snippet visibility | createSnippet new-nonprivate (hardLine, public) |

The advanced catalogue now has 44 executable variants of 185 and 141
typed-closed ones (was 29 and 156). All 15 are writes; none is a no-op.

- deleteFile runs the production file reads through the guarded writer: file
  HEAD at the branch and at the last commit, then the raw read at that commit.
- The legacy cancellation sends two requests (`cancel_auto_merge` answers 404,
  then the deprecated endpoint answers `{"status":"success"}`). Snapshot
  re-reads accept exactly one dispatch, so this variant has no pre-read
  snapshot; the witness binds the parent ID it captured before the first
  dispatch. Its fixture MR carries only `merge_when_pipeline_succeeds`.
- deleteProject is the terminal case. Its receipt has cleanup `NOT_RUN` with
  reason `terminalScenario`; the finalizer neither deletes again nor supplies
  evidence, and the witness must report `absent`.
- The sandbox creates no draft in the conversation segment, so every
  publication carries the production `foreignDraftsInPublish` confirmation:
  whole-batch and external-drafts differ in shape (a new thread, a reply in an
  existing thread and a single-line diff draft, against one ordinary draft),
  not in provenance. The in-segment draft path is NOT_RUN.
- A project snippet may be public in the private sandbox project; the project's
  visibility still bounds access ([snippets](https://docs.gitlab.com/user/snippets/),
  checked 2026-10-30).

Still closed, with typed reasons:

- `playPipelineSchedule` empty-parameters: `scheduleParametersUnproven`, the
  same code the runner records before fixture and provider.
- deleteProject retention-pending: `retentionRenameUnbound`. GitLab.com renames
  a project scheduled for deletion to `<path>-deletion_scheduled-<id>` and
  answers the original path with 301; the witness accepts only an unrenamed
  pending project, and a regression shows the renamed state is refused.
- applySuggestion suggestion-version: `suggestionVersionRefused`. A suggestion
  positioned on an older MR version is refused before dispatch (zero writes);
  this is refusal evidence, not operation coverage.
- deleteFile and applySuggestion same-field-upload-roundtrip:
  `uploadFieldNotApplicable`; no field round-trips server-read text (the only
  model-written text is a new commit message), so an upload placeholder has
  nothing to restore.
- Drift, provenance, refusal, registry, runner and owner-only variants keep
  their earlier codes. Unsupported suggestion ranges and multiline or image
  draft positions remain refused by the witnesses before dispatch.
- The closure texts that named seams wave 3a delivered are reworded:
  edit_file/createFile now `fileChainNotImplemented` and the remaining snippet
  variants `snippetChainNotRun`; they need a chain, not a witness. createSnippet
  private-project is `snippetVariantNotOpened`: its chain already runs through
  new-nonprivate, and the variant is simply not opened yet.

### Real API shapes and primary sources

Positive fixtures intersect production workspace_api.dart, write-port files,
merge and CI preparation, and snippet_models.dart with these official contracts:

- [Repository tree](https://docs.gitlab.com/api/repositories/) and [pagination](https://docs.gitlab.com/api/rest/#pagination): id/name/type/path/mode, ref/recursive and complete offset headers. The [upstream tree finder](https://gitlab.com/gitlab-org/gitlab/-/blob/09044ba45e8cdeda94409a218ac268bc41be340a/app/finders/repositories/tree_finder.rb) resolves ref to a commit before reading the tree.
- [Repository files](https://docs.gitlab.com/api/repository_files/): file_path/encoding/content/blob_id/commit_id/last_commit_id.
- [Discussions](https://docs.gitlab.com/api/discussions/), [notes](https://docs.gitlab.com/api/notes/) and [draft notes](https://docs.gitlab.com/api/draft_notes/): nested suggestions/position, public note id/body/author/system/internal, draft id/note/author_id/merge_request_id/discussion_id. The [Suggestion model](https://gitlab.com/gitlab-org/gitlab/-/blob/09044ba45e8cdeda94409a218ac268bc41be340a/app/models/suggestion.rb) and [range extraction](https://gitlab.com/gitlab-org/gitlab/-/blob/09044ba45e8cdeda94409a218ac268bc41be340a/lib/gitlab/diff/file.rb) define absolute one-based inclusive lines.
- [Board lists](https://docs.gitlab.com/api/boards/#list-all-board-lists-in-an-issue-board): numeric id under the board-specific collection, excluding built-in open/closed lists.
- [Schedules](https://docs.gitlab.com/api/pipeline_schedules/), [pipelines](https://docs.gitlab.com/api/pipelines/) and [CI source](https://docs.gitlab.com/ci/jobs/job_rules/#ci_pipeline_source-predefined-variable): schedule id/ref/owner/active; pipeline id/project_id/ref/source/created_at. Play returns a message, not a pipeline selector.
- [Merge requests](https://docs.gitlab.com/api/merge_requests/#cancel-merge-when-pipeline-succeeds-deprecated): endpoint responses and independent id/iid/project_id/merge_when_pipeline_succeeds.
- [Projects and personal inventory](https://docs.gitlab.com/api/projects/#list-all-personal-projects-for-a-user): namespace id/kind/full_path, path_with_namespace, owner, visibility and marked_for_deletion_on. Private-profile/inaccessible-resource ambiguity means no isolated 404 establishes deletion.
- [Project snippets](https://docs.gitlab.com/api/project_snippets/) and [snippets](https://docs.gitlab.com/api/snippets/): visibility/files/raw routes. The project-GET table omits fields confirmed by its [upstream entity](https://gitlab.com/gitlab-org/gitlab/-/blob/09044ba45e8cdeda94409a218ac268bc41be340a/lib/api/entities/snippet.rb), [inherited fields](https://gitlab.com/gitlab-org/gitlab/-/blob/09044ba45e8cdeda94409a218ac268bc41be340a/lib/api/entities/basic_snippet.rb) and [request test](https://gitlab.com/gitlab-org/gitlab/-/blob/09044ba45e8cdeda94409a218ac268bc41be340a/spec/requests/api/project_snippets_spec.rb).
