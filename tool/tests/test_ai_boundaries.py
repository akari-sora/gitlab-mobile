from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
AI_ROOT = ROOT / "lib" / "core" / "ai"
PORT = AI_ROOT / "tools" / "gitlab_read_port.dart"


class AiBoundaryTest(unittest.TestCase):
    def test_provider_uses_only_the_dependency_free_catalogue_version(self):
        source = (AI_ROOT / "ai_provider.dart").read_text(encoding="utf-8")
        self.assertNotRegex(source, r"(?:import|export)\s+'tools/tool_catalogue\.dart'")
        self.assertRegex(source, r"import\s+'tools/tool_catalogue_version\.dart'")
        self.assertRegex(source, r"export\s+'tools/tool_catalogue_version\.dart'")

    def test_catalogue_version_has_no_dependencies_and_remains_exported(self):
        version = AI_ROOT / "tools" / "tool_catalogue_version.dart"
        self.assertTrue(version.is_file(), "Catalogue version needs its own file")
        source = version.read_text(encoding="utf-8")
        self.assertNotRegex(source, r"(?m)^\s*(?:import|export|part)\b")
        self.assertRegex(source, r"const\s+aiToolCatalogueVersion\s*=\s*1\s*;")
        catalogue = (AI_ROOT / "tools" / "tool_catalogue.dart").read_text(
            encoding="utf-8"
        )
        self.assertRegex(catalogue, r"export\s+'tool_catalogue_version\.dart'")

    def test_only_read_port_imports_gitlab_api(self):
        importers = []
        for path in AI_ROOT.rglob("*.dart"):
            if "gitlab_api.dart" in path.read_text(encoding="utf-8"):
                importers.append(path.relative_to(ROOT).as_posix())
        self.assertEqual(importers, ["lib/core/ai/tools/gitlab_read_port.dart"])

    def test_read_port_calls_only_whitelisted_members(self):
        source = PORT.read_text(encoding="utf-8")
        members = self._api_members(source)
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

    def test_read_port_guard_catches_method_tear_offs(self):
        source = "final write = _api.writeRecord; await write();"
        self.assertEqual(self._api_members(source), {"writeRecord"})

    def test_read_port_guard_catches_cascade_calls(self):
        source = "_api..writeRecord(['projects', projectId]);"
        self.assertEqual(self._api_members(source), {"writeRecord"})

    def test_read_port_guard_catches_calls_through_aliases(self):
        source = "final api = _api; api.writeRecord(['projects', projectId]);"
        self.assertEqual(self._api_members(source), {"writeRecord"})

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

    @staticmethod
    def _api_members(source):
        receivers = {"_api"}
        aliases = re.compile(r"\b(?:final|var)\s+(\w+)\s*=\s*(\w+)\b")
        changed = True
        while changed:
            changed = False
            for alias, target in aliases.findall(source):
                if target in receivers and alias not in receivers:
                    receivers.add(alias)
                    changed = True
        members = set()
        for receiver in receivers:
            members.update(
                re.findall(rf"\b{re.escape(receiver)}(?:\.\.|\.)(\w+)\b", source)
            )
        return members


if __name__ == "__main__":
    unittest.main()
