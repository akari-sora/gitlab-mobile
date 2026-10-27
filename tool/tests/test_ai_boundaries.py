from pathlib import Path
import re
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
AI_ROOT = ROOT / "lib" / "core" / "ai"
PORT = AI_ROOT / "tools" / "gitlab_read_port.dart"
AI_FEATURE_ROOT = ROOT / "lib" / "features" / "ai"

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
GROUP_READ_PORT_MEMBERS = {"namespaceWorkItem"}

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

# 3t owns exactly these four opening/candidate reads and three ledger writes.
# Keep the original 35-member MR6b-3 contract intact.
_MR6B3T_WRITE_PORT_MEMBERS = {
    "workItemContent",
    "workItemActivityEditAccess",
    "workItemLabels",
    "workItemLabelCandidates",
    "updateWorkItemContent",
    "editWorkItemActivityNote",
    "updateWorkItemLabels",
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
} | _MR6B3_WRITE_PORT_MEMBERS | _MR6B3T_WRITE_PORT_MEMBERS

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
        self.assertEqual(self._read_port_violations(source), [])

    def test_read_port_class_and_escaping_fixtures(self):
        project = " ".join(f"_api.{name}();" for name in READ_PORT_MEMBERS)
        group = "_api.namespaceWorkItem();"
        def fixture(project_body=project, group_body=group, extra=""):
            return (f"final class GitLabAiReadPort {{ {project_body} }}\n"
                    f"final class GitLabAiGroupReadPort {{ {group_body} }}\n{extra}")

        self.assertEqual(self._read_port_violations(fixture()), [])
        for mutant in (
            fixture(project + " " + group, ""),
            fixture(group_body=group + " _api.record();"),
            fixture(extra="final class Foreign { void f() => _api.record(); }"),
            fixture(extra="void f() => _api.record();"),
            fixture(extra="void f() => helper(_api);"),
        ):
            with self.subTest(mutant=mutant):
                self.assertTrue(self._read_port_violations(mutant))

    def test_ai_namespace_reads_are_strict_and_not_torn_off(self):
        violations = []
        for root in (AI_ROOT, AI_FEATURE_ROOT):
            for path in root.rglob("*.dart"):
                violations.extend(
                    f"{path.relative_to(ROOT)}: {message}"
                    for message in self._namespace_read_violations(
                        path.read_text(encoding="utf-8")
                    )
                )
        self.assertEqual(violations, [])

    def test_namespace_guard_negative_fixtures(self):
        valid = "api.namespaceWorkItem(path, iid, expectedNamespaceId: id, strictIdentity: true)"
        self.assertEqual(self._namespace_read_violations(valid), [])
        self.assertEqual(self._namespace_read_violations(
            "// api.namespaceWorkItem\n api.namespaceWorkItemTypes();"
        ), [])
        self.assertEqual(self._namespace_read_violations(
            "/* outer /* api.namespaceWorkItem */ still comment */"
        ), [])
        for mutant in (
            "final read = api.namespaceWorkItem;",
            "api.namespaceWorkItem(path, iid, expectedNamespaceId: id)",
            "api.namespaceWorkItem(path, iid, expectedNamespaceId: id, strictIdentity: enabled)",
            "api.namespaceWorkItem(path, iid, expectedNamespaceId: id, strictIdentity: true && enabled)",
            "api.namespaceWorkItem(nested(expectedNamespaceId: id, strictIdentity: true), iid)",
            "api.namespaceWorkItem(path, iid, strictIdentity: true)",
            "'${api.namespaceWorkItem(path, iid)}'",
        ):
            with self.subTest(mutant=mutant):
                self.assertTrue(self._namespace_read_violations(mutant))

    def test_verified_group_identity_factory_has_restricted_producers(self):
        violations = []
        for path in (ROOT / "lib").rglob("*.dart"):
            source = path.read_text(encoding="utf-8")
            relative = path.relative_to(ROOT).as_posix()
            violations.extend(
                f"{relative}: {message}"
                for message in self._group_identity_factory_violations(relative, source)
            )
            violations.extend(
                f"{relative}: {message}"
                for message in self._group_port_actor_violations(relative, source)
            )
        self.assertEqual(violations, [])

    def test_verified_group_identity_factory_negative_fixtures(self):
        call = ("VerifiedGroupWorkItemIdentity.fromServerEvidence("
                "actorUserId: actorUserId)")
        port = "lib/core/ai/tools/gitlab_read_port.dart"
        controller = "lib/features/ai/ai_chat_controller.dart"
        core = "lib/core/work_item_graphql_api.dart"
        valid = f"final class GitLabAiGroupReadPort {{ void read() {{ {call}; }} }}"
        self.assertEqual(self._group_identity_factory_violations(port, valid), [])
        for path, mutant in (
            (controller, f"void read() {{ {call}; }}"),
            (port, f"void read() {{ {call}; }}"),
            (port, f"final class Foreign {{ void read() {{ {call}; }} }}"),
            (port, valid.replace("actorUserId: actorUserId", "actorUserId: scope.groupId")),
            (core, f"Future<void> namespaceWorkItem() async {{ {call}; }}"),
        ):
            with self.subTest(path=path, mutant=mutant):
                self.assertTrue(self._group_identity_factory_violations(path, mutant))
        self.assertEqual(self._group_identity_factory_violations(
            core, f"Future<void> namespaceWorkItem() async {{ if (strictIdentity) {{ {call}; }} }}"
        ), [])
        valid_wiring = "GitLabAiGroupReadPort(api, actorUserId: session.active!.user.id)"
        self.assertEqual(self._group_port_actor_violations(controller, valid_wiring), [])
        for mutant in (
            "GitLabAiGroupReadPort(api, actorUserId: scope.groupId)",
            "GitLabAiGroupReadPort(api, actorUserId: grant.actorUserId)",
            "GitLabAiGroupReadPort(api, actorUserId: grant.actorUserId); " + valid_wiring,
            "GitLabAiGroupReadPort(api, options(actorUserId: session.active!.user.id))",
        ):
            with self.subTest(mutant=mutant):
                self.assertTrue(self._group_port_actor_violations(controller, mutant))

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

    def test_freshness_prepared_merge_copies_every_field(self):
        source = (AI_ROOT / "tools" / "write_coordinator.dart").read_text(
            encoding="utf-8"
        )

        def field_difference(text):
            freshness = re.search(
                r"final class AiWriteFreshness \{(.*?)\n\}", text, re.DOTALL
            )
            merge = re.search(
                r"AiWriteFreshness _withPreparedFields\(.*?\) => "
                r"AiWriteFreshness\((.*?)\n\);", text, re.DOTALL
            )
            self.assertIsNotNone(freshness)
            self.assertIsNotNone(merge)
            fields = set(re.findall(
                r"(?m)^\s*final\s+[^;\n=]+?\s+(\w+);", freshness.group(1)
            ))
            constructor = re.search(
                r"\bAiWriteFreshness\(\{(.*?)\}\);", freshness.group(1), re.DOTALL
            )
            self.assertIsNotNone(constructor)
            self.assertEqual(
                len(re.findall(r"\bthis\.\w+", constructor.group(1))),
                len(fields),
                "AiWriteFreshness constructor/field count mismatch; check wrapped field declarations",
            )
            copied = set(re.findall(r"(?m)^\s*(\w+):", merge.group(1)))
            self.assertTrue(fields)
            for field in fields & copied:
                self.assertRegex(merge.group(1), rf"\bfresh\.{field}\b")
            return fields - copied, copied - fields

        self.assertEqual(field_difference(source), (set(), set()))
        # A new constructor-backed field must also be copied by the merge.
        mutant = source.replace(
            "this.updatedAt,", "this.futureField,\n    this.updatedAt,", 1
        ).replace(
            "final String? updatedAt;",
            "final String? futureField;\n  final String? updatedAt;", 1
        )
        self.assertEqual(field_difference(mutant), ({"futureField"}, set()))

    def test_ledger_named_methods_are_write_port_whitelisted(self):
        # Replacements for the removed exact-delta test: test_ledger_named_methods_are_write_port_whitelisted + test_row13_write_port_calls_only_whitelisted_members.
        self.assertTrue(_MR6B3T_WRITE_PORT_MEMBERS.isdisjoint(_MR6B3_WRITE_PORT_MEMBERS))
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
    def _code_only(source):
        """Mask comments and literal text, preserving interpolated Dart code."""
        masked = list(source)
        length = len(source)

        def hide(index):
            if source[index] != "\n":
                masked[index] = " "

        def string_at(index):
            quote = source[index]
            delimiter = quote * (3 if source.startswith(quote * 3, index) else 1)
            raw = index > 0 and source[index - 1] == "r"
            for offset in range(len(delimiter)):
                hide(index + offset)
            index += len(delimiter)
            while index < length:
                if source.startswith(delimiter, index):
                    for offset in range(len(delimiter)):
                        hide(index + offset)
                    return index + len(delimiter)
                if not raw and source.startswith("${", index):
                    hide(index)
                    hide(index + 1)
                    index = code_at(index + 2, interpolation=True)
                    continue
                if not raw and source[index] == "\\" and index + 1 < length:
                    hide(index)
                    hide(index + 1)
                    index += 2
                else:
                    hide(index)
                    index += 1
            return index

        def code_at(index, *, interpolation=False):
            braces = 0
            while index < length:
                if source.startswith("//", index):
                    while index < length and source[index] != "\n":
                        hide(index)
                        index += 1
                elif source.startswith("/*", index):
                    depth = 0
                    while index < length:
                        if source.startswith("/*", index):
                            hide(index)
                            hide(index + 1)
                            depth += 1
                            index += 2
                        elif source.startswith("*/", index):
                            hide(index)
                            hide(index + 1)
                            depth -= 1
                            index += 2
                            if depth == 0:
                                break
                        else:
                            hide(index)
                            index += 1
                elif source[index] in "'\"":
                    index = string_at(index)
                elif interpolation and source[index] == "}" and braces == 0:
                    hide(index)
                    return index + 1
                else:
                    if interpolation and source[index] == "{":
                        braces += 1
                    elif interpolation and source[index] == "}":
                        braces -= 1
                    index += 1
            return index

        code_at(0)
        return "".join(masked)

    @classmethod
    def _read_port_violations(cls, source):
        code = cls._code_only(source)
        classes = []
        for declaration in re.finditer(r"\bclass\s+(\w+)[^{]*\{", code):
            depth = 1
            end = declaration.end()
            while end < len(code) and depth:
                depth += (code[end] == "{") - (code[end] == "}")
                end += 1
            if depth:
                return ["unterminated class"]
            classes.append((declaration.group(1), declaration.start(), end))
        expected = {
            "GitLabAiReadPort": READ_PORT_MEMBERS,
            "GitLabAiGroupReadPort": GROUP_READ_PORT_MEMBERS,
        }
        violations = []
        for name, wanted in expected.items():
            matching = [(start, end) for found, start, end in classes if found == name]
            if len(matching) != 1:
                violations.append(f"expected one {name}")
            elif cls._api_members(source[matching[0][0]:matching[0][1]]) != wanted:
                violations.append(f"unexpected {name} API members")
        for name, start, end in classes:
            if name not in expected and (cls._api_members(source[start:end]) or
                                         re.search(r"\b(?:GitLabApi|_api)\b", code[start:end])):
                violations.append(f"API access in unknown class {name}")
        outside = list(source)
        for _, start, end in classes:
            outside[start:end] = " " * (end - start)
        outside = "".join(outside)
        if cls._api_members(outside) or re.search(r"\b(?:GitLabApi|_api)\b", cls._code_only(outside)):
            violations.append("API access outside concrete classes")
        if cls._api_members(source) != READ_PORT_MEMBERS | GROUP_READ_PORT_MEMBERS:
            violations.append("unexpected read-port API union")
        return violations

    @staticmethod
    def _brace_block(code, opening):
        depth = 1
        end = opening + 1
        while end < len(code) and depth:
            depth += (code[end] == "{") - (code[end] == "}")
            end += 1
        return (opening, end) if depth == 0 else None

    @staticmethod
    def _call_arguments(code, opening):
        if opening >= len(code) or code[opening] != "(":
            return None
        depth = 1
        end = opening + 1
        while end < len(code) and depth:
            depth += (code[end] == "(") - (code[end] == ")")
            end += 1
        if depth:
            return None
        args = code[opening + 1:end - 1]
        result = []
        start = nesting = 0
        for index, char in enumerate(args):
            if char in "([{":
                nesting += 1
            elif char in ")]}":
                nesting -= 1
            elif char == "," and nesting == 0:
                result.append(args[start:index].strip())
                start = index + 1
        result.append(args[start:].strip())
        return result

    @classmethod
    def _group_identity_factory_violations(cls, relative, source):
        code = cls._code_only(source)
        factory = re.compile(r"\bVerifiedGroupWorkItemIdentity\s*\.\s*fromServerEvidence\b")
        locations = list(factory.finditer(code))
        if not locations:
            return []
        allowed = []
        if relative == "lib/core/ai/tools/gitlab_read_port.dart":
            for match in re.finditer(r"\bclass\s+GitLabAiGroupReadPort\b[^{]*\{", code):
                block = cls._brace_block(code, match.end() - 1)
                if block:
                    allowed.append(block)
        elif relative == "lib/core/work_item_graphql_api.dart":
            for method in re.finditer(r"\bnamespaceWorkItem\s*\([\s\S]*?\)\s*async\s*\{", code):
                method_block = cls._brace_block(code, method.end() - 1)
                if not method_block:
                    continue
                for branch in re.finditer(r"\bif\s*\(\s*strictIdentity\s*\)\s*\{", code[method_block[0]:method_block[1]]):
                    block = cls._brace_block(code, method_block[0] + branch.end() - 1)
                    if block and block[1] <= method_block[1]:
                        allowed.append(block)
        violations = []
        for match in locations:
            if not any(start < match.start() < end for start, end in allowed):
                violations.append("group identity factory outside strict reader or group read class")
            opening = match.end()
            while opening < len(code) and code[opening].isspace():
                opening += 1
            args = cls._call_arguments(code, opening)
            if args is None:
                violations.append("group identity factory tear-off")
            elif not any(re.fullmatch(r"actorUserId\s*:\s*actorUserId", arg)
                         for arg in args):
                violations.append("group identity actor must be the session actor parameter")
        return violations

    @classmethod
    def _group_port_actor_violations(cls, relative, source):
        code = cls._code_only(source)
        violations = []
        for match in re.finditer(r"\bGitLabAiGroupReadPort\s*\(", code):
            if relative == "lib/core/ai/tools/gitlab_read_port.dart":
                args = cls._call_arguments(code, match.end() - 1)
                if (args and args[0] == "this._api" and
                    any(re.search(r"\brequired\s+this\.actorUserId\b", arg)
                        for arg in args)):
                    continue
                violations.append("group read port constructed outside controller")
                continue
            if relative != "lib/features/ai/ai_chat_controller.dart":
                violations.append("group read port constructed outside controller")
                continue
            args = cls._call_arguments(code, match.end() - 1) or []
            if not any(re.fullmatch(
                r"actorUserId\s*:\s*session\s*\.\s*active\s*!\s*\.\s*user\s*\.\s*id",
                arg,
            ) for arg in args):
                violations.append("group read port actor must come from the active session")
        return violations

    @classmethod
    def _namespace_read_violations(cls, source):
        code = cls._code_only(source)
        violations = []
        for match in re.finditer(r"\.namespaceWorkItem\b", code):
            tail = match.end()
            while tail < len(code) and code[tail].isspace():
                tail += 1
            if tail == len(code) or code[tail] != "(":
                violations.append("namespaceWorkItem tear-off")
                continue
            depth, end = 1, tail + 1
            while end < len(code) and depth:
                depth += (code[end] == "(") - (code[end] == ")")
                end += 1
            args = code[tail + 1:end - 1] if depth == 0 else ""
            arguments = []
            start = 0
            nesting = 0
            for index, char in enumerate(args):
                if char in "([{":
                    nesting += 1
                elif char in ")]}":
                    nesting -= 1
                elif char == "," and nesting == 0:
                    arguments.append(args[start:index].strip())
                    start = index + 1
            arguments.append(args[start:].strip())
            if not any(re.fullmatch(r"strictIdentity\s*:\s*true", arg)
                       for arg in arguments):
                violations.append("namespaceWorkItem requires literal strictIdentity: true")
            if not any(re.match(r"expectedNamespaceId\s*:", arg)
                       for arg in arguments):
                violations.append("namespaceWorkItem requires expectedNamespaceId")
        return violations

    @staticmethod
    def _write_port_sources(tools=None):
        tools = tools or AI_ROOT / "tools"
        main = tools / "gitlab_write_port.dart"
        sources = [(main, main.read_text(encoding="utf-8"), False)]
        part_pattern = re.compile(
            r"\bpart\s+of\s+['\"](?:[^'\"]*/)?gitlab_write_port\.dart['\"]\s*;"
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
