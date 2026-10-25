from pathlib import Path
import re
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
AI_ROOT = ROOT / "lib" / "core" / "ai"
PORT = AI_ROOT / "tools" / "gitlab_read_port.dart"

READ_PORT_MEMBERS = {
    "textFile",
    "tree",
    "cachedRecord",
    "cachedRecords",
    "record",
    "records",
    "jobTraceChunk",
    "commit",
    "commitDiff",
    "search",
    "snippetText",
}

_MR6B3_WRITE_PORT_MEMBERS = {
    "projectWorkItem",
    "workItemState",
    "workItemStatus",
    "workItemDates",
    "workItemHealthEdit",
    "workItemAssignees",
    "searchWorkItemAssigneeCandidates",
    "workItemMilestone",
    "workItemMilestoneChoices",
    "workItemWeight",
    "workItemActivityWriteAccess",
    "workItemActivity",
    "workItemActivityNext",
    "workItemDiscussionNotesNext",
    "workItemActivityDeleteAccess",
    "workItemActivityReactionAccess",
    "workItemNotifications",
    "incidentStatus",
    "pendingTodosForSnooze",
    "snoozedTodosForUnsnooze",
    "updateWorkItemState",
    "updateWorkItemStatus",
    "updateWorkItemDates",
    "updateWorkItemHealthStatus",
    "updateWorkItemAssignees",
    "updateWorkItemMilestone",
    "updateWorkItemWeight",
    "createWorkItemActivityComment",
    "createWorkItemActivityReply",
    "deleteWorkItemActivityNote",
    "setWorkItemActivityNoteReaction",
    "setWorkItemNotifications",
    "setIncidentStatus",
    "snoozeTodo",
    "unsnoozeTodo",
}

WRITE_PORT_MEMBERS = {
    "instance",
    "currentUser",
    "record",
    "records",
    "fileMetadata",
    "textFile",
    "snippetText",
    "projectSnippetSnapshot",
    "snippetBlob",
    "effectiveProjectAccess",
    "addAwardEmoji",
    "removeAwardEmoji",
    "setStar",
    "setSubscribed",
    "markTodoDone",
    "createNote",
    "updateNote",
    "createIssue",
    "updateIssue",
    "createMergeRequest",
    "updateMergeRequest",
    "unapproveMergeRequest",
    "createTodo",
    "createDiscussion",
    "createDiscussionNote",
    "updateDiscussionNote",
    "setDiscussionResolved",
    "createDraftNote",
    "updateDraftNote",
    "createLabel",
    "updateLabel",
    "createMilestone",
    "updateMilestone",
    "setMilestoneState",
    "createBoard",
    "renameBoard",
    "setBoardSystemListHidden",
    "createBoardList",
    "moveBoardList",
    "moveBoardCard",
    "uploadProjectFile",
    "createRepositoryFile",
    "updateRepositoryFile",
    "deleteFile",
    "applySuggestion",
    "batchApplySuggestions",
    "createBranch",
    "deleteBranch",
    "createTag",
    "deleteTag",
    "createRelease",
    "updateRelease",
    "deleteRelease",
    "mergeRequest",
    "approveMergeRequest",
    "rebaseMergeRequest",
    "cancelAutoMerge",
    "publishDraftNotes",
    "deleteDraftNote",
    "createPipeline",
    "pipelineAction",
    "jobAction",
    "playPipelineSchedule",
    "deletePipeline",
    "createSnippet",
    "updateSnippetMetadata",
    "updateSnippet",
    "updateSnippetFiles",
    "deleteSnippetFile",
    "deleteSnippet",
    "deleteNote",
    "deleteDiscussionNote",
    "deleteIssue",
    "deleteMergeRequest",
    "deleteLabel",
    "deleteMilestone",
    "deleteBoard",
    "deleteBoardList",
    "markAllTodosDone",
    "deletePackage",
    "deletePackageFile",
    "deleteContainerRepository",
    "deleteContainerTag",
    "createProject",
    "editProject",
    "deleteProject",
    "forkProject",
} | _MR6B3_WRITE_PORT_MEMBERS

GENERIC_CHANNELS = {
    "writeRecord",
    "removeRecord",
    "writeEmpty",
    "graphMutation",
    "_send",
}


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
        self.assertRegex(source, r"const\s+aiToolCatalogueVersion\s*=\s*4\s*;")
        catalogue = (AI_ROOT / "tools" / "tool_catalogue.dart").read_text(
            encoding="utf-8"
        )
        self.assertRegex(catalogue, r"export\s+'tool_catalogue_version\.dart'")

    def test_row13_only_read_and_write_ports_import_gitlab_api(self):
        importers = []
        for path in AI_ROOT.rglob("*.dart"):
            if "gitlab_api.dart" in path.read_text(encoding="utf-8"):
                importers.append(path.relative_to(ROOT).as_posix())
        self.assertEqual(sorted(importers), [
            "lib/core/ai/tools/gitlab_read_port.dart",
            "lib/core/ai/tools/gitlab_write_port.dart",
        ])

    def test_read_port_calls_only_whitelisted_members(self):
        source = PORT.read_text(encoding="utf-8")
        members = self._api_members(source)
        self.assertTrue(members)
        self.assertLessEqual(members, READ_PORT_MEMBERS)

    def test_read_port_whitelist_adds_exactly_snippet_text(self):
        previous_members = READ_PORT_MEMBERS - {"snippetText"}
        self.assertEqual(self._api_members("_api.snippetText(1, 2);"), {"snippetText"})
        self.assertNotIn("snippetText", previous_members)
        self.assertNotIn("projectSnippetSnapshot", READ_PORT_MEMBERS)

    def test_ai_cached_reads_refuse_disk_and_bound_age(self):
        source = PORT.read_text(encoding="utf-8")
        self.assertRegex(source, r"_aiMaxAge\s*=\s*Duration\(seconds:\s*60\)")
        self.assertRegex(source, r"cachedRecord\([\s\S]*?allowDisk:\s*false")
        self.assertRegex(source, r"cachedRecords\([\s\S]*?allowDisk:\s*false")
        self.assertRegex(source, r"lineage\s*==\s*CacheLineage\.disk")
        self.assertRegex(source, r"read\.dropped\s*\|\|\s*read\.superseded")

    def test_ai_typed_cache_reads_disable_disk(self):
        source = PORT.read_text(encoding="utf-8")
        self.assertRegex(source, r"textFile\([\s\S]*?allowDisk:\s*false")
        self.assertRegex(source, r"tree\([\s\S]*?allowDisk:\s*false")

    def test_row13_write_port_calls_only_whitelisted_members(self):
        sources = self._write_port_sources()
        members = set()
        violations = []
        for path, source, is_part in sources:
            members.update(self._api_members(source))
            violations.extend(
                f"{path.relative_to(ROOT)}: {violation}"
                for violation in self._write_port_violations(source, is_part=is_part)
            )
        self.assertTrue(members)
        self.assertLessEqual(members, WRITE_PORT_MEMBERS)
        self.assertEqual(violations, [])

    def test_mr6b3_write_port_whitelist_delta_is_exact(self):
        expected_reads = {
            "projectWorkItem",
            "workItemState",
            "workItemStatus",
            "workItemDates",
            "workItemHealthEdit",
            "workItemAssignees",
            "searchWorkItemAssigneeCandidates",
            "workItemMilestone",
            "workItemMilestoneChoices",
            "workItemWeight",
            "workItemActivityWriteAccess",
            "workItemActivity",
            "workItemActivityNext",
            "workItemDiscussionNotesNext",
            "workItemActivityDeleteAccess",
            "workItemActivityReactionAccess",
            "workItemNotifications",
            "incidentStatus",
            "pendingTodosForSnooze",
            "snoozedTodosForUnsnooze",
        }
        expected_writes = {
            "updateWorkItemState",
            "updateWorkItemStatus",
            "updateWorkItemDates",
            "updateWorkItemHealthStatus",
            "updateWorkItemAssignees",
            "updateWorkItemMilestone",
            "updateWorkItemWeight",
            "createWorkItemActivityComment",
            "createWorkItemActivityReply",
            "deleteWorkItemActivityNote",
            "setWorkItemActivityNoteReaction",
            "setWorkItemNotifications",
            "setIncidentStatus",
            "snoozeTodo",
            "unsnoozeTodo",
        }
        self.assertEqual(_MR6B3_WRITE_PORT_MEMBERS, expected_reads | expected_writes)
        self.assertEqual(len(expected_reads), 20)
        self.assertEqual(len(expected_writes), 15)
        self.assertEqual(len(_MR6B3_WRITE_PORT_MEMBERS), 35)
        self.assertNotIn("namespaceWorkItem", WRITE_PORT_MEMBERS)
        self.assertNotIn("snoozedTodos", WRITE_PORT_MEMBERS)
        self.assertTrue(
            {"updateWorkItemContent", "editWorkItemActivityNote", "updateWorkItemLabels"}
            .isdisjoint(WRITE_PORT_MEMBERS)
        )

    def test_ledger_named_methods_are_write_port_whitelisted(self):
        methods = set()
        paths = [AI_ROOT / "tools" / "write_ledger.dart"]
        paths.extend(sorted((AI_ROOT / "tools" / "ledger").glob("rows_*.dart")))
        row_pattern = re.compile(
            r"AiCapability\(\s*operationId:\s*'([^']+)'"
            r"((?:(?!AiCapability\().)*)",
            re.DOTALL,
        )
        for path in paths:
            source = path.read_text(encoding="utf-8")
            for operation_id, body in row_pattern.findall(source):
                named = re.search(r"\bnamedMethod:\s*'([^']+)'", body)
                methods.add(named.group(1) if named else operation_id)
        self.assertTrue(methods)
        self.assertLessEqual(methods, WRITE_PORT_MEMBERS)

    def test_write_port_guard_catches_part_alias_and_type_declaration(self):
        source = "final alias = _api; final GitLabApi escaped = alias;"
        self.assertEqual(
            self._write_port_violations(source, is_part=True),
            ["part declares GitLabApi", "part uses _api without member access"],
        )

    def test_write_port_guard_catches_api_passed_as_argument(self):
        for source in (
            "helper(_api);",
            "helper(api: _api);",
            "helper(<Object>[_api]);",
        ):
            with self.subTest(source=source):
                self.assertIn(
                    "part uses _api without member access",
                    self._write_port_violations(source, is_part=True),
                )

    def test_write_port_guard_catches_generic_channels_anywhere(self):
        for channel in sorted(GENERIC_CHANNELS):
            with self.subTest(channel=channel):
                source = f"// escape attempt: {channel}"
                self.assertEqual(
                    self._write_port_violations(source, is_part=False),
                    [f"uses generic channel {channel}"],
                )

    def test_write_port_guard_catches_gitlab_api_text_in_parts(self):
        source = "// ../../gitlab_api.dart"
        self.assertEqual(
            self._write_port_violations(source, is_part=True),
            ["part contains gitlab_api.dart"],
        )

    def test_write_port_discovery_finds_arbitrary_nested_part_files(self):
        with tempfile.TemporaryDirectory() as directory:
            tools = Path(directory)
            (tools / "gitlab_write_port.dart").write_text("", encoding="utf-8")
            nested = tools / "nested"
            nested.mkdir()
            part = nested / "arbitrary_name.dart"
            part.write_text(
                "part of 'gitlab_write_port.dart';\n",
                encoding="utf-8",
            )
            sources = self._write_port_sources(tools)
        self.assertEqual(
            [(path.relative_to(tools).as_posix(), is_part) for path, _, is_part in sources],
            [
                ("gitlab_write_port.dart", False),
                ("nested/arbitrary_name.dart", True),
            ],
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

    @staticmethod
    def _write_port_sources(tools=None):
        tools = tools or AI_ROOT / "tools"
        main = tools / "gitlab_write_port.dart"
        sources = [(main, main.read_text(encoding="utf-8"), False)]
        part_pattern = re.compile(
            r"\bpart\s+of\s+['\"]gitlab_write_port\.dart['\"]\s*;"
        )
        for path in sorted(tools.rglob("*.dart")):
            if path == main:
                continue
            source = path.read_text(encoding="utf-8")
            if part_pattern.search(source):
                sources.append((path, source, True))
        return sources

    @staticmethod
    def _write_port_violations(source, *, is_part):
        violations = []
        for channel in sorted(GENERIC_CHANNELS):
            if re.search(rf"\b{re.escape(channel)}\b", source):
                violations.append(f"uses generic channel {channel}")
        if not is_part:
            return violations
        if re.search(r"\bGitLabApi\b", source):
            violations.append("part declares GitLabApi")
        if re.search(r"\bgitlab_api\.dart\b", source):
            violations.append("part contains gitlab_api.dart")
        if re.search(r"\b_api\b(?!\s*\.)", source):
            violations.append("part uses _api without member access")
        return violations


if __name__ == "__main__":
    unittest.main()
