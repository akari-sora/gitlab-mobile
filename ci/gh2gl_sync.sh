#!/usr/bin/env bash
# Bring work pushed to the GitHub mirror back to this canonical GitLab project.
# Runs only in the scheduled pipeline with GH2GL_SYNC=1 (see docs/CI.md "GitHub branch sync").
#   - A GitHub branch matching GH2GL_PATTERNS (default claude/*) is pushed to GitLab under the same
#     name only as a fast-forward: when GitLab has commits GitHub lacks (review fixes, a rebase) or
#     GitHub rewrote history, the branch is skipped with a warning. GitLab stays canonical.
#   - A branch already contained in the default branch (merged, including squash merges) is skipped,
#     so it is not revived.
#   - A new branch opens a draft MR to the default branch through push options; an update marks the
#     MR draft again so a reviewed head cannot change silently.
#   - Commits pushed straight to GitHub's default branch that GitLab lacks are saved as
#     rescue/github-main-<sha8> with a draft MR (this works when the schedule runs before the next
#     GitLab push mirror update overwrites GitHub's default branch).
# The push uses a project deploy key (file variable GH2GL_DEPLOY_KEY, scoped to the gh2gl-sync
# environment). It cannot push to protected branches. Nothing is deleted.
set -euo pipefail

: "${GH2GL_GITHUB:?set GH2GL_GITHUB to owner/repo of the GitHub mirror}"
if [ -z "${GH2GL_DEPLOY_KEY:-}" ] || [ ! -f "${GH2GL_DEPLOY_KEY}" ]; then
  echo "GH2GL_DEPLOY_KEY must be a file-type CI/CD variable" >&2
  exit 1
fi
patterns="${GH2GL_PATTERNS:-claude/*}"
default_branch="${CI_DEFAULT_BRANCH:-main}"
gitlab_url="${GH2GL_GITLAB_URL:-git@gitlab.com:${CI_PROJECT_PATH}.git}"
github_url="${GH2GL_GITHUB_URL:-https://github.com/${GH2GL_GITHUB}.git}"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
install -m 600 "${GH2GL_DEPLOY_KEY}" "${work}/key"
# gitlab.com host key (published fingerprint SHA256:eUXGGm1YGsMAS7vkcx6JOJdOGHPem5gQp4taiCfCLB8).
echo 'gitlab.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAfuCHKVTjquxvt6CM6tdG4SLp1Btn/nOeHHE5UOzRdf' > "${work}/known_hosts"
export GIT_SSH_COMMAND="ssh -i ${work}/key -o IdentitiesOnly=yes -o UserKnownHostsFile=${work}/known_hosts -o StrictHostKeyChecking=yes"

git init -q --bare "${work}/sync.git"
cd "${work}/sync.git"

gh_specs=("+refs/heads/${default_branch}:refs/gh-main")
gl_specs=("+refs/heads/${default_branch}:refs/gl-main")
IFS=',' read -r -a pat_list <<< "${patterns}"
for p in "${pat_list[@]}"; do
  gh_specs+=("+refs/heads/${p}:refs/gh/${p}")
  gl_specs+=("+refs/heads/${p}:refs/gl/${p}")
done
git fetch -q --prune "${github_url}" "${gh_specs[@]}"
git fetch -q --prune "${gitlab_url}" "${gl_specs[@]}"

synced=0; skipped=0; failed=0
while read -r ref; do
  [ -n "${ref}" ] || continue
  branch="${ref#refs/gh/}"
  if [ "${branch}" = "${default_branch}" ]; then continue; fi
  gh_sha="$(git rev-parse "${ref}")"
  gl_sha="$(git rev-parse -q --verify "refs/gl/${branch}" || true)"
  if [ "${gh_sha}" = "${gl_sha}" ]; then continue; fi
  if git merge-base --is-ancestor "${gh_sha}" refs/gl-main; then
    echo "skip ${branch}: already in ${default_branch}"; skipped=$((skipped + 1)); continue
  fi
  # A squash merge leaves no ancestry; merging the branch into the default branch would change nothing.
  if merged_tree="$(git merge-tree --write-tree refs/gl-main "${gh_sha}" 2>/dev/null)" &&
     [ "${merged_tree}" = "$(git rev-parse 'refs/gl-main^{tree}')" ]; then
    echo "skip ${branch}: its changes are already in ${default_branch}"; skipped=$((skipped + 1)); continue
  fi
  if [ -n "${gl_sha}" ] && ! git merge-base --is-ancestor "${gl_sha}" "${gh_sha}"; then
    echo "WARNING skip ${branch}: GitLab ${gl_sha:0:8} is not an ancestor of GitHub ${gh_sha:0:8} (GitLab has its own commits or GitHub rewrote history); resolve on GitLab"
    skipped=$((skipped + 1)); continue
  fi
  if [ -z "${gl_sha}" ]; then
    opts=(-o merge_request.create -o "merge_request.target=${default_branch}" -o merge_request.draft
          -o "merge_request.description=Synced from GitHub ${GH2GL_GITHUB} branch ${branch} by the gh2gl_sync schedule. Review and merge on GitLab; the push mirror then updates GitHub.")
    lease="--force-with-lease=refs/heads/${branch}:"
  else
    opts=(-o merge_request.draft)
    lease="--force-with-lease=refs/heads/${branch}:${gl_sha}"
  fi
  if git push -q "${lease}" "${opts[@]}" "${gitlab_url}" "${ref}:refs/heads/${branch}"; then
    echo "synced ${branch} ${gh_sha:0:8}"; synced=$((synced + 1))
  else
    echo "ERROR push of ${branch} failed"; failed=$((failed + 1))
  fi
done < <(git for-each-ref --format='%(refname)' refs/gh/)

if ! git merge-base --is-ancestor refs/gh-main refs/gl-main; then
  sha="$(git rev-parse refs/gh-main)"
  rescue="rescue/github-main-${sha:0:8}"
  if [ -z "$(git ls-remote "${gitlab_url}" "refs/heads/${rescue}" | cut -f1)" ]; then
    if git push -q -o merge_request.create -o "merge_request.target=${default_branch}" -o merge_request.draft \
        -o "merge_request.title=Draft: rescue commits pushed straight to GitHub ${default_branch}" \
        "${gitlab_url}" "refs/gh-main:refs/heads/${rescue}"; then
      echo "GitHub ${default_branch} had commits GitLab lacks; saved as ${rescue}"
    else
      echo "ERROR rescue push of ${rescue} failed"; failed=$((failed + 1))
    fi
  fi
fi
echo "done: ${synced} synced, ${skipped} skipped, ${failed} failed"
[ "${failed}" -eq 0 ]
