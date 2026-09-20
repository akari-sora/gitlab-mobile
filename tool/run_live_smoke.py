#!/usr/bin/env python3
"""Run the private CRUD suite locally; never take a token on the command line."""
from __future__ import annotations

import argparse
import getpass
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def run(expected_user_id: int = 9571238) -> int:
    dart = shutil.which("dart")
    if not dart:
        print("Flutter/Dart SDK is not on PATH. Install it and run flutter pub get first.", file=sys.stderr)
        return 2
    if expected_user_id <= 0:
        print("Expected user ID must be positive.", file=sys.stderr)
        return 2
    root = Path(__file__).resolve().parents[1]
    try:
        token = getpass.getpass("GitLab PAT (hidden; isolated private test project will be created and cleaned up): ")
        if not token or any(char.isspace() for char in token):
            print("A non-empty token without whitespace is required.", file=sys.stderr)
            return 2
        with tempfile.TemporaryDirectory(prefix="gitlab-mobile-smoke-") as directory:
            path = Path(directory) / "credential"
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as stream:
                stream.write(token)
            env = os.environ.copy()
            env["SMOKE_TOKEN_FILE"] = str(path)
            env["SMOKE_EXPECTED_USER_ID"] = str(expected_user_id)
            # Argument list, no shell; no token value in argv or environment.
            result = subprocess.run([dart, "run", "tool/live_smoke.dart"], cwd=root, env=env, check=False)
            return result.returncode
    except (EOFError, KeyboardInterrupt):
        print("Smoke run interrupted.", file=sys.stderr)
        return 130
    except OSError:
        print("Could not start Dart or create the temporary credential file.", file=sys.stderr)
        return 2


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--expected-user-id", type=int, default=9571238)
    return run(parser.parse_args().expected_user_id)


if __name__ == "__main__":
    raise SystemExit(main())
