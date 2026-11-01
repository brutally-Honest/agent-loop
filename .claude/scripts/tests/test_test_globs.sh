#!/usr/bin/env bash
# TEST_GLOBS match test files at any depth, because match_globs uses case patterns, where
# * also matches "/". A "no test file changed" error on a nested test file is a wrong
# base commit, not these globs.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
mk_repo

matches() { bash -c '. .claude/scripts/lib.sh; al_init; match_globs "$1" "$TEST_GLOBS"' _ "$1"; }

for p in cmd/app/viewer_usage_test.go internal/timeline/usage_render_test.go viewer_test.go a/b/c/d/deep_test.go; do
	t "$p is a test file"
	matches "$p" && pass || fail "$p does not match TEST_GLOBS"
done

for p in cmd/app/viewer.go internal/timeline/render.go testdata.go; do
	t "$p is not a test file"
	matches "$p" && fail "$p matches TEST_GLOBS" || pass
done

done_tests
