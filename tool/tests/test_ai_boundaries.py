from pathlib import Path
import re
import tempfile
import unittest
from urllib.parse import unquote, urlsplit


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

# Frozen from 574e406: two tokens before and three after every code-only _api.
# Preserve order and duplicates; changing API use requires reviewing this list.
# This list locks local token sequences, not call-site identity.
READ_PORT_API_OCCURRENCES = {
    "GitLabAiReadPort": [
        "this . _api , this .",
        "final GitLabApi _api ; final int",
        ") => _api . record (",
        ") => _api . record (",
        ") => _api . record (",
        ") => _api . snippetText (",
        ") => _api . record (",
        ") => _api . snippetText (",
        ") => _api . textFile (",
        ") => _api . tree (",
        ") => _api . cachedRecord (",
        ") => _api . cachedRecord (",
        ") => _api . cachedRecords (",
        ") => _api . cachedRecords (",
        ") => _api . records (",
        ") => _api . jobTraceChunk (",
        ") => _api . commit (",
        ") => _api . commitDiff (",
        ") => _api . search (",
    ],
    "GitLabAiGroupReadPort": [
        "this . _api , { required",
        "final GitLabApi _api ; final GitLabInstance",
        "= await _api . namespaceWorkItem (",
        "apiOwner : _api , generation :",
    ],
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
    "captureGroupReadEpoch",
    "isClosed",
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
} | _MR6B3_WRITE_PORT_MEMBERS | _MR6B3T_WRITE_PORT_MEMBERS | {"namespaceWorkItem"}

MAIN_WRITE_PORT_MEMBERS = {
    'captureGroupReadEpoch',
    'isClosed',
    'addAwardEmoji',
    'createBoard',
    'createBoardList',
    'createDiscussion',
    'createDiscussionNote',
    'createDraftNote',
    'createIssue',
    'createLabel',
    'createMergeRequest',
    'createMilestone',
    'createNote',
    'createTodo',
    'currentUser',
    'instance',
    'markTodoDone',
    'moveBoardCard',
    'moveBoardList',
    'record',
    'records',
    'removeAwardEmoji',
    'renameBoard',
    'setBoardSystemListHidden',
    'setDiscussionResolved',
    'setMilestoneState',
    'setStar',
    'setSubscribed',
    'unapproveMergeRequest',
    'updateDiscussionNote',
    'updateDraftNote',
    'updateIssue',
    'updateLabel',
    'updateMergeRequest',
    'updateMilestone',
    'updateNote',
    'uploadProjectFile',
}

NON_GRAPH_WRITE_PORT_MEMBERS = {
    'applySuggestion',
    'approveMergeRequest',
    'batchApplySuggestions',
    'cancelAutoMerge',
    'createBranch',
    'createPipeline',
    'createProject',
    'createRelease',
    'createRepositoryFile',
    'createSnippet',
    'createTag',
    'currentUser',
    'deleteBoard',
    'deleteBoardList',
    'deleteBranch',
    'deleteContainerRepository',
    'deleteContainerTag',
    'deleteDiscussionNote',
    'deleteDraftNote',
    'deleteFile',
    'deleteIssue',
    'deleteLabel',
    'deleteMergeRequest',
    'deleteMilestone',
    'deleteNote',
    'deletePackage',
    'deletePackageFile',
    'deletePipeline',
    'deleteProject',
    'deleteRelease',
    'deleteSnippet',
    'deleteSnippetFile',
    'deleteTag',
    'editProject',
    'effectiveProjectAccess',
    'fileMetadata',
    'forkProject',
    'instance',
    'jobAction',
    'markAllTodosDone',
    'mergeRequest',
    'pipelineAction',
    'playPipelineSchedule',
    'publishDraftNotes',
    'rebaseMergeRequest',
    'record',
    'records',
    'snippetText',
    'textFile',
    'updateRelease',
    'updateRepositoryFile',
    'updateSnippet',
    'updateSnippetFiles',
    'updateSnippetMetadata',
}

GROUP_FAMILY_STAGES = {
    'state': ('state', 'groupStateStageOperations', {'updateGroupWorkItemState'}, {'workItemState', 'updateWorkItemState'}),
    'status': ('status', 'groupStatusStageOperations', {'updateGroupWorkItemStatus'}, {'updateWorkItemStatus', 'workItemStatus'}),
    'dates': ('dates', 'groupDatesStageOperations', {'updateGroupWorkItemDates'}, {'workItemDates', 'updateWorkItemDates'}),
    'health': ('health', 'groupHealthStageOperations', {'updateGroupWorkItemHealthStatus'}, {'updateWorkItemHealthStatus', 'workItemHealthEdit'}),
    'assignees': ('assignees', 'groupAssigneesStageOperations', {'updateGroupWorkItemAssignees'}, {'searchWorkItemAssigneeCandidates', 'updateWorkItemAssignees', 'workItemAssignees'}),
    'milestone_weight': ('milestone_weight', 'groupMilestoneWeightStageOperations', {'updateGroupWorkItemWeight', 'updateGroupWorkItemMilestone'}, {'workItemWeight', 'workItemMilestone', 'updateWorkItemWeight', 'updateWorkItemMilestone', 'workItemMilestoneChoices'}),
    'activity_create': ('activity_create', 'groupActivityCreateStageOperations', {'createGroupWorkItemActivityComment', 'createGroupWorkItemActivityReply'}, {'workItemDiscussionNotesNext', 'createWorkItemActivityReply', 'workItemActivityWriteAccess', 'workItemActivityNext', 'workItemActivity', 'createWorkItemActivityComment'}),
    'activity_delete': ('activity_delete', 'groupActivityDeleteStageOperations', {'deleteGroupWorkItemActivityNote'}, {'workItemDiscussionNotesNext', 'workItemActivityDeleteAccess', 'deleteWorkItemActivityNote', 'workItemActivityNext', 'workItemActivity'}),
    'reactions_notifications': ('t1', 'groupT1StageOperations', {'setGroupWorkItemNotifications', 'setGroupWorkItemActivityNoteReaction'}, {'workItemDiscussionNotesNext', 'setWorkItemNotifications', 'workItemNotifications', 'setWorkItemActivityNoteReaction', 'workItemActivityReactionAccess', 'workItemActivityNext', 'workItemActivity'}),
    'content': ('content', 'groupContentStageOperations', {'updateGroupWorkItemContent'}, {'updateWorkItemContent', 'workItemContent'}),
    'activity_edit': ('activity_edit', 'groupActivityEditStageOperations', {'editGroupWorkItemActivityNote'}, {'workItemDiscussionNotesNext', 'workItemActivityNext', 'editWorkItemActivityNote', 'workItemActivity', 'workItemActivityEditAccess'}),
    'labels': ('labels', 'groupLabelsStageOperations', {'updateGroupWorkItemLabels'}, {'updateWorkItemLabels', 'workItemLabels', 'workItemLabelCandidates'}),
}

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
        fixture = self._read_port_fixture
        self.assertEqual(self._read_port_violations(fixture()), [])
        for mutant, expected in (
            (fixture(project="_api.namespaceWorkItem();").replace(
                "await _api.namespaceWorkItem(", "await other.namespaceWorkItem(", 1),
             "unexpected GitLabAiReadPort API members"),
            (fixture(group="_api.record();"), "unexpected GitLabAiGroupReadPort API members"),
            (fixture(extra="final class Foreign { void f() => _api.record(); }"),
             "API access in unknown class Foreign"),
            (fixture(extra="void f() => _api.record();"), "API access outside concrete classes"),
            (fixture(extra="void f() => helper(_api);"), "API access outside concrete classes"),
        ):
            with self.subTest(mutant=mutant):
                self.assertIn(expected, self._read_port_violations(mutant))

        # Each attack is placed in each known concrete class.  Keep its normal
        # calls intact so rejection cannot come merely from a changed member set.
        attacks = (
            ("void f() { final GitLabApi other = _api; other.record(); }",
             ("unexpected _api reference", "unexpected GitLabApi reference")),
            ("void f() { (_api).record(); }", ("unexpected _api reference",)),
            ("GitLabApi get _g => _api; void f() { _g.record(); }",
             ("unexpected _api reference", "unexpected GitLabApi reference")),
            ("static void _peek(GitLabApi api) { api.record(); } void f() { _peek(_api); }",
             ("unexpected _api reference", "unexpected GitLabApi reference")),
            ("void f() { (_api as dynamic).record(); }",
             ("unexpected _api reference", "dynamic cast")),
            ("void f() { helper(_api); }", ("unexpected _api reference",)),
        )
        for attack, rules in attacks:
            for target in ("project", "group"):
                mutant = fixture(
                    project=attack if target == "project" else "",
                    group=attack if target == "group" else "",
                    extra="void helper(api) { api.record(); }",
                )
                with self.subTest(attack=attack, target=target):
                    name = "GitLabAiReadPort" if target == "project" else "GitLabAiGroupReadPort"
                    for rule in rules:
                        self.assertIn(f"{rule} in {name}", self._read_port_violations(mutant))

        for target, name in (("project", "GitLabAiReadPort"),
                             ("group", "GitLabAiGroupReadPort")):
            for suffix in ("", ".named"):
                declaration = f"{name}{suffix}(this._api); final GitLabApi _api;"
                # Retain the formal-parameter rule's positive coverage. Extra
                # constructors/fields now also require a frozen-snapshot edit.
                body = f"class {name} {{ {declaration} }}"
                wanted = READ_PORT_MEMBERS if target == "project" else GROUP_READ_PORT_MEMBERS
                with self.subTest(name=name, suffix=suffix):
                    self.assertEqual(self._read_port_token_violations(name, body, wanted), [])
                    self.assertIn(f"unexpected {name} API occurrence snapshot",
                                  self._read_port_violations(fixture(**{target: declaration})))
                for attack in (f"final escaped = {name}{suffix}(this._api);",
                               f"void f() {{ {name}{suffix}(this._api); }}"):
                    mutant = fixture(**{target: attack})
                    with self.subTest(name=name, suffix=suffix, attack=attack):
                        self.assertIn(f"unexpected _api reference in {name}",
                                      self._read_port_violations(mutant))

        for attack, rule in (
            ("void f() { helper(apiOwner: _api); }", "unexpected _api reference"),
            ("void f() { helper(this._api); }", "unexpected _api reference"),
            ("void f() { (_api as dynamic); }", "dynamic cast"),
            ("GitLabApi get _g => throw 0;", "unexpected GitLabApi reference"),
            ("void f() { GitLabApi.other; }", "unexpected GitLabApi reference"),
            ("void f() { final GitLabApi _api; }", "unexpected GitLabApi reference"),
        ):
            with self.subTest(attack=attack):
                self.assertIn(f"{rule} in GitLabAiGroupReadPort",
                              self._read_port_violations(fixture(group=attack)))

        factory = ("Future<void> workItem() async { "
                   "VerifiedGroupWorkItemIdentity.fromServerEvidence(apiOwner: _api); }")
        self.assertEqual(self._read_port_token_violations(
            "GitLabAiGroupReadPort", f"class GitLabAiGroupReadPort {{ {factory} }}",
            GROUP_READ_PORT_MEMBERS,
        ), [])
        for mutant in (
            fixture().replace("apiOwner: _api", "apiOwner: helper(_api)"),
            fixture(group="void f() { helper(apiOwner: _api); }"),
            fixture().replace("workItem(\n    AiGroupResourceScope scope,",
                              "otherMethod(\n    AiGroupResourceScope scope,"),
            fixture(group=factory.replace("workItem", "workItem2")),
        ):
            with self.subTest(mutant=mutant):
                self.assertIn("unexpected _api reference in GitLabAiGroupReadPort",
                              self._read_port_violations(mutant))

        self.assertIn("unexpected _api reference in GitLabAiGroupReadPort",
                      self._read_port_violations(fixture(group=" '$_api';")))
        self.assertEqual(self._read_port_violations(fixture(group=" r'$_api';")), [])

    def test_read_port_line_comment_endings_in_unnormalized_source(self):
        original = PORT.read_bytes()
        marker = b"  final int projectId;\n"
        self.assertEqual(original.count(marker), 1)
        attack = "  Future<Object?> escaped() => _api.writeRecord('POST', const ['projects'], const {});"
        for ending in ("\r", "\r\n", "\n"):
            for comment in ("//", "///"):
                additions = (
                    f"  {comment} bait{ending}{attack}\n",
                    "  String escaped() => '${" + comment + " bait" + ending +
                    "_api.writeRecord('POST', const ['projects'], const {})}';\n",
                )
                for addition in additions:
                    # Decode bytes directly: Path.read_text would normalize CR.
                    source = original.replace(marker, marker + addition.encode("utf-8"), 1).decode("utf-8")
                    with self.subTest(ending=repr(ending), addition=addition):
                        self.assertIn(addition, source)
                        code = self._code_only(source)
                        self.assertEqual(len(code), len(source))
                        self.assertEqual(code.count("\r"), source.count("\r"))
                        violations = self._read_port_violations(source)
                        self.assertIn("unexpected _api reference in GitLabAiReadPort", violations)
                        self.assertIn("unexpected GitLabAiReadPort API occurrence snapshot", violations)

    def test_read_port_cr_stays_inside_literals_and_block_comments(self):
        bait = "before\r_api.writeRecord dynamic apiOwner\r\nafter"
        for quote in ("'''", '"""'):
            for prefix in ("", "r"):
                addition = f"String bait() => {prefix}{quote}{bait}{quote};"
                with self.subTest(addition=addition):
                    self.assertEqual(self._read_port_violations(
                        self._read_port_fixture(project=addition)), [])
        for addition in (
            "/* outer\r /* _api.writeRecord */\r\n dynamic apiOwner */",
            "String bait() => r'''before\r${_api.writeRecord()}\r\nafter''';",
            "String bait() => '''before\\'''\r_api.writeRecord\r\nafter''';",
        ):
            with self.subTest(addition=addition):
                self.assertEqual(self._read_port_violations(
                    self._read_port_fixture(project=addition)), [])

    def test_read_port_ignores_top_level_comment_and_raw_string_api_bait(self):
        for addition in ("// _api.namespaceWorkItem", "const bait = r'_api.namespaceWorkItem';"):
            with self.subTest(addition=addition):
                self.assertEqual(self._read_port_violations(
                    self._read_port_fixture(extra=addition)), [])

    def test_read_port_snapshot_rejects_opus_smuggling_with_normal_members(self):
        ns = ("namespaceWorkItem('a/b', 1, expectedNamespaceId: 'gid://gitlab/Group/1', "
              "strictIdentity: true)")
        shapes = {
            "G1": ("group", f"void f() {{ _api..{ns}..group(7); }}"),
            "G2": ("group", f"Future<Object?> f() => (_api..{ns}).group(7);"),
            "G3": ("group", f"Future<Object?> f() async {{ final (api, _) = (_api..{ns}, 0); "
                              "return api.group(7); }"),
            "G4": ("group", f"late final _leaked = (_api..{ns}); "
                              "Future<Object?> f() => _leaked.group(7);"),
            "G5": ("group", f"late final _getter = () => _api..{ns}; "
                              "Future<Object?> f() => _getter().group(7);"),
            "G6": ("group", "Future<Object?> f() async { "
                              "final dynamic owner = _verifiedIdentity?.apiOwner; "
                              "return owner?.currentUser(); }"),
            "P1": ("project", "void f() { _api..record(const ['x'])"
                                "..writeRecord('POST', const ['projects'], const {}); }"),
            "P2": ("project", "Future<Object?> f() => (_api..record)"
                                ".writeRecord('POST', const ['projects'], const {});"),
            "P3": ("project", "void f() => _leakHelper(_api..record);"),
        }
        for name, (target, attack) in shapes.items():
            extra = ("void _leakHelper(dynamic api) => "
                     "api.writeRecord('POST', const ['projects'], const {});"
                     if name == "P3" else "")
            mutant = self._read_port_fixture(**{target: attack}, extra=extra)
            with self.subTest(shape=name):
                violations = self._read_port_violations(mutant)
                self.assertEqual(self._api_members(self._code_only(mutant)),
                                 READ_PORT_MEMBERS | GROUP_READ_PORT_MEMBERS)
                self.assertFalse(any("API members" in v or "API union" in v for v in violations))
                if name == "G6":
                    self.assertIn("dynamic keyword in read port", violations)
                    self.assertIn("unexpected apiOwner occurrence in read port", violations)
                    self.assertFalse(any("snapshot" in v for v in violations))
                else:
                    class_name = "GitLabAiGroupReadPort" if target == "group" else "GitLabAiReadPort"
                    self.assertIn(f"unexpected {class_name} API occurrence snapshot", violations)
                    self.assertIn("API cascade in read port", violations)

    def test_read_port_snapshot_and_file_wide_rules(self):
        source = self._read_port_fixture()
        for mutant in (
            self._read_port_fixture(project="void f() => _api.record(const ['x']);"),
            source.replace("await _api.namespaceWorkItem(", "await other.namespaceWorkItem(", 1),
            source.replace("_api.commit(projectId, sha)", "_api.commit.call(projectId, sha)", 1),
            source.replace("_api.commit(projectId, sha)", "_api.search(projectId, sha)", 1)
                  .replace("_api.search(scope, query,", "_api.commit(scope, query,", 1),
        ):
            with self.subTest(mutant=mutant):
                self.assertTrue(any("snapshot" in v for v in self._read_port_violations(mutant)))
        for extra, expected in (
            ("void f() => _api?..record();", "API cascade in read port"),
            ("typedef X = dynamic;", "dynamic keyword in read port"),
            ("List<dynamic> values = [];", "dynamic keyword in read port"),
            ("void f(dynamic value) {}", "dynamic keyword in read port"),
            ("Object? f(Object value) => value.apiOwner;", "unexpected apiOwner occurrence in read port"),
            ("Object? f(Object? value) => value?.apiOwner;", "unexpected apiOwner occurrence in read port"),
            ("void f({Object? apiOwner}) {}", "unexpected apiOwner occurrence in read port"),
        ):
            with self.subTest(extra=extra):
                self.assertIn(expected, self._read_port_violations(source + extra))
        self.assertEqual(self._read_port_violations(self._read_port_fixture(
            group="// _api..record(); dynamic apiOwner\n"
                  "/* typedef X = dynamic; */ r'_api?..record(); dynamic .apiOwner';",
        )), [])

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
        write_port = "lib/core/ai/tools/gitlab_write_port.dart"
        write_valid = ("Future<void> _resolveGroupWorkItem() async { _api.instance; "
                       "await _api.namespaceWorkItem(path, iid, expectedNamespaceId: id, strictIdentity: true); " + call + "; }")
        self.assertEqual(self._group_identity_factory_violations(write_port, write_valid), [])
        for mutant in (write_valid + "void other() { " + call + "; }",
                       write_valid.replace("_api.instance;", "_api.instance; " + call + ";"),
                       write_valid.replace("strictIdentity: true", "strictIdentity: false"),
                       write_valid.replace("actorUserId: actorUserId", "actorUserId: grant.groupId")):
            self.assertTrue(self._group_identity_factory_violations(write_port, mutant))
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

    def test_group_scope_construction_has_restricted_producers(self):
        violations = []
        for path in (ROOT / "lib").rglob("*.dart"):
            relative = path.relative_to(ROOT).as_posix()
            violations.extend(
                f"{relative}: {message}"
                for message in self._group_scope_construction_violations(
                    relative, path.read_text(encoding="utf-8")
                )
            )
        self.assertEqual(violations, [])

    def test_group_scope_construction_negative_fixtures(self):
        other = "lib/features/ai/ai_chat_controller.dart"
        construct = "AiGroupResourceScope(accountKey: key)"
        for allowed in (
            "lib/core/ai/tools/tool_scope.dart",
            "lib/features/ai/ai_chat_context.dart",
            "test/ai/group_scope_test.dart",  # Test construction is exempt.
        ):
            self.assertEqual(self._group_scope_construction_violations(allowed, construct), [])
        for mutant in (
            construct,
            "const AiGroupResourceScope(accountKey: key)",
            "final create = AiGroupResourceScope.new;",
            "factory Alias() = AiGroupResourceScope;",
            "final create = scopes.AiGroupResourceScope.new;",
            "'${AiGroupResourceScope(accountKey: key)}'",
        ):
            with self.subTest(mutant=mutant):
                self.assertTrue(self._group_scope_construction_violations(other, mutant))
        self.assertEqual(self._group_scope_construction_violations(
            other, "AiGroupResourceScope? scope; // AiGroupResourceScope()\n'no AiGroupResourceScope()';"
        ), [])
        self.assertTrue(self._group_scope_construction_violations(
            "lib/core/ai/tools/gitlab_read_port.dart", construct))
        for producer in ("lib/core/ai/tools/tool_scope.dart",
                         "lib/features/ai/ai_chat_context.dart", other):
            for alias in ("typedef S = AiGroupResourceScope;",
                          "typedef S = scopes.AiGroupResourceScope;"):
                with self.subTest(producer=producer, alias=alias):
                    self.assertTrue(self._group_scope_construction_violations(producer, alias))
            self.assertEqual(self._group_scope_construction_violations(
                producer, "// typedef S = AiGroupResourceScope;\n'no typedef S = AiGroupResourceScope;';"), [])

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

    def test_g0e_write_port_exact_categories_and_resolver(self):
        sources = self._write_port_sources()
        main = sources[0][1]
        self.assertEqual(self._api_members(self._code_only(main)), MAIN_WRITE_PORT_MEMBERS | {"namespaceWorkItem"})
        self.assertEqual(self._namespace_write_violations(main, is_main=True), [])
        graph, non_graph = set(), set()
        for path, source, _ in sources[1:]:
            name = path.name
            members = self._api_members(self._code_only(source))
            self.assertEqual(self._namespace_write_violations(source, is_main=False), [], name)
            if name.startswith("gitlab_write_port_group_"):
                family = name.removeprefix("gitlab_write_port_group_").removesuffix(".dart")
                self.assertIn(family, GROUP_FAMILY_STAGES)
                fixture, symbol, complete, expected = GROUP_FAMILY_STAGES[family]
                stage_source = (ROOT / "test" / "ai" / f"mr6b3g_{fixture}_test.dart").read_text()
                declaration = re.search(rf"\b{re.escape(symbol)}\s*=\s*<String>\s*\{{([^}}]*)\}}", stage_source)
                self.assertIsNotNone(declaration, symbol)
                stage = set(re.findall(r"['\"](\w+)['\"]", declaration.group(1)))
                self.assertTrue(stage == set() or stage == complete, family)
                self.assertEqual(members, expected if stage else set(), family)
            elif name.startswith("gitlab_write_port_graphql_"):
                graph.update(members)
            else:
                non_graph.update(members)
        self.assertEqual(non_graph, NON_GRAPH_WRITE_PORT_MEMBERS)
        self.assertEqual(graph, _MR6B3_WRITE_PORT_MEMBERS | _MR6B3T_WRITE_PORT_MEMBERS | {"instance", "currentUser"})

    def test_g0e_namespace_location_guard_rejects_part_and_tearoff(self):
        self.assertTrue(self._namespace_write_violations("void f() => _api.namespaceWorkItem;", is_main=False))
        self.assertTrue(self._namespace_write_violations("void f() => _api.namespaceWorkItem();", is_main=False))
        self.assertTrue(self._namespace_write_violations("Future<void> _resolveGroupWorkItem() async { } void other() => _api.namespaceWorkItem();", is_main=True))
        self.assertEqual(self._namespace_write_violations("Future<void> _resolveGroupWorkItem() async { _api.instance; await _api.namespaceWorkItem(); }", is_main=True), [])
        self.assertTrue(self._namespace_write_violations("Future<void> _resolveGroupWorkItem() async { _api.instance; _api.record(); await _api.namespaceWorkItem(); }", is_main=True))

    def test_g0e_namespace_guard_recognizes_member_trivia(self):
        resolver = "Future<void> _resolveGroupWorkItem() async { _api.instance; await _api.namespaceWorkItem(); }"
        for trivia in (" ", "\n", "/* gap */"):
            valid = resolver.replace("_api.namespaceWorkItem", f"_api.{trivia}namespaceWorkItem")
            self.assertEqual(self._namespace_write_violations(valid, is_main=True), [])
        for operator in (".", "..", "?.", "?.."):
            for trivia in (" ", "\n", "/* gap */"):
                for suffix in ("()", ""):
                    access = f"_api{operator}{trivia}namespaceWorkItem{suffix}"
                    with self.subTest(access=access):
                        code = self._code_only(access)
                        self.assertEqual(self._api_members(code), {"namespaceWorkItem"})
                        self.assertTrue(self._namespace_read_violations(access))
                        self.assertTrue(self._namespace_write_violations(access, is_main=False))
                        self.assertTrue(self._namespace_write_violations(resolver + " void other() => " + access + ";", is_main=True))

    def test_g0e_group_target_gate_is_pinned_and_never_assigned_in_lib(self):
        ledger = (AI_ROOT / "tools" / "write_ledger.dart").read_text()
        self.assertRegex(ledger, r"\bconst\s+bool\s+aiGroupWorkItemWritesEnabled\s*=\s*false\s*;")
        violations = []
        for path in (ROOT / "lib").rglob("*.dart"):
            for finding in self._group_gate_assignment_violations(path.read_text()):
                violations.append(f"{path.relative_to(ROOT)}: {finding}")
        self.assertEqual(violations, [])
        self.assertTrue(self._group_gate_assignment_violations("aiGroupWorkItemWritesEnabledForTesting = true;"))
        self.assertTrue(self._group_gate_assignment_violations("aiGroupWorkItemWritesEnabledForTesting ??= true;"))

    @classmethod
    def _group_gate_assignment_violations(cls, source):
        code = cls._code_only(source)
        name = r"\baiGroupWorkItemWritesEnabledForTesting\b"
        return ["test gate override assigned"] if re.search(name + r"\s*(?:=(?!=)|\?\?=|[+*/%-]=|\+\+|--)", code) else []

    @classmethod
    def _namespace_write_violations(cls, source, *, is_main):
        code = cls._code_only(source)
        refs = list(re.finditer(r"\.\s*namespaceWorkItem\b", code))
        if not is_main:
            return [] if not refs else ["namespaceWorkItem outside main resolver"]
        if len(refs) != 1:
            return ["expected one namespaceWorkItem reference"]
        declaration = re.search(r"\bFuture\s*<[^>]+>\s+_resolveGroupWorkItem\s*\(", code)
        if not declaration:
            return ["missing group resolver"]
        body = re.search(r"\basync\s*\{", code[declaration.end():])
        if not body:
            return ["missing async resolver body"]
        opening = declaration.end() + body.end() - 1
        depth, end = 1, opening + 1
        while end < len(code) and depth:
            depth += (code[end] == "{") - (code[end] == "}")
            end += 1
        if depth or not opening < refs[0].start() < end or not re.search(r"_api\s*\.\s*namespaceWorkItem\s*\(", code[opening:end]):
            return ["namespaceWorkItem outside group resolver"]
        if cls._api_members(code[opening:end]) != {"instance", "namespaceWorkItem"}:
            return ["group resolver API members differ from the fixed delta"]
        return []

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
        self.assertIn("namespaceWorkItem", WRITE_PORT_MEMBERS)
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

    def test_write_port_discovery_uses_declared_uris_across_directories(self):
        with tempfile.TemporaryDirectory() as directory:
            tools = Path(directory).resolve() / "tools"
            tools.mkdir()
            (tools / "gitlab_write_port.dart").write_text(
                "part /* comment */ 'nested/arbitrary_name.dart';\npart '../other.dart';\n",
                encoding="utf-8",
            )
            nested = tools / "nested"
            nested.mkdir()
            part = nested / "arbitrary_name.dart"
            part.write_text(
                "part /* comment */ of '../gitlab_write_port.dart';\n",
                encoding="utf-8",
            )
            (tools.parent / "other.dart").write_text(
                "part of 'tools/gitlab_write_port.dart';\n_api.writeRecord();\n",
                encoding="utf-8",
            )
            (tools / "unreferenced.dart").write_text(
                "part of 'gitlab_write_port.dart';\n_api.graphMutation();\n",
                encoding="utf-8",
            )
            sources = self._write_port_sources(tools)
            self.assertEqual(
                [(path.relative_to(tools.parent).as_posix(), is_part)
                 for path, _, is_part in sources],
                [("tools/gitlab_write_port.dart", False),
                 ("tools/nested/arbitrary_name.dart", True), ("other.dart", True)],
            )
            self.assertIn("writeRecord", self._api_members(sources[-1][1]))
            self.assertIn(
                "uses generic channel writeRecord",
                self._write_port_violations(sources[-1][1], is_part=True),
            )
            self.assertNotIn("graphMutation", {
                member for _, source, _ in sources for member in self._api_members(source)
            })

    def test_write_port_discovery_rejects_missing_or_foreign_part_of(self):
        with tempfile.TemporaryDirectory() as directory:
            tools = Path(directory)
            main = tools / "gitlab_write_port.dart"
            main.write_text("part 'child.dart';\n", encoding="utf-8")
            with self.assertRaises(FileNotFoundError):
                self._write_port_sources(tools)
            child = tools / "child.dart"
            for content in (
                "", "part of 'other.dart';", "// part of 'gitlab_write_port.dart';",
                "void f() { part of 'gitlab_write_port.dart'; }",
                "part of gitlab_write_port;",
            ):
                child.write_text(content, encoding="utf-8")
                with self.subTest(content=content), self.assertRaises(ValueError):
                    self._write_port_sources(tools)
            main.write_text("void f() { part 'child.dart'; }", encoding="utf-8")
            with self.assertRaises(ValueError):
                self._write_port_sources(tools)

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

    @classmethod
    def _api_members(cls, source):
        source = cls._code_only(source)
        receivers = {"_api"}
        aliases = re.compile(r"\b(?:final|var)\s+(\w+)\s*=\s*(\w+)\b(?!\s*(?:[.(]|\?\.))")
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
                re.findall(rf"\b{re.escape(receiver)}\s*(?:\?\.\.|\.\.|\?\.|\.)\s*(\w+)\b", source)
            )
        return members

    @staticmethod
    def _code_only(source):
        """Mask comments and literal text, preserving interpolated Dart code."""
        masked = list(source)
        length = len(source)

        def hide(index):
            if source[index] not in "\r\n":
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
                if (not raw and source[index] == "$" and index + 1 < length and
                        re.match(r"[a-zA-Z_]", source[index + 1])):
                    hide(index)
                    index += 1
                    while index < length and re.match(r"[a-zA-Z_0-9]", source[index]):
                        index += 1
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
                    while index < length and source[index] not in "\r\n":
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
        if re.search(r"\b_api\s*\??\s*\.\.", code):
            violations.append("API cascade in read port")
        if re.search(r"\bdynamic\b", code):
            violations.append("dynamic keyword in read port")
        owner_offsets = set()
        for name, wanted in expected.items():
            matching = [(start, end) for found, start, end in classes if found == name]
            if len(matching) != 1:
                violations.append(f"expected one {name}")
            else:
                body = code[matching[0][0]:matching[0][1]]
                if cls._api_members(body) != wanted:
                    violations.append(f"unexpected {name} API members")
                if cls._api_occurrences(body) != READ_PORT_API_OCCURRENCES[name]:
                    violations.append(f"unexpected {name} API occurrence snapshot")
                violations.extend(cls._read_port_token_violations(name, body, wanted))
                if name == "GitLabAiGroupReadPort":
                    owner_offsets.update(matching[0][0] + offset
                                         for offset in cls._group_owner_api_offsets(body))
        for token in re.finditer(r"\bapiOwner\b", code):
            argument = re.match(r"apiOwner\s*:\s*(_api)\b", code[token.start():])
            if not argument or token.start() + argument.start(1) not in owner_offsets:
                violations.append("unexpected apiOwner occurrence in read port")
        for name, start, end in classes:
            if name not in expected and (cls._api_members(source[start:end]) or
                                         re.search(r"\b(?:GitLabApi|_api)\b", code[start:end])):
                violations.append(f"API access in unknown class {name}")
        outside = list(code)
        for _, start, end in classes:
            outside[start:end] = " " * (end - start)
        outside = "".join(outside)
        if cls._api_members(outside) or re.search(r"\b(?:GitLabApi|_api)\b", outside):
            violations.append("API access outside concrete classes")
        if cls._api_members(code) != READ_PORT_MEMBERS | GROUP_READ_PORT_MEMBERS:
            violations.append("unexpected read-port API union")
        return violations

    @staticmethod
    def _api_occurrences(code):
        tokens = re.findall(r"[A-Za-z_$][A-Za-z0-9_$]*|\?\.\.|\.\.|\?\.|=>|[^\s]", code)
        return [" ".join(tokens[max(0, index - 2):index + 4])
                for index, token in enumerate(tokens) if token == "_api"]

    @staticmethod
    def _read_port_fixture(*, project="", group="", extra=""):
        source = PORT.read_text(encoding="utf-8")
        for marker, addition in (
            ("  final int projectId;\n", project),
            ("  VerifiedGroupWorkItemIdentity? _verifiedIdentity;\n", group),
        ):
            if source.count(marker) != 1:
                raise ValueError(f"read-port fixture marker changed: {marker}")
            source = source.replace(marker, marker + addition + "\n", 1)
        return source + "\n" + extra

    @staticmethod
    def _argument_spans(code, opening):
        """Return top-level argument spans of a balanced parenthesized call."""
        if opening >= len(code) or code[opening] != "(":
            return None
        stack = []
        spans = []
        start = opening + 1
        for index in range(start, len(code)):
            char = code[index]
            if char in "([{":
                stack.append(char)
            elif char in ")]}":
                if not stack:
                    if char != ")":
                        return None
                    spans.append((start, index))
                    return spans
                if {"(": ")", "[": "]", "{": "}"}[stack.pop()] != char:
                    return None
            elif char == "," and not stack:
                spans.append((start, index))
                start = index + 1
        return None

    @classmethod
    def _read_port_token_violations(cls, name, code, wanted):
        """Allow API tokens only at their declared, capability-limited uses."""
        violations = []
        api_allowed = set()
        type_allowed = set()
        for field in re.finditer(r"\bfinal\s+(GitLabApi)\s+(_api)\s*;", code):
            before = code[:field.start()]
            if before.count("{") - before.count("}") != 1:
                continue
            type_allowed.add(field.start(1))
            api_allowed.add(field.start(2))

        # Only formal field parameters in actual top-level constructors count.
        for constructor in re.finditer(rf"\b{re.escape(name)}(?:\s*\.\s*\w+)?\s*\(", code):
            before = code[:constructor.start()]
            if before.count("{") - before.count("}") != 1:
                continue
            depth = 0
            boundary = 0
            for index, char in enumerate(before):
                if char == "{":
                    depth += 1
                    if depth == 1:
                        boundary = index + 1
                elif char == "}":
                    depth -= 1
                    if depth == 1:
                        boundary = index + 1
                elif char == ";" and depth == 1:
                    boundary = index + 1
            if not re.fullmatch(r"\s*(?:external\s+)?(?:const\s+)?", before[boundary:]):
                continue
            opening = constructor.end() - 1
            spans = cls._argument_spans(code, opening)
            if spans is None:
                continue
            end = spans[-1][1] + 1
            params = code[opening:end]
            for param in re.finditer(
                r"(?:^|[({,])\s*(?:required\s+)?this\s*\.\s*(_api)\s*(?=[,})])",
                params,
            ):
                prefix = params[1:param.start(1)]
                if (prefix.count("(") != prefix.count(")") or
                        prefix.count("{") - prefix.count("}") +
                        prefix.count("[") - prefix.count("]") > 1):
                    continue
                api_allowed.add(opening + param.start(1))

        if name == "GitLabAiReadPort":
            # The port uses only this read-only limit; no other static API is allowed.
            for constant in re.finditer(r"\b(GitLabApi)\s*\.\s*maxTextBytes\b", code):
                type_allowed.add(constant.start(1))
        else:
            api_allowed.update(cls._group_owner_api_offsets(code))

        if re.search(r"\bas\s+dynamic\b", code):
            violations.append(f"dynamic cast in {name}")
        for token in re.finditer(r"\bGitLabApi\b", code):
            if token.start() not in type_allowed:
                violations.append(f"unexpected GitLabApi reference in {name}")
        for token in re.finditer(r"\b_api\b", code):
            if token.start() in api_allowed:
                continue
            member = re.match(r"\s*(?:\.\.|\.)\s*(\w+)\b", code[token.end():])
            if not member or member.group(1) not in wanted:
                violations.append(f"unexpected _api reference in {name}")
        return violations

    @classmethod
    def _group_owner_api_offsets(cls, code):
        # Only workItem's single top-level identity-factory argument may own API.
        owners = []
        for method in re.finditer(r"\bworkItem\s*\([^)]*\)\s*async\s*\{", code):
            before = code[:method.start()]
            if before.count("{") - before.count("}") != 1:
                continue
            block = cls._brace_block(code, method.end() - 1)
            if not block:
                continue
            for factory in re.finditer(
                r"\bVerifiedGroupWorkItemIdentity\s*\.\s*fromServerEvidence\s*\(",
                code[block[0]:block[1]],
            ):
                opening = block[0] + factory.end() - 1
                spans = cls._argument_spans(code, opening)
                if not spans or spans[-1][1] >= block[1]:
                    continue
                for start, end in spans:
                    arg = re.fullmatch(r"\s*apiOwner\s*:\s*(_api)\s*", code[start:end])
                    if arg:
                        owners.append(start + arg.start(1))
        return set(owners) if len(owners) == 1 else set()

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
    def _group_scope_construction_violations(cls, relative, source):
        if not relative.startswith("lib/"):
            return []
        code = cls._code_only(source)
        if re.search(r"\btypedef\b[^;]*\bAiGroupResourceScope\b", code):
            return ["group scope typedef alias is forbidden even in its producers"]
        if relative in {
            "lib/core/ai/tools/tool_scope.dart",  # Defines the scope.
            "lib/features/ai/ai_chat_context.dart",
        }:
            return []
        if (re.search(r"\bAiGroupResourceScope\s*(?:\(|\.)", code) or
                re.search(r"=\s*(?:\w+\s*\.\s*)?AiGroupResourceScope\b", code)):
            return ["group scope constructed or aliased outside its producers"]
        return []

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
        elif relative == "lib/core/ai/tools/gitlab_write_port.dart":
            for method in re.finditer(r"\bFuture\s*<[^>]+>\s+_resolveGroupWorkItem\s*\([\s\S]*?\)\s*async\s*\{", code):
                block = cls._brace_block(code, method.end() - 1)
                if block and not cls._namespace_write_violations(source, is_main=True):
                    strict_calls = list(re.finditer(r"\.\s*namespaceWorkItem\s*\(", code[block[0]:block[1]]))
                    if len(strict_calls) == 1 and not cls._namespace_read_violations(code[block[0]:block[1]]):
                        allowed.append((block[0] + strict_calls[0].start(), block[1]))
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
        for match in re.finditer(r"\.\s*namespaceWorkItem\b", code):
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

    @classmethod
    def _part_uris(cls, source):
        """Read live part directives, rejecting unsupported directive syntax."""
        code = cls._code_only(source)
        gap = r"(?:\s|//[^\n]*(?:\n|$)|/\*[\s\S]*?\*/)*"
        directive = re.compile(
            rf"\bpart{gap}(?:(of)\b{gap})?(['\"])([^'\"]+)\2{gap};"
        )
        found = []
        starts = set()
        for match in directive.finditer(source):
            if code[match.start():match.start() + 4] != "part":
                continue
            before = code[:match.start()]
            if before.count("{") != before.count("}"):
                raise ValueError("part directive is not top level")
            starts.add(match.start())
            found.append((match.group(1) == "of", match.group(3)))
        for token in re.finditer(r"\bpart\b", code):
            before = code[:token.start()]
            is_directive = re.match(r"part\s+of\b", code[token.start():])
            if (token.start() not in starts and
                    (before.count("{") == before.count("}") or is_directive)):
                raise ValueError("unrecognized part directive")
        return found

    @staticmethod
    def _resolve_part_uri(base, uri):
        parsed = urlsplit(uri)
        if parsed.scheme or parsed.netloc or parsed.query or parsed.fragment or uri.startswith("/"):
            raise ValueError(f"part URI is not relative: {uri}")
        return (base / unquote(parsed.path)).resolve()

    @classmethod
    def _write_port_sources(cls, tools=None):
        tools = tools or AI_ROOT / "tools"
        main = (tools / "gitlab_write_port.dart").resolve()
        main_source = main.read_text(encoding="utf-8")
        sources = [(main, main_source, False)]
        directives = cls._part_uris(main_source)
        if any(is_part_of for is_part_of, _ in directives):
            raise ValueError("write library declares part of")
        paths = set()
        for _, uri in directives:
            path = cls._resolve_part_uri(main.parent, uri)
            if path == main or path in paths:
                raise ValueError(f"duplicate or self-referential part: {uri}")
            paths.add(path)
            source = path.read_text(encoding="utf-8")
            part_directives = cls._part_uris(source)
            if (len(part_directives) != 1 or not part_directives[0][0] or
                    cls._resolve_part_uri(path.parent, part_directives[0][1]) != main):
                raise ValueError(f"part does not belong to write library: {path}")
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
        if re.search(r"\b_api\b(?!\s*(?:\.|\?\.))", source):
            violations.append("part uses _api without member access")
        return violations


if __name__ == "__main__":
    unittest.main()
