from collections import namedtuple
from pathlib import Path
import json
import os
import re
import shutil
import subprocess
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[2]
# The jobs a merge request that changes only documentation skips (.app_regular).
APP_JOBS = frozenset({'flutter_checks', 'flutter_ai_checks', 'native_templates', 'android_debug'})
SPECIAL_PIPELINES = ('LIVE_SMOKE', 'RESOLVE_LOCK', 'PUBLIC_SMOKE', 'GH2GL_SYNC')
# https://docs.gitlab.com/ci/jobs/job_rules/#ci_pipeline_source-predefined-variable
PIPELINE_SOURCES = ('api', 'chat', 'external', 'external_pull_request_event',
                    'merge_request_event', 'ondemand_dast_scan', 'ondemand_dast_validation',
                    'parent_pipeline', 'pipeline', 'push', 'schedule',
                    'security_orchestration_policy', 'trigger', 'web', 'webide')
# The MR7 tests both Flutter lanes run: they test the app's release and background gates.
GATE_TESTS = ('test/ai/mr7_release_gate_test.dart', 'test/ai/mr7_background_gate_test.dart')
# A renamed file in a merge request's changes.
Rename = namedtuple('Rename', 'old new')


def yaml_scalar(text):
    """A plain or single-quoted YAML scalar, the only kinds these rules use."""
    if text.startswith("'") and text.endswith("'") and len(text) > 1:
        return text[1:-1].replace("''", "'")
    if text[:1] in ('"', "'", '[', '{', '&', '*', '!', '|', '>'):
        raise AssertionError(f'unsupported YAML scalar: {text}')
    return text


def pipeline_variables(source, branch='main', **extra):
    """Predefined variables of a pipeline for this project."""
    variables = {'CI_PIPELINE_SOURCE': source, 'CI_DEFAULT_BRANCH': 'main',
                 'CI_PROJECT_ID': '86648389', 'MR7_RELEASE_AI': 'false'}
    if source == 'merge_request_event':
        variables.update(CI_MERGE_REQUEST_IID='7', CI_COMMIT_REF_PROTECTED='false')
    elif branch:
        variables.update(CI_COMMIT_BRANCH=branch, CI_COMMIT_REF_PROTECTED=str(branch == 'main').lower())
    variables.update(extra)
    return variables


class PipelineModel:
    """Which jobs GitLab adds to a pipeline, from the rules, extends and needs in
    .gitlab-ci.yml (https://docs.gitlab.com/ci/yaml/#rules). It reads only the
    syntax this file uses and fails on anything else, so a rule it cannot read
    is never ignored."""

    TOP_LEVEL = ('workflow', 'stages', 'variables', 'default')
    TERM = re.compile(r'\$(\w+)\s*(==|!=|=~)\s*(?:"([^"]*)"|/(.*)/|\$(\w+))')

    def __init__(self, content):
        self.blocks = {match[1]: match[2] for match in
                       re.finditer(r'^([.\w-]+):\n(.*?)(?=\n\S|\Z)', content, re.MULTILINE | re.DOTALL)}
        self.jobs = sorted(name for name in self.blocks
                           if not name.startswith('.') and name not in self.TOP_LEVEL)

    def section(self, name, key):
        block = self.blocks[name]
        match = re.search(rf'^  {key}:\n(.*?)(?=\n  \S|\Z)', block, re.MULTILINE | re.DOTALL)
        if match is None and re.search(rf'^  {key}:', block, re.MULTILINE):
            raise AssertionError(f'{name}: unsupported {key} syntax')
        return match and match[1]

    def rules(self, name):
        """The job's own rules, or those of the last template in extends that has them."""
        own = self.section(name, 'rules')
        if own is not None:
            return self.parse_rules(own)
        extends = re.search(r'^  extends: (.+)$', self.blocks[name], re.MULTILINE)
        if extends:
            for parent in reversed([item.strip() for item in extends[1].strip('[]').split(',')]):
                inherited = self.rules(parent)
                if inherited is not None:
                    return inherited
        return None

    @staticmethod
    def parse_rules(text):
        rules = []
        for item in re.split(r'^    - ', text, flags=re.MULTILINE)[1:]:
            rule, changes = {}, None
            for line in ('      ' + item).splitlines():
                if not line.strip() or line.lstrip().startswith('#'):
                    continue
                match = re.fullmatch(r'( {6}| {8})([a-z_]+):(?: (.+))?', line)
                if match is None:
                    raise AssertionError(f'unsupported rule line: {line!r}')
                indent, key, value = match.groups()
                if len(indent) == 6:
                    changes = None
                    if key == 'changes' and value is None:
                        changes = rule['changes'] = {}
                    elif key in ('if', 'when', 'allow_failure') and value is not None:
                        rule[key] = yaml_scalar(value)
                    else:
                        raise AssertionError(f'unsupported rule key: {line!r}')
                elif changes is not None and key in ('compare_to', 'regexp') and value is not None:
                    changes[key] = yaml_scalar(value)
                else:
                    raise AssertionError(f'unsupported changes key: {line!r}')
            rules.append(rule)
        return rules

    def needs(self, name):
        text = self.section(name, 'needs')
        needs = []
        for item in re.split(r'^    - ', text or '', flags=re.MULTILINE)[1:]:
            job = re.match(r'job: (\S+)$', item, re.MULTILINE)
            if job is None:
                raise AssertionError(f'{name}: unsupported needs entry {item!r}')
            needs.append((job[1], bool(re.search(r'^      optional: true$', item, re.MULTILINE))))
        return needs

    @classmethod
    def holds(cls, condition, variables):
        """&& and || over comparisons; an undefined variable is null."""
        def term(text):
            match = cls.TERM.fullmatch(text.strip())
            if match is None:
                raise AssertionError(f'unsupported rule term: {text}')
            name, operator, literal, pattern, other = match.groups()
            value = variables.get(name)
            if operator == '=~':
                return value is not None and re.search(pattern, value) is not None
            expected = variables.get(other) if other else literal
            return (value == expected) == (operator == '==')

        return any(all(term(part) for part in group.split('&&')) for group in condition.split('||'))

    @staticmethod
    def changed(changes, paths):
        """rules:changes with a Ruby regexp: true when any changed path matches it
        (https://docs.gitlab.com/ci/yaml/#ruleschangesregexp). Without compare_to
        a merge-request pipeline reads the merge request's changed paths with
        rename detection off, so a Rename counts as its old path (deleted) and
        its new path (added). With compare_to GitLab reads diff stats, which keep
        only the new path."""
        if set(changes) - {'compare_to'} != {'regexp'}:
            raise AssertionError(f'unsupported changes clause: {changes}')
        listed = []
        for path in paths:
            if isinstance(path, Rename):
                listed += [path.new] if 'compare_to' in changes else [path.old, path.new]
            else:
                listed.append(path)
        # Ruby's \z (end of string) is Python's \Z.
        pattern = re.compile(re.sub(r'(?<!\\)\\z', r'\\Z', changes['regexp']))
        return any(pattern.search(path) for path in listed)

    def included(self, name, variables, changed):
        rules = self.rules(name)
        if rules is None:
            return True
        for rule in rules:
            if 'if' in rule and not self.holds(rule['if'], variables):
                continue
            if 'changes' in rule and not self.changed(rule['changes'], changed):
                continue
            return rule.get('when', 'on_success') != 'never'
        return False

    def pipeline(self, variables, changed=()):
        return {name for name in self.jobs if self.included(name, variables, changed)}


class CiPipelineConfigTests(unittest.TestCase):
    def setUp(self):
        self.ci_file = Path(__file__).resolve().parents[2] / '.gitlab-ci.yml'
        self.content = self.ci_file.read_text(encoding='utf-8')

    def test_default_retry_covers_infrastructure_failures(self):
        self.assertIn('retry:', self.content)
        self.assertIn('when: [runner_system_failure, stuck_or_timeout_failure]', self.content)

    def test_started_main_pipelines_run_to_completion(self):
        workflow = re.search(r'^workflow:\n(.*?)(?=\n\S|\Z)', self.content,
                             re.MULTILINE | re.DOTALL).group(1)
        main_rule = ("    - if: '$CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH'\n"
                     "      auto_cancel:\n"
                     "        on_new_commit: conservative\n")
        self.assertIn(main_rule, workflow)
        self.assertLess(workflow.index(main_rule), workflow.index("    - if: '$CI_COMMIT_BRANCH'"),
                        'the main rule must match before the generic branch rule')
        match = re.search(r'^main_run_to_completion:\n(.*?)(?=\n\S|\Z)', self.content,
                          re.MULTILINE | re.DOTALL)
        self.assertIsNotNone(match, 'main_run_to_completion job must be present in .gitlab-ci.yml')
        guard = match.group(1)
        self.assertIn('  stage: verify\n', guard)
        self.assertIn('  interruptible: false\n', guard)
        self.assertNotIn('needs:', guard, 'the guard must start with the first stage')
        self.assertNotIn('extends:', guard)
        rules = re.search(r'^  rules:\n(.*?)(?=\n  \S)', guard, re.MULTILINE | re.DOTALL).group(1)
        self.assertIn('\'$LIVE_SMOKE == "1" || $RESOLVE_LOCK == "1" || $PUBLIC_SMOKE == "1" || $GH2GL_SYNC == "1"\'\n'
                      '      when: never', rules)
        self.assertIn("- if: '$CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH'", rules)
        self.assertNotIn('on_success', rules, 'the guard runs only on main')

    def test_public_api_smoke_does_not_override_retry_with_zero(self):
        # Extract public_api_smoke job block
        match = re.search(r'^public_api_smoke:\n(.*?)(?=\n\S|\Z)', self.content, re.MULTILINE | re.DOTALL)
        self.assertIsNotNone(match, 'public_api_smoke job must be present in .gitlab-ci.yml')
        job_block = match.group(1)
        self.assertNotIn('retry: 0', job_block,
                         'public_api_smoke is read-only and must inherit default retry for queue resilience')

    def test_public_api_smoke_runs_only_on_demand_or_on_its_schedule(self):
        match = re.search(r'^public_api_smoke:\n(.*?)(?=\n\S|\Z)', self.content, re.MULTILINE | re.DOTALL)
        self.assertIsNotNone(match, 'public_api_smoke job must be present in .gitlab-ci.yml')
        rules = re.search(r'^  rules:\n(.*?)(?=\n  \S)', match.group(1), re.MULTILINE | re.DOTALL).group(1)
        self.assertIn('\'$PUBLIC_SMOKE == "1" && $CI_PIPELINE_SOURCE =~ /^(api|schedule|web)$/\'', rules)
        self.assertNotIn('on_success', rules,
                         'anonymous gitlab.com reads share a per-IP budget and must not run on every push')

    def test_android_build_does_not_wait_for_the_public_smoke(self):
        match = re.search(r'^android_debug:\n(.*?)(?=\n\S|\Z)', self.content, re.MULTILINE | re.DOTALL)
        self.assertIsNotNone(match, 'android_debug job must be present in .gitlab-ci.yml')
        needs = re.search(r'^  needs:\n(.*?)(?=\n  \S)', match.group(1), re.MULTILINE | re.DOTALL).group(1)
        self.assertNotIn('public_api_smoke', needs)
        for job in ('python_checks', 'flutter_checks', 'flutter_ai_checks', 'native_templates'):
            self.assertIn(f'- job: {job}', needs)

    def test_live_crud_smoke_disables_retry_for_mutation_safety(self):
        # Extract live_crud_smoke job block
        match = re.search(r'^live_crud_smoke:\n(.*?)(?=\n\S|\Z)', self.content, re.MULTILINE | re.DOTALL)
        self.assertIsNotNone(match, 'live_crud_smoke job must be present in .gitlab-ci.yml')
        job_block = match.group(1)
        self.assertIn('retry: 0', job_block,
                      'live_crud_smoke mutates live data and must keep retry: 0')

    def test_ai_checks_have_the_same_regular_lane_and_separate_artifacts(self):
        jobs = {}
        for name in ('flutter_checks', 'flutter_ai_checks'):
            match = re.search(rf'^{name}:\n(.*?)(?=\n\S|\Z)', self.content,
                              re.MULTILINE | re.DOTALL)
            self.assertIsNotNone(match, name)
            jobs[name] = match.group(1)
            self.assertIn('extends: [.flutter, .app_regular]', jobs[name])
            self.assertIn('timeout: 35m', jobs[name])
            self.assertNotRegex(jobs[name], re.compile(r'^  (rules|tags|retry):', re.MULTILINE))
        self.assertIn('- bash ci/check.sh\n', jobs['flutter_checks'])
        self.assertIn('junit: ci-output/junit.xml', jobs['flutter_checks'])
        self.assertIn('- bash ci/check.sh ai\n', jobs['flutter_ai_checks'])
        self.assertIn('paths: [ci-output-ai/, coverage-ai/]', jobs['flutter_ai_checks'])
        self.assertIn('junit: ci-output-ai/junit.xml', jobs['flutter_ai_checks'])

    def test_attestation_and_ai_delivery_are_guarded_manual_jobs(self):
        for name in ('mr7_release_attestation', 'publish_preview_ai'):
            with self.subTest(job=name):
                match = re.search(rf'^{name}:\n(.*?)(?=\n\S|\Z)', self.content,
                                  re.MULTILINE | re.DOTALL)
                self.assertIsNotNone(match, name)
                job = match.group(1)
                rules_match = re.search(r'^  rules:\n(.*?)(?=\n  \S|\Z)', job,
                                        re.MULTILINE | re.DOTALL)
                self.assertIsNotNone(rules_match, name)
                self.assertNotRegex(rules_match.group(1),
                                    re.compile(r'^    - when: (?!never\b)', re.MULTILINE))
                rules = re.findall(r'^    - if: ([^\n]+)\n((?:      [^\n]+\n)*)',
                                   rules_match.group(1) + '\n', re.MULTILINE)
                self.assertTrue(rules, name)
                for special in ('$LIVE_SMOKE', '$RESOLVE_LOCK', '$PUBLIC_SMOKE', '$GH2GL_SYNC'):
                    self.assertIn(special, rules[0][0])
                self.assertRegex(rules[0][1], r'(?m)^      when: never$')
                allows = [(condition, attributes) for condition, attributes in rules
                          if not re.search(r'^      when: never$', attributes, re.MULTILINE)]
                self.assertEqual(len(allows), 1, name)
                condition, attributes = allows[0]
                self.assertNotIn('||', condition)
                for required in (
                    r'\$CI_PROJECT_ID\s*==\s*"86648389"',
                    r'\$CI_COMMIT_REF_PROTECTED\s*==\s*"true"',
                    r'\$CI_COMMIT_BRANCH\s*==\s*"main"',
                    r'\$CI_PIPELINE_SOURCE\s*!=\s*"merge_request_event"',
                ):
                    self.assertRegex(condition, required)
                self.assertRegex(attributes, r'(?m)^      when: manual$')
                self.assertRegex(attributes, r'(?m)^      allow_failure: true$')
                self.assertIn('retry: 0', job)
                self.assertIn('name: mr7-release', job)

    def test_off_preview_is_restricted_to_this_projects_protected_main(self):
        self.assertRegex(self.content, re.compile(r"^  MR7_RELEASE_AI: ['\"]false['\"]$", re.MULTILINE))
        match = re.search(r'^publish_preview:\n(.*?)(?=\n\S|\Z)', self.content,
                          re.MULTILINE | re.DOTALL)
        self.assertIsNotNone(match)
        job = match.group(1)
        rules_match = re.search(r'^  rules:\n(.*?)(?=\n  \S|\Z)', job,
                                re.MULTILINE | re.DOTALL)
        self.assertIsNotNone(rules_match)
        self.assertNotRegex(rules_match.group(1),
                            re.compile(r'^    - when: (?!never\b)', re.MULTILINE))
        rules = re.findall(r'^    - if: ([^\n]+)\n((?:      [^\n]+\n)*)',
                           rules_match.group(1) + '\n', re.MULTILINE)
        self.assertEqual(len(rules), 2)
        for special in ('$LIVE_SMOKE', '$RESOLVE_LOCK', '$PUBLIC_SMOKE', '$GH2GL_SYNC'):
            self.assertIn(special, rules[0][0])
        self.assertRegex(rules[0][1], r'(?m)^      when: never$')
        condition = rules[1][0]
        self.assertNotIn('||', condition)
        for required in (
            r'\$CI_PROJECT_ID\s*==\s*"86648389"',
            r'\$CI_COMMIT_REF_PROTECTED\s*==\s*"true"',
            r'\$CI_COMMIT_BRANCH\s*==\s*"main"',
            r'\$CI_PIPELINE_SOURCE\s*!=\s*"merge_request_event"',
            r'\$MR7_RELEASE_AI\s*!=\s*"true"',
        ):
            self.assertRegex(condition, required)
        self.assertIn('bash ci/deliver_preview.sh', job)


class DocsOnlyMergeRequestTests(unittest.TestCase):
    """A merge request that changes only Markdown and image files under docs/
    and root *.md files skips the Flutter, native and Android jobs; every other
    pipeline runs them."""

    # flutter analyze reads every other file under docs/ (Dart, pubspec.yaml,
    # analysis_options.yaml), so only these file types count as documentation.
    DOC_SUFFIXES = ('.md', '.png', '.jpg', '.jpeg', '.gif', '.svg', '.webp')
    DOCS_ONLY = (['docs/PLAN_STATUS.md'],
                 ['docs/CI.md', 'README.md', 'docs/images/shot.png', 'docs/plans/a/b.md'],
                 ['AGENTS.md', '.md', 'docs/.md', 'docs/a.jpg', 'docs/b/c.jpeg', 'docs/d.gif',
                  'docs/e.svg', 'docs/f.webp'])
    OTHER_FILES = ('lib/main.dart', 'test/app_test.dart', 'tool/l10n.py', 'tool/mr7/README.md',
                   'ci/check.sh', 'integration_test/mr6c_background_test.dart', 'pubspec.yaml',
                   'pubspec.lock', 'android/app/build.gradle', 'ios/Runner/Info.plist',
                   '.gitlab-ci.yml', '.fvmrc', 'analysis_options.yaml', 'assets/icon/icon.png',
                   'LICENSE', 'docs', 'doc/notes.md', 'documentation/notes.md', 'assets/notes.md',
                   'lib/README.md', 'test/README.md', 'x/docs/y.md', 'README.MD', 'README.markdown',
                   'notes.md.txt', '.github/README.md',
                   'docs/examples/x.dart', 'docs/x/pubspec.yaml', 'docs/x/analysis_options.yaml',
                   'docs/x.yaml', 'docs/x.json', 'docs/ANDROID_RELEASE_INVENTORY.json',
                   'docs/receipts/run.json', 'docs/x.txt', 'docs/noext', 'docs/x.md.dart',
                   'docs/shot.PNG', 'docs/notes.MD', 'docs/x.png/y.dart')

    def setUp(self):
        self.content = (ROOT / '.gitlab-ci.yml').read_text(encoding='utf-8')
        self.model = PipelineModel(self.content)

    @classmethod
    def docs_only(cls, path):
        if '/' not in path:
            return path.endswith('.md')
        return path.startswith('docs/') and path.endswith(cls.DOC_SUFFIXES)

    def other_pipelines(self):
        for source in PIPELINE_SOURCES:
            if source != 'merge_request_event':
                yield f'{source} on main', pipeline_variables(source)
        yield 'tag', pipeline_variables('push', branch=None, CI_COMMIT_TAG='v0.6.0',
                                        CI_COMMIT_REF_PROTECTED='true')
        yield 'branch without a merge request', pipeline_variables('push', branch='feat/x')
        yield 'web on a branch', pipeline_variables('web', branch='feat/x')

    def test_app_jobs_share_one_merge_request_only_changes_rule(self):
        for job in sorted(APP_JOBS):
            block = self.model.blocks[job]
            self.assertIn('  extends: [.flutter, .app_regular]\n', block, job)
            self.assertIsNone(self.model.section(job, 'rules'), job)
        self.assertEqual(self.content.count('changes:'), 1, 'only .app_regular reads changed files')
        self.assertIsNone(re.search(r'^\s*(?:- )?compare_to\s*:', self.content, re.MULTILINE),
                          'compare_to keeps only the new path of a renamed file')
        rules = self.model.rules('.app_regular')
        self.assertEqual(rules[0], self.model.rules('.regular')[0], 'special pipelines skip both templates')
        self.assertEqual(rules[-1], {'when': 'on_success'})
        merge_request = '$CI_PIPELINE_SOURCE == "merge_request_event"'
        self.assertEqual(rules[1:-1], [
            {'if': merge_request, 'changes': {'regexp': rules[1]['changes']['regexp']}},
            {'if': merge_request, 'when': 'never'},
        ])
        self.assertFalse([job for job, optional in self.model.needs('android_debug') if optional],
                         'android_debug and its needs share the same rules; optional needs would hide a gap')

    def test_docs_only_merge_request_skips_exactly_the_app_jobs(self):
        merge_request = pipeline_variables('merge_request_event')
        with_code = self.model.pipeline(merge_request, ['docs/CI.md', 'lib/main.dart'])
        self.assertTrue(APP_JOBS <= with_code)
        for changed in self.DOCS_ONLY:
            with self.subTest(changed=changed):
                self.assertTrue(all(self.docs_only(path) for path in changed))
                docs_only = self.model.pipeline(merge_request, changed)
                self.assertEqual(with_code - docs_only, APP_JOBS)
                self.assertEqual(docs_only - with_code, set())
                self.assertIn('python_checks', docs_only, 'the pipeline is never empty')

    def test_merge_request_changing_any_other_file_runs_the_app_jobs(self):
        merge_request = pipeline_variables('merge_request_event')
        for path in self.OTHER_FILES:
            self.assertFalse(self.docs_only(path), path)
            for changed in ([path], ['docs/CI.md', 'README.md', path]):
                with self.subTest(changed=changed):
                    self.assertTrue(APP_JOBS <= self.model.pipeline(merge_request, changed))

    def test_merge_request_renaming_a_file_into_documentation_runs_the_app_jobs(self):
        merge_request = pipeline_variables('merge_request_event')
        changes = self.model.rules('.app_regular')[1]['changes']
        for old, new in (('lib/x.dart', 'docs/x.md'), ('test/fixtures/run.json', 'docs/receipts/run.md'),
                         ('tool/notes.txt', 'docs/notes.md'), ('assets/icon/icon.png', 'docs/icon.png'),
                         ('CHANGELOG', 'CHANGELOG.md'), ('lib/README.md', 'README.md')):
            with self.subTest(old=old, new=new):
                self.assertFalse(self.docs_only(old))
                self.assertTrue(self.docs_only(new))
                # GitLab lists the old path as deleted and the new path as added.
                self.assertTrue(APP_JOBS <= self.model.pipeline(merge_request, [old, new]))
                self.assertTrue(APP_JOBS <= self.model.pipeline(merge_request, [Rename(old, new)]))
                self.assertFalse(self.model.changed(dict(changes, compare_to='refs/heads/main'), [Rename(old, new)]),
                                 'with compare_to only the new path is seen and the jobs are skipped')
        within_docs = self.model.pipeline(merge_request, [Rename('docs/a.md', 'docs/b/a.md'), 'README.md'])
        self.assertFalse(APP_JOBS & within_docs)

    def test_main_tag_schedule_api_and_other_pipelines_run_the_app_jobs_whatever_changed(self):
        for label, variables in self.other_pipelines():
            for changed in ([], ['docs/CI.md'], ['README.md', 'docs/PLAN_STATUS.md'], ['lib/main.dart']):
                with self.subTest(pipeline=label, changed=changed):
                    jobs = self.model.pipeline(variables, changed)
                    self.assertTrue(APP_JOBS <= jobs)
                    self.assertIn('python_checks', jobs)
        main_push = self.model.pipeline(pipeline_variables('push'), ['docs/CI.md'])
        self.assertTrue({'main_run_to_completion', 'publish_preview', 'publish_preview_ai',
                         'mr7_release_attestation'} <= main_push)

    def test_special_pipelines_still_skip_the_app_jobs(self):
        for special in SPECIAL_PIPELINES:
            for source in ('api', 'schedule', 'web'):
                for changed in ([], ['lib/main.dart']):
                    with self.subTest(special=special, source=source, changed=changed):
                        jobs = self.model.pipeline(pipeline_variables(source, **{special: '1'}), changed)
                        self.assertFalse(APP_JOBS & jobs)
                        self.assertNotIn('python_checks', jobs)

    def test_every_needed_job_is_in_the_pipeline(self):
        merge_request = pipeline_variables('merge_request_event')
        scenarios = [(label, variables, changed) for label, variables in self.other_pipelines()
                     for changed in ([], ['docs/CI.md'])]
        scenarios += [('docs-only merge request', merge_request, changed) for changed in self.DOCS_ONLY]
        scenarios += [('merge request with code', merge_request, ['docs/CI.md', 'lib/main.dart']),
                      ('empty merge request', merge_request, [])]
        scenarios += [(f'{special} pipeline', pipeline_variables('api', **{special: '1'}), [])
                      for special in SPECIAL_PIPELINES]
        for label, variables, changed in scenarios:
            jobs = self.model.pipeline(variables, changed)
            for job in sorted(jobs):
                for needed, optional in self.model.needs(job):
                    with self.subTest(pipeline=label, changed=changed, job=job):
                        self.assertTrue(optional or needed in jobs,
                                        f"'{job}' job needs '{needed}' job, but it was not added")

    def test_docs_only_pattern_matches_its_definition_on_every_tracked_file(self):
        listing = subprocess.run(['git', 'ls-files', '-z'], cwd=ROOT, capture_output=True, check=True)
        tracked = [path for path in listing.stdout.decode('utf-8').split('\0') if path]
        changes = self.model.rules('.app_regular')[1]['changes']
        docs = [path for path in tracked if self.docs_only(path)]
        self.assertTrue(docs, 'the repository has documentation')
        self.assertLess(len(docs), len(tracked))
        for path in tracked + [path for changed in self.DOCS_ONLY for path in changed] + list(self.OTHER_FILES):
            with self.subTest(path=path):
                self.assertEqual(self.model.changed(changes, [path]), not self.docs_only(path))


class CheckScriptTests(unittest.TestCase):
    """Run the real shell script with synthetic Flutter events and no SDK."""

    # A synthetic test/ tree: test files of both lanes, a nested file that is not
    # a sandbox tool test, and helpers that are never test entry points.
    SANDBOX_TESTS = ('test/ai/mr7_live_probe_test.dart', 'test/ai/mr7_sandbox_contract_test.dart',
                     'test/ai/mr7_sandbox_wave3_test.dart')
    SHARED_TESTS = ('test/ai/fixtures/mr7_sandbox_fixture_test.dart', 'test/ai/mr7_background_gate_test.dart',
                    'test/ai/mr7_release_gate_test.dart', 'test/app_test.dart',
                    'test/offline/archive_test.dart')
    HELPERS = ('test/ai/mr7_release_gate_support.dart', 'test/flutter_test_config.dart',
               'test/support/fake_adapter.dart', 'tool/mr7/sandbox_contract.dart')

    def lane(self, mode):
        tests = self.SHARED_TESTS + (self.SANDBOX_TESTS if mode == 'ai' else ())
        return sorted(tests)

    def run_check(self, *args, test_exit='0', tree=SANDBOX_TESTS + SHARED_TESTS + HELPERS, links=()):
        root = Path(__file__).resolve().parents[2]
        scratch = root / 'ci-output'
        scratch.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='check-script-', dir=scratch) as directory:
            work = Path(directory)
            (work / 'ci').mkdir()
            (work / 'bin').mkdir()
            for name in ('check.sh', 'test_progress.py', 'test_report.py'):
                shutil.copyfile(root / 'ci' / name, work / 'ci' / name)
            (work / 'pubspec.lock').write_text('synthetic lock\n')
            for name in tree:
                (work / name).parent.mkdir(parents=True, exist_ok=True)
                (work / name).write_text('void main() {}\n')
            for name, target in links:
                os.symlink(target, work / name)
            flutter = work / 'bin' / 'flutter'
            flutter.write_text(textwrap.dedent('''\
                #!/usr/bin/env python3
                import json, os, pathlib, sys
                with open(os.environ['COMMANDS'], 'a') as output:
                    output.write(json.dumps(sys.argv[1:]) + '\\n')
                if sys.argv[1] == 'test':
                    for event in ({'type':'testStart','test':{'id':1,'name':'synthetic'}},
                                  {'type':'testDone','testID':1,'result':'success'},
                                  {'type':'done','success':True}):
                        print(json.dumps(event))
                    path = next((arg.split('=', 1)[1] for arg in sys.argv
                                 if arg.startswith('--coverage-path=')), 'coverage/lcov.info')
                    pathlib.Path(path).parent.mkdir(parents=True, exist_ok=True)
                    pathlib.Path(path).write_text('LF:2\\nLH:1\\n')
                    sys.exit(int(os.environ['TEST_EXIT']))
                '''))
            timeout = work / 'bin' / 'timeout'
            timeout.write_text(textwrap.dedent('''\
                #!/usr/bin/env python3
                import json, os, subprocess, sys
                with open(os.environ['TIMEOUT_ARGS'], 'w') as output:
                    json.dump(sys.argv[1:4], output)
                sys.exit(subprocess.call(sys.argv[4:]))
                '''))
            flutter.chmod(0o755)
            timeout.chmod(0o755)
            env = dict(os.environ, PATH=f"{work / 'bin'}:{os.environ['PATH']}",
                       COMMANDS=str(work / 'commands.jsonl'),
                       TIMEOUT_ARGS=str(work / 'timeout.json'), TEST_EXIT=test_exit)
            env.pop('CI', None)
            result = subprocess.run(['bash', 'ci/check.sh', *args], cwd=work, env=env,
                                    capture_output=True, text=True, timeout=20)
            commands = [json.loads(line) for line in (work / 'commands.jsonl').read_text().splitlines()] \
                if (work / 'commands.jsonl').exists() else []
            timeout_args = json.loads((work / 'timeout.json').read_text()) \
                if (work / 'timeout.json').exists() else []
            files = {str(path.relative_to(work)) for path in work.rglob('*') if path.is_file()} - set(tree) \
                - {name for name, _ in links}
            return result, commands, timeout_args, files

    def test_default_and_ai_modes_run_their_lane_with_correct_defines(self):
        for mode in ('default', 'ai'):
            with self.subTest(mode=mode):
                result, commands, timeout_args, files = self.run_check(*(() if mode == 'default' else (mode,)))
                self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
                self.assertEqual(timeout_args, ['--signal=TERM', '--kill-after=15s', '30m'])
                self.assertEqual(commands[:2], [['pub', 'get', '--enforce-lockfile'], ['analyze', '--no-pub']])
                expected_args = ['test', '--no-pub', '--coverage', '--timeout=60s', '--machine']
                if mode == 'ai':
                    expected_args += ['--dart-define=MERGELINE_AI_ASSISTANT=true',
                                      '--dart-define=MERGELINE_AI_BACKGROUND=false',
                                      '--coverage-path=coverage-ai/lcov.info']
                self.assertEqual(commands[2], expected_args + self.lane(mode))
                output = 'ci-output' if mode == 'default' else 'ci-output-ai'
                coverage = 'coverage' if mode == 'default' else 'coverage-ai'
                self.assertIn(f'{output}/junit.xml', files)
                self.assertIn(f'{coverage}/lcov.info', files)

    def test_failed_flutter_test_remains_a_failure(self):
        result, _, _, files = self.run_check('ai', test_exit='7')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('test_exit=7', result.stdout)
        self.assertIn('ci-output-ai/junit.xml', files)

    def test_unknown_mode_is_rejected_before_invoking_flutter(self):
        for args in (('unknown',), ('--list-tests',), ('default', '--unknown'),
                     ('ai', '--list-tests', 'extra')):
            with self.subTest(args=args):
                result, commands, _, files = self.run_check(*args)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(commands, [])
                self.assertEqual(result.stdout, '')

    def test_list_tests_prints_each_lanes_files_without_running_flutter(self):
        found = len(self.SANDBOX_TESTS + self.SHARED_TESTS)
        for mode in ('default', 'ai'):
            with self.subTest(mode=mode):
                result, commands, _, files = self.run_check(mode, '--list-tests')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.splitlines(), self.lane(mode))
                self.assertIn(f'{mode} lane runs {len(self.lane(mode))} of {found} test files', result.stderr)
                self.assertEqual(commands, [])
                self.assertEqual([name for name in files if name.startswith(('ci-output', 'coverage'))], [],
                                 'listing writes no output or coverage')

    def test_sandbox_tool_tests_run_only_in_the_ai_lane_and_gate_tests_in_both(self):
        lanes = {mode: self.run_check(mode, '--list-tests')[0].stdout.splitlines() for mode in ('default', 'ai')}
        for gate in GATE_TESTS:
            self.assertIn(gate, lanes['default'])
            self.assertIn(gate, lanes['ai'])
        self.assertEqual(sorted(set(lanes['ai']) - set(lanes['default'])), sorted(self.SANDBOX_TESTS))
        self.assertEqual(set(lanes['default']) - set(lanes['ai']), set())
        for helper in self.HELPERS:
            self.assertNotIn(helper, lanes['ai'])

    def test_symlinked_test_files_are_listed_as_flutter_test_finds_them(self):
        # flutter_tools _findTests: listSync(recursive: true, followLinks: false), then
        # every *_test.dart entry that is a file once a link is followed.
        links = (('test/linked_test.dart', 'app_test.dart'),
                 ('test/ai/mr7_sandbox_linked_test.dart', 'mr7_release_gate_test.dart'),
                 ('test/dangling_test.dart', 'missing.dart'),
                 ('test/directory_test.dart', 'offline'),
                 ('test/linked_directory', 'offline'))
        found = len(self.SANDBOX_TESTS + self.SHARED_TESTS) + 2
        for mode in ('default', 'ai'):
            with self.subTest(mode=mode):
                result, commands, _, _ = self.run_check(mode, '--list-tests', links=links)
                self.assertEqual(result.returncode, 0, result.stderr)
                expected = sorted(self.lane(mode) + ['test/linked_test.dart']
                                  + (['test/ai/mr7_sandbox_linked_test.dart'] if mode == 'ai' else []))
                self.assertEqual(result.stdout.splitlines(), expected)
                self.assertIn(f'{mode} lane runs {len(expected)} of {found} test files', result.stderr)
                self.assertEqual(commands, [])

    def test_no_test_files_fails_before_invoking_flutter(self):
        result, commands, _, _ = self.run_check(tree=self.HELPERS)
        self.assertEqual(result.returncode, 1)
        self.assertIn('no test files found under test/', result.stderr)
        self.assertEqual(commands, [])

    def test_repository_lanes_differ_by_exactly_the_sandbox_tool_tests(self):
        everything = sorted(str(path.relative_to(ROOT)) for path in (ROOT / 'test').rglob('*_test.dart')
                            if path.is_file())
        sandbox = sorted(str(path.relative_to(ROOT)) for pattern in ('mr7_sandbox_*_test.dart', 'mr7_live_*_test.dart')
                         for path in (ROOT / 'test' / 'ai').glob(pattern))
        self.assertTrue(sandbox, 'the repository has MR7 sandbox tool tests')
        lanes = {}
        for mode in ('default', 'ai'):
            result = subprocess.run(['bash', 'ci/check.sh', mode, '--list-tests'], cwd=ROOT,
                                    capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stderr)
            lanes[mode] = result.stdout.splitlines()
        self.assertEqual(lanes['ai'], everything, 'the ai lane runs every test file under test/')
        self.assertEqual(sorted(set(everything) - set(lanes['default'])), sandbox)
        self.assertEqual(len(lanes['default']), len(set(lanes['default'])))
        self.assertTrue(set(lanes['default']) <= set(everything))
        for gate in GATE_TESTS:
            self.assertTrue((ROOT / gate).is_file(), gate)
            self.assertIn(gate, lanes['default'])
            self.assertIn(gate, lanes['ai'])


if __name__ == '__main__':
    unittest.main()
