from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
RUNNER = ROOT / "lib" / "core" / "ai" / "runner.dart"


class AiRunnerContractTest(unittest.TestCase):
    def test_cancel_active_is_required_without_close_fallback(self):
        source = RUNNER.read_text(encoding="utf-8")
        self._assert_cancel_active_contract(source)

    def test_mr4_ledger_has_only_repository_evidence_or_not_run(self):
        source = (ROOT / "docs" / "V0_6_AI_VERIFICATION.md").read_text(encoding="utf-8")
        section = source[source.index("The submitted MR4 base"):]
        self.assertIn("cdbfc63", section)
        self.assertIn("test/ai/fix2_plain_text_test.dart", section)
        self.assertIn("**NOT_RUN**", section)
        for outside_evidence in ("mutation-scripts/", "RESULT-fix1.md", "/Users/", "/tmp/"):
            self.assertNotIn(outside_evidence, section)

    def test_close_fallback_mutation_breaks_contract(self):
        source = RUNNER.read_text(encoding="utf-8")
        mutated = source.replace(
            "_cancelActive = cancelActive,",
            "_cancelActive = cancelActive ?? close,",
        ).replace(
            "_cancelActive = cancelActive;",
            "_cancelActive = cancelActive ?? close;",
        )
        with self.assertRaises(AssertionError):
            self._assert_cancel_active_contract(mutated)

    def _assert_cancel_active_contract(self, source):
        constructor = self._parameters(source, "AiRunner")
        replacement = self._parameters(source, "replaceKeyRecipient")

        required_declaration = "required void Function() cancelActive"
        self.assertIn(required_declaration, constructor)
        self.assertIn(required_declaration, replacement)
        self.assertEqual(
            len(re.findall(r"_cancelActive\s*=\s*cancelActive[,;]", source)),
            2,
        )
        self.assertNotRegex(source, r"_cancelActive\s*=\s*cancelActive\s*\?\?")

    @staticmethod
    def _parameters(source, method):
        match = re.search(
            rf"\b{method}\s*\(\{{(?P<body>.*?)\n\s*\}}\)",
            source,
            re.DOTALL,
        )
        if match is None:
            raise AssertionError(f"Could not find {method} named parameters")
        return match.group("body")


if __name__ == "__main__":
    unittest.main()
