#!/usr/bin/env bash
set -euo pipefail
: "${CI_JOB_TOKEN:?This command runs inside GitLab CI}"
: "${CI_COMMIT_SHA:?Missing commit identity}"
if [ "${CI_COMMIT_BRANCH:-}" != "${CI_DEFAULT_BRANCH:-main}" ]; then
  echo 'Preview delivery is restricted to the default branch.' >&2
  exit 1
fi
(cd artifacts && sha256sum --check SHA256SUMS)
base="${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/packages/generic/gitlab-mobile-preview/${CI_COMMIT_SHA}"
for file in artifacts/*.apk artifacts/build-metadata.json artifacts/SHA256SUMS; do
  curl --fail-with-body --retry 3 --retry-all-errors --retry-connrefused --retry-delay 2 \
    --header "JOB-TOKEN: ${CI_JOB_TOKEN}" \
    --upload-file "$file" "$base/$(basename "$file")"
done
printf 'Preview package delivered for commit %s\n' "$CI_COMMIT_SHA"
