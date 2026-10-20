"""Safety and orchestration tests for tool/run_ai_live_smoke.py."""
from __future__ import annotations

from contextlib import redirect_stderr
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import run_ai_live_smoke as smoke


class UnreadablePipe(io.BytesIO):
    def read(self, *args, **kwargs):
        raise AssertionError("Python must not read credential-pipe bytes")

    def readline(self, *args, **kwargs):
        raise AssertionError("Python must not read credential-pipe bytes")


class FakeProcess:
    def __init__(self, status: int = 0, *, stdout: io.BytesIO | None = None):
        self.status = status
        self.stdout = stdout
        self.killed = False

    def wait(self) -> int:
        return self.status

    def kill(self) -> None:
        self.killed = True


class AiLiveSmokeLauncherTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.home = Path(temporary.name)
        home_patch = mock.patch.dict(os.environ, {"HOME": str(self.home)})
        home_patch.start()
        self.addCleanup(home_patch.stop)
        self.dart = self.home / "dart"
        self.dart.touch()
        self.config_path = (
            self.home / ".config" / "gitlab-mobile" / "ai-smoke.json"
        )
        self.write_config()

    def write_config(self, values=None):
        self.config_path.parent.mkdir(parents=True, exist_ok=True)
        self.config_path.write_text(
            json.dumps(
                values
                if values is not None
                else {
                    "anthropic-direct": "op://test-vault/anthropic/credential",
                    "opencode-responses": "op://test-vault/opencode/credential",
                    "opencode-chat": "op://test-vault/opencode/credential",
                    "opencode-messages": "op://test-vault/opencode/credential",
                }
            ),
            encoding="utf-8",
        )

    def test_op_stdout_is_connected_directly_to_dart_stdin(self):
        pipe = UnreadablePipe(b"synthetic-secret-that-the-test-never-reads")
        credential = FakeProcess(stdout=pipe)
        dart_process = FakeProcess()
        calls: list[tuple[list[str], dict[str, object]]] = []

        def popen(argv, **kwargs):
            calls.append((argv, kwargs))
            return credential if len(calls) == 1 else dart_process

        status = smoke.run_target(
            "anthropic-direct",
            dart=self.dart,
            popen=popen,
        )

        self.assertEqual(status, 0)
        self.assertEqual(calls[0][0][:2], ["op", "read"])
        self.assertEqual(calls[0][1]["stdout"], smoke.subprocess.PIPE)
        self.assertEqual(calls[0][1]["stderr"], smoke.subprocess.DEVNULL)
        self.assertIs(calls[1][1]["stdin"], pipe)
        self.assertNotIn(b"synthetic-secret", repr(calls).encode())
        self.assertTrue(pipe.closed)

    def test_credential_reference_is_loaded_from_local_config(self):
        reference = "op://different-local-vault/different-item/credential"
        self.write_config({"anthropic-direct": reference})
        calls: list[list[str]] = []

        def popen(argv, **kwargs):
            calls.append(argv)
            return (
                FakeProcess(stdout=io.BytesIO())
                if len(calls) == 1
                else FakeProcess()
            )

        self.assertEqual(
            smoke.run_target("anthropic-direct", dart=self.dart, popen=popen),
            0,
        )
        self.assertEqual(calls[0], ["op", "read", reference])

    def test_missing_config_is_exit_2_without_starting_a_process(self):
        self.config_path.unlink()
        popen = mock.Mock()
        stderr = io.StringIO()

        with redirect_stderr(stderr):
            status = smoke.run_target(
                "anthropic-direct",
                dart=self.dart,
                popen=popen,
            )

        self.assertEqual(status, 2)
        popen.assert_not_called()
        self.assertIn("AI smoke credential config not found", stderr.getvalue())

    def test_malformed_json_is_exit_2_without_leaking_config_text(self):
        reference = "op://private-vault/private-item/credential"
        self.config_path.write_text(
            '{"anthropic-direct": "' + reference,
            encoding="utf-8",
        )
        popen = mock.Mock()
        stderr = io.StringIO()

        with redirect_stderr(stderr):
            status = smoke.run_target(
                "anthropic-direct",
                dart=self.dart,
                popen=popen,
            )

        self.assertEqual(status, 2)
        popen.assert_not_called()
        self.assertIn(
            "AI smoke credential config is invalid",
            stderr.getvalue(),
        )
        self.assertNotIn(reference, stderr.getvalue())

    def test_non_object_json_is_exit_2_without_leaking_references(self):
        reference = "op://private-vault/private-item/credential"
        self.config_path.write_text(json.dumps([reference]), encoding="utf-8")
        popen = mock.Mock()
        stderr = io.StringIO()

        with redirect_stderr(stderr):
            status = smoke.run_target(
                "anthropic-direct",
                dart=self.dart,
                popen=popen,
            )

        self.assertEqual(status, 2)
        popen.assert_not_called()
        self.assertIn(
            "AI smoke credential config is invalid",
            stderr.getvalue(),
        )
        self.assertNotIn(reference, stderr.getvalue())

    def test_invalid_utf8_is_exit_2_without_leaking_config_bytes(self):
        self.config_path.write_bytes(
            b"\xffop://private-vault/private-item/credential"
        )
        popen = mock.Mock()
        stderr = io.StringIO()

        with redirect_stderr(stderr):
            status = smoke.run_target(
                "anthropic-direct",
                dart=self.dart,
                popen=popen,
            )

        self.assertEqual(status, 2)
        popen.assert_not_called()
        self.assertIn(
            "AI smoke credential config is invalid",
            stderr.getvalue(),
        )
        self.assertNotIn("private-item", stderr.getvalue())

    def test_missing_target_config_is_exit_2_without_leaking_other_references(self):
        unrelated_reference = "op://private-vault/unrelated-item/credential"
        self.write_config({"unrelated-target": unrelated_reference})
        popen = mock.Mock()
        stderr = io.StringIO()

        with redirect_stderr(stderr):
            status = smoke.run_target(
                "anthropic-direct",
                dart=self.dart,
                popen=popen,
            )

        self.assertEqual(status, 2)
        popen.assert_not_called()
        self.assertIn(
            "No credential configured for anthropic-direct",
            stderr.getvalue(),
        )
        self.assertNotIn(unrelated_reference, stderr.getvalue())

    def test_non_op_reference_is_rejected_without_leaking_it(self):
        invalid_reference = "https://private.example/secret-reference"
        self.write_config({"anthropic-direct": invalid_reference})
        popen = mock.Mock()
        stderr = io.StringIO()

        with redirect_stderr(stderr):
            status = smoke.run_target(
                "anthropic-direct",
                dart=self.dart,
                popen=popen,
            )

        self.assertEqual(status, 2)
        popen.assert_not_called()
        self.assertIn(
            "Invalid credential configuration for anthropic-direct",
            stderr.getvalue(),
        )
        self.assertNotIn(invalid_reference, stderr.getvalue())

    def test_non_string_reference_is_rejected_before_process_start(self):
        self.write_config({"anthropic-direct": {"reference": "not-a-string"}})
        popen = mock.Mock()
        stderr = io.StringIO()

        with redirect_stderr(stderr):
            status = smoke.run_target(
                "anthropic-direct",
                dart=self.dart,
                popen=popen,
            )

        self.assertEqual(status, 2)
        popen.assert_not_called()
        self.assertIn(
            "Invalid credential configuration for anthropic-direct",
            stderr.getvalue(),
        )
        self.assertNotIn("not-a-string", stderr.getvalue())

    def test_subprocess_start_error_cannot_print_credential_reference(self):
        reference = "op://private-vault/private-item/credential"
        self.write_config({"anthropic-direct": reference})
        popen = mock.Mock(side_effect=OSError(f"failed to launch {reference}"))
        stderr = io.StringIO()

        with redirect_stderr(stderr):
            status = smoke.run_target(
                "anthropic-direct",
                dart=self.dart,
                popen=popen,
            )

        self.assertEqual(status, 2)
        self.assertEqual(popen.call_count, 1)
        self.assertNotIn(reference, stderr.getvalue())

    def test_dart_start_error_closes_pipe_and_stops_credential_process(self):
        reference = "op://private-vault/private-item/credential"
        self.write_config({"anthropic-direct": reference})
        pipe = UnreadablePipe(b"synthetic-secret-that-python-never-reads")
        credential = FakeProcess(stdout=pipe)
        calls = 0

        def popen(argv, **kwargs):
            nonlocal calls
            calls += 1
            if calls == 1:
                return credential
            raise OSError(f"failed to start Dart for {reference}")

        stderr = io.StringIO()
        with redirect_stderr(stderr):
            status = smoke.run_target(
                "anthropic-direct",
                dart=self.dart,
                popen=popen,
            )

        self.assertEqual(status, 2)
        self.assertEqual(calls, 2)
        self.assertTrue(pipe.closed)
        self.assertTrue(credential.killed)
        self.assertNotIn(reference, stderr.getvalue())

    def test_launcher_uses_only_reviewed_target_values(self):
        calls: list[list[str]] = []

        def popen(argv, **kwargs):
            calls.append(argv)
            return (
                FakeProcess(stdout=io.BytesIO())
                if len(calls) == 1
                else FakeProcess()
            )

        self.assertEqual(
            smoke.run_target("opencode-chat", dart=self.dart, popen=popen),
            0,
        )
        self.assertEqual(calls[1][-2:], ["--target", "opencode-chat"])
        self.assertNotIn("--prompt", calls[1])
        self.assertNotIn("--model", calls[1])
        self.assertNotIn("--output", calls[1])

    def test_unknown_target_is_rejected_before_any_process_starts(self):
        popen = mock.Mock()
        with self.assertRaisesRegex(ValueError, "Unknown smoke target"):
            smoke.run_target("custom", dart=self.dart, popen=popen)
        popen.assert_not_called()

    def test_keyless_ollama_starts_dart_without_op_or_credential_pipe(self):
        popen = mock.Mock(return_value=FakeProcess())
        self.assertEqual(
            smoke.run_target("ollama-responses", dart=self.dart, popen=popen),
            0,
        )
        popen.assert_called_once()
        argv = popen.call_args.args[0]
        self.assertEqual(argv[-2:], ["--target", "ollama-responses"])
        self.assertNotIn("op", argv)
        self.assertEqual(popen.call_args.kwargs["stdin"], smoke.subprocess.DEVNULL)

    def test_both_ollama_targets_run_without_config(self):
        self.config_path.unlink()
        popen = mock.Mock(return_value=FakeProcess())

        for target_id in ("ollama-chat", "ollama-responses"):
            with self.subTest(target_id=target_id):
                self.assertEqual(
                    smoke.run_target(target_id, dart=self.dart, popen=popen),
                    0,
                )

        self.assertEqual(popen.call_count, 2)
        for call, target_id in zip(
            popen.call_args_list,
            ("ollama-chat", "ollama-responses"),
        ):
            self.assertEqual(call.args[0][-2:], ["--target", target_id])
            self.assertEqual(call.kwargs["stdin"], smoke.subprocess.DEVNULL)

    def test_op_failure_stops_the_matrix(self):
        statuses = iter([FakeProcess(17, stdout=io.BytesIO()), FakeProcess(0)])
        popen = mock.Mock(side_effect=lambda *args, **kwargs: next(statuses))
        self.assertEqual(
            smoke.run(["anthropic-direct", "opencode-chat"], dart=self.dart, popen=popen),
            17,
        )
        self.assertEqual(popen.call_count, 2)

    def test_dart_failure_is_returned_when_credential_lookup_succeeds(self):
        statuses = iter([FakeProcess(0, stdout=io.BytesIO()), FakeProcess(9)])
        popen = mock.Mock(side_effect=lambda *args, **kwargs: next(statuses))
        self.assertEqual(
            smoke.run_target("opencode-responses", dart=self.dart, popen=popen),
            9,
        )

    def test_missing_pinned_dart_does_not_start_op(self):
        popen = mock.Mock()
        missing = self.dart.with_name("missing-dart")
        self.assertEqual(
            smoke.run_target("opencode-messages", dart=missing, popen=popen),
            2,
        )
        popen.assert_not_called()

    def test_missing_op_is_reported_without_starting_dart(self):
        popen = mock.Mock(side_effect=FileNotFoundError())
        self.assertEqual(
            smoke.run_target("anthropic-direct", dart=self.dart, popen=popen),
            2,
        )
        self.assertEqual(popen.call_count, 1)


if __name__ == "__main__":
    unittest.main()
