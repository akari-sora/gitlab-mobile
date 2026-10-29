# MR7 sandbox: host contract (7B0)

The default transport uses synthetic GitLab and provider fixtures. The explicit
`--transport live` mode contacts GitLab.com and the configured AI provider: it
creates one private project in the verified personal namespace, runs the selected
bounded scenarios, and attempts to delete that project after a verified run.
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

## Isolation and stop contract

Setup first validates `/user` and personal namespace ownership, then collects
an events baseline **before** its one administrative project creation. Setup
is not AI `createProject` evidence. Existing fixtures, protected project
86648389, group namespaces, forks, mirrors and imports are refused.

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
Retention can produce `PENDING`. A terminal AI project deletion is not deleted
again by the finalizer. Post-cleanup event failure invalidates isolation even
if deletion was independently verified. Failed receipts remain preserved. A
durable provisional quarantine receipt survives an abrupt parent termination.

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

| Seam | Scenario API and required evidence |
|---|---|
| D | `Mr7DiscussionObservation`: use the returned opaque discussion ID for creation, the dispatched parent/thread for updates, the complete exact note-ID set and each note's resolution and parent. |
| M | `Mr7MilestoneObservation(id: ..., iid: ...)`: route by global ID and compare both identifiers. Legacy numeric `read` also routes milestones by ID. |
| P | `Mr7ApprovalObservation`: reread the dispatched MR and `/approvals`; validate the full `approved_by` user set against the fresh actor. Approve requires that actor present and `approved: true`; unapprove requires absence and `approved: false`. Unknown operations and opposite specifications are refused. |
| A, S3 | `Mr7ListObservation`: choose a typed parent and closed collection, supply the exact complete global-ID/name set, and read every counted page (maximum 20 pages of 100). Recheck the parent afterwards. For removal, derive the removed selector from the dispatched route and require its absence even if the supplied expected set includes it. Issue/MR removal compares the route iid with validated unique row iids, independently of global IDs. A 404, truncated page, duplicate or changed total proves nothing. Awards additionally validate user and awardable relationships. |
| S2 | `Mr7FileObservation`, `Mr7RefObservation`, `Mr7ReleaseObservation`: bind dispatched encoded path/name and requested content, SHA and exact independent content/ref/release fields. File observations require the dispatched branch in `readbackPaths`, read its name/head before and after the immutable-SHA file read, and require both heads to match. Branch/tag creation also requires the dispatched resolved source `ref` to equal the observed SHA. |
| S4 | `Mr7SnippetObservation`: bind the returned/dispatched project snippet, exact file set, metadata revision and per-file refs. Validate same-instance web raw URLs but fetch only constructed API raw paths; compare raw bytes exactly. Revalidate metadata after all content reads. |
| B2-S3 | `Mr7Scenario.observerQueries(identity, result)`: register documents and every variables digest after the response. `Mr7GraphObservation` verifies currentUser, parent and project separately from returned child IDs. Child operations and every absence claim require a complete connection; parent identity alone never proves deletion. The closed operation mapping binds the dispatched parent, schema collection field (including aliases), child GID type and specific target. Created/updated children must appear; removed children must be the exact `absentIds` target. Filtered connections and an initial continuation cursor are refused. Connections require stable `totalCount`, unique nodes, terminal pageInfo and sealed continuations (at most 20 pages / 2,000 nodes); query aliases can project a supported count field as `totalCount`. Note awards require the actual Note as the bound parent plus matching `noteId` and child relationship. `bindReturnedResource` can freshly bind a returned GID through the existing closed REST mapping. Unsupported operation mappings, GID types and GraphQL syntax remain refused. |
| N, S8 | `Mr7Scenario.noChangeObservation`: a typed parent-state witness matching the actual tool arguments is mandatory for a 304 star/subscription, core 409 `noChange`, or zero-dispatch core `noChange`. Response no-ops require exactly one attempted mutation; zero-dispatch no-ops require none. Auto-merge checks both supported indicators and rejects contradictory enabled state. Missing/mismatched evidence stops later scenarios and cleanup. |
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
HTTP response. WorkItem state observers remain unavailable.

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
uncertain. GraphQL WorkItem observers and secondary B3 effect witnesses are
deferred.
