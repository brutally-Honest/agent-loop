#!/usr/bin/env bash
# loop.sh — the deterministic half of the agent loop.
#
# The model dispatches agents; this script decides. Whether a task really finished,
# what runs next, how many fix rounds are left and when to stop are all decided here
# and printed as a final "ACTION ..." line for the orchestrator to follow.
#
# Usage: .claude/scripts/loop.sh <command> [args]   (run from the repo root)
#   status [feature]                  where things stand + the next step
#   new <kind> <slug> [--worktree] [--quick] [--base REF] [--supersedes NNN]
#   gate plan|tasks|implement|amend   precondition check for a skill (exit 1 = stop)
#   check spec|plan|tasks|brief [--draft]  |  check change [CR-nnn]
#   config [TASK]                     every setting's effective value and where it came from
#   start --session ID [flags] | pause [--now] | next | log <ID> <agent> '<first line>' | stop '<reason>' | finish
#   task <ID> | findings <ID> | review-info <ID|BRANCH|Q> | post-check <ID>
#   verify | test <args> | impact <ACn...> | cr-new | lineage | report | doctor | suggest-verify | unlock | resolve
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"
# shellcheck source=validate.sh
. "$HERE/validate.sh"
al_init

short() { git rev-parse --short "${1:-HEAD}" 2>/dev/null; }
soft_feature() { F=$( (resolve_feature "${1:-}" && printf '%s' "$F") 2>/dev/null ) && [ -n "$F" ]; }
VLOG() { if [ -n "${F:-}" ]; then ensure_state; printf '%s/verify.log' "$(sdir)"; else mkdir -p "$STATE_ROOT"; printf '%s/verify.log' "$STATE_ROOT"; fi; }

render() { # template dest   (uses F KIND TITLE SUP CR)
	local src="$AL_KIT_DIR/templates/$1"
	[ -f "$src" ] || die "missing template $src"
	sed -e "s|{{FEATURE}}|$F|g" -e "s|{{KIND}}|${KIND:-}|g" -e "s|{{DATE}}|$(today)|g" \
		-e "s|{{TITLE}}|${TITLE:-$F}|g" -e "s|{{SUPERSEDES}}|${SUP:-}|g" -e "s|{{CR}}|${CR:-}|g" -e 's/^\([a-z-]*\): $/\1:/' "$src" > "$2"
}

run_verify() { # 0 = green. Records HEAD as green only when verify ran on a clean tree and left it clean.
	local log rc before
	log=$(VLOG)
	if [ -z "$VERIFY_CMD" ]; then { verify_unset_msg; echo; } > "$log"; return 1; fi # unset is red, never a silent green
	before=$(git status --porcelain)
	(bash -c "$VERIFY_CMD") > "$log" 2>&1; rc=$?
	if [ "$(git status --porcelain)" != "$before" ]; then
		printf '\nagent-loop: verify changed files in the working tree — verify must be read-only:\n%s\n' "$(git status --short)" >> "$log"
		rc=1
	fi
	if [ $rc = 0 ] && [ -z "$before" ] && [ -n "${F:-}" ]; then sfile_set green "$(git rev-parse HEAD)"; fi
	return $rc
}

autocommit_research() { # commit research.md when it is the only uncommitted change (your answers to Qn)
	local st r="$SPECS_DIR/$F/research.md"
	st=$(git status --porcelain); [ -n "$st" ] || return 0
	printf '%s\n' "$st" | grep -v " $r\$" | grep -q . && return 0
	git add -- "$r" && git commit -q -m "docs($F): update research notes" -- "$r" && echo "Committed your research.md changes."
}

draft_crs() { local c; for c in $(cr_files); do [ "$(fm_get "$c" status)" = draft ] && basename "$c" .md; done; return 0; }

# --- new ------------------------------------------------------------------------

next_number() {
	local max=0 n b
	b=$(base_branch)
	for n in $( {
		ls -1 "$SPECS_DIR" 2>/dev/null
		git ls-tree --name-only "$b" "$SPECS_DIR/" 2>/dev/null
		git for-each-ref --format='%(refname:short)' refs/heads
	} | awk '{ k = split($0, p, "/"); s = p[k]; if (s ~ /^[0-9][0-9][0-9]-/) print substr(s, 1, 3) }'); do
		n=$((10#$n)); [ "$n" -gt "$max" ] && max=$n
	done
	printf '%03d' $((max + 1))
}

cmd_new() {
	local kind="" slug="" wt=0 quick=0 base="" br target path d
	SUP=""
	while [ $# -gt 0 ]; do
		case $1 in
			--worktree) wt=1 ;; --quick) quick=1 ;;
			--base) base=${2:-}; shift ;;
			--supersedes) SUP=${2:-}; shift ;;
			-*) die "unknown flag $1" ;;
			*) if [ -z "$kind" ]; then kind=$1; elif [ -z "$slug" ]; then slug=$1; else die "unexpected argument '$1'"; fi ;;
		esac
		shift
	done
	case $kind in feat | fix | refactor | chore) ;; *) die "kind must be feat, fix, refactor or chore (got '$kind')" ;; esac
	printf '%s' "$slug" | grep -Eq '^[a-z0-9][a-z0-9-]{1,47}$' || die "slug must be 2-48 chars: lowercase letters, digits, dashes (got '$slug')"
	git ls-files --error-unmatch .claude/scripts/loop.sh >/dev/null 2>&1 \
		|| die "commit the agent-loop kit first (git add .claude .gitignore && git commit) — branches, worktrees and clean-tree checks need it tracked"
	base=${base:-$(base_branch)}
	git rev-parse --verify --quiet "$base^{commit}" >/dev/null || die "base '$base' not found"
	if [ -n "$SUP" ]; then
		d=$(git ls-tree --name-only "$base" "$SPECS_DIR/" 2>/dev/null | awk -v n="${SUP%%-*}" '{ k = split($0, p, "/"); if (index(p[k], n "-") == 1) { print p[k]; exit } }')
		[ -n "$d" ] || die "--supersedes $SUP: no such feature merged into $base"
		SUP=$d
	fi
	n=$(next_number); F="$n-$slug"; KIND=$kind
	TITLE=$(printf '%s' "$slug" | tr '-' ' '); TITLE="$(printf '%s' "${TITLE:0:1}" | tr '[:lower:]' '[:upper:]')${TITLE:1}"
	br="$kind/$F"
	git show-ref --verify --quiet "refs/heads/$br" && die "branch $br already exists"
	if [ $wt = 1 ]; then
		path=".claude/worktrees/$F"
		git check-ignore -q "$path/x" || die ".claude/worktrees/ is not gitignored — add it to .gitignore first (install.sh does this)"
		git worktree add -q -b "$br" "$path" "$base" || die "git worktree add failed"
		target="$REPO/$path"
	else
		tree_clean || die "working tree not clean — commit or stash first (or use --worktree)"
		git switch -q -c "$br" "$base" || die "git switch -c $br $base failed"
		target=$REPO
	fi
	mkdir -p "$target/$SPECS_DIR/$F"
	if [ $quick = 1 ]; then render brief.md "$target/$SPECS_DIR/$F/brief.md"
	else render spec.md "$target/$SPECS_DIR/$F/spec.md"; fi
	render research.md "$target/$SPECS_DIR/$F/research.md"
	echo "FEATURE $F"
	echo "BRANCH $br"
	echo "DIR $SPECS_DIR/$F"
	[ $wt = 1 ] && echo "WORKTREE $target"
	return 0
}

# --- status ------------------------------------------------------------------------

art_line() { # name
	local f st v extra=""
	f=$(art "$1"); st=$(art_state "$f"); v=$(fm_get "$f" version)
	[ "$st" = missing ] || extra=" v${v:-1}"
	[ "$1" = plan ] && [ "$st" = draft ] && extra="$extra ($(section "$f" "Open questions" | grep -E '^[[:space:]]*[-*][[:space:]]*(\*\*)?Q[0-9]+' | grep -vc 'decided:') undecided questions)"
	printf '  %-9s %s%s\n' "$1.md" "$st" "$extra"
}

next_step() {
	local st q ce c
	if is_quick; then
		st=$(art_state "$(art brief)")
		case $st in
			draft) echo "review $(art brief), then /approve brief (it builds right after)" ;;
			approved) [ "$(state_get Q)" = PASS ] && echo "done — read the report (loop.sh report) and open the PR" || echo "/implement" ;;
			*) echo "brief.md is $st — /amend, or reopen it from a terminal: .claude/scripts/approve.sh reopen brief --reason '…'" ;;
		esac
		return
	fi
	c=$(draft_crs | head -1); [ -n "$c" ] && { echo "$c is waiting: /approve change (or edit it, or delete it)"; return; }
	st=$(art_state "$(art spec)")
	case $st in
		missing) echo "/spec <requirement>"; return ;;
		draft) echo "review $(art spec), then /approve spec (or keep refining with /spec)"; return ;;
		approved) ;;
		*) echo "spec.md is $st — /amend, or reopen it from a terminal: .claude/scripts/approve.sh reopen spec --reason '…'"; return ;;
	esac
	st=$(art_state "$(art plan)")
	case $st in
		missing) echo "/plan-feature"; return ;;
		draft) echo "/plan-feature (draft or reopened plan), then /approve plan"; return ;;
		approved) ;;
		*) echo "plan.md is $st — /amend, or reopen it: .claude/scripts/approve.sh reopen plan --reason '…'"; return ;;
	esac
	ce=$(chain_errors plan) || { echo "$ce — /plan-feature to revise"; return; }
	st=$(art_state "$(art tasks)")
	case $st in
		missing) echo "tasks are generated after /approve plan — ask Claude to run the tasker, or re-run /approve plan from a draft plan"; return ;;
		draft) echo "tasks.md is a draft — fix what '.claude/scripts/loop.sh check tasks' reports, then /approve tasks"; return ;;
		approved) ;;
		*) echo "tasks.md is $st — /amend"; return ;;
	esac
	ce=$(chain_errors tasks) || { echo "$ce"; return; }
	q=$(open_questions | tr '\n' ' ')
	[ -n "$q" ] && { echo "answer $q in $(art research) (change '(open)' to '(answered)'), then /implement"; return; }
	for c in $(task_ids "$(art tasks)"); do
		case $(state_get "$c") in
			STOPPED) echo "$c hit the fix-round limit: its last attempt is committed on top of $(short "$(sfile_get "base.$c")"). Fix it by hand, or drop it (git reset --hard $(short "$(sfile_get "base.$c")")) and /amend the task; then /implement restarts $c from HEAD"; return ;;
			ESCALATED) echo "$c needs your decision (the reviewer's ESCALATE): fix the spec via /amend, or fix the code yourself; then /implement"; return ;;
		esac
	done
	for c in $(task_ids "$(art tasks)"); do
		case $(state_get "$c") in PASS | NEEDS-HUMAN) ;; *) echo "/implement"; return ;; esac
	done
	local nh=""
	for c in $(task_ids "$(art tasks)"); do [ "$(state_get "$c")" = NEEDS-HUMAN ] && nh="$nh $c"; done
	st=$(state_get BRANCH); [ "$(cfg REVIEW)" = none ] && st=PASS
	case $st in
		PASS | FIX | ESCALATE) echo "done — read the report (loop.sh report)${nh:+, do the manual checks for$nh}, then open the PR" ;;
		*) echo "/implement (branch review pending)" ;;
	esac
}

cmd_status() {
	local id st c
	if ! soft_feature "${1:-}"; then
		echo "No feature on this branch ($(current_branch)). Start one: /spec <requirement>  or  /quick <small change>"
		return 0
	fi
	echo "Feature  $F  ($(fm_get "$(art spec)" kind)$(fm_get "$(art brief)" kind), branch $(current_branch), base $(base_branch))"
	if is_quick; then art_line brief; else
		art_line spec; art_line plan; art_line tasks
		for c in $(cr_files); do printf '  %-9s %s (scope %s)%s\n' "$(basename "$c" .md)" "$(art_state "$c")" "$(fm_get "$c" scope)" "$([ -n "$(fm_get "$c" applied)" ] && echo ", applied")"; done
	fi
	st=$(open_questions | tr '\n' ' '); [ -n "$st" ] && echo "  open questions: $st(research.md)"
	if is_quick; then
		[ -n "$(state_get Q)" ] && echo "Build: $(state_get Q)"
	elif [ -f "$(art tasks)" ]; then
		echo "Tasks"
		for id in $(task_ids "$(art tasks)"); do
			st=$(state_get "$id"); [ -n "$st" ] || { in_list "$id" "$(done_tasks)" && st=PASS || st=todo; }
			printf '  %s  %-12s %s\n' "$id" "$st" "$(task_title "$(art tasks)" "$id")"
		done
	fi
	echo "Next: $(next_step)"
}

# --- gates ------------------------------------------------------------------------

pending_crs() { local c; for c in $(cr_files); do [ "$(fm_get "$c" status)" = approved ] && [ -z "$(fm_get "$c" applied)" ] && basename "$c" .md; done; return 0; }

gate_plan() {
	local e p st mode=new
	is_quick && die "$F is a /quick feature (brief.md) — it has no plan"
	e=$(chain_errors spec) || die "the planner stops here — $e. Approve the spec first: /approve spec"
	p=$(art plan); st=$(art_state "$p")
	case $st in
		missing) render plan.md "$p" ;;
		draft) [ -n "$(fm_get "$p" previous)" ] && mode=amend ;;
		approved) die "plan.md is already approved — to change it, use /amend" ;;
		*) die "plan.md is $st — /amend, or reopen it from a terminal: .claude/scripts/approve.sh reopen plan --reason '…'" ;;
	esac
	echo "GATE plan: OK"
	echo "FEATURE $F"
	echo "MODE $mode"
	echo "MODEL $(cfg MODEL_PLANNER)"
	echo "CHANGE-REQUESTS $(pending_crs | tr '\n' ' ')"
}

gate_tasks() {
	local e t st mode=new
	e=$(chain_errors plan) || die "the tasker stops here — $e"
	t=$(art tasks); st=$(art_state "$t")
	case $st in
		missing) render tasks.md "$t" ;;
		draft) [ -n "$(fm_get "$t" previous)" ] && mode=amend ;;
		approved) die "tasks.md is already approved — to change it, use /amend" ;;
		*) die "tasks.md is $st — /amend" ;;
	esac
	echo "GATE tasks: OK"
	echo "FEATURE $F"
	echo "MODE $mode"
	echo "DONE-TASKS $(done_tasks | tr '\n' ' ')"
	echo "CHANGE-REQUESTS $(pending_crs | tr '\n' ' ')"
}

gate_implement() {
	local e c br id st
	if is_quick; then e=$(chain_errors brief) || die "not ready to build — $e. /approve brief first"
	else e=$(chain_errors tasks) || die "not ready to build — $(printf '%s' "$e" | tr '\n' ';') (see: .claude/scripts/loop.sh status)"; fi
	c=$(draft_crs | head -1); [ -z "$c" ] || die "$c is waiting for a decision — /approve change, or delete it"
	br=$(current_branch); [ "$br" != "$(base_branch)" ] || die "you're on $br — check out the feature branch"
	[ -n "$VERIFY_CMD" ] || die "$(verify_unset_msg)"
	autocommit_research >/dev/null
	tree_clean || die "working tree not clean — commit or stash first: $(git status --short | head -5 | tr '\n' ' ')"
	echo "GATE implement: OK"
	echo "FEATURE $F"
	echo "KIND $(fm_get "$(art spec)" kind)$(fm_get "$(art brief)" kind)"
	echo "VERIFY $VERIFY_CMD"
	echo "PROFILE $(cfg PROFILE)   REVIEW $(cfg REVIEW)   VERIFY $(cfg VERIFY)   FIX_ROUNDS $(cfg FIX_ROUNDS)"
	if is_quick; then echo "UNIT Q ($(state_get Q))"
	else
		for id in $(task_ids "$(art tasks)"); do
			st=$(state_get "$id"); [ -n "$st" ] || st=todo
			[ "$st" = PASS ] || echo "TASK $id $st — $(task_title "$(art tasks)" "$id")"
		done
	fi
}

gate_amend() {
	local f st c n
	if is_quick; then f=$(art brief); else f=$(art spec); fi
	st=$(art_state "$f")
	case $st in
		approved) ;;
		draft) die "${f##*/} is still a draft — just edit it (/spec or /quick); a change request is only for approved work" ;;
		missing) die "no ${f##*/} for $F" ;;
		*) n=${f##*/}; die "$n is $st (edited after approval without a change request). If that edit is what you want: run '.claude/scripts/approve.sh reopen ${n%.md} --reason \"…\"' in a terminal, then /approve it again" ;;
	esac
	git cat-file -e "$(base_branch):$f" 2>/dev/null \
		&& die "$F is already merged into $(base_branch) — changes now are a new feature: /spec --supersedes ${F%%-*} <the change>"
	for c in "$STATE_ROOT/$F/lock"; do [ -f "$c" ] && echo "NOTE a run lock exists (session $(cat "$c")) — if a build is running, stop it first"; done
	echo "GATE amend: OK"
	echo "FEATURE $F"
	echo "MODEL $(cfg MODEL_IMPACT)"
	echo "QUICK $(is_quick && echo yes || echo no)"
	echo "DONE-TASKS $(done_tasks | tr '\n' ' ')"
	echo "DRAFT-CR $(draft_crs | head -1)"
}

cmd_gate() {
	local what=${1:-} feat="" flags=""; shift || true
	while [ $# -gt 0 ]; do
		case $1 in --*) flags="$flags $1 ${2:-}"; shift ;; *) feat=$1 ;; esac
		shift
	done
	resolve_feature "$feat"
	# shellcheck disable=SC2086
	if [ "$what" = implement ]; then parse_run_flags $flags; check_effective_cfg; fi
	case $what in
		plan) gate_plan ;; tasks) gate_tasks ;; implement) gate_implement ;; amend) gate_amend ;;
		*) die "usage: gate plan|tasks|implement|amend [feature]" ;;
	esac
}

cmd_check() {
	local what=${1:-} mode=approve f out rc
	shift || true
	[ "${1:-}" = --draft ] && { mode=draft; shift; }
	case $what in
		change)
			resolve_feature
			if [ -n "${1:-}" ]; then f="$SPECS_DIR/$F/changes/$1.md"; else f=$(for c in $(draft_crs); do echo "$SPECS_DIR/$F/changes/$c.md"; done | tail -1); fi
			[ -n "$f" ] || die "no draft change request; pass its id (CR-nnn)"
			out=$(check_change "$f"); rc=$? ;;
		spec | plan) resolve_feature "${1:-}"; f=$(art "$what"); out=$(check_"$what" "$f" "$mode"); rc=$? ;;
		tasks | brief) resolve_feature "${1:-}"; f=$(art "$what"); out=$(check_"$what" "$f"); rc=$? ;;
		*) die "usage: check spec|plan|tasks|brief [--draft] | check change [CR-nnn]" ;;
	esac
	if [ $rc = 0 ]; then echo "OK: $f passes the $mode checks"; else echo "NOT READY: $f"; printf '%s\n' "$out"; fi
	return $rc
}

# --- the loop ------------------------------------------------------------------------

pre_task() { # id -> 0 ok (base recorded) | 1 with STOP-REASON lines
	local id=$1 ce q
	autocommit_research >/dev/null
	tree_clean || { echo "STOP-REASON working tree not clean before $id:"; git status --short | head -10; return 1; }
	if is_quick; then ce=$(chain_errors brief); else ce=$(chain_errors tasks); fi \
		|| { echo "STOP-REASON approvals are not valid any more: $ce"; return 1; }
	q=$(draft_crs | head -1); [ -z "$q" ] || { echo "STOP-REASON $q is waiting for a decision"; return 1; }
	if [ "$(state_get "$id")" = BLOCKED ]; then
		q=$(state_detail "$id")
		if open_questions | grep -qx "$q"; then
			echo "STOP-REASON $q is still open in $(art research) — answer it (change '(open)' to '(answered)' and write the answer), then /implement"
			return 1
		fi
	fi
	if [ "$(sfile_get green)" != "$(git rev-parse HEAD)" ]; then
		run_verify || { echo "STOP-REASON verify is red at the start of $id — the previous change broke something:"; tail -20 "$(VLOG)"; return 1; }
	fi
	sfile_set "base.$id" "$(git rev-parse HEAD)"
	sfile_set "rounds.$id" 0
	rm -f "$(sdir)/findings.$id" "$(sdir)/watch.$id"
	state_set "$id" IN-PROGRESS
	[ "$id" = Q ] || state_set BRANCH CLEARED
	log_event "$id pre-task ok base=$(short)"
	return 0
}

PE=0
pe() { printf '  - %s\n' "$*"; PE=1; }

post_task() { # id [quick|full] -> 0 ok | 1 + problems.  quick = no verify (used by the SubagentStop hook)
	local id=$1 mode=${2:-full} base commits c msg p tests changed kind w="" skips ce
	PE=0
	base=$(sfile_get "base.$id"); [ -n "$base" ] || { pe "no base recorded for $id (pre-task never ran)"; return 1; }
	tree_clean || pe "working tree not clean: $(git status --short | head -5 | tr '\n' ' ')"
	commits=$(git rev-list "$base..HEAD")
	[ -n "$commits" ] || pe "no new commit since $(short "$base")"
	for c in $commits; do
		msg=$(git log -1 --format=%B "$c")
		printf '%s\n' "$msg" | grep -qx "Task: $id" || pe "commit $(short "$c") lacks the trailer 'Task: $id'"
		printf '%s\n' "$msg" | grep -qx "Feature: $F" || pe "commit $(short "$c") lacks the trailer 'Feature: $F'"
	done
	while IFS= read -r p; do
		[ -n "$p" ] || continue
		case $p in
			.claude/*) pe "changed $p — agents never touch the kit" ;;
			.agent-loop/*) pe "committed loop state $p" ;;
			"$SPECS_DIR"/*) [ "$p" = "$SPECS_DIR/$F/research.md" ] || pe "changed $p — under $SPECS_DIR/ only $SPECS_DIR/$F/research.md may change" ;;
		esac
		match_globs "$p" "$PROTECTED_GLOBS" && pe "changed protected file $p (loop.conf PROTECTED_GLOBS)"
		match_globs "$p" "$WATCHED_GLOBS" && w="${w}WATCH changed $p — reviewer: is this needed, and does it weaken a check?
"
	done <<EOF
$(git diff --name-only "$base" HEAD)
EOF
	if is_quick; then tests=$(section "$(art brief)" "Steps" | grep 'Tests:' | grep -viE 'Tests:[[:space:]]*none')
	else tests=$(task_field "$(art tasks)" "$id" Tests); case $tests in [Nn]one* | '') tests="" ;; esac; fi
	if [ -n "$tests" ]; then
		changed=""
		while IFS= read -r p; do [ -n "$p" ] && match_globs "$p" "$TEST_GLOBS" && changed=1; done <<EOF
$(git diff --name-only --diff-filter=AM "$base" HEAD)
EOF
		[ -n "$changed" ] || pe "the task names tests but no test file was added or changed (TEST_GLOBS in loop.conf)"
	fi
	while IFS= read -r p; do
		[ -n "$p" ] && match_globs "$p" "$TEST_GLOBS" && w="${w}WATCH deleted test file $p — reviewer: must be justified by the spec
"
	done <<EOF
$(git diff --name-only --diff-filter=D "$base" HEAD)
EOF
	kind=$(fm_get "$(art spec)" kind)$(fm_get "$(art brief)" kind)
	if [ "$kind" = refactor ]; then
		while IFS= read -r p; do
			[ -n "$p" ] && match_globs "$p" "$TEST_GLOBS" && w="${w}WATCH refactor modified existing test $p — behaviour must not change
"
		done <<EOF
$(git diff --name-only --diff-filter=M "$base" HEAD)
EOF
	fi
	skips=$(git diff "$base" HEAD -U0 | grep '^+' | grep -v '^+++' \
		| grep -E 't\.Skip\(|\.skip\(|(^|[^A-Za-z_])x(it|describe|test)\(|\.only\(|@Disabled|pytest\.mark\.skip|(it|test)\.todo\(|//[[:space:]]*nolint|eslint-disable' | head -5)
	[ -n "$skips" ] && w="${w}$(printf '%s\n' "$skips" | sed 's/^/WATCH added skip\/disable marker: /')
"
	if is_quick; then ce=$(chain_errors brief); else ce=$(chain_errors tasks); fi || pe "approved files no longer match their approval: $ce"
	if [ "$mode" = full ] && [ $PE = 0 ]; then
		run_verify || pe "verify is red ($VERIFY_CMD):
$(tail -25 "$(VLOG)")"
	fi
	sfile_set "watch.$id" "$w"
	[ -n "$w" ] && printf '%s' "$w"
	return $PE
}

bump() { # id source -> prints ACTION
	local r max
	max=$(cfg FIX_ROUNDS)
	r=$(sfile_get "rounds.$1"); r=$(( ${r:-0} + 1 ))
	if [ "$r" -gt "$max" ]; then
		state_set "$1" STOPPED fix-limit
		log_event "$1 STOP fix-limit ($max fix rounds used)"
		echo "ACTION stop fix-limit $1"
	else
		sfile_set "rounds.$1" "$r"
		log_event "$1 fix round $r/$max ($2)"
		model_for "$1"
		echo "ACTION fix $1 $2 $r/$max model=$CV"
	fi
}

act_implement() { model_for "$1"; echo "ACTION implement $1 model=$CV"; }
act_review() {
	if [ "$1" = BRANCH ]; then cfg_lookup MODEL_BRANCH_REVIEWER; else cfg_lookup MODEL_REVIEWER; fi
	echo "ACTION review $1 model=$CV"
}

task_review() { [ "$1" != Q ] && [ -f "$(art tasks)" ] && task_field "$(art tasks)" "$1" Review | tr '[:upper:]' '[:lower:]'; return 0; }

review_reason() { # id -> one line why; returns 0 when the task gets a reviewer
	local id=$1 pol tr
	pol=$(cfg REVIEW)
	[ "$pol" = none ] && { echo "skipped: reviews are off (REVIEW=none)"; return 1; }
	tr=$(task_review "$id")
	case $tr in
		always) echo "reviewed: the task says Review: always"; return 0 ;;
		skip) echo "skipped: the task says Review: skip"; return 1 ;;
	esac
	case $pol in
		every) echo "reviewed: REVIEW=every"; return 0 ;;
		branch)
			[ "$id" = Q ] && { echo "reviewed: a quick change has no branch review"; return 0; }
			echo "skipped: REVIEW=branch (the branch review covers it)"; return 1 ;;
		*) echo "reviewed: REVIEW=$pol"; return 0 ;;
	esac
}

after_implemented() { # id -> ACTION review, or PASS without a reviewer
	local why
	if why=$(review_reason "$1"); then
		log_event "$1 $why"; act_review "$1"
	else
		state_set "$1" PASS "$(short)"; [ "$1" = Q ] || state_set BRANCH CLEARED
		log_event "$1 PASS without review — $why"
		echo "$1 passes without a review ($why)"
		if [ "$1" = Q ]; then echo "ACTION finish"; else echo "ACTION next"; fi
	fi
}

parse_run_flags() { # flags... -> RUN_CONF (KEY=value lines) or dies with the valid values
	local f v k m pair
	RUN_CONF=""
	_rc() { cfg_valid "$1" "$2" || die "--$3 '$2' is not valid — use one of: $(cfg_values "$1")"; RUN_CONF="$RUN_CONF$1=$2
"; }
	while [ $# -gt 0 ]; do
		f=$1; v=${2:-}
		case $f in
			--profile) _rc PROFILE "$v" profile ;;
			--review) _rc REVIEW "$v" review ;;
			--verify) _rc VERIFY "$v" verify ;;
			--fix-rounds) _rc FIX_ROUNDS "$v" fix-rounds ;;
			--mutation) _rc MUTATION "$v" mutation ;;
			--model)
				[ -n "$v" ] || die "--model needs a list, e.g. --model T002=haiku,implementer=sonnet,reviewer=opus"
				for pair in $(printf '%s' "$v" | tr ',' ' '); do
					k=${pair%%=*}; m=${pair#*=}
					[ "$k" != "$pair" ] || die "--model: '$pair' should be <task or agent>=<model>, e.g. T002=haiku"
					cfg_valid MODEL_IMPLEMENTER "$m" || die "--model $pair: model must be one of: haiku sonnet opus"
					case $k in
						T[0-9][0-9][0-9] | Q) RUN_CONF="${RUN_CONF}MODEL_$k=$m
" ;;
						implementer | reviewer | branch-reviewer | planner | quick | impact)
							RUN_CONF="${RUN_CONF}MODEL_$(printf '%s' "$k" | tr 'a-z-' 'A-Z_')=$m
" ;;
						*) die "--model $pair: '$k' is not a task id (T002) or an agent (implementer, reviewer, branch-reviewer, planner, quick, impact)" ;;
					esac
				done ;;
			*) die "unknown flag '$f' — /implement takes: --profile fast|balanced|strict, --review none|branch|risk|every, --verify targeted|task|every-N|end|off, --fix-rounds 0-3, --mutation off|risk|every, --model T002=haiku,reviewer=opus" ;;
		esac
		shift; [ $# -gt 0 ] && shift
	done
	return 0
}

check_effective_cfg() { # dies naming the first setting that is not valid, and where it was set
	local k
	for k in $CFG_KEYS; do
		cfg_lookup "$k"
		cfg_valid "$k" "$CV" || die "$k=$CV (set in: $CS) is not valid — use one of: $(cfg_values "$k")"
	done
}

cmd_config() { # [TASK]
	local t=${1:-} k v
	soft_feature || F=""
	echo "Settings${F:+ for $F} — first match wins: run flags > task fields > plan.md frontmatter > .claude/loop.conf > profile > kit default"
	for k in $CFG_KEYS; do cfg_lookup "$k"; printf '%s=%s (%s)\n' "$k" "$CV" "$CS"; done
	if [ -n "$t" ]; then
		[ -n "$F" ] || die "no feature on this branch — check out the feature branch to see a task's settings"
		if [ "$t" != Q ]; then task_block "$(art tasks)" "$t" | grep -q . || die "no task $t in $(art tasks)"; fi
		echo "Task $t"
		model_for "$t"; printf 'MODEL=%s (%s)\n' "$CV" "$CS"
		if [ "$t" != Q ]; then
			for k in Size Risk Review Verify; do
				v=$(task_field "$(art tasks)" "$t" "$k"); [ -n "$v" ] && printf '%s=%s (task)\n' "$(printf '%s' "$k" | tr '[:lower:]' '[:upper:]')" "$v"
			done
		fi
		printf 'REVIEWED=%s\n' "$(review_reason "$t")"
	fi
	return 0
}

cmd_start() {
	local sid="" feat="" out flags=""
	while [ $# -gt 0 ]; do
		case $1 in
			--session) sid=${2:-}; shift ;;
			--*) flags="$flags $1 ${2:-}"; shift ;;
			*) feat=$1 ;;
		esac
		shift
	done
	resolve_feature "$feat"
	# shellcheck disable=SC2086
	out=$(parse_run_flags $flags 2>&1) || { printf '%s\n' "$out"; echo "ACTION stop flags"; exit 1; }
	out=$(check_effective_cfg 2>&1) || { printf '%s\n' "$out"; echo "ACTION stop config"; exit 1; }
	out=$(gate_implement 2>&1) || { printf '%s\n' "$out"; echo "ACTION stop gate"; exit 1; }
	ensure_state
	# shellcheck disable=SC2086
	parse_run_flags $flags
	if [ -n "$RUN_CONF" ]; then printf '%s' "$RUN_CONF" > "$(sdir)/run.conf"
	elif [ -f "$(sdir)/run.conf" ]; then echo "Using the flags of the interrupted run: $(tr '\n' ' ' < "$(sdir)/run.conf")"; fi
	case $sid in '' | *'$'* | *CLAUDE_SESSION_ID*) warn "no session id — the orchestrator write-lock is off for this run"; sid="" ;; esac
	ensure_state
	rm -f "$(sdir)/paused"
	if [ -n "$sid" ]; then sfile_set lock "$sid $(now)"; fi
	log_event "RUN START head=$(short) session=${sid:-none}"
	if [ "$(sfile_get green)" != "$(git rev-parse HEAD)" ]; then
		echo "Running verify on HEAD: $VERIFY_CMD"
		if ! run_verify; then
			tail -30 "$(VLOG)"
			log_event "STOP verify red before the first task"
			rm -f "$(sdir)/lock"
			echo "verify is red on HEAD before any task ran — fix that first (log: $(VLOG))"
			echo "ACTION stop verify-red"
			exit 1
		fi
	fi
	printf '%s\n' "$out" | grep -E '^(TASK|UNIT) '
	echo "ACTION next"
}

cmd_next() {
	local id st out
	resolve_feature
	if [ -f "$(sdir)/paused" ]; then release_lock; log_event "PAUSED at a task boundary"; echo "ACTION pause"; return 0; fi
	if is_quick; then
		st=$(state_get Q)
		case $st in
			PASS) echo "ACTION finish" ;;
			IMPLEMENTED) after_implemented Q ;;
			*) if out=$(pre_task Q); then act_implement Q; else printf '%s\n' "$out"; log_event "STOP pre-task Q"; echo "ACTION stop pre-task Q"; fi ;;
		esac
		return 0
	fi
	for id in $(task_ids "$(art tasks)"); do
		[ "$(state_get "$id")" = IMPLEMENTED ] && { echo "RESUME $id was implemented but not reviewed"; after_implemented "$id"; return 0; }
	done
	for id in $(task_ids "$(art tasks)"); do
		st=$(state_get "$id")
		[ -z "$st" ] && in_list "$id" "$(done_tasks)" && continue
		case $st in PASS | NEEDS-HUMAN) continue ;; esac
		if out=$(pre_task "$id"); then act_implement "$id"
		else printf '%s\n' "$out"; log_event "STOP pre-task $id"; echo "ACTION stop pre-task $id"; fi
		return 0
	done
	[ "$(cfg REVIEW)" = none ] && { echo "ACTION finish"; return 0; }
	case $(state_get BRANCH) in PASS | FIX | ESCALATE) echo "ACTION finish" ;; *) act_review BRANCH ;; esac
}

cmd_log() {
	local id=${1:-} agent=${2:-} line=${3:-} verdict w2 w3 out q
	resolve_feature
	[ -n "$id" ] && [ -n "$agent" ] || die "usage: log <ID> <agent> '<first line of its final message>'"
	set -f; set -- $line; set +f
	verdict=${1:-}; w2=${2:-}; w3=${3:-}
	case $agent in
		implementer | quick-builder)
			[ "$id" != BRANCH ] || die "BRANCH is reviewed, not implemented"
			if [ -n "$w2" ] && [ "$w2" != "$id" ]; then
				log_event "$id $agent CONTRACT reported '$line'"; echo "ACTION stop contract $id (agent reported another task: '$line')"; return 0
			fi
			case $(state_get "$id") in
				PASS | NEEDS-HUMAN | '') log_event "$id $agent CONTRACT result for a task that is not in progress"
					echo "ACTION stop contract $id ($id is not in progress — run loop.sh next to get the current action)"; return 0 ;;
			esac
			case $verdict in
				DONE)
					log_event "$id $agent DONE $(short)"
					if out=$(post_task "$id" full); then
						state_set "$id" IMPLEMENTED "$(short)"
						[ -n "$out" ] && printf '%s\n' "$out"
						after_implemented "$id"
					else
						sfile_set "findings.$id" "$out"
						echo "post-task checks failed for $id:"; printf '%s\n' "$out"
						log_event "$id post-task FAILED"
						bump "$id" post-task
					fi ;;
				BLOCKED)
					q=$(printf '%s' "$w3" | grep -oE '^Q[0-9]+'); q=${q:-Q?}
					state_set "$id" BLOCKED "$q"; log_event "$id $agent BLOCKED $q"
					echo "ACTION stop blocked $id $q" ;;
				NEEDS-HUMAN)
					tree_clean || { log_event "$id NEEDS-HUMAN with a dirty tree"; echo "ACTION stop dirty-tree $id"; return 0; }
					state_set "$id" NEEDS-HUMAN "$w3"; log_event "$id $agent NEEDS-HUMAN $w3"
					echo "ACTION next" ;;
				*) log_event "$id $agent CONTRACT '$line'"; echo "ACTION stop contract $id (first line was not DONE/BLOCKED/NEEDS-HUMAN)" ;;
			esac ;;
		reviewer)
			if [ "$id" = BRANCH ]; then
				case $verdict in PASS | FIX | ESCALATE) ;; *) verdict=UNCLEAR ;; esac
				state_set BRANCH "$verdict"; log_event "BRANCH reviewer $verdict"
				echo "ACTION finish"; return 0
			fi
			if [ "$verdict" != ESCALATE ] && [ "$(state_get "$id")" != IMPLEMENTED ]; then
				log_event "$id reviewer CONTRACT $verdict logged while $id is $(state_get "$id")"
				echo "ACTION stop contract $id (a review was logged for $id, but $id has not passed its post-task checks — it is $(state_get "$id"))"
				return 0
			fi
			case $verdict in
				PASS)
					state_set "$id" PASS "$(short)"; state_set BRANCH CLEARED
					log_event "$id reviewer PASS $(short)"
					if is_quick; then echo "ACTION finish"; else echo "ACTION next"; fi ;;
				FIX) log_event "$id reviewer FIX"; bump "$id" review ;;
				ESCALATE) state_set "$id" ESCALATED; log_event "$id reviewer ESCALATE"; echo "ACTION stop escalate $id" ;;
				*) log_event "$id reviewer CONTRACT '$line'"; echo "ACTION stop contract $id (reviewer verdict was not PASS/FIX/ESCALATE)" ;;
			esac ;;
		*) die "agent must be implementer, quick-builder or reviewer" ;;
	esac
}

release_lock() { rm -f "$(sdir)/lock"; }

cmd_stop() { resolve_feature; log_event "STOP $*"; release_lock; cmd_report; }
cmd_finish() { resolve_feature; log_event "RUN END"; release_lock; cmd_report; rm -f "$(sdir)/run.conf"; }
cmd_pause() { # [--now] [--session ID] [feature] — the run stops at the next task boundary (--now: agents are stopped too)
	local mode=graceful sid="" feat="" l lsid fs=""
	while [ $# -gt 0 ]; do
		case $1 in --now) mode=now ;; --session) sid=${2:-}; shift ;; -*) die "unknown flag $1" ;; *) feat=$1 ;; esac
		shift
	done
	if [ -n "$sid" ]; then
		for l in "$STATE_ROOT"/*/lock; do
			[ -f "$l" ] || continue
			read -r lsid _ < "$l" || true
			[ "$lsid" = "$sid" ] && fs="$fs $(basename "$(dirname "$l")")"
		done
		[ -n "$fs" ] || { echo "no build is running in this session"; return 0; }
	else
		resolve_feature "$feat"; fs=$F
	fi
	for F in $fs; do
		sfile_set paused "mode=$mode $(now)"
		release_lock
		log_event "PAUSE requested ($mode)"
		echo "PAUSED $F ($mode) — /resume continues the build"
	done
}

cmd_unlock() { if soft_feature "${1:-}"; then release_lock; else rm -f "$STATE_ROOT"/*/lock; fi; echo "orchestrator lock released"; }

cmd_task() {
	local id=${1:-} r
	resolve_feature; [ -n "$id" ] || die "usage: task <ID>"
	r=$(sfile_get "rounds.$id")
	echo "FEATURE $F   KIND $(fm_get "$(art spec)" kind)$(fm_get "$(art brief)" kind)   ROUND ${r:-0}/$(cfg FIX_ROUNDS)"
	if [ "$id" = Q ]; then
		echo "UNIT the whole brief: $(art brief)"; doc "$(art brief)"
		echo; echo "COMMIT TRAILERS (required, as the last lines of every commit message):"
		echo "Task: Q"; echo "Feature: $F"
	else
		task_block "$(art tasks)" "$id" | grep -q . || die "no task $id in $(art tasks)"
		task_block "$(art tasks)" "$id"
		echo; echo "COMMIT TRAILERS (required, as the last lines of every commit message):"
		echo "Task: $id"; echo "Feature: $F"
		echo "AC: $(task_field "$(art tasks)" "$id" AC)"
	fi
	echo "VERIFY .claude/scripts/loop.sh verify   ($VERIFY_CMD)"
}

cmd_post_check() { # the post-task contract without verify (agents self-check; the SubagentStop hook uses it)
	local id=${1:-}
	resolve_feature; [ -n "$id" ] || die "usage: post-check <ID>"
	if post_task "$id" quick; then echo "OK: $id meets the post-task contract (verify runs when the orchestrator logs DONE)"; return 0; fi
	return 1
}

cmd_findings() { local id=${1:-}; resolve_feature; [ -n "$id" ] || die "usage: findings <ID>"; sfile_get "findings.$id"; }

cmd_review_info() {
	local id=${1:-} base mb id2
	resolve_feature; [ -n "$id" ] || die "usage: review-info <ID|BRANCH|Q>"
	echo "FEATURE $F   KIND $(fm_get "$(art spec)" kind)$(fm_get "$(art brief)" kind)"
	case $id in
		BRANCH)
			mb=$(git merge-base "$(base_branch)" HEAD)
			echo "MODE branch — judge the whole branch against $(art spec) (every AC, scope both ways, checks on checks)"
			echo "RANGE $(short "$mb")..$(short)   (git diff $(short "$mb")..HEAD)"
			echo "TASKS"; for id2 in $(task_ids "$(art tasks)"); do printf '  %s %s\n' "$id2" "$(state_get "$id2")"; done
			git diff --stat "$mb" HEAD | tail -25
			git diff --name-only "$mb" HEAD | while IFS= read -r p; do match_globs "$p" "$WATCHED_GLOBS" && echo "WATCH changed $p"; done
			git diff --name-only --diff-filter=D "$mb" HEAD | while IFS= read -r p; do match_globs "$p" "$TEST_GLOBS" && echo "WATCH deleted test file $p"; done
			;;
		*)
			base=$(sfile_get "base.$id"); [ -n "$base" ] || die "no base recorded for $id"
			if [ "$id" = Q ]; then
				echo "MODE brief — the standard is $(art brief) (Change, Acceptance, Out of scope) plus AGENTS.md/CLAUDE.md"
			else
				echo "MODE task — the standard is $(art spec) plus AGENTS.md/CLAUDE.md. The block below is the CLAIM you check, not the standard:"
				task_block "$(art tasks)" "$id"
			fi
			echo "RANGE $(short "$base")..$(short)   (git diff $(short "$base")..HEAD)"
			echo "ROUND $(sfile_get "rounds.$id")/$(cfg FIX_ROUNDS)"
			git diff --stat "$base" HEAD | tail -25
			sfile_get "watch.$id"
			;;
	esac
}

cmd_verify() {
	local rc
	soft_feature || F=""
	run_verify; rc=$?
	if [ $rc = 0 ]; then echo "verify: green ($VERIFY_CMD)"; else tail -40 "$(VLOG)"; echo "verify: RED (${VERIFY_CMD:-not set}) — full log: $(VLOG)"; fi
	return $rc
}

cmd_test() {
	[ -n "$TEST_CMD" ] || die "TEST_CMD is not set in .claude/loop.conf"
	bash -c "$TEST_CMD"' "$@"' _ "$@"
}

cmd_impact() {
	local a t b
	resolve_feature; [ $# -gt 0 ] || die "usage: impact AC1 [AC2 ...]"
	b=$(base_branch)
	for a in "$@"; do
		echo "$a"
		if [ -f "$(art tasks)" ]; then
			for t in $(task_ids "$(art tasks)"); do
				task_field "$(art tasks)" "$t" AC | ac_refs | grep -qx "$a" || continue
				st=$(state_get "$t"); [ -n "$st" ] || { in_list "$t" "$(done_tasks)" && st=PASS || st=todo; }
				printf '  task %s %-12s %s\n' "$t" "$st" "$(task_title "$(art tasks)" "$t")"
			done
		fi
		git log "$b..HEAD" --format='@@%h %s%n%B' | A="$a" awk '
			/^@@/ { c = substr($0, 3); next }
			/^AC:/ { n = split($0, x, /[^A-Za-z0-9]+/); for (i = 1; i <= n; i++) if (x[i] == ENVIRON["A"]) print "  commit " c }' | sort -u
	done
}

cmd_cr_new() {
	local n max=0 c d
	resolve_feature
	d=$(draft_crs | head -1)
	if [ -n "$d" ]; then echo "CR $d (existing draft — revise it)"; echo "FILE $SPECS_DIR/$F/changes/$d.md"; return 0; fi
	mkdir -p "$SPECS_DIR/$F/changes"
	for c in $(cr_files); do n=${c##*/CR-}; n=${n%.md}; n=$((10#$n)); [ "$n" -gt "$max" ] && max=$n; done
	CR=$(printf 'CR-%03d' $((max + 1)))
	render cr.md "$SPECS_DIR/$F/changes/$CR.md"
	echo "CR $CR"
	echo "FILE $SPECS_DIR/$F/changes/$CR.md"
}

cmd_lineage() {
	local b s d
	resolve_feature "${1:-}"; b=$(base_branch)
	echo "$F"
	s=$(fm_get "$(art spec)" supersedes)
	while [ -n "$s" ]; do
		echo "  supersedes $s"
		s=$(git show "$b:$SPECS_DIR/$s/spec.md" 2>/dev/null | awk 'NR==1 && $0!="---"{exit} NR>1 && /^---/{exit} /^supersedes:/{sub(/^supersedes:[[:space:]]*/,""); print; exit}')
	done
	for d in $(git ls-tree --name-only "$b" "$SPECS_DIR/" 2>/dev/null); do
		git show "$b:$d/spec.md" 2>/dev/null | grep -q "^supersedes: $F\$" && echo "  superseded by ${d##*/}"
	done
	return 0
}

cmd_report() {
	local id st d q end title
	echo "Report — $F on $(current_branch) ($(now))"
	if is_quick; then
		echo "  Q  $(state_get Q) $(state_detail Q)  (fix rounds: $(sfile_get rounds.Q))"
	else
		echo "Tasks"
		for id in $(task_ids "$(art tasks)"); do
			st=$(state_get "$id"); d=$(state_detail "$id"); title=$(task_title "$(art tasks)" "$id")
			[ -n "$st" ] || { in_list "$id" "$(done_tasks)" && st=PASS || st=todo; }
			case $st in
				NEEDS-HUMAN) printf '  %s  NEEDS-HUMAN  %s — check by hand: %s\n' "$id" "$title" "$(task_field "$(art tasks)" "$id" Manual)" ;;
				BLOCKED) printf '  %s  BLOCKED %s  %s — %s\n' "$id" "$d" "$title" "$(section "$(art research)" "Open questions" | grep -F "**$d**" | head -1)" ;;
				*) printf '  %s  %-12s %s %s(fix rounds: %s)\n' "$id" "$st" "$title" "${d:+$d }" "$(sfile_get "rounds.$id")" ;;
			esac
		done
		if [ "$(cfg REVIEW)" = none ]; then echo "Reviews: off (REVIEW=none) — no task or branch review ran"
		else echo "Branch review: $(state_get BRANCH | sed 's/^CLEARED$/not run since the last change/; s/^$/not run/')"; fi
	fi
	end=$(grep -E ' (STOP|RUN END)' "$(sdir)/run.log" 2>/dev/null | tail -1)
	[ -n "$end" ] && echo "Run: $end"
	q=$(section "$(art research)" "Open questions" | grep '(open)')
	[ -n "$q" ] && { echo "Open questions:"; printf '%s\n' "$q" | sed 's/^/  /'; }
	echo "Next: $(next_step)"
	echo "Log: .agent-loop/$F/run.log"
}

cmd_doctor() {
	local ok=0
	chk() { if eval "$2" >/dev/null 2>&1; then echo "  ok    $1"; else echo "  FAIL  $1 — $3"; ok=1; fi; }
	echo "agent-loop doctor ($REPO)"
	chk "git" "command -v git" "install git"
	chk "jq (hooks need it)" "command -v jq" "install jq — without it the guard denies every Bash/Edit call"
	chk "sha256sum or shasum" "command -v sha256sum || command -v shasum" "install coreutils"
	chk "kit committed" "git ls-files --error-unmatch .claude/scripts/loop.sh" "git add .claude .gitignore && git commit"
	chk "hooks executable" "test -x .claude/hooks/guard.sh -a -x .claude/hooks/on-command.sh -a -x .claude/hooks/on-agent-stop.sh" "chmod +x .claude/hooks/*.sh .claude/scripts/*.sh"
	chk "settings.json wires the hooks" "jq -e '.hooks.PreToolUse and .hooks.UserPromptExpansion and .hooks.UserPromptSubmit and .hooks.SubagentStop' .claude/settings.json" "merge the kit's settings.json (install.sh does it)"
	chk ".agent-loop/ gitignored" "git check-ignore -q .agent-loop/x" "add '.agent-loop/' to .gitignore"
	chk ".claude/worktrees/ gitignored" "git check-ignore -q .claude/worktrees/x" "add '.claude/worktrees/' to .gitignore"
	if [ -n "$VERIFY_CMD" ]; then echo "  ok    VERIFY_CMD set"; else echo "  FAIL  $(verify_unset_msg)"; ok=1; fi
	if [ -f AGENTS.md ] || [ -f CLAUDE.md ]; then echo "  ok    AGENTS.md / CLAUDE.md present"; else echo "  warn  no AGENTS.md or CLAUDE.md — optional, but agents read it for conventions and hard rules"; fi
	echo "  base branch: $(base_branch)   verify: ${VERIFY_CMD:-<none>}"
	return $ok
}

cmd=${1:-help}; shift || true
case $cmd in
	new) cmd_new "$@" ;;
	status) cmd_status "$@" ;;
	config) cmd_config "$@" ;;
	suggest-verify) suggest_verify ;;
	gate) cmd_gate "$@" ;;
	check) cmd_check "$@" ;;
	start) cmd_start "$@" ;;
	next) cmd_next "$@" ;;
	log) cmd_log "$@" ;;
	stop) cmd_stop "$@" ;;
	finish) cmd_finish "$@" ;;
	unlock) cmd_unlock "$@" ;;
	pause) cmd_pause "$@" ;;
	task) cmd_task "$@" ;;
	findings) cmd_findings "$@" ;;
	post-check) cmd_post_check "$@" ;;
	review-info) cmd_review_info "$@" ;;
	verify) cmd_verify "$@" ;;
	test) cmd_test "$@" ;;
	impact) cmd_impact "$@" ;;
	cr-new) cmd_cr_new "$@" ;;
	lineage) cmd_lineage "$@" ;;
	report) resolve_feature "${1:-}"; cmd_report ;;
	doctor) cmd_doctor ;;
	resolve) resolve_feature "${1:-}"; echo "$F" ;;
	help | -h | --help) sed -n '2,/^set -uo/p' "$0" | sed '$d; s/^# \{0,1\}//' ;;
	*) die "unknown command '$cmd' (try: loop.sh help)" ;;
esac
