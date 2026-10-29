from pathlib import Path
import os
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'ci' / 'gh2gl_sync.sh'
# Ignore the developer's global and system git config (hooks, signing, templates) so the
# test repositories behave the same everywhere and their own hooks run.
EMPTY_GITCONFIG = Path(tempfile.mkdtemp()) / 'gitconfig'
EMPTY_GITCONFIG.write_text('')
GIT_ENV = dict(os.environ, GIT_CONFIG_GLOBAL=str(EMPTY_GITCONFIG), GIT_CONFIG_NOSYSTEM='1')


def git(*args, cwd=None):
    return subprocess.run(['git', *args], cwd=cwd, check=True, capture_output=True, text=True,
                          env=GIT_ENV).stdout.strip()


# In CI (CI is set) a missing git must fail the run instead of skipping it.
@unittest.skipUnless((shutil.which('git') and shutil.which('bash')) or os.environ.get('CI'), 'git and bash are required')
class Gh2GlSyncTests(unittest.TestCase):
    """Runs ci/gh2gl_sync.sh against two local bare repositories standing in for GitHub and GitLab."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.github = self.tmp / 'github.git'
        self.gitlab = self.tmp / 'gitlab.git'
        for bare in (self.github, self.gitlab):
            git('init', '-q', '--bare', '-b', 'main', str(bare))
            git('config', 'receive.advertisePushOptions', 'true', cwd=bare)
        self.work = self.tmp / 'work'
        git('init', '-q', '-b', 'main', str(self.work))
        git('config', 'user.email', 't@example.invalid', cwd=self.work)
        git('config', 'user.name', 't', cwd=self.work)
        self.commit('base')
        git('push', '-q', str(self.github), 'main', cwd=self.work)
        git('push', '-q', str(self.gitlab), 'main', cwd=self.work)
        self.key = self.tmp / 'key'
        self.key.write_text('not a real key\n')

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def commit(self, name):
        (self.work / name).write_text(name)
        git('add', name, cwd=self.work)
        git('commit', '-q', '-m', name, cwd=self.work)
        return git('rev-parse', 'HEAD', cwd=self.work)

    def run_sync(self, key=None):
        env = dict(GIT_ENV)
        env.update({
            'GH2GL_GITHUB': 'example/mirror',
            'GH2GL_DEPLOY_KEY': str(key or self.key),
            'GH2GL_GITHUB_URL': str(self.github),
            'GH2GL_GITLAB_URL': str(self.gitlab),
            'CI_DEFAULT_BRANCH': 'main',
            'CI_PROJECT_PATH': 'example/project',
        })
        return subprocess.run(['bash', str(SCRIPT)], env=env, capture_output=True, text=True)

    def ref(self, bare, name):
        out = subprocess.run(['git', 'rev-parse', '-q', '--verify', f'refs/heads/{name}'], cwd=bare,
                             capture_output=True, text=True, env=GIT_ENV)
        return out.stdout.strip() or None

    def test_new_branch_is_synced(self):
        git('checkout', '-q', '-b', 'claude/feature', cwd=self.work)
        sha = self.commit('feature')
        git('push', '-q', str(self.github), 'claude/feature', cwd=self.work)
        result = self.run_sync()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.ref(self.gitlab, 'claude/feature'), sha)
        self.assertIn('synced claude/feature', result.stdout)

    def test_fast_forward_update_is_synced(self):
        git('checkout', '-q', '-b', 'claude/feature', cwd=self.work)
        self.commit('one')
        git('push', '-q', str(self.github), 'claude/feature', cwd=self.work)
        self.assertEqual(self.run_sync().returncode, 0)
        sha = self.commit('two')
        git('push', '-q', str(self.github), 'claude/feature', cwd=self.work)
        result = self.run_sync()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.ref(self.gitlab, 'claude/feature'), sha)

    def test_gitlab_side_commits_are_not_overwritten(self):
        git('checkout', '-q', '-b', 'claude/feature', cwd=self.work)
        self.commit('one')
        git('push', '-q', str(self.github), 'claude/feature', cwd=self.work)
        self.assertEqual(self.run_sync().returncode, 0)
        review_fix = self.commit('review-fix')
        git('push', '-q', str(self.gitlab), 'claude/feature', cwd=self.work)
        git('reset', '-q', '--hard', 'HEAD~1', cwd=self.work)
        self.commit('github-only')
        git('push', '-q', '--force', str(self.github), 'claude/feature', cwd=self.work)
        result = self.run_sync()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.ref(self.gitlab, 'claude/feature'), review_fix)
        self.assertIn('WARNING skip claude/feature', result.stdout)

    def test_merged_branch_is_not_revived(self):
        git('checkout', '-q', '-b', 'claude/done', cwd=self.work)
        self.commit('done')
        git('push', '-q', str(self.github), 'claude/done', cwd=self.work)
        git('checkout', '-q', 'main', cwd=self.work)
        git('merge', '-q', '--ff-only', 'claude/done', cwd=self.work)
        git('push', '-q', str(self.gitlab), 'main', cwd=self.work)
        result = self.run_sync()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIsNone(self.ref(self.gitlab, 'claude/done'))
        self.assertIn('skip claude/done: already in main', result.stdout)

    def test_commits_pushed_straight_to_github_main_are_rescued(self):
        sha = self.commit('direct')
        git('push', '-q', str(self.github), 'main', cwd=self.work)
        result = self.run_sync()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.ref(self.gitlab, f'rescue/github-main-{sha[:8]}'), sha)
        self.assertNotEqual(self.ref(self.gitlab, 'main'), sha)

    def add_hook(self, body):
        hook = self.gitlab / 'hooks' / 'pre-receive'
        hook.write_text('#!/usr/bin/env bash\n' + body)
        hook.chmod(0o755)

    def test_push_options_open_a_draft_mr_and_redraft_on_update(self):
        log = self.tmp / 'options.log'
        self.add_hook(f'''while read -r old new ref; do echo "$ref" >> {log}; done
for i in $(seq 0 $(( ${{GIT_PUSH_OPTION_COUNT:-0}} - 1 ))); do v="GIT_PUSH_OPTION_$i"; echo "${{!v}}" >> {log}; done
''')
        git('checkout', '-q', '-b', 'claude/feature', cwd=self.work)
        self.commit('one')
        git('push', '-q', str(self.github), 'claude/feature', cwd=self.work)
        self.assertEqual(self.run_sync().returncode, 0)
        first = log.read_text()
        self.assertIn('merge_request.create', first)
        self.assertIn('merge_request.draft', first)
        self.assertIn('merge_request.target=main', first)
        log.write_text('')
        self.commit('two')
        git('push', '-q', str(self.github), 'claude/feature', cwd=self.work)
        self.assertEqual(self.run_sync().returncode, 0)
        second = log.read_text()
        self.assertIn('merge_request.draft', second)
        self.assertNotIn('merge_request.create', second)

    def test_one_rejected_branch_does_not_stop_the_others(self):
        self.add_hook('''while read -r old new ref; do
  if [ "$ref" = refs/heads/claude/bad ]; then echo "rejected by test hook" >&2; exit 1; fi
done
''')
        git('checkout', '-q', '-b', 'claude/bad', cwd=self.work)
        self.commit('bad')
        git('push', '-q', str(self.github), 'claude/bad', cwd=self.work)
        git('checkout', '-q', 'main', cwd=self.work)
        git('checkout', '-q', '-b', 'claude/good', cwd=self.work)
        good = self.commit('good')
        git('push', '-q', str(self.github), 'claude/good', cwd=self.work)
        result = self.run_sync()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.ref(self.gitlab, 'claude/good'), good)
        self.assertIsNone(self.ref(self.gitlab, 'claude/bad'))
        self.assertIn('ERROR push of claude/bad failed', result.stdout)

    def test_squash_merged_branch_is_not_revived(self):
        git('checkout', '-q', '-b', 'claude/sq', cwd=self.work)
        self.commit('sq-a')
        self.commit('sq-b')
        git('push', '-q', str(self.github), 'claude/sq', cwd=self.work)
        git('checkout', '-q', 'main', cwd=self.work)
        git('merge', '-q', '--squash', 'claude/sq', cwd=self.work)
        git('commit', '-q', '-m', 'squashed', cwd=self.work)
        git('push', '-q', str(self.gitlab), 'main', cwd=self.work)
        result = self.run_sync()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIsNone(self.ref(self.gitlab, 'claude/sq'))
        self.assertIn('skip claude/sq: its changes are already in main', result.stdout)

    def test_non_file_key_variable_is_refused_without_echo(self):
        secret = '-----BEGIN OPENSSH PRIVATE KEY-----notreal'
        result = self.run_sync(key=secret)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('notreal', result.stdout + result.stderr)
        self.assertIn('must be a file-type', result.stderr)


class Gh2GlPipelineTests(unittest.TestCase):
    def setUp(self):
        self.content = (ROOT / '.gitlab-ci.yml').read_text(encoding='utf-8')

    def test_sync_job_runs_only_on_the_schedule_and_uses_its_environment(self):
        block = re.search(r'^gh2gl_sync:\n(.*?)(?=\n\S|\Z)', self.content, re.MULTILINE | re.DOTALL).group(1)
        self.assertIn('\'$GH2GL_SYNC == "1" && $CI_PIPELINE_SOURCE == "schedule"\'', block)
        self.assertIn('name: gh2gl-sync', block)

    def test_other_jobs_are_skipped_in_the_sync_pipeline(self):
        # .regular (python_checks), .app_regular (flutter_checks, flutter_ai_checks, native_templates,
        # android_debug), main_run_to_completion, publish_preview and public_api_smoke end their "never"
        # condition with the GH2GL_SYNC check.
        self.assertEqual(self.content.count('|| $GH2GL_SYNC == "1"\''), 5)
        for job in ('.regular', '.app_regular', 'main_run_to_completion', 'publish_preview', 'public_api_smoke'):
            block = re.search(rf'^{re.escape(job)}:\n(.*?)(?=\n\S|\Z)', self.content,
                              re.MULTILINE | re.DOTALL).group(1)
            self.assertIn('$GH2GL_SYNC == "1"', block, job)


if __name__ == '__main__':
    unittest.main()
