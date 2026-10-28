#!/usr/bin/env python3
"""Exact-source MR7 attestation and delivery gate; Python standard library only."""

import argparse
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urljoin, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener


PROJECT = 86648389
RELEASE_REF = "main"
API = "https://gitlab.com/api/v4"
WEB = "https://gitlab.com/aa22396584/gitlab-mobile"
STABLE_CERT = "5bec28281b4c1405f9ee47590c40665a24b0f984fc0d6b8854a3458e8db0a71d"
CHECKS = ("python_checks", "flutter_checks", "flutter_ai_checks", "native_templates", "android_debug")
RECEIPTS = {"live": ("public_api_smoke", "provider_smoke", "production_operations", "events_isolation"),
            "emulator": ("production_smoke",)}
FLAGS = {"ai_assistant": True, "ai_background": False}
ATTESTATION_PATH = "mr7-attestation/attestation.json"
MAX_AGE = timedelta(hours=24)
MAX_JSON = 2 * 1024 * 1024
# 7R enumerates production operation/target/variant and emulator rows in source.
# No runtime or environment override can open this pending release contract.
RELEASE_REQUIREMENTS = None


class GateError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise GateError(message)


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def json_bytes(data, *, object_only=True):
    require(len(data) <= MAX_JSON, "JSON exceeds receipt limit")

    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, "Duplicate JSON key")
            result[key] = value
        return result

    def invalid_constant(_):
        raise GateError("Non-finite JSON number")

    value = json.loads(data, object_pairs_hook=pairs, parse_constant=invalid_constant)
    require(not object_only or isinstance(value, dict), "Expected a JSON object")
    return value


def numeric_id(value):
    require(not isinstance(value, bool) and re.fullmatch(r"[1-9][0-9]*", str(value)),
            "Expected a numeric job ID")
    return int(value)


def source_digests(root=Path("."), *, require_clean=False):
    root = Path(root)
    if require_clean:
        result = subprocess.run(["git", "diff", "--quiet", "HEAD", "--"], cwd=root,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        require(result.returncode == 0, "Tracked checkout differs from release commit")
    tools = "lib/core/ai/tools/"
    capability = [tools + name for name in ("release_policy.dart", "write_ledger.dart",
                  "tool_catalogue.dart", "tool_catalogue_version.dart")]
    capability += [path.relative_to(root).as_posix()
                   for path in sorted((root / tools / "ledger").glob("*.dart"))]
    policy = [tools + "release_policy.dart", "lib/features/ai/ai_gate.dart",
              "lib/features/ai/ai_background_execution.dart"]

    def files_hash(names):
        return digest(canonical({name: digest((root / name).read_bytes()) for name in names}))

    tree = subprocess.check_output(["git", "rev-parse", "HEAD^{tree}"], cwd=root, text=True).strip()
    return {"tree": tree, "lock_sha256": digest((root / "pubspec.lock").read_bytes()),
            "capability_sha256": files_hash(capability), "policy_sha256": files_hash(policy)}


def timestamp(value):
    require(isinstance(value, str), "Missing timestamp")
    try:
        result = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise GateError("Invalid timestamp") from error
    require(result.tzinfo is not None, "Timestamp must include timezone")
    return result.astimezone(timezone.utc)


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class GitLab:
    """API origin is fixed; CDN redirects never receive either credential."""

    def __init__(self, read_token, job_token):
        require(job_token, "Missing authenticated GitLab job access")
        self.read_token, self.job_token = read_token, job_token
        self.opener = build_opener(NoRedirect())

    def read(self, url, *, job_token=False, artifact=False, limit=MAX_JSON):
        headers = {"JOB-TOKEN" if job_token else "PRIVATE-TOKEN":
                   self.job_token if job_token else self.read_token}
        for _ in range(4):
            try:
                with self.opener.open(Request(url, headers=headers), timeout=30) as response:
                    data = response.read(limit + 1)
                    require(len(data) <= limit, "GitLab response exceeds limit")
                    return data
            except HTTPError as error:
                if artifact and error.code in (301, 302, 303, 307, 308):
                    location = urljoin(url, error.headers.get("Location", ""))
                    target = urlsplit(location)
                    require(target.scheme == "https" and target.hostname
                            and not target.username and not target.password, "Unsafe artifact redirect")
                    url, headers = location, {}
                    continue
                raise GateError(f"GitLab API rejected request (HTTP {error.code})") from None
            except (URLError, TimeoutError):
                raise GateError("GitLab API request failed") from None
        raise GateError("Too many artifact redirects")

    def get(self, path):
        require(self.read_token, "Missing protected read_api access")
        return json_bytes(self.read(f"{API}/projects/{PROJECT}/{path}"))

    def current_job(self):
        return json_bytes(self.read(f"{API}/job", job_token=True))

    def current_release_protected(self):
        data = self.read(f"{API}/projects/{PROJECT}/repository/branches?search=%5Emain%24&per_page=100",
                         job_token=True)
        branches = json_bytes(data, object_only=False)
        require(isinstance(branches, list), "Missing authenticated branch list")
        matches = [branch for branch in branches if isinstance(branch, dict)
                   and branch.get("name") == RELEASE_REF]
        return len(matches) == 1 and matches[0].get("protected") is True

    def artifact(self, job_id, path):
        parsed = PurePosixPath(path)
        require(not parsed.is_absolute() and ".." not in parsed.parts, "Invalid receipt artifact path")
        return self.read(f"{API}/projects/{PROJECT}/jobs/{numeric_id(job_id)}/"
                         f"artifacts/{quote(path, safe='/')}", artifact=True)

    def trace(self, job_id):
        return self.read(f"{API}/projects/{PROJECT}/jobs/{numeric_id(job_id)}/trace",
                         limit=8 * 1024 * 1024)


def verify_job(api, job, name, sha, *, status="success", pipeline_id=None):
    job_id = numeric_id(job.get("id"))
    pipeline = job.get("pipeline", {})
    require(job.get("name") == name and job.get("status") == status, "Wrong job name or status")
    require(job.get("ref") == RELEASE_REF and job.get("tag") is False,
            "Job is not on the protected release branch")
    require(job.get("commit", {}).get("id") == sha and pipeline.get("sha") == sha, "Job SHA mismatch")
    require(pipeline.get("project_id") == PROJECT and pipeline.get("ref") == RELEASE_REF,
            "Job project or pipeline ref mismatch")
    pid = numeric_id(pipeline.get("id"))
    require(pipeline_id is None or pid == pipeline_id, "Wrong release pipeline")
    require(job.get("web_url") == f"{WEB}/-/jobs/{job_id}", "Wrong job URL")
    actual = api.get(f"pipelines/{pid}")
    require(actual.get("id") == pid and actual.get("project_id") == PROJECT
            and actual.get("sha") == sha and actual.get("ref") == RELEASE_REF
            and actual.get("source") in ("push", "web", "api", "schedule")
            and actual.get("web_url") == f"{WEB}/-/pipelines/{pid}", "Untrusted release pipeline")
    require(api.get(f"repository/branches/{RELEASE_REF}").get("protected") is True,
            "Release branch is not protected")
    return {"id": job_id, "name": name, "status": status, "release_sha": sha,
            "pipeline_id": pid, "pipeline_url": actual["web_url"], "job_url": job["web_url"]}


def verify_current_job(job, name, sha):
    pipeline = job.get("pipeline", {})
    require(job.get("name") == name and job.get("status") == "running"
            and job.get("source") in ("push", "web", "api", "schedule")
            and job.get("ref") == RELEASE_REF and job.get("tag") is False
            and job.get("commit", {}).get("id") == sha
            and pipeline.get("sha") == sha and pipeline.get("ref") == RELEASE_REF
            and pipeline.get("project_id") == PROJECT
            and job.get("web_url") == f"{WEB}/-/jobs/{numeric_id(job.get('id'))}",
            "Untrusted current job identity")
    return job


def current_identity(api, name, sha):
    job = verify_current_job(api.current_job(), name, sha)
    verify_job(api, job, name, sha, status="running")
    return job


def inspect_apk(apk):
    sdk = Path(os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT") or "")
    tools = sdk / "build-tools" / "36.0.0"
    aapt, signer = tools / "aapt2", tools / "apksigner"
    require(aapt.is_file() and signer.is_file(), "AI delivery needs pinned Android APK inspection tools")
    badging = subprocess.check_output([str(aapt), "dump", "badging", str(apk)], text=True)
    package = re.search(r"^package: name='([^']+)'", badging, re.M)
    signing = subprocess.check_output([str(signer), "verify", "--verbose", "--print-certs", str(apk)], text=True)
    certs = re.findall(r"^Signer #\d+ certificate SHA-256 digest: ([0-9a-fA-F]{64})\s*$", signing, re.M)
    require(package is not None and len(certs) == 1, "Invalid APK package or signing certificate")
    return {"package": package.group(1),
            "debuggable": bool(re.search(r"^application-debuggable(?:\s|$)", badging, re.M)),
            "certificate_sha256": certs[0].lower()}


def metadata_for_delivery(root, sha, mode):
    directory = Path(root) / "artifacts"
    data = (directory / "build-metadata.json").read_bytes()
    metadata = json_bytes(data)
    require(metadata.get("commit") == sha and metadata.get("channel") == "gitlab",
            "Metadata commit or distribution channel mismatch")
    # Missing flags in older previews still mean off. Other JSON types fail closed.
    flags = {key: metadata.get(key, False) for key in FLAGS}
    require(all(type(value) is bool for value in flags.values()), "Invalid metadata flags")
    require(not flags["ai_background"] or flags["ai_assistant"], "Invalid background flag")
    require(flags["ai_assistant"] == (mode == "ai"), "Wrong delivery mode for artifact flags")
    apks = sorted(directory.glob("*.apk"))
    require(len(apks) == 1 and not apks[0].is_symlink(), "Expected exactly one APK")
    with apks[0].open("rb") as stream:
        apk_hash = hashlib.file_digest(stream, "sha256").hexdigest()
    if "apk_sha256" in metadata:
        require(metadata["apk_sha256"] == apk_hash, "APK metadata digest mismatch")
    if mode == "ai":
        expected = {"build_type": "release", "package": "io.gitlabmobile.gitlab_mobile",
                    "debuggable": False, "certificate_sha256": STABLE_CERT,
                    "entrypoint": "lib/main.dart", **FLAGS}
        for key, value in expected.items():
            require(key in metadata and type(metadata[key]) is type(value)
                    and metadata[key] == value, f"Ineligible AI release metadata: {key}")
        for key, value in source_digests(root, require_clean=True).items():
            require(metadata.get(key) == value, f"Source metadata mismatch: {key}")
        require(metadata.get("apk_sha256") == apk_hash, "Missing exact APK digest")
        require(inspect_apk(apks[0]) == {key: metadata[key] for key in
                ("package", "debuggable", "certificate_sha256")}, "APK inspection disagrees with metadata")
    return metadata, {"apk_name": apks[0].name, "apk_sha256": apk_hash, "metadata_sha256": digest(data)}


def validate_receipts(api, rows, sha, source, *, now):
    requirements = RELEASE_REQUIREMENTS
    require(isinstance(requirements, dict)
            and requirements.get("capability_sha256") == source["capability_sha256"]
            and isinstance(requirements.get("operations"), dict)
            and isinstance(requirements.get("emulator"), (tuple, list))
            and bool(requirements["emulator"]), "7R source evidence requirements are not configured")
    require(isinstance(rows, list), "Missing receipt rows")
    expected = {(kind, name) for kind, names in RECEIPTS.items() for name in names}
    seen = set()
    for row in rows:
        require(isinstance(row, dict), "Invalid receipt row")
        key = (row.get("kind"), row.get("name"))
        require(key in expected and key not in seen, "Unknown or duplicate receipt row")
        seen.add(key)
        job_id = numeric_id(row.get("job_id"))
        identity = verify_job(api, api.get(f"jobs/{job_id}"), "mr7_release_receipts", sha)
        require(row.get("job_url") == identity["job_url"], "Receipt job URL mismatch")
        path = f"mr7-receipts/{key[0]}/{key[1]}.json"
        require(row.get("path") == path, "Unexpected receipt artifact path")
        data = api.artifact(job_id, path)
        require(row.get("sha256") == digest(data), "Receipt digest mismatch")
        receipt = json_bytes(data)
        require(receipt.get("schema") == 1 and receipt.get("status") == "PASS"
                and receipt.get("kind") == key[0] and receipt.get("name") == key[1]
                and receipt.get("release_sha") == sha and receipt.get("source") == source
                and receipt.get("flags") == FLAGS and receipt.get("policy") == "production"
                and receipt.get("flavor") == "gitlab" and receipt.get("build_type") == "release",
                "Receipt does not prove this production release tuple")
        age = now - timestamp(receipt.get("created_at"))
        require(timedelta(0) <= age <= MAX_AGE, "Stale or future receipt")
        if key == ("live", "production_operations"):
            expected_rows = {(operation, variant) for operation, variants in requirements["operations"].items()
                             for variant in variants}
            details = receipt.get("operations", [])
            require(isinstance(details, list), "Missing operation details")
            names = [(item.get("operation_id"), item.get("variant")) for item in details]
            require(len(names) == len(set(names)) and set(names) == expected_rows,
                    "Missing required operation or variant rows")
            for detail in details:
                validate_detail(api, job_id, detail, sha, source, now, "operations",
                                (detail["operation_id"], detail["variant"]))
        elif key == ("emulator", "production_smoke"):
            details = receipt.get("rows", [])
            require(isinstance(details, list), "Missing emulator details")
            names = [detail.get("name") for detail in details]
            require(len(names) == len(set(names)) and set(names) == set(requirements["emulator"]),
                    "Missing required emulator rows")
            for detail in details:
                validate_detail(api, job_id, detail, sha, source, now, "emulator-rows", (detail["name"],))
        elif key == ("live", "events_isolation"):
            require(receipt.get("isolation") == "PASS" and receipt.get("outside_events") == 0
                    and type(receipt.get("outside_events")) is int
                    and type(receipt.get("expected_user_id")) is int
                    and receipt["expected_user_id"] > 0, "Missing events isolation proof")
    require(seen == expected, "Missing required live or emulator receipt rows")


def validate_detail(api, job_id, locator, sha, source, now, directory, identity):
    path = f"mr7-receipts/{directory}/{digest(canonical(identity))}.json"
    require(locator.get("path") == path, "Unexpected detail receipt path")
    data = api.artifact(job_id, path)
    require(locator.get("sha256") == digest(data), "Detail receipt digest mismatch")
    detail = json_bytes(data)
    require(detail.get("status") == "PASS" and detail.get("release_sha") == sha
            and detail.get("source") == source and detail.get("flags") == FLAGS
            and detail.get("policy") == "production", "Wrong detail release tuple")
    age = now - timestamp(detail.get("created_at"))
    require(timedelta(0) <= age <= MAX_AGE, "Stale detail receipt")
    if directory == "operations":
        require((detail.get("operation_id"), detail.get("variant")) == identity
                and detail.get("independent_readback") == "PASS"
                and detail.get("events_isolation") == "PASS", "Missing operation readback or isolation")
    else:
        require((detail.get("name"),) == identity and detail.get("device_result") == "PASS",
                "Missing emulator device result")


def validate_attestation(api, attestation, sha, source, metadata, hashes,
                         *, pipeline_id, provider_job=None, now=None):
    now = now or datetime.now(timezone.utc)
    require(re.fullmatch(r"[0-9a-f]{40}", sha) is not None, "Expected full release SHA")
    require(attestation.get("schema") == 1 and attestation.get("release_sha") == sha,
            "Attestation SHA mismatch")
    require(attestation.get("source") == source, "Attestation source digest mismatch")
    age = now - timestamp(attestation.get("created_at"))
    require(timedelta(0) <= age <= MAX_AGE, "Stale or future attestation")
    require(attestation.get("pipeline_url") == f"{WEB}/-/pipelines/{pipeline_id}",
            "Attestation pipeline URL mismatch")
    expected_artifact = {**hashes, "flavor": metadata.get("channel"),
                         **{key: metadata.get(key) for key in ("build_type", "package", "debuggable",
                            "certificate_sha256", "entrypoint", "flutter_version",
                            "flutter_revision", "dart_version")}, "flags": FLAGS}
    require(attestation.get("artifact") == expected_artifact, "Attestation artifact tuple mismatch")
    require(all(isinstance(metadata.get(key), str) and metadata[key] for key in
                ("flutter_version", "flutter_revision", "dart_version")), "Missing SDK tuple")
    checks = attestation.get("checks")
    require(isinstance(checks, dict) and set(checks) == set(CHECKS), "Missing required check rows")
    for name, row in checks.items():
        require(isinstance(row, dict), "Invalid check row")
        receipt = verify_job(api, api.get(f"jobs/{numeric_id(row.get('job_id'))}"), name, sha,
                             pipeline_id=pipeline_id)
        require(row == {"job_id": receipt["id"], "job_url": receipt["job_url"],
                        "sha256": digest(canonical(receipt))}, "Check receipt digest mismatch")
        if name == "android_debug":
            require(metadata.get("job_url") == receipt["job_url"]
                    and metadata.get("pipeline_url") == receipt["pipeline_url"],
                    "Build metadata job or pipeline mismatch")
    validate_receipts(api, attestation.get("receipts"), sha, source, now=now)
    provider = attestation.get("provider", {})
    job_id = numeric_id(provider.get("job_id"))
    job = provider_job or api.get(f"jobs/{job_id}")
    identity = verify_job(api, job, "mr7_release_attestation", sha,
                          status="running" if provider_job else "success", pipeline_id=pipeline_id)
    require(provider == {"project_id": PROJECT, "job_id": identity["id"],
                         "job_url": identity["job_url"],
                         "user_id": numeric_id(job.get("user", {}).get("id"))},
            "Attestation provider identity mismatch")


def fetch_attestation(api, job_id, sha, pipeline_id):
    job_id = numeric_id(job_id)
    job = api.get(f"jobs/{job_id}")
    verify_job(api, job, "mr7_release_attestation", sha, pipeline_id=pipeline_id)
    require(job.get("artifacts_file", {}).get("size", 0) > 0, "Missing attestation artifact")
    expiry = job.get("artifacts_expire_at")
    require(expiry is None or timestamp(expiry) > datetime.now(timezone.utc), "Attestation artifact expired")
    # Jobs API has no documented artifact SHA-256. Anchor bytes to the successful
    # job's authenticated digest record and checksum in the same job artifact.
    trace = api.trace(job_id).decode("utf-8", errors="strict")
    hashes = re.findall(r"^MR7_ATTESTATION_SHA256=([0-9a-f]{64})\r?$", trace, re.M)
    require(len(hashes) == 1, "Missing or ambiguous authenticated attestation digest")
    data = api.artifact(job_id, ATTESTATION_PATH)
    require(digest(data) == hashes[0], "Immutable job attestation digest mismatch")
    require(api.artifact(job_id, "mr7-attestation/SHA256SUMS") ==
            f"{hashes[0]}  attestation.json\n".encode(), "Attestation artifact checksum mismatch")
    attestation = json_bytes(data)
    require(attestation.get("provider", {}).get("job_id") == job_id,
            "Attestation provider differs from selected artifact job")
    return attestation


def make_attestation(api, current, sha, root, receipts_job_id, now=None):
    now = now or datetime.now(timezone.utc)
    metadata, hashes = metadata_for_delivery(root, sha, "ai")
    source = source_digests(root)
    pid = numeric_id(current["pipeline"]["id"])
    verify_job(api, api.get(f"jobs/{numeric_id(receipts_job_id)}"), "mr7_release_receipts", sha)
    manifest = json_bytes(api.artifact(receipts_job_id, "mr7-receipts/index.json"))
    require(set(manifest.get("checks", {})) == set(CHECKS), "Missing required check locators")
    checks = {}
    for name, job_id in manifest["checks"].items():
        receipt = verify_job(api, api.get(f"jobs/{numeric_id(job_id)}"), name, sha, pipeline_id=pid)
        checks[name] = {"job_id": receipt["id"], "job_url": receipt["job_url"],
                        "sha256": digest(canonical(receipt))}
    attestation = {
        "schema": 1, "release_sha": sha, "source": source, "created_at": now.isoformat(),
        "pipeline_url": f"{WEB}/-/pipelines/{pid}",
        "provider": {"project_id": PROJECT, "job_id": current["id"],
                     "job_url": current["web_url"], "user_id": current["user"]["id"]},
        "checks": checks, "receipts": manifest.get("receipts"),
        "artifact": {**hashes, "flavor": metadata["channel"],
                     **{key: metadata.get(key) for key in ("build_type", "package", "debuggable",
                        "certificate_sha256", "entrypoint", "flutter_version",
                        "flutter_revision", "dart_version")}, "flags": FLAGS}}
    validate_attestation(api, attestation, sha, source, metadata, hashes,
                         pipeline_id=pid, provider_job=current, now=now)
    return attestation


def api_from_environment():
    # A protected environment-scoped read_api file token is required. Arbitrary
    # environment-provided attestation files, URLs and booleans are not authority.
    token_file = os.environ.get("MR7_GITLAB_READ_TOKEN_FILE", "")
    require(token_file and Path(token_file).is_file(), "Missing protected read_api token file")
    return GitLab(Path(token_file).read_text().strip(), os.environ.get("CI_JOB_TOKEN", ""))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("create", "delivery"))
    parser.add_argument("--mode", choices=("off", "ai"), default="ai")
    parser.add_argument("--attestation-job-id")
    parser.add_argument("--receipts-job-id")
    args = parser.parse_args(argv)
    sha = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
    require(os.environ.get("CI_COMMIT_SHA") == sha, "Checkout and CI SHA differ")
    require(os.environ.get("CI_PROJECT_ID") == str(PROJECT)
            and os.environ.get("CI_COMMIT_REF_PROTECTED") == "true"
            and os.environ.get("CI_COMMIT_BRANCH") == RELEASE_REF
            and os.environ.get("CI_PIPELINE_SOURCE") != "merge_request_event",
            "Not a protected project release lane")
    if args.action == "delivery" and args.mode == "off":
        api = GitLab(None, os.environ.get("CI_JOB_TOKEN", ""))
        verify_current_job(api.current_job(), "publish_preview", sha)
        require(api.current_release_protected(), "Release branch is not protected")
        metadata_for_delivery(Path("."), sha, "off")
        print("MR7 AI-off delivery metadata verified")
        return
    api = api_from_environment()
    name = "mr7_release_attestation" if args.action == "create" else "publish_preview_ai"
    current = current_identity(api, name, sha)
    if args.action == "create":
        attestation = make_attestation(api, current, sha, Path("."), args.receipts_job_id)
        output = Path("mr7-attestation")
        output.mkdir(exist_ok=True)
        data = json.dumps(attestation, indent=2, sort_keys=True).encode() + b"\n"
        with (output / "attestation.json").open("xb") as target:
            target.write(data)
        with (output / "SHA256SUMS").open("x") as target:
            target.write(f"{digest(data)}  attestation.json\n")
        print(f"MR7_ATTESTATION_SHA256={digest(data)}")
    else:
        metadata, hashes = metadata_for_delivery(Path("."), sha, "ai")
        pid = numeric_id(current["pipeline"]["id"])
        attestation = fetch_attestation(api, args.attestation_job_id, sha, pid)
        validate_attestation(api, attestation, sha, source_digests(), metadata, hashes, pipeline_id=pid)
        print("MR7 exact-SHA AI-on attestation verified")


if __name__ == "__main__":
    try:
        main()
    except (GateError, OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        print(f"MR7 gate rejected: {error if isinstance(error, GateError) else type(error).__name__}",
              file=sys.stderr)
        sys.exit(1)
