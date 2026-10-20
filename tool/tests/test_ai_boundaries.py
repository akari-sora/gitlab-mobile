from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
AI_ROOT = ROOT / "lib" / "core" / "ai"
PORT = AI_ROOT / "tools" / "gitlab_read_port.dart"


class AiBoundaryTest(unittest.TestCase):
    def test_only_read_port_imports_gitlab_api(self):
        importers = []
        for path in AI_ROOT.rglob("*.dart"):
            if "gitlab_api.dart" in path.read_text(encoding="utf-8"):
                importers.append(path.relative_to(ROOT).as_posix())
        self.assertEqual(importers, ["lib/core/ai/tools/gitlab_read_port.dart"])

    def test_read_port_calls_only_whitelisted_members(self):
        source = PORT.read_text(encoding="utf-8")
        members = set(re.findall(r"\b_api\.(\w+)\s*\(", source))
        self.assertTrue(members)
        self.assertLessEqual(
            members,
            {
                "textFile",
                "tree",
                "record",
                "records",
                "jobTraceChunk",
                "commit",
                "commitDiff",
                "search",
            },
        )

    def test_generic_reads_start_at_the_bound_project(self):
        source = PORT.read_text(encoding="utf-8")
        calls = list(re.finditer(r"\b_api\.(?:record|records)\s*\(", source))
        self.assertTrue(calls)
        for call in calls:
            tail = source[call.end() : call.end() + 160]
            compact = re.sub(r"\s+", "", tail)
            self.assertTrue(
                compact.startswith("['projects','$projectId',"),
                msg=tail,
            )

    def test_ai_core_has_no_credentials_or_debug_output(self):
        forbidden = re.compile(
            r"\b(?:accessToken|refreshToken|credential|PatCredential|"
            r"OAuthCredential|LogInterceptor)\b|\bprint\s*\("
        )
        findings = []
        for path in AI_ROOT.rglob("*.dart"):
            source = path.read_text(encoding="utf-8")
            for number, line in enumerate(source.splitlines(), start=1):
                code = re.sub(r"(?:r)?'''[^']*'''|(?:r)?\"\"\"[^\"]*\"\"\"", "", line)
                code = re.sub(r"(?:r)?'(?:\\.|[^'\\])*'", "", code)
                code = re.sub(r'(?:r)?"(?:\\.|[^"\\])*"', "", code)
                code = code.split("//", 1)[0]
                if forbidden.search(code):
                    findings.append(f"{path.relative_to(ROOT)}:{number}:{line}")
        self.assertEqual(findings, [])


if __name__ == "__main__":
    unittest.main()
