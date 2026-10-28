#!/usr/bin/env bash
set -euo pipefail
: "${CI_JOB_TOKEN:?This command runs inside GitLab CI}"
: "${CI_COMMIT_SHA:?Missing commit identity}"
mode="${1:-off}"
case "$mode" in off|ai) ;; *) echo 'Unknown delivery mode.' >&2; exit 1 ;; esac
if [ "$#" -gt 1 ] || [ "${CI_PROJECT_ID:-}" != 86648389 ] || \
   [ "${CI_COMMIT_REF_PROTECTED:-}" != true ] || [ "${CI_COMMIT_BRANCH:-}" != main ] || \
   [ "${CI_PIPELINE_SOURCE:-}" = merge_request_event ]; then
  echo 'Preview delivery requires this project protected release branch.' >&2
  exit 1
fi
python3 ci/mr7_attestation.py delivery --mode "$mode" \
  --attestation-job-id "${MR7_ATTESTATION_JOB_ID:-}"
(cd artifacts && sha256sum --check SHA256SUMS)
base="https://gitlab.com/api/v4/projects/86648389/packages/generic/gitlab-mobile-preview/${CI_COMMIT_SHA}"
for file in artifacts/*.apk artifacts/build-metadata.json artifacts/SHA256SUMS; do
  curl --fail-with-body --retry 3 --retry-all-errors --retry-connrefused --retry-delay 2 \
    --header "JOB-TOKEN: ${CI_JOB_TOKEN}" \
    --upload-file "$file" "$base/$(basename "$file")"
done
printf 'Preview package delivered for commit %s\n' "$CI_COMMIT_SHA"
