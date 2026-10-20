#!/usr/bin/env python3
"""Launch the opt-in AI provider smoke matrix without handling credentials.

This tool intentionally has no prompt, model, URL, credential-reference, or
output-path arguments. Reviewed traffic parameters are kept in the fixed matrix
below. Credential references for keyed targets come from
``~/.config/gitlab-mobile/ai-smoke.json``. It is not used by the default CI
pipeline.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass
import json
from pathlib import Path
import subprocess
import sys
from typing import Callable, Sequence


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_DART = Path.home() / "fvm/versions/3.47.2/bin/dart"


@dataclass(frozen=True)
class SmokeTarget:
    requires_credential: bool


TARGETS = {
    "anthropic-direct": SmokeTarget(True),
    "opencode-responses": SmokeTarget(True),
    "opencode-chat": SmokeTarget(True),
    "opencode-messages": SmokeTarget(True),
    "ollama-chat": SmokeTarget(False),
    "ollama-responses": SmokeTarget(False),
}


def _credential_reference(target_id: str) -> str | None:
    config_path = Path.home() / ".config" / "gitlab-mobile" / "ai-smoke.json"
    try:
        raw_config = config_path.read_text(encoding="utf-8")
    except FileNotFoundError:
        print("AI smoke credential config not found.", file=sys.stderr)
        return None
    except UnicodeError:
        print("AI smoke credential config is invalid.", file=sys.stderr)
        return None
    except OSError:
        print("Could not read the AI smoke credential config.", file=sys.stderr)
        return None

    try:
        config = json.loads(raw_config)
    except (json.JSONDecodeError, UnicodeError):
        print("AI smoke credential config is invalid.", file=sys.stderr)
        return None
    if not isinstance(config, dict):
        print("AI smoke credential config is invalid.", file=sys.stderr)
        return None

    if target_id not in config:
        print(f"No credential configured for {target_id}.", file=sys.stderr)
        return None
    reference = config[target_id]
    if not isinstance(reference, str) or not reference.startswith("op://"):
        print(f"Invalid credential configuration for {target_id}.", file=sys.stderr)
        return None
    return reference


def _stop_process(process: subprocess.Popen) -> None:
    try:
        process.kill()
    except OSError:
        pass
    try:
        process.wait()
    except OSError:
        pass


def run_target(
    target_id: str,
    *,
    dart: Path = DEFAULT_DART,
    popen: Callable[..., subprocess.Popen] = subprocess.Popen,
) -> int:
    """Pipe ``op read`` directly to one fixed Dart smoke target."""
    target = TARGETS.get(target_id)
    if target is None:
        raise ValueError(f"Unknown smoke target: {target_id}")
    if not dart.is_file():
        print(f"Pinned Dart executable not found: {dart}", file=sys.stderr)
        return 2

    dart_command = [
        str(dart),
        "run",
        "tool/ai_live_smoke.dart",
        "--target",
        target_id,
    ]
    if not target.requires_credential:
        try:
            smoke = popen(
                dart_command,
                cwd=ROOT,
                stdin=subprocess.DEVNULL,
            )
            return smoke.wait()
        except OSError:
            print("Could not start Dart.", file=sys.stderr)
            return 2

    credential_ref = _credential_reference(target_id)
    if credential_ref is None:
        return 2
    try:
        credential = popen(
            ["op", "read", credential_ref],
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
    except OSError:
        print("Could not start 1Password CLI.", file=sys.stderr)
        return 2
    if credential.stdout is None:
        _stop_process(credential)
        print("Could not create the credential pipe.", file=sys.stderr)
        return 2

    try:
        smoke = popen(
            dart_command,
            cwd=ROOT,
            stdin=credential.stdout,
        )
    except OSError:
        credential.stdout.close()
        _stop_process(credential)
        print("Could not start Dart.", file=sys.stderr)
        return 2
    except BaseException:
        credential.stdout.close()
        _stop_process(credential)
        raise
    credential.stdout.close()

    try:
        smoke_status = smoke.wait()
        credential_status = credential.wait()
    except OSError:
        _stop_process(smoke)
        _stop_process(credential)
        print("AI live smoke process failed.", file=sys.stderr)
        return 2
    except BaseException:
        _stop_process(smoke)
        _stop_process(credential)
        raise
    if credential_status != 0:
        print(f"Credential lookup failed for {target_id}.", file=sys.stderr)
        return credential_status or 2
    return smoke_status


def run(
    targets: Sequence[str],
    *,
    dart: Path = DEFAULT_DART,
    popen: Callable[..., subprocess.Popen] = subprocess.Popen,
) -> int:
    for target_id in targets:
        status = run_target(target_id, dart=dart, popen=popen)
        if status != 0:
            return status
    return 0


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--target",
        action="append",
        choices=tuple(TARGETS),
        dest="targets",
        help="Run only this reviewed target; repeat to run several.",
    )
    args = parser.parse_args(argv)
    try:
        return run(args.targets or tuple(TARGETS))
    except KeyboardInterrupt:
        print("AI live smoke interrupted.", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
