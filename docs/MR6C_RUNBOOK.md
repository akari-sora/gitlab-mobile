# MR6c C8 host tooling handoff

This is **partial host tooling, not completed C8 acceptance**. The host has a
guarded install/mailbox/recovery/restoration path for V9 `task_manager_stop`.
The QA entrypoint uses production account, controller, runner, native bridge
and encrypted journal code with synthetic transports. Its device behavior has
not run. Other V1–V12 variants have no complete executable case drivers and
stay NOT_RUN. V9's recovery subcheck can pass, but its full variant remains
NOT_VERIFIED until onDestroy/notification/unreadable-journal evidence exists.
`--plan` is offline and exits 0; a partial matrix exits 2 even if the recovery
subcheck passes. `--recover` restores APK bytes from a verified
pending receipt. A handshake, launch or process death alone cannot pass a case.

All V1–V12/device/OS/API/flavor outcomes, iOS, default six-hour timeout and
API 24–30 back are NOT_RUN. V1 network is NOT_VERIFIED. API 34 system timeout
is not applicable, never PASS. This packet ran no native generation, APK build,
emulator, physical device or live GitLab. The lead must integrate the reviewed
C6/C7 changes and rerun on the resulting source; only existing branch refs were
read here. Current main lacks C6's back counter and C7's startup recovery UI.

**Host commands that can run now**, from the repo root:

```sh
python3 -m unittest discover -s tool/tests -p 'test_*.py' -v
python3 -m unittest discover -s ci/tests -p '*_test.py' -v
python3 -m compileall -q ci tool
/Users/iml1s/fvm/versions/3.47.2/bin/flutter test --no-pub test/ai/mr6c_tooling_test.dart
/Users/iml1s/fvm/versions/3.47.2/bin/flutter test --no-pub test/ai/mr6c_socket_tooling_test.dart
/Users/iml1s/fvm/versions/3.47.2/bin/flutter analyze --no-pub tool/mr6c_qa_protocol.dart integration_test/mr6c_background_test.dart test/ai/mr6c_tooling_test.dart
```

HTTPS tests use short-lived loopback sockets and temporary certificates, not
emulator networking. They require openssl; a skip is not a pass.

**Create a fresh generation snapshot after integration.** First read
`docs/ANDROID_SIGNING.md` and `docs/ANDROID_RELEASE_INVENTORY.json`. Keep the
stable signer, never init/rotate/uninstall/clear. Check space before builds.
Copy tracked source plus this packet's explicit untracked additions; hash
all copied bytes. Do not copy SDKs, private signing files or old native output.
These commands do not change Git refs/index:

```sh
export MR6C_SOURCE="$PWD"
export MR6C_SOURCE_HEAD="$(git rev-parse HEAD)"
export MR6C_FLUTTER=/Users/iml1s/fvm/versions/3.47.2/bin/flutter
export MR6C_SESSION_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/mr6c-c8.XXXXXX")"
export MR6C_GENERATED_ROOT="$MR6C_SESSION_ROOT/generated"
export MR6C_EVIDENCE="$MR6C_SESSION_ROOT/evidence"
df -h "$MR6C_SESSION_ROOT"
python3 - <<'PY'
import hashlib, json, os, pathlib, shutil, subprocess
source = pathlib.Path(os.environ['MR6C_SOURCE'])
target = pathlib.Path(os.environ['MR6C_GENERATED_ROOT'])
evidence = pathlib.Path(os.environ['MR6C_EVIDENCE'])
target.mkdir(exist_ok=False)
evidence.mkdir(exist_ok=False)
tracked = subprocess.check_output(['git', 'ls-files', '-z'], cwd=source).decode().split('\0')
added = '''docs/MR6C_RUNBOOK.md
integration_test/mr6c_background_test.dart
test/ai/mr6c_tooling_test.dart
tool/mr6c_artifacts.py
tool/mr6c_emulator_checks.py
tool/mr6c_https_fixture.py
tool/mr6c_qa_protocol.dart
tool/mr6c_qa_fixture.dart
tool/mr6c_socket_transport.dart
test/ai/mr6c_socket_tooling_test.dart
tool/tests/test_mr6c_artifacts.py
tool/tests/test_mr6c_emulator_checks.py
tool/tests/test_mr6c_https_fixture.py'''.splitlines()
manifest = {}
for name in sorted(set(filter(None, tracked)) | set(added)):
    src, dst = source / name, target / name
    if src.is_symlink() or not src.is_file():
        raise SystemExit('Missing or symlink source: ' + name)
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)
    value = hashlib.sha256(src.read_bytes()).hexdigest()
    if hashlib.sha256(dst.read_bytes()).hexdigest() != value:
        raise SystemExit('Snapshot digest mismatch: ' + name)
    manifest[name] = value
receipt = {'source_head': os.environ['MR6C_SOURCE_HEAD'], 'files': manifest}
(evidence / 'source-snapshot.json').write_text(json.dumps(receipt, indent=2) + '\n')
PY
cd "$MR6C_GENERATED_ROOT"
export MR6C_LOCK_SHA256="$(python3 -c 'import hashlib; print(hashlib.sha256(open("pubspec.lock", "rb").read()).hexdigest())')"
```

Retain the snapshot receipt: a HEAD string does not bind uncommitted C8 files.
If source changes, make a new snapshot and rerun. Do not delete existing native
directories to make bootstrap succeed.

**Generation/build commands for the lead; NOT_RUN in this packet.** Execute
sequentially, check each exit status, and record source/command/result. The
Python suite tests managed-function idempotence and second CLI refusal.

```sh
python3 tool/bootstrap.py --flutter "$MR6C_FLUTTER" --check-sdk
python3 tool/bootstrap.py --flutter "$MR6C_FLUTTER"
fvm flutter pub get --enforce-lockfile
fvm flutter analyze --no-pub
python3 -m unittest discover -s tool/tests -p 'test_*.py' -v
python3 -m unittest discover -s ci/tests -p '*_test.py' -v
python3 -m compileall -q ci tool
fvm flutter test --no-pub test/ai test/app_lock_test.dart test/authenticated_app_shell_adaptive_test.dart
fvm flutter build apk --debug --flavor gitlab --no-pub
fvm flutter build apk --debug --flavor play --no-pub
MR6C_GENERATED_ROOT="$PWD" python3 -m unittest discover -s tool/tests -p 'test_bootstrap.py' -v
python3 tool/mr6c_artifacts.py build-release --root "$PWD" --source-head "$MR6C_SOURCE_HEAD" --expected-lock-sha256 "$MR6C_LOCK_SHA256" --output "$MR6C_EVIDENCE/release-builds.json"
```

The last command invokes the exact release gitlab/play builds without
`--no-pub` and hashes pubspec.lock before/after each, including failed builds.
A mismatch/nonzero fails without repairing the lock. New packaged APKs need a
public inventory receipt: source, entrypoint, QA/gate flags, version, SDK,
size/hash and public signer. These tools do not publish or create that receipt.

**Artifact/R8 readback.** Reuses C1's actual XML/helper and build-config checks;
all four flavor/variant manifests/APKs must exist. Missing files fail without
synthetic fallback. Debug DEX must define the QA adapter. Release uses actual
defined classes, complete pre-R8 program inputs and same-build mapping for
renamed methods. The reflected QA class-name string is not a packaged handler.

`build-release` creates exclusive private `release-builds-r8-gitlab` and
`release-builds-r8-play` directories beside its JSON output. It runs verbose
Flutter release builds with the Gradle daemon disabled, requests compiler input
dumps, requires a fresh R8 minify task, and inspects the complete program.jar
and feature program jars in exactly one R8 release dump. It binds dump, APK,
mapping, source HEAD and lock hashes in each receipt. Host fakes test these
fences; actual pinned-toolchain propagation/dump shape still needs a real build.

```sh
python3 tool/mr6c_artifacts.py readback --root "$PWD" --source-head "$MR6C_SOURCE_HEAD" --gitlab-r8-inputs "$MR6C_EVIDENCE/release-builds-r8-gitlab/receipt.json" --play-r8-inputs "$MR6C_EVIDENCE/release-builds-r8-play/receipt.json" --output "$MR6C_EVIDENCE/artifacts.json"
```

The legacy `record-r8-inputs` command records operator-attested inputs only;
it cannot prove completeness and never promotes release native checks to PASS.
Dart AOT QA-handler isolation remains NOT_VERIFIED, so overall
readback exits nonzero even when native checks pass. Exact same-invocation R8
capture for pinned AGP9.1.0 remains unverified. R8 documents
`-Dcom.android.tools.r8.dumpinputtodirectory=/absolute/dumps` with Gradle
`--no-daemon`; dumps include program.jar/library.jar/classpath.jar/config and
feature jars. Missing/cached/multiple ambiguous dumps fail. A later separate
Gradle build cannot certify the earlier Flutter APK.
[Google R8 guidance](https://issuetracker.google.com/issues/335663479),
[R8 dump format](https://r8.googlesource.com/r8/+/d07d52b5e1895454e13868a3d01af712d3beb0e8/src/main/java/com/android/tools/r8/utils/AndroidApp.java),
[matching mappings](https://developer.android.com/studio/debug/apk-analyzer).

**AVD handoff.** Only V9 task-manager stop is wired. Provenance receipts are
external attestations, not secure-store scans. Review their current relevance
to the exact sandbox. The QA main also rejects nonempty/unknown data before
seeding, API initialization, history recovery or journal cleanup. Recover
loads the exact persistent synthetic account/key/journal; it never reseeds.
Retained mailbox files block another session without being cleared. Use a new
owned clean sandbox for another run; never wipe an owner's AVD to retry.
Before initial installation the host additionally requires a live presence-only
scan through an already available `su 0` capability. CE, DE, external data and
OBB roots must have no files, symlinks or other non-directory entries. Empty
ordinary directory trees are permitted. Missing privilege, unreadable paths,
unknown shell behavior or any content means NOT_RUN before install/reset.
The script does not enable adbd root or configure privileges. No file names or
contents leave the device. Real Android execution of this check remains NOT_RUN.

Set MR6C_SERIAL/AVD/API from current readback. Never choose a default device.
Only Pixel_9 or Pixel_9_MR6c_API34/35/36, qemu=1 and the exact API are allowed.
Pixel_9 has historical owner accounts. Unknown/non-synthetic data means NOT_RUN,
including installation, launch, force-stop and cleanup. A clean other flavor or
pm path absence does not prove this sandbox has no retained owner data.

```sh
adb devices -l
adb -s "$MR6C_SERIAL" shell getprop ro.kernel.qemu
adb -s "$MR6C_SERIAL" emu avd name
adb -s "$MR6C_SERIAL" shell getprop ro.build.version.sdk
python3 -m unittest discover -s tool/tests -p 'test_mr6c_emulator_checks.py' -v
python3 tool/mr6c_emulator_checks.py --plan --avd "$MR6C_AVD" --api "$MR6C_API" --flavor "$MR6C_FLAVOR" --cases all --output "$MR6C_EVIDENCE/offline-$MR6C_API-$MR6C_FLAVOR"
```

The last command is offline matrix generation. API-specific serials are read
independently. Add --flavor play only for separately verified app.mergeline;
gitlab uses io.gitlabmobile.gitlab_mobile. MainActivity namespace is always
io.gitlabmobile.gitlab_mobile. None of these device commands ran here.

Before installation, save one original base APK, verify SHA-256/package/version/
public signer and persist restoration metadata. Splits/unknown/unsavable APKs
mean NOT_RUN. QA uses exactly the original versionCode and stable compatible
signer. If originally absent, use a fixed version in an owned dedicated sandbox
allowed to retain QA, close only that AVD at the end and report retained QA.
Never touch an owner's daily app or rotate a key to make installation work.

Use a reviewed sandbox receipt and its underlying creation/QA proof, not a
newly invented assertion. The receipt has schema1, avd/api/flavor/package,
synthetic_only=true, owner_data_absent=true, qa_package_may_remain, and
proof={kind:dedicated_avd_creation|synthetic_qa_receipt,path,sha256}. The proof
JSON must bind the same identity and synthetic/owner-absence assertions.
Unknown provenance means NOT_RUN. The host requires the receipt SHA-256.

The following read-only preflight chooses the build number, after sandbox
verification. Set MR6C_SERIAL/AVD/API/FLAVOR and MR6C_SANDBOX_RECEIPT to reviewed
absolute values. An absent package uses fixed build number5 in an owned
dedicated AVD that permits retaining QA. Before marking install_started or
restore_pending and before install -r, the coordinator rechecks package
presence and requires exactly one base APK whose SHA-256 matches the saved
original; an originally absent package must still be absent. A mismatch stops
without install or force-stop and retains the original APK and restoration
receipt (plus the pulled current APK when its digest differs). Keep exclusive
ownership of the AVD: the check and install are not atomic.

```sh
export MR6C_SANDBOX_SHA256="$(python3 -c 'import hashlib,os; print(hashlib.sha256(open(os.environ["MR6C_SANDBOX_RECEIPT"],"rb").read()).hexdigest())')"
python3 - <<'PY'
import json, os, pathlib, sys, tempfile
sys.path.insert(0, 'tool')
from mr6c_emulator_checks import Adb, remote_single_apk, pull_verified, inspect_public_apk, write_json
from mr6c_artifacts import sdk_tools
a = Adb(os.environ['MR6C_SERIAL'], os.environ['MR6C_AVD'], int(os.environ['MR6C_API']), os.environ['MR6C_FLAVOR'])
a.verify_identity()
a.verify_sandbox(os.environ['MR6C_SANDBOX_RECEIPT'])
a.require_empty_sandbox()
remote = remote_single_apk(a)
number = 5
if remote:
    with tempfile.TemporaryDirectory(prefix='mr6c-apk-info-', dir=os.environ['MR6C_EVIDENCE']) as tmp:
        apk = pathlib.Path(tmp) / 'original.apk'
        pull_verified(a, remote, apk)
        number = inspect_public_apk(apk, a.flavor, sdk_tools(pathlib.Path.cwd()))['version_code']
write_json(pathlib.Path(os.environ['MR6C_EVIDENCE']) / 'qa-build-number.json', {'build_number': number})
PY
export MR6C_BUILD_NUMBER="$(python3 -c 'import json,os; print(json.load(open(os.environ["MR6C_EVIDENCE"]+"/qa-build-number.json"))["build_number"])')"
```

Build once, then record operator-attested command/source provenance and run the
coordinator. The new evidence/work directories must not contain earlier output.

```sh
fvm flutter build apk --debug --no-pub --flavor "$MR6C_FLAVOR" --build-number "$MR6C_BUILD_NUMBER" --target integration_test/mr6c_background_test.dart --dart-define=MR6C_QA=true
export MR6C_QA_APK="$PWD/build/app/outputs/flutter-apk/app-$MR6C_FLAVOR-debug.apk"
python3 - <<'PY'
import hashlib, json, os, pathlib
def digest(path): return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()
root = pathlib.Path(os.environ['MR6C_EVIDENCE'])
source = root / 'qa-source.json'
source.write_text(json.dumps({'source_head': os.environ['MR6C_SOURCE_HEAD'], 'source_snapshot_sha256': digest(root/'source-snapshot.json'), 'entrypoint': 'integration_test/mr6c_background_test.dart', 'qa_define': True, 'flutter': '3.47.2'}) + '\n')
provenance = {'schema': 1, 'flavor': os.environ['MR6C_FLAVOR'], 'variant': 'debug', 'qa_enabled': True, 'apk_sha256': digest(os.environ['MR6C_QA_APK']), 'source_metadata_sha256': digest(source)}
(root/'qa-provenance.json').write_text(json.dumps(provenance) + '\n')
PY
export MR6C_QA_PROVENANCE_SHA256="$(python3 -c 'import hashlib,os; print(hashlib.sha256(open(os.environ["MR6C_EVIDENCE"]+"/qa-provenance.json","rb").read()).hexdigest())')"
python3 tool/mr6c_emulator_checks.py --serial "$MR6C_SERIAL" --avd "$MR6C_AVD" --api "$MR6C_API" --flavor "$MR6C_FLAVOR" --cases all --output "$MR6C_EVIDENCE/avd-$MR6C_API-$MR6C_FLAVOR" --sandbox-receipt "$MR6C_SANDBOX_RECEIPT" --sandbox-receipt-sha256 "$MR6C_SANDBOX_SHA256" --qa-apk "$MR6C_QA_APK" --qa-provenance "$MR6C_EVIDENCE/qa-provenance.json" --qa-provenance-sha256 "$MR6C_QA_PROVENANCE_SHA256" --source-metadata "$MR6C_EVIDENCE/qa-source.json" --work-dir "$MR6C_EVIDENCE/avd-$MR6C_API-$MR6C_FLAVOR-work" --absent-version-code "$MR6C_BUILD_NUMBER"
```

The host saves/verifies the original APK, writes its restoration receipt before
installation, installs QA once, waits for ready/barrier, issues V9 user-stop,
independently checks process/service death, starts recover and compares the
execution identity with separate ciphertext hashes. Finally it restores and
readbacks the original APK. An absent original is retained on the dedicated
AVD, which is closed. Restored means APK bytes/metadata; synthetic fixture
accounts/journal remain in that owned sandbox. No restored app is launched.

If the second pre-install scan refused, `prepared_no_install` means no install
occurred and no restoration is pending. Preserve the receipt/saved APK and use
fresh work/output directories for any separately verified retry; do not feed
that terminal receipt to --recover.

For interrupted restoration, use the retained receipt's actual current hash:

```sh
export MR6C_RESTORE_RECEIPT="$MR6C_EVIDENCE/avd-$MR6C_API-$MR6C_FLAVOR-work/restore.json"
export MR6C_RESTORE_SHA256="$(python3 -c 'import hashlib,os; print(hashlib.sha256(open(os.environ["MR6C_RESTORE_RECEIPT"],"rb").read()).hexdigest())')"
python3 tool/mr6c_emulator_checks.py --recover --serial "$MR6C_SERIAL" --avd "$MR6C_AVD" --api "$MR6C_API" --flavor "$MR6C_FLAVOR" --cases all --output "$MR6C_EVIDENCE/recovery-$MR6C_API-$MR6C_FLAVOR" --sandbox-receipt "$MR6C_SANDBOX_RECEIPT" --sandbox-receipt-sha256 "$MR6C_SANDBOX_SHA256" --restore-receipt "$MR6C_RESTORE_RECEIPT" --restore-receipt-sha256 "$MR6C_RESTORE_SHA256"
```

These are the fixed child commands for review; the coordinator executes them.
Do not run this reference block in addition to the coordinator:

```sh
adb -s "$MR6C_SERIAL" install -r "$MR6C_QA_APK"
# Once per independent case, before prepare, NEVER inside prepare -> recover:
adb -s "$MR6C_SERIAL" shell am force-stop "$MR6C_PACKAGE"
adb -s "$MR6C_SERIAL" shell pidof "$MR6C_PACKAGE"
# Each phase: strict envelope, fresh sequence and 30-minute deadline.
adb -s "$MR6C_SERIAL" shell run-as "$MR6C_PACKAGE" mkdir -p files/mr6c_qa
adb -s "$MR6C_SERIAL" shell "run-as $MR6C_PACKAGE sh -c 'cat > files/mr6c_qa/command.tmp'" < "$MR6C_COMMAND_JSON"
adb -s "$MR6C_SERIAL" shell run-as "$MR6C_PACKAGE" mv files/mr6c_qa/command.tmp files/mr6c_qa/command.json
adb -s "$MR6C_SERIAL" shell am start -W -n "$MR6C_PACKAGE/io.gitlabmobile.gitlab_mobile.MainActivity"
```

Check each exit status sequentially. Failed install never triggers uninstall or
clear/retry. Ack ready/barrier with ack.json's exact envelope/event. There is no
build/install/uninstall/clear/extra reset between prepare/recover. Never use
flutter run or flutter test -d: its lifecycle can destroy continuity. Death,
start and done alone are never PASS. Recovery must load actual persistent
synthetic accounts, production journal key/files without reseeding. Bind stable
execution identity and separate phase file digests; recovery changes ciphertext.
Unknown data stops before save/recovery/orphan cleanup/auto-login/network. Inject
the synthetic API factory before SessionController initialize, including /user.

After all cases or failure only, verify saved bytes, stop QA, then run
`adb -s "$MR6C_SERIAL" install -r "$MR6C_ORIGINAL_APK"`. Pull/read back hash,
version and signer before restored. Failure is FAIL/pending; keep original and
receipt. Never launch the restored app for owner login. For absent original,
retain QA only in the owned sandbox and close that AVD; no uninstall.

V9 Task Manager user-stop: `adb -s "$MR6C_SERIAL" shell cmd activity stop-app
"$MR6C_PACKAGE"`; settings force-stop: `adb -s "$MR6C_SERIAL" shell am force-stop
"$MR6C_PACKAGE"`. Recents is a real AVD swipe, with process/service readback;
these are distinct cases. V7 cold restart uses am kill after release/background.
Prove approval AND result IDs before kill, after death and after recover; only
approvals disappear. No reset/force-stop/stop-app inside that subcase. Save only
IDs/presence, never notification dumps or text.

V2 API35/36 saves original timeout, exact sync mode and full compat override
BEFORE mutation. Unknown/boolean sync or version-scoped/raw overrides mean
NOT_RUN. Under `adb -s "$MR6C_SERIAL" shell`, fixed mutations are
`am compat enable FGS_INTRODUCE_TIME_LIMITS "$MR6C_PACKAGE"`,
`device_config set_sync_disabled_for_tests until_reboot`, and
`device_config put activity_manager data_sync_fgs_timeout_duration 10000`.
Read back each; finally restore timeout (delete only if originally null), exact
sync/override with durable receipt. Doze saves battery/idle before unplug and
force-idle, proves mState=IDLE, then unforces/restores; never overwrite another
session's simulation. SyntheticTimeout bypasses native onTimeout, so it proves
only synthetic invalidation. Delivered/dropped callback, shortened system and
default six-hour outcomes remain separate. All OS results here are NOT_RUN.

**Host HTTPS fixture, executable independently.** Use a new output directory:

```sh
python3 tool/mr6c_https_fixture.py --output "$MR6C_EVIDENCE/tls-api$MR6C_API-$MR6C_FLAVOR" --duration 780
```

endpoint.json carries the public PEM/host/port. The private key stays in this
session and is removed on normal exit/Ctrl-C. After SIGKILL, remove only this
session's fixture-key.pem after confirming the server is dead. The server binds
loopback for emulator alias 10.0.2.2. The dedicated adapter restricts trust to
that session certificate+host+port while checking hostname. No HttpOverrides,
accept-all TLS, CA installation, adb forwarding or changed production TLS.

SSE: POST /v1/chat/completions, model mr6c-synthetic, stream true, messages
starting MR6C_SYNTHETIC. Normal rounds last 120s, heartbeat5s, below existing
5-minute model deadline. Reads: /api/v4/user, /api/v4/projects/1 and
/api/v4/projects/1/issues/1. Mutation: POST /api/v4/projects/1/issues with exactly
{"title":"MR6C_SYNTHETIC"}. Only synthetic credentials are accepted; headers,
bodies and requested paths are not recorded. GraphQL and the complete V1 case
driver are absent. This server alone cannot establish runner integration.

The real driver must span12min under existing budgets, issue a production API
read every30s, and collect DEVICE bytes/heartbeats/readbacks plus host writes.
Compute start/intermediate/end gaps from observations: SSE<=15s, GitLab<=60s.
Missing device timelines: NOT_VERIFIED/NOT_RUN. Observed gaps/disconnection: FAIL.
Service/Dart survival is separate. No fake adapter, added wake lock or exemption
can certify socket continuity. `tool/mr6c_socket_transport.dart` now supplies
a restricted injectable Dio adapter with session-only trust, ordinary hostname
validation, no proxy/redirects, fixed-origin routes and safe received-byte/
heartbeat/readback counters. Host TLS tests cover wrong CA/hostname, split
heartbeats, credential/origin rejection and redirects. It is not wired to a
12-minute production runner/AVD V1 case yet; V1 remains NOT_RUN/NOT_VERIFIED.

**Evidence and closure.** Keep source receipt, per-command exit/results,
lock-before/after, APK/signer/mapping/input digests, every API/flavor/case variant,
generic counters/native timing, channel/model/REST/Graph N/denominators/p50/p95/
max, TTL expiry and rollback attempts/success/failure, stable execution identity,
per-phase file digests and restore status. Never retain credentials, permits,
tickets, approval/account payloads, raw dumps, screenshots or private logs.
Prune owned large build scratch only after restoration and independent review.

§15 row22 maps generation/managed functions/dual-flavor builds/compiled methods;
row27 maps V2–V5/V8–V10, including SAME-case background+live-engine+lost-callback;
row28 maps V9/V11 real recovery/no replay. Run all §4.3 variants, not selected
smoke. Standard CI analyze/test/native_templates/android_debug and actual URLs
remain lead work. Gitlab-only CI is not play. Worker RESULTs do not close
MR6c/MR7/G6/iOS; independent evidence review is required.

Official requirements checked2026-10-28:
[plugin22.3.3](https://pub.dev/packages/flutter_local_notifications/versions/22.3.3)
requires desugaring, compileSdk>=35 and Java/Kotlin17; generated checks require
SDK24/36/36, AGP9.1.0 and desugar2.1.4.
[Android16 job quotas](https://developer.android.com/about/versions/16/behavior-changes-all)
are distinct from dataSync FGS. The plugin archive had no literal job APIs in a
bounded source check; final transitive jobs still need artifact review.
[Target36 predictive back](https://developer.android.com/about/versions/16/behavior-changes-16)
requires V10 device evidence.
[FGS timeout](https://developer.android.com/develop/background-work/services/fgs/timeout),
[compat tools](https://developer.android.com/guide/app-compatibility/test-debug),
[AOSP sync restore](https://android.googlesource.com/platform/frameworks/libs/net/+/a9f72028e7e51f3808108e08611dc785beafccb3/common/testutils/host/com/android/testutils/DisableConfigSyncTargetPreparer.kt)
justify strategy, not an OS PASS. Exact raw/version compat scope must be
preserved; an effective boolean alone is insufficient.
