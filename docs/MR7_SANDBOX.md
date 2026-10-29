# MR7 sandbox: synthetic host contract (7B0)

This packet supplies synthetic GitLab and Responses-provider transports. It
does not install a live adapter or contact GitLab or an AI provider. All live,
device, OAuth, release, billing and publication evidence is `NOT_RUN`.
`--transport live` exits before reading credentials or launching a child.

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
`GitLabAiWritePort`. Candidate receipts say `CANDIDATE_ONLY`. Every receipt
says `finalEligible: false`; neither a candidate nor a synthetic production
receipt qualifies for 7R final evidence.

## Owner configuration and future credential delivery

The owner supplies the expected numeric user ID and personal namespace through
the secure session's `MR7_EXPECTED_USER_ID` and `MR7_OWNER_NAMESPACE` environment
variables. Synthetic defaults are user 7 and `synthetic-owner`; these have no
relationship to an owner account. The nonce, new project ID and path are owned
by this run. There are no existing-project or resume options.

The optional `--provider-config` argument is a **file path**, containing exactly
these nonsecret fields (populate the file privately from owner-supplied input or
environment, without echoing values into shell commands):

```json
{
  "endpoint": "https://provider.example/v1",
  "format": "responses",
  "model": "synthetic-model",
  "caps": {"tools": true, "maxTokens": 4096},
  "maxCost": 1.0,
  "maxCalls": 4,
  "keyEnv": "MR7_PROVIDER_KEY"
}
```

Formats accepted as metadata are `responses`, `chat_completions` and
`anthropic_messages`. The endpoint must use HTTPS with no user info, query or
fragment; model and capabilities are explicit, never discovered from a private
model list. Cost must be positive and finite, calls a positive integer. This
metadata does not enable those live protocols. The synthetic transport uses
fixed Responses/model fixtures and spends zero provider money. A future live
adapter must enforce the supplied caps before sending; custom/router recipient
and retention remain unknown until independently established.

The dormant `credential_files()` helper accepts named PAT/key environment
variables or `getpass` hidden input. It uses separate exclusive 0600 files in a
0700 temporary directory and deletes them when the context exits. Synthetic
runs never call it or send owner credentials. Future live wiring must obtain
the owner PAT and provider key through that helper, send only credential-file
paths or stdin to a shell-free child, and never send the GitLab PAT to the
provider. There are no token/API-key command-line options. Child environments
are allowlisted; child stdout/stderr is suppressed, parser errors do not echo
unknown arguments, and receipts are scanned for known environment secrets.
Disable shell tracing and HTTP dumps. Do not paste credentials into commands,
logs, prompts, source, receipts or reports.

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
necessarily in memory; only distinct serialized requests are proved here.
Real independent server readback is `NOT_RUN`.

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
The executable-document subset rejects fragments, directives, defaults, block
strings and secondary request overrides rather than skipping their semantics.
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
| N, S8 | `Mr7Scenario.noChangeObservation`: a typed parent-state witness matching the actual tool arguments is mandatory for a 304 star/subscription or core 409 `noChange`. Exactly one request must have been attempted. Auto-merge checks both supported indicators and rejects contradictory enabled state. Missing/mismatched evidence stops later scenarios and cleanup. |
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
Existing zero-dispatch core no-ops retain their prior
classification. Core acknowledgements, failed-certain responses and uncertain
results keep their original semantics; all evidence remains synthetic and
candidate evidence remains ineligible for final release acceptance.

Wave 2 still owns scenario integration, WorkItem binding and inline fragments,
fixture hooks, target-kind sets, account-todo/registry/terminal-project and
secondary-effect observations, editable confirmation, uploads/provenance,
shared budgets/journals and detailed closed-variant receipts. This vocabulary
does not widen those paths or enable any production operation. Suggestion and
multi-effect writes without a directly bound file target remain unverified.
