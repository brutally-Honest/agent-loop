#!/usr/bin/env bash
# approve.sh — HUMAN-ONLY approval stamp (and reopen).
#
# Claude never runs this. You trigger it by typing /approve in Claude Code (a
# UserPromptExpansion hook runs it from your keystroke), or you run it in your own
# terminal. guard.sh denies it to every agent and to the main session, and
# settings.json denies it as a permission rule.
#
#   approve.sh                         approve whatever is waiting (auto)
#   approve.sh spec|plan|tasks|brief   approve that artifact of the current feature
#   approve.sh change [CR-nnn]         accept a change request (reopens what it changes)
#   approve.sh reopen spec|plan|tasks|brief --reason "why"   unfreeze an approved artifact
#   add a feature id (012 or 012-slug) to act on a feature other than the branch's
#
# Approving = validate (refuse on any error) -> stamp status/approved/sha256 into the
# frontmatter -> reopen downstream artifacts the change invalidates -> commit specs/<f>/.
# If the commit fails (e.g. a git hook rejects it) every file is restored.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"
# shellcheck source=validate.sh
. "$HERE/validate.sh"
al_init

target="" rtarget="" by=human reason="" feat="" cr=""
while [ $# -gt 0 ]; do
	case $1 in
		--by) by=${2:-}; shift ;;
		--reason) reason=${2:-}; shift ;;
		CR-[0-9]*) cr=$1 ;;
		spec | plan | tasks | brief | change | auto | reopen)
			if [ -z "$target" ]; then target=$1
			elif [ "$target" = reopen ] && [ -z "$rtarget" ]; then rtarget=$1
			else die "unexpected '$1'"; fi ;;
		-*) die "unknown flag $1" ;;
		*) feat=$1 ;;
	esac
	shift
done
target=${target:-auto}
case $by in human | auto) ;; *) die "--by must be human or auto" ;; esac
resolve_feature "$feat"

br=$(current_branch) || die "detached HEAD — check out the feature branch"
[ "$br" != "$(base_branch)" ] || die "you're on $br — approvals are committed on the feature branch; check it out first"
case $br in *"$F"*) ;; *) die "branch $br is not $F's branch — check out the feature branch first" ;; esac

SNAP=""
snapshot() { SNAP=$(mktemp -d "${TMPDIR:-/tmp}/al-snap.XXXXXX") && cp -Rp "$SPECS_DIR/$F/." "$SNAP/"; }
restore() { [ -n "$SNAP" ] || return 0; git reset -q -- "$SPECS_DIR/$F" 2>/dev/null; cp -Rp "$SNAP/." "$SPECS_DIR/$F/"; rm -rf "$SNAP"; SNAP=""; }
done_snap() { [ -n "$SNAP" ] && rm -rf "$SNAP"; SNAP=""; }

commit_docs() { # subject body
	local out
	git add -- "$SPECS_DIR/$F" || return 1
	out=$(git commit -q -m "$1" -m "$2" -- "$SPECS_DIR/$F" 2>&1) || { printf '%s\n' "$out"; return 1; }
}

finish_commit() { # subject body
	local out
	if ! out=$(commit_docs "$1" "$2"); then
		restore
		die "the commit failed, so nothing was approved (files restored):
$out"
	fi
	done_snap
}

stamp() { # file by [key value]...
	local f=$1 who=$2; shift 2
	fm_set "$f" status approved
	fm_set "$f" approved "$(now)"
	fm_set "$f" approved-by "$who"
	while [ $# -ge 2 ]; do fm_set "$f" "$1" "$2"; shift 2; done
	fm_set "$f" sha256 "$(body_hash "$f")"
}

add_changelog() { # file line -> appended to '## Changelog' (created if missing)
	local f=$1 tmp
	tmp=$(mktemp "${TMPDIR:-/tmp}/al.XXXXXX") || return 1
	L="$2" awk '
		/^## / { if (inlog && !done) { print ENVIRON["L"]; done = 1 } inlog = (tolower($0) ~ /^## changelog/) }
		{ print }
		END { if (!done) { if (!inlog) { print ""; print "## Changelog" } print ENVIRON["L"] } }' "$f" > "$tmp" && cat "$tmp" > "$f"
	rm -f "$tmp"
}

reopen_file() { # file reason -> prints one line
	local f=$1 why=$2 ver new prev k
	ver=$(fm_get "$f" version); ver=${ver:-1}; new=$((ver + 1))
	prev=$(git log -1 --format=%h -- "$f")
	fm_set "$f" status draft
	fm_set "$f" version "$new"
	fm_set "$f" previous "$prev"
	for k in approved approved-by sha256 fingerprint spec-fingerprint plan-sha256; do
		[ -n "$(fm_get "$f" "$k")" ] && fm_set "$f" "$k" ""
	done
	add_changelog "$f" "- v$new ($(today)) — reopened: $why"
	echo "REOPENED ${f##*/} v$new (draft) — $why"
}

ready_or_die() { # file state-required
	local f=$1 st
	st=$(art_state "$f")
	case $st in
		draft) ;;
		missing) die "${f##*/} does not exist for $F" ;;
		approved) die "${f##*/} is already approved" ;;
		*) die "${f##*/} is $st — reopen it first: .claude/scripts/approve.sh reopen ${f##*/} --reason '…'" ;;
	esac
}

pending_crs_where() { # key -> approved CRs whose <key> is still empty
	local c
	for c in $(cr_files); do
		[ "$(fm_get "$c" status)" = approved ] && [ -z "$(fm_get "$c" "$1")" ] && echo "$c"
	done
	return 0
}

approve_spec() {
	local f p t c e ver fp casc=""
	f=$(art spec); ready_or_die "$f"
	e=$(check_spec "$f" approve) || die "spec.md is not ready to approve:
$e"
	for c in $(pending_crs_where spec-applied); do
		[ "$(fm_get "$c" scope)" = spec ] || continue
		e=$(check_cr_applied "$c" "$f") || die "spec.md does not apply $(basename "$c" .md) yet:
$e"
	done
	snapshot
	ver=$(fm_get "$f" version); ver=${ver:-1}
	fp=$(spec_fp "$f")
	stamp "$f" human fingerprint "$fp"
	for c in $(pending_crs_where spec-applied); do [ "$(fm_get "$c" scope)" = spec ] && fm_set "$c" spec-applied "v$ver"; done
	p=$(art plan); t=$(art tasks)
	if [ "$(art_state "$p")" = approved ] && [ "$(fm_get "$p" spec-fingerprint)" != "$fp" ]; then
		casc="$casc$(reopen_file "$p" "spec v$ver changed its contract sections")
"
	fi
	if [ "$(art_state "$t")" = approved ] && [ "$(fm_get "$t" spec-fingerprint)" != "$fp" ]; then
		casc="$casc$(reopen_file "$t" "spec v$ver changed its contract sections")
"
	fi
	finish_commit "docs($F): approve spec v$ver" "sha256 $(fm_get "$f" sha256)
fingerprint $fp"
	echo "APPROVED spec v$ver of $F ($(git rev-parse --short HEAD))"
	[ -n "$casc" ] && printf '%s' "$casc"
	if [ -n "$casc" ]; then echo "NEXT /plan — the planner revises the reopened plan and tasks for spec v$ver, then /approve plan"
	elif [ -f "$p" ]; then
		if [ "$(art_state "$p")" = approved ]; then echo "NEXT plan.md and tasks.md stay valid (the contract sections did not change) — /implement"
		else echo "NEXT /plan"; fi
	else echo "NEXT /plan"; fi
}

approve_plan() { # stamps the plan; with AUTO_APPROVE_TASKS=on also a valid tasks.md, in the same commit
	local f s t c e ver tver casc="" tnote="" subj n
	is_quick && die "$F is a /quick feature — it has no plan"
	e=$(chain_errors spec) || die "the spec must be approved first — $e"
	f=$(art plan); ready_or_die "$f"
	e=$(check_plan "$f" approve) || die "plan.md is not ready to approve:
$e"
	snapshot
	ver=$(fm_get "$f" version); ver=${ver:-1}
	s=$(art spec)
	stamp "$f" human spec-fingerprint "$(spec_fp "$s")"
	for c in $(pending_crs_where plan-applied); do [ "$(fm_get "$c" scope)" = plan ] && fm_set "$c" plan-applied "v$ver"; done
	t=$(art tasks)
	if [ "$(art_state "$t")" = approved ] && [ "$(fm_get "$t" plan-sha256)" != "$(fm_get "$f" sha256)" ]; then
		casc=$(reopen_file "$t" "plan v$ver changed")
	fi
	subj="docs($F): approve plan v$ver"
	case $(art_state "$t") in
		missing) tnote="NEXT tasks.md is missing — /plan has the planner write it, then /approve tasks" ;;
		draft)
			if [ "$(cfg AUTO_APPROVE_TASKS)" != on ]; then
				tnote="NEXT review $t, then /approve tasks (AUTO_APPROVE_TASKS=off)"
			elif e=$(check_tasks "$t"); then
				tver=$(fm_get "$t" version); tver=${tver:-1}
				stamp "$t" human plan-sha256 "$(fm_get "$f" sha256)" spec-fingerprint "$(spec_fp "$s")"
				for c in $(pending_crs_where applied); do fm_set "$c" applied "tasks v$tver"; done
				subj="$subj + tasks v$tver"
				n=$(task_ids "$t" | grep -c .)
				tnote="APPROVED tasks v$tver of $F — $n tasks
NEXT /implement"
			else
				tnote="tasks.md stays a draft — it does not pass the checks yet:
$e
NEXT fix tasks.md (by hand, or /plan), then /approve tasks"
			fi ;;
		approved) tnote="NEXT /implement" ;;
	esac
	finish_commit "$subj" "sha256 $(fm_get "$f" sha256)"
	echo "APPROVED plan v$ver of $F ($(git rev-parse --short HEAD))"
	[ -n "$casc" ] && echo "$casc"
	printf '%s\n' "$tnote"
}

approve_tasks() {
	local f p s c e ver subj n
	is_quick && die "$F is a /quick feature — it has no tasks.md"
	e=$(chain_errors plan) || die "the plan must be approved first — $e"
	f=$(art tasks); ready_or_die "$f"
	e=$(check_tasks "$f") || die "tasks.md is not ready to approve:
$e"
	snapshot
	ver=$(fm_get "$f" version); ver=${ver:-1}
	p=$(art plan); s=$(art spec)
	stamp "$f" "$by" plan-sha256 "$(fm_get "$p" sha256)" spec-fingerprint "$(spec_fp "$s")"
	for c in $(pending_crs_where applied); do fm_set "$c" applied "tasks v$ver"; done
	subj="docs($F): approve tasks v$ver"; [ "$by" = auto ] && subj="docs($F): auto-approve tasks v$ver"
	finish_commit "$subj" "sha256 $(fm_get "$f" sha256)
generated from plan $(fm_get "$p" sha256 | cut -c1-12)"
	n=$(task_ids "$f" | grep -c .)
	echo "APPROVED tasks v$ver of $F by $by — $n tasks ($(git rev-parse --short HEAD))"
	echo "NEXT /implement"
}

approve_brief() {
	local f c e ver
	is_quick || die "$F has no brief.md (it is a full feature: approve spec, plan, tasks)"
	f=$(art brief); ready_or_die "$f"
	e=$(check_brief "$f") || die "brief.md is not ready to approve:
$e"
	for c in $(pending_crs_where applied); do
		e=$(check_cr_applied "$c" "$f") || die "brief.md does not apply $(basename "$c" .md) yet:
$e"
	done
	snapshot
	ver=$(fm_get "$f" version); ver=${ver:-1}
	stamp "$f" human
	for c in $(pending_crs_where applied); do fm_set "$c" applied "brief v$ver"; done
	finish_commit "docs($F): approve brief v$ver" "sha256 $(fm_get "$f" sha256)"
	echo "APPROVED brief v$ver of $F ($(git rev-parse --short HEAD))"
	echo "NEXT the build starts now (the /implement loop)"
}

approve_change() {
	local c name e scope title casc=""
	if [ -n "$cr" ]; then c="$SPECS_DIR/$F/changes/$cr.md"
	else c=$(for x in $(cr_files); do [ "$(fm_get "$x" status)" = draft ] && echo "$x"; done | tail -1); fi
	[ -n "$c" ] && [ -f "$c" ] || die "no draft change request to approve (create one with /amend)"
	name=$(basename "$c" .md)
	ready_or_die "$c"
	e=$(check_change "$c") || die "$name is not ready to approve:
$e"
	scope=$(fm_get "$c" scope)
	title=$(doc "$c" | head -1 | sed -E 's/^#[[:space:]]*//; s/^CR-[0-9]+[[:space:]]*(—|-|:)?[[:space:]]*//')
	snapshot
	stamp "$c" human
	case $scope in
		spec)
			if is_quick; then casc=$(reopen_file "$(art brief)" "$name: $title")
			else casc=$(reopen_file "$(art spec)" "$name: $title"); fi ;;
		plan)
			is_quick && { restore; die "quick features have no plan — use scope spec"; }
			casc=$(reopen_file "$(art plan)" "$name: $title")
			[ "$(fm_get "$(art tasks)" status)" = approved ] && casc="$casc
		$(reopen_file "$(art tasks)" "$name: $title")" ;;
		tasks) is_quick && { restore; die "quick features have no tasks — use scope spec"; }; casc=$(reopen_file "$(art tasks)" "$name: $title") ;;
	esac
	finish_commit "docs($F): approve $name ($scope)" "$title"
	echo "APPROVED change $name of $F ($(git rev-parse --short HEAD)) — scope $scope"
	echo "$casc"
	case $scope in
		spec)
			if is_quick; then echo "NEXT apply the Delta of $name to brief.md exactly (strike removed ACs, never delete), run 'loop.sh check brief', then /approve brief"
			else echo "NEXT apply the Delta of $name to spec.md exactly (strike removed ACs, never delete), run 'loop.sh check spec', then /approve spec — plan and tasks reopen automatically if the contract changed"; fi ;;
		plan) echo "NEXT /plan (amend mode, guided by $name) — the planner revises plan.md and tasks.md — then /approve plan" ;;
		tasks) echo "NEXT /plan (the planner revises tasks.md for $name), then /approve tasks" ;;
	esac
}

reopen_cmd() {
	local f st ver
	case $rtarget in spec | plan | tasks | brief) ;; *) die "usage: approve.sh reopen spec|plan|tasks|brief --reason \"why\"" ;; esac
	[ -n "$reason" ] || die "--reason \"why\" is required (it goes in the changelog)"
	f=$(art "$rtarget"); [ -f "$f" ] || die "no $rtarget.md for $F"
	st=$(fm_get "$f" status)
	[ "$st" = approved ] || die "$rtarget.md is $st — only an approved file can be reopened"
	snapshot
	reopen_file "$f" "$reason"
	ver=$(fm_get "$f" version)
	finish_commit "docs($F): reopen $rtarget v$ver" "$reason"
	echo "NEXT edit $f, then /approve $rtarget"
}

if [ "$target" = auto ]; then
	if is_quick; then [ "$(art_state "$(art brief)")" = draft ] && target=brief
	else
		for x in $(cr_files); do [ "$(fm_get "$x" status)" = draft ] && target=change; done
		if [ "$target" = auto ]; then
			for x in spec plan tasks; do
				[ "$(art_state "$(art "$x")")" = draft ] && { target=$x; break; }
			done
		fi
	fi
	[ "$target" != auto ] || die "nothing is waiting for approval in $F (see: .claude/scripts/loop.sh status)"
fi

case $target in
	spec) approve_spec ;;
	plan) approve_plan ;;
	tasks) approve_tasks ;;
	brief) approve_brief ;;
	change) approve_change ;;
	reopen) reopen_cmd ;;
esac
