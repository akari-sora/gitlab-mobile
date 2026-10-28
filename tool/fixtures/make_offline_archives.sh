#!/bin/sh
set -eu
# The synthetic Git object database stays in the ignored task scratch area.
# No branch or commit in the application checkout is modified.
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
mkdir -p "$repo_root/.dart_tool/c3a/archive" "$repo_root/test/fixtures/offline"
scratch=$(mktemp -d "$repo_root/.dart_tool/c3a/archive/fixture.XXXXXXXX")
trap 'rm -rf "$scratch"' EXIT HUP INT TERM
git init -q "$scratch/repo"
mkdir -p "$scratch/repo/docs" "$scratch/repo/long/$(printf '%090d' 0)" "$scratch/repo/pax/$(printf '%0150d' 0)"
printf 'hello\n' > "$scratch/repo/docs/hello.txt"
printf 'line\n' > "$scratch/repo/docs/crlf.txt"
printf '$Id$\n' > "$scratch/repo/docs/ident.txt"
printf '$Format:%%H$\n' > "$scratch/repo/docs/subst.txt"
printf 'ignored\n' > "$scratch/repo/docs/ignored.txt"
printf 'docs/crlf.txt text eol=crlf\ndocs/ident.txt ident\ndocs/subst.txt export-subst\ndocs/ignored.txt export-ignore\n' > "$scratch/repo/.gitattributes"
printf 'long\n' > "$scratch/repo/long/$(printf '%090d' 0)/$(printf '%090d' 0).txt"
printf 'pax\n' > "$scratch/repo/pax/$(printf '%0150d' 0)/$(printf '%0150d' 0).txt"
ln -s hello.txt "$scratch/repo/docs/link"
git -C "$scratch/repo" add .
git -C "$scratch/repo" update-index --add --cacheinfo 160000,0000000000000000000000000000000000000001,submodule
tree=$(git -C "$scratch/repo" write-tree)
git -C "$scratch/repo" archive --format=tar.gz --prefix=fixture/ "$tree" > "$repo_root/test/fixtures/offline/synthetic.tar.gz"
git -C "$scratch/repo" archive --format=tar.gz --prefix=fixture/ "$tree" docs > "$repo_root/test/fixtures/offline/synthetic-docs.tar.gz"
commit=$(printf 'offline fixture\n' | env \
  GIT_AUTHOR_NAME=Fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
  GIT_COMMITTER_NAME=Fixture GIT_COMMITTER_EMAIL=fixture@example.invalid \
  GIT_AUTHOR_DATE='2000-01-01T00:00:00Z' GIT_COMMITTER_DATE='2000-01-01T00:00:00Z' \
  git -C "$scratch/repo" commit-tree "$tree")
git -C "$scratch/repo" archive --format=tar.gz --prefix=fixture/ "$commit" > "$repo_root/test/fixtures/offline/synthetic-commit.tar.gz"
