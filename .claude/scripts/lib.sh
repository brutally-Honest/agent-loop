#!/usr/bin/env bash
# lib.sh — shared helpers for the agent-loop scripts and hooks. Sourced, never run.
#
# Portable: bash 3.2+ (macOS default), POSIX awk (mawk/BWK/gawk), git, sha256sum|shasum.
# Every parser here works on comment-stripped markdown, so the hints inside
# <!-- ... --> in the templates never count as content.

AL_SCRIPTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
AL_KIT_DIR=$(dirname "$AL_SCRIPTS_DIR")   # the .claude/ folder these scripts live in

die()   { printf 'agent-loop: %s\n' "$*" >&2; exit 1; }
warn()  { printf 'agent-loop: warning: %s\n' "$*" >&2; }
now()   { date -u +%Y-%m-%dT%H:%M:%SZ; }
today() { date -u +%Y-%m-%d; }

# --- repo + config ----------------------------------------------------------

al_init() {
	REPO=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repository"
	cd "$REPO" || die "cannot cd to $REPO"
	VERIFY_CMD=""
	TEST_CMD=""
	BASE_BRANCH=""
	SPECS_DIR="specs"
	MAX_FIX_ROUNDS=2
	PLAN_MAX_LINES=200
	QUICK_MAX_ACS=5
	QUICK_MAX_STEPS=5
	PROTECTED_GLOBS=".githooks/* .github/workflows/*"
	WATCHED_GLOBS="Makefile go.mod go.sum package.json package-lock.json pnpm-lock.yaml .golangci.yml .golangci.yaml .eslintrc* eslint.config.* tsconfig*.json"
	TEST_GLOBS="*_test.go *.test.* *.spec.* test_*.py *_test.py tests/* test/* */tests/* */test/* */__tests__/*"
	READONLY_EXTRA_CMDS=""
	AL_CONF="$REPO/.claude/loop.conf"
	[ -f "$AL_CONF" ] || AL_CONF="$AL_KIT_DIR/loop.conf"
	# shellcheck disable=SC1090
	if [ -f "$AL_CONF" ]; then . "$AL_CONF"; fi
	STATE_ROOT="$REPO/.agent-loop"
}

suggest_verify() { # best guess at VERIFY_CMD from files at the repo root; prints nothing if no guess
	local parts="" pm s r
	_sv_add() { if [ -z "$parts" ]; then parts=$1; else parts="$parts && $1"; fi; }
	if [ -f Makefile ] && grep -qE '^verify:' Makefile; then echo "make verify"; return 0; fi
	if [ -f package.json ]; then
		pm=npm
		if [ -f pnpm-lock.yaml ]; then pm=pnpm; elif [ -f yarn.lock ]; then pm=yarn; elif [ -f bun.lockb ] || [ -f bun.lock ]; then pm=bun; fi
		for s in typecheck lint build test; do
			r=$(jq -r --arg s "$s" '.scripts[$s] // empty' package.json 2>/dev/null)
			[ -n "$r" ] || continue
			case $r in *'no test specified'*) continue ;; esac
			_sv_add "$pm run $s"
		done
	fi
	if [ -f go.mod ]; then _sv_add "go vet ./... && go test ./..."; fi
	if [ -f Cargo.toml ]; then _sv_add "cargo test"; fi
	if [ -f pyproject.toml ] || [ -f setup.py ] || [ -f pytest.ini ] || [ -f tox.ini ]; then _sv_add "pytest -q"; fi
	if [ -n "$parts" ]; then printf '%s\n' "$parts"; fi
	return 0
}

verify_unset_msg() { # one line: why nothing ran + a suggestion, wherever an empty VERIFY_CMD stops something
	local g; g=$(suggest_verify)
	if [ -n "$g" ]; then printf 'VERIFY_CMD is not set in .claude/loop.conf — suggested from this repo: VERIFY_CMD="%s"' "$g"
	else printf 'VERIFY_CMD is not set in .claude/loop.conf — set it to the command that runs your tests, lint and build'; fi
}

sha256() {
	if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
	else shasum -a 256 | cut -d' ' -f1; fi
}

match_globs() { # path "glob glob ..." -> 0 if the path matches any glob
	local p=$1 g
	set -f
	for g in $2; do
		# shellcheck disable=SC2254
		case $p in $g) set +f; return 0 ;; esac
	done
	set +f
	return 1
}

current_branch() { git symbolic-ref --quiet --short HEAD 2>/dev/null; }

base_branch() {
	if [ -n "$BASE_BRANCH" ]; then printf '%s\n' "$BASE_BRANCH"; return; fi
	local b
	if b=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null); then
		b=${b#origin/}
		git show-ref --verify --quiet "refs/heads/$b" && { printf '%s\n' "$b"; return; }
	fi
	for b in main master trunk develop; do
		git show-ref --verify --quiet "refs/heads/$b" && { printf '%s\n' "$b"; return; }
	done
	current_branch
}

tree_clean() { [ -z "$(git status --porcelain 2>/dev/null)" ]; }

# --- frontmatter + markdown ---------------------------------------------------

fm_get() { # file key -> value ('' if absent)
	[ -f "$1" ] || return 0
	K="$2" awk '
		NR == 1 { if ($0 != "---") exit; next }
		/^---[[:space:]]*$/ { exit }
		index($0, ENVIRON["K"] ":") == 1 {
			v = substr($0, length(ENVIRON["K"]) + 2)
			sub(/^[[:space:]]+/, "", v); sub(/[[:space:]]+$/, "", v)
			print v; exit
		}' "$1"
}

fm_set() { # file key value  (adds the key if missing; keeps file permissions)
	local f=$1 tmp
	tmp=$(mktemp "${TMPDIR:-/tmp}/al.XXXXXX") || return 1
	K="$2" V="$3" awk '
		NR == 1 && $0 == "---" { infm = 1; print; next }
		function kv() { return ENVIRON["V"] == "" ? ENVIRON["K"] ":" : ENVIRON["K"] ": " ENVIRON["V"] }
		infm && /^---[[:space:]]*$/ { if (!done) print kv(); infm = 0; print; next }
		infm && index($0, ENVIRON["K"] ":") == 1 { print kv(); done = 1; next }
		{ print }' "$f" > "$tmp" && cat "$tmp" > "$f"
	rm -f "$tmp"
}

strip_fm() { awk 'NR == 1 && $0 == "---" { infm = 1; next } infm { if ($0 ~ /^---[[:space:]]*$/) infm = 0; next } { print }'; }
fm_body()  { [ -f "$1" ] && strip_fm < "$1"; }
body_hash() { fm_body "$1" | sha256; }

strip_noise() { # drop <!-- comments --> (single or multi line) and blank lines
	awk '{
		line = $0; out = ""
		while (1) {
			if (incom) { p = index(line, "-->"); if (!p) { line = ""; break }; line = substr(line, p + 3); incom = 0 }
			p = index(line, "<!--"); if (!p) { out = out line; break }
			out = out substr(line, 1, p - 1); line = substr(line, p + 4); incom = 1
		}
		if (out ~ /[^[:space:]]/) print out
	}'
}

doc() { fm_body "$1" | strip_noise; }   # file -> body without frontmatter, comments, blank lines

sec() { # stdin markdown, $1 = level-2 heading title (case-insensitive) -> that section's lines
	T="$1" awk '
		function n(s) { s = tolower(s); sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
		/^## / { if (insec) exit; if (n(substr($0, 4)) == n(ENVIRON["T"])) { insec = 1; next } }
		insec { print }'
}
section() { doc "$1" | sec "$2"; }

ac_active() { awk '/^[[:space:]]*[-*][[:space:]]+\*\*AC[0-9]+\*\*/ { if (match($0, /AC[0-9]+/)) print substr($0, RSTART, RLENGTH) }'; }
ac_struck() { awk '/^[[:space:]]*[-*][[:space:]]+~~\*\*AC[0-9]+\*\*~~/ { if (match($0, /AC[0-9]+/)) print substr($0, RSTART, RLENGTH) }'; }
ac_line()   { I="$1" awk '/^[[:space:]]*[-*][[:space:]]+(~~)?\*\*AC[0-9]+\*\*/ { if (match($0, /AC[0-9]+/) && substr($0, RSTART, RLENGTH) == ENVIRON["I"]) { print; exit } }'; }
ac_refs()   { grep -oE 'AC[0-9]+' | sort -u; }   # every AC id mentioned in stdin
in_list()   { printf '%s\n' "$2" | grep -qx -- "$1"; }

# --- features + artifacts -----------------------------------------------------

resolve_feature() { # [id | NNN] -> sets F, or dies
	local arg=${1:-} d br n
	if [ -n "$arg" ]; then
		if [ -d "$SPECS_DIR/$arg" ]; then F=$arg; return 0; fi
		n=${arg%%-*}
		for d in "$SPECS_DIR/$n"-*; do [ -d "$d" ] && { F=${d##*/}; return 0; }; done
		die "no feature '$arg' under $SPECS_DIR/"
	fi
	br=$(current_branch) || die "detached HEAD: pass the feature id (e.g. 012)"
	case ${br##*/} in
		[0-9][0-9][0-9]-*) F=${br##*/} ;;
		*) die "branch '$br' is not a feature branch (<kind>/NNN-slug) — check out one, or pass the feature id" ;;
	esac
	[ -d "$SPECS_DIR/$F" ] || die "branch $br has no $SPECS_DIR/$F/ folder"
}

art() { printf '%s/%s/%s.md' "$SPECS_DIR" "$F" "$1"; }   # spec|plan|tasks|brief|research
is_quick() { [ -f "$(art brief)" ]; }

spec_fp() { # fingerprint of the contract sections: change any of them and downstream approvals go stale
	local f=$1 s
	for s in "Goal" "Non-goals" "Acceptance criteria" "Edge cases" "Constraints"; do
		printf '## %s\n' "$s"
		section "$f" "$s" | sed 's/[[:space:]]*$//'
	done | sha256
}

# art_state FILE -> missing | draft | approved | tampered:<why> | <other status>
# "approved" is only trusted when the stored hash matches the body AND the file is
# committed AND the last commit that touched it is an approval commit made by approve.sh.
art_state() {
	local f=$1 st subj
	[ -f "$f" ] || { echo missing; return; }
	st=$(fm_get "$f" status); [ -n "$st" ] || st=draft
	if [ "$st" = approved ]; then
		[ "$(fm_get "$f" sha256)" = "$(body_hash "$f")" ] || { echo "tampered:edited-after-approval"; return; }
		git ls-files --error-unmatch "$f" >/dev/null 2>&1 && git diff --quiet HEAD -- "$f" 2>/dev/null \
			|| { echo "tampered:uncommitted-approval"; return; }
		subj=$(git log -1 --format=%s -- "$f")
		case $subj in
			*": approve "* | *": auto-approve "*) ;;
			*) echo "tampered:last-commit-is-not-an-approval"; return ;;
		esac
	fi
	echo "$st"
}

chain_errors() { # up-to: spec|plan|tasks|brief -> prints problems; returns 1 if any
	local e=0 s p t st
	if [ "$1" = brief ]; then
		st=$(art_state "$(art brief)"); [ "$st" = approved ] || { echo "brief.md is $st"; return 1; }
		return 0
	fi
	s=$(art spec); st=$(art_state "$s")
	[ "$st" = approved ] || { echo "spec.md is $st"; e=1; }
	[ "$1" = spec ] && return $e
	p=$(art plan); st=$(art_state "$p")
	if [ "$st" != approved ]; then echo "plan.md is $st"; e=1
	elif [ $e = 0 ] && [ "$(fm_get "$p" spec-fingerprint)" != "$(spec_fp "$s")" ]; then
		echo "plan.md was approved against an older spec (its contract sections changed)"; e=1
	fi
	[ "$1" = plan ] && return $e
	t=$(art tasks); st=$(art_state "$t")
	if [ "$st" != approved ]; then echo "tasks.md is $st"; e=1
	elif [ $e = 0 ]; then
		[ "$(fm_get "$t" plan-sha256)" = "$(fm_get "$p" sha256)" ] || { echo "tasks.md was approved against an older plan"; e=1; }
		[ "$(fm_get "$t" spec-fingerprint)" = "$(spec_fp "$s")" ] || { echo "tasks.md was approved against an older spec"; e=1; }
	fi
	return $e
}

# --- tasks.md -----------------------------------------------------------------

task_ids() { doc "$1" | awk '/^### T[0-9][0-9][0-9]([^0-9]|$)/ { print substr($0, 5, 4) }'; }
task_ids_stdin() { awk '/^### T[0-9][0-9][0-9]([^0-9]|$)/ { print substr($0, 5, 4) }'; }
task_block_stdin() { # stdin = comment-stripped body, $1 = id
	I="$1" awk '
		/^##/ { if (inb) exit; if (index($0, "### " ENVIRON["I"]) == 1 && substr($0, 9, 1) !~ /[0-9]/) { inb = 1; print; next } }
		inb { print }'
}
task_block() { doc "$1" | task_block_stdin "$2"; }
task_title() { task_block "$1" "$2" | head -1 | sed -E 's/^### T[0-9]+[[:space:]]*(—|-|:)?[[:space:]]*//'; }
field_stdin() { # stdin = a task block, $1 = field name -> value
	K="$1" awk '{ l = $0; sub(/^[[:space:]]+/, "", l)
		if (index(l, "- " ENVIRON["K"] ":") == 1) { v = substr(l, length(ENVIRON["K"]) + 4); sub(/^[[:space:]]+/, "", v); sub(/[[:space:]]+$/, "", v); print v; exit } }'
}
task_field() { task_block "$1" "$2" | field_stdin "$3"; }

# --- loop state (.agent-loop/<feature>/, gitignored) ----------------------------

sdir() { printf '%s/%s' "$STATE_ROOT" "$F"; }
ensure_state() { mkdir -p "$(sdir)"; }
log_event() { ensure_state; printf '%s %s\n' "$(now)" "$*" >> "$(sdir)/run.log"; }
state_set() { # id status [detail]
	ensure_state
	printf '%s\t%s\t%s\t%s\n' "$1" "$2" "${3:-}" "$(now)" >> "$(sdir)/state"
}
state_get() { # id -> last status
	[ -f "$(sdir)/state" ] || return 0
	I="$1" awk -F '\t' '$1 == ENVIRON["I"] { s = $2 } END { if (s != "") print s }' "$(sdir)/state"
}
state_detail() {
	[ -f "$(sdir)/state" ] || return 0
	I="$1" awk -F '\t' '$1 == ENVIRON["I"] { s = $3 } END { if (s != "") print s }' "$(sdir)/state"
}
sfile_get() { [ -f "$(sdir)/$1" ] && cat "$(sdir)/$1"; return 0; }
sfile_set() { ensure_state; printf '%s\n' "$2" > "$(sdir)/$1"; }

trailer_ids() { # task ids that have a "Task: Tnnn" commit on this branch since the base branch
	local b; b=$(base_branch)
	git log "$b..HEAD" --format=%B 2>/dev/null | awk '/^Task: T[0-9][0-9][0-9]$/ { print $2 }' | sort -u
}

done_tasks() { # ids reviewed PASS (falls back to commit trailers when there is no state yet, e.g. a fresh clone)
	if [ -f "$(sdir)/state" ]; then
		awk -F '\t' '{ s[$1] = $2 } END { for (k in s) if (s[k] == "PASS" && k ~ /^T[0-9]/) print k }' "$(sdir)/state" | sort
	else
		trailer_ids
	fi
}

open_questions() { section "$(art research)" "Open questions" | grep -oE '\*\*Q[0-9]+\*\* *\(open\)' | grep -oE 'Q[0-9]+'; }

cr_files() { ls "$SPECS_DIR/$F/changes"/CR-[0-9][0-9][0-9].md 2>/dev/null; }
