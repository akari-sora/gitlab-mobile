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
