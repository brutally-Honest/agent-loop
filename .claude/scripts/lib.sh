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
	# profile keys stay unset unless loop.conf sets them, so cfg can tell "repo" from "profile"
	unset $CFG_KEYS MAX_FIX_ROUNDS
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
	# v0.1 name of FIX_ROUNDS
	if [ -z "${FIX_ROUNDS+x}" ] && [ -n "${MAX_FIX_ROUNDS+x}" ]; then FIX_ROUNDS=$MAX_FIX_ROUNDS; fi
	STATE_ROOT="$REPO/.agent-loop"
}

# --- settings: run > task > feature > repo > profile > kit default ------------------
#
# cfg KEY [TASK] prints the effective value; cfg_lookup sets CV (value) and CS (where it
# came from: run | task | feature | repo | profile:<name> | default) without a subshell.
#   run      .agent-loop/<f>/run.conf, KEY=value lines written by `loop.sh start` from flags
#   task     the task block's Model: / Review: / Verify: fields (see model_for, task_review)
#   feature  plan.md frontmatter (brief.md for /quick), keys in lower-kebab case: review:, fix-rounds:
#   repo     .claude/loop.conf
CFG_KEYS="PROFILE REVIEW VERIFY FIX_ROUNDS MUTATION CRITIC MODEL_PLANNER MODEL_IMPLEMENTER MODEL_REVIEWER MODEL_BRANCH_REVIEWER MODEL_QUICK MODEL_IMPACT SIZE_MODELS AUTO_APPROVE_TASKS TRAILERS REVIEW_LINES REVIEW_GLOBS PLAN_MAX_LINES BATCH_SMALL"

profile_default() { # profile key -> value; returns 1 when the profile leaves the key to the kit default
	case $1:$2 in
		fast:REVIEW) echo branch ;;              balanced:REVIEW) echo risk ;;            strict:REVIEW) echo every ;;
		fast:VERIFY) echo every-3 ;;             balanced:VERIFY) echo task ;;            strict:VERIFY) echo task ;;
		fast:FIX_ROUNDS) echo 1 ;;               balanced:FIX_ROUNDS) echo 2 ;;           strict:FIX_ROUNDS) echo 2 ;;
		fast:MUTATION) echo off ;;               balanced:MUTATION) echo risk ;;          strict:MUTATION) echo every ;;
		fast:CRITIC) echo off ;;                 balanced:CRITIC) echo self ;;            strict:CRITIC) echo agent ;;
		fast:MODEL_PLANNER) echo sonnet ;;       balanced:MODEL_PLANNER) echo opus ;;     strict:MODEL_PLANNER) echo opus ;;
		*:MODEL_IMPLEMENTER) echo sonnet ;;
		fast:MODEL_REVIEWER) echo sonnet ;;      balanced:MODEL_REVIEWER) echo sonnet ;;  strict:MODEL_REVIEWER) echo opus ;;
		fast:MODEL_BRANCH_REVIEWER) echo sonnet ;; balanced:MODEL_BRANCH_REVIEWER) echo opus ;; strict:MODEL_BRANCH_REVIEWER) echo opus ;;
		*:MODEL_QUICK) echo sonnet ;;
		*:MODEL_IMPACT) echo sonnet ;;
		fast:SIZE_MODELS) echo "S=haiku M=sonnet L=sonnet" ;;
		balanced:SIZE_MODELS) echo "S=haiku M=sonnet L=opus" ;;
		strict:SIZE_MODELS) echo "S=sonnet M=sonnet L=opus" ;;
		fast:AUTO_APPROVE_TASKS) echo on ;;      balanced:AUTO_APPROVE_TASKS) echo on ;;  strict:AUTO_APPROVE_TASKS) echo off ;;
		*:TRAILERS) echo on ;;
		fast:REVIEW_LINES) echo 300 ;;           balanced:REVIEW_LINES) echo 150 ;;
		fast:REVIEW_GLOBS) echo "" ;;            balanced:REVIEW_GLOBS) printf '%s\n' "$WATCHED_GLOBS" ;;
		*:PLAN_MAX_LINES) echo 200 ;;
		*) return 1 ;;
	esac
}

kit_default() { # key -> value for keys no profile sets
	case $1 in
		REVIEW_LINES) echo 150 ;;
		REVIEW_GLOBS) printf '%s\n' "$WATCHED_GLOBS" ;;
		BATCH_SMALL) echo off ;;
		PROFILE) echo balanced ;;
	esac
}

cfg_values() { # key -> the valid values, for messages
	case $1 in
		PROFILE) echo "fast balanced strict" ;;
		REVIEW) echo "none branch risk every" ;;
		VERIFY) echo "targeted task every-N end off" ;;
		FIX_ROUNDS) echo "0 1 2 3" ;;
		MUTATION) echo "off risk every" ;;
		CRITIC) echo "off self agent" ;;
		MODEL_*) echo "haiku sonnet opus" ;;
		SIZE_MODELS) echo "'S=<model> M=<model> L=<model>'" ;;
		AUTO_APPROVE_TASKS | TRAILERS | BATCH_SMALL) echo "on off" ;;
		REVIEW_LINES | PLAN_MAX_LINES) echo "a number" ;;
		REVIEW_GLOBS) echo "space-separated globs" ;;
	esac
}

cfg_valid() { # key value -> 0 if valid
	local v=$2 m
	case $1 in
		VERIFY) case $v in every-[1-9] | every-[1-9][0-9]) return 0 ;; esac ;;
		SIZE_MODELS)
			for m in $v; do case $m in [SML]=haiku | [SML]=sonnet | [SML]=opus) ;; *) return 1 ;; esac; done
			return 0 ;;
		REVIEW_LINES | PLAN_MAX_LINES) case $v in '' | *[!0-9]*) return 1 ;; *) return 0 ;; esac ;;
		REVIEW_GLOBS) return 0 ;;
	esac
	case " $(cfg_values "$1") " in *" $v "*) return 0 ;; esac
	return 1
}

feature_conf_file() { if is_quick; then art brief; else art plan; fi; }

run_conf_get() { # key -> value from this run's flags
	[ -n "${F:-}" ] && [ -f "$STATE_ROOT/$F/run.conf" ] || return 0
	K="$1" awk '{ i = index($0, "="); if (i && substr($0, 1, i - 1) == ENVIRON["K"]) v = substr($0, i + 1) } END { if (v != "") print v }' "$STATE_ROOT/$F/run.conf"
}

cfg_lookup() { # KEY -> CV CS
	local k=$1 v prof
	v=$(run_conf_get "$k"); if [ -n "$v" ]; then CV=$v; CS=run; return 0; fi
	if [ -n "${F:-}" ]; then
		v=$(fm_get "$(feature_conf_file)" "$(printf '%s' "$k" | tr 'A-Z_' 'a-z-')")
		if [ -n "$v" ]; then CV=$v; CS=feature; return 0; fi
	fi
	if eval "[ -n \"\${$k+x}\" ]"; then eval "CV=\$$k"; CS=repo; return 0; fi
	if [ "$k" = PROFILE ]; then CV=balanced; CS=default; return 0; fi
	cfg_lookup PROFILE; prof=$CV
	if v=$(profile_default "$prof" "$k"); then CV=$v; CS="profile:$prof"; return 0; fi
	CV=$(kit_default "$k"); CS=default
}
cfg() { cfg_lookup "$1"; printf '%s\n' "$CV"; }

model_for() { # task id -> CV CS: the implementer's model (Q: the quick-builder's)
	local t=$1 v sz
	if [ "$t" = Q ]; then
		v=$(run_conf_get MODEL_Q); if [ -n "$v" ]; then CV=$v; CS=run; return 0; fi
		cfg_lookup MODEL_QUICK; return 0
	fi
	v=$(run_conf_get "MODEL_$t"); if [ -n "$v" ]; then CV=$v; CS=run; return 0; fi
	if [ -f "$(art tasks)" ]; then
		v=$(task_field "$(art tasks)" "$t" Model); if [ -n "$v" ]; then CV=$v; CS=task; return 0; fi
		sz=$(task_field "$(art tasks)" "$t" Size | cut -c1)
		if [ -n "$sz" ]; then
			cfg_lookup SIZE_MODELS
			v=$(printf '%s\n' $CV | awk -F= -v s="$sz" '$1 == s { print $2 }')
			if [ -n "$v" ]; then CV=$v; CS="size $sz, SIZE_MODELS from $CS"; return 0; fi
		fi
	fi
	cfg_lookup MODEL_IMPLEMENTER
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
strip_comments() { awk '{ line = $0; out = ""
	while (1) {
		if (incom) { p = index(line, "-->"); if (!p) { line = ""; break }; line = substr(line, p + 3); incom = 0 }
		p = index(line, "<!--"); if (!p) { out = out line; break }
		out = out substr(line, 1, p - 1); line = substr(line, p + 4); incom = 1
	}
	print out }'; }   # like strip_noise, but blank lines (paragraph breaks) stay

sec() { # stdin markdown, $1 = level-2 heading title (case-insensitive) -> that section's lines
	T="$1" awk '
		function n(s) { s = tolower(s); sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
		/^## / { if (insec) exit; if (n(substr($0, 4)) == n(ENVIRON["T"])) { insec = 1; next } }
		insec { print }'
}
section() { doc "$1" | sec "$2"; }
sec_raw() { sec "$1"; }   # same as sec; named for streams that keep blank lines

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
