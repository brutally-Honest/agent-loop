#!/usr/bin/env bash
# guard.sh — PreToolUse hook (Bash, Edit, Write, MultiEdit, NotebookEdit).
#
# One policy for every session in the repo. The role comes from the hook input's
# agent_type (the subagent's name; "main" when absent), so each agent's limits are
# enforced by code, not by its prompt:
#
#   everyone      approve.sh is human-only; .claude/ kit core and .agent-loop/ state are
#                 never written by Claude; approved spec/plan/tasks/brief/CR files are
#                 frozen; nobody writes approval fields (status: approved, sha256, ...).
#   reviewer, spec-critic          read-only: no edits; single allow-listed read commands.
#   planner, tasker, impact-analyst read-only except their own file (plan.md / tasks.md /
#                 changes/CR-*.md), and only when the upstream artifact is approved.
#   implementer, quick-builder     code anywhere except specs/ (bar research.md), .claude/,
#                 PROTECTED_GLOBS; git writes only in the exact shapes a task commit needs.
#   main session  free, except while it holds a /implement run lock: then it may not edit
#                 code or change git state (the orchestrator dispatches; agents build).
#
# Decisions: deny (blocked, reason shown to Claude), allow (only for the exact git
# shapes below), or no output (normal permission flow). Needs jq: without it every
# call is denied, so a missing jq can't silently switch the policy off.
set -u
input=$(cat)

emit() { jq -cn --arg d "$1" --arg r "agent-loop: $2" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$d,permissionDecisionReason:$r}}'; exit 0; }
deny() { emit deny "$*"; }
allow() { emit allow "$*"; }
pass() { exit 0; }

if ! command -v jq >/dev/null 2>&1; then
	printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"agent-loop guard needs jq on PATH. Install jq (or remove the agent-loop hooks from .claude/settings.json)."}}'
	exit 0
fi

tool=$(jq -r '.tool_name // ""' <<<"$input")
role=$(jq -r '.agent_type // "main"' <<<"$input")
cwd=$(jq -r '.cwd // ""' <<<"$input")
sid=$(jq -r '.session_id // ""' <<<"$input")

case $role in
	implementer | quick-builder) class=builder ;;
	reviewer | spec-critic) class=reader ;;
	planner | tasker | impact-analyst) class=writer ;;
	main) class=main ;;
	*) class=other ;;   # built-in or unrelated agents: treated like the main session
esac

[ -n "$cwd" ] && cd "$cwd" 2>/dev/null
git rev-parse --show-toplevel >/dev/null 2>&1 || pass   # not a git repo: no policy
# shellcheck source=../scripts/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../scripts/lib.sh"
al_init
[ -n "${AGENT_LOOP_DEBUG:-}" ] && { mkdir -p "$STATE_ROOT"; printf '%s guard %s\n' "$(date -u +%H:%M:%S)" "$input" >> "$STATE_ROOT/hook-debug.log"; }

locked=0
if [ -n "$sid" ] && [ -d "$STATE_ROOT" ]; then
	for l in "$STATE_ROOT"/*/lock; do
		[ -f "$l" ] && [ "$(cat "$l")" = "$sid" ] && locked=1
	done
fi

# ------------------------------------------------------------------------------- Bash
if [ "$tool" = Bash ]; then
	cmd=$(jq -r '.tool_input.command // ""' <<<"$input")
	# accept ./.claude/... and /abs/repo/.claude/... spellings of the kit scripts
	case $cmd in "./.claude/"*) cmd=${cmd#./} ;; "$REPO/.claude/"*) cmd=${cmd#"$REPO"/} ;; esac
	has() { printf '%s' "$cmd" | grep -Eq -- "$1"; }
	# the command with harmless redirections removed (2>&1, >/dev/null), for write detection
	clean=$(printf '%s' "$cmd" | sed -E 's#[0-9]*>&[0-9]+##g; s#[0-9]*>>?[[:space:]]*/dev/null##g')
	writes() { printf '%s' "$clean" | grep -Eq '>|(^|[^[:alnum:]_.-])(rm|mv|cp|tee|truncate|dd|chmod|chown|ln|install|rsync|touch|patch)([^[:alnum:]_-]|$)|sed[^|;&]*[[:space:]]-[a-zA-Z]*i|perl[^|;&]*[[:space:]]-[a-zA-Z]*i|(python|python3|node|ruby)[[:space:]]+-[ce]'; }
	single() { ! printf '%s' "$clean" | grep -Eq '[;&|<>`]|\$\(' && [ "$(printf '%s' "$cmd" | wc -l | tr -d ' ')" = 0 ]; }
	loopsh() { has '^\.claude/scripts/loop\.sh( |$)'; }

	has 'approve\.sh' && deny "approve.sh is human-only — the user types /approve (or runs it in a terminal)."
	# a mention of .claude/ or .agent-loop/ only counts when it isn't a loop.sh call or the commit-message scratch files
	kitrest=$(printf '%s' "$cmd" | sed -E 's#(\./|/[^[:space:]]*/)?\.claude/scripts/loop\.sh##g')
	staterest=$(printf '%s' "$cmd" | sed -E 's#\.agent-loop/(commit-msg|note|scratch/[^[:space:]]*)##g')
	if printf '%s' "$kitrest" | grep -q '\.claude/' && writes; then deny "the agent-loop kit under .claude/ is edited by the human, not by Claude."; fi
	if printf '%s' "$staterest" | grep -q '\.agent-loop' && writes; then deny ".agent-loop/ holds loop state; only loop.sh writes it."; fi

	# loop.sh is the loop's own tool: approve well-formed single calls per role, whatever the spelling
	if loopsh && single; then
		sub=$(printf '%s' "$cmd" | awk '{ print $2 }')
		case $class:$sub in
			main:* | other:*) allow "loop.sh $sub" ;;
			builder:verify | builder:test | builder:status | builder:check | builder:task | builder:findings | builder:post-check | builder:review-info | builder:impact | builder:resolve | builder:lineage | builder:report)
				allow "loop.sh $sub" ;;
		esac
	fi

	GIT_WRITE='push|reset|rebase|checkout|switch|merge|tag|worktree|config|update-ref|filter-branch|filter-repo|clean|cherry-pick|revert|remote|fetch|pull|gc|prune|replace|reflog|submodule|am|apply|notes'
	gitsub() { # the git subcommand of a single command, skipping global options
		local w
		set -f; set -- $cmd; set +f
		[ "${1:-}" = git ] || return 0
		shift
		while [ $# -gt 0 ]; do
			case $1 in -C | -c | --git-dir | --work-tree | --namespace) shift 2 ;; -*) shift ;; *) printf '%s' "$1"; return 0 ;; esac
		done
	}

	case $class in
	reader | writer)
		if true; then
			single || deny "$role runs single read-only commands only (no ; & | < > \` \$( or newlines)."
			has '(^|[[:space:]])(-exec|-execdir|-delete|-ok|-okdir|-fprint|-fprint0|-fls|-fprintf|--output|-o|-coverprofile|-cpuprofile|-memprofile|-trace|-toolexec|-outputdir)([[:space:]=]|$)' \
				&& deny "$role may not write files or run other programs (flag not allowed)."
			if has '^git([[:space:]]+(-C[[:space:]]+[^[:space:]]+|--no-pager))*[[:space:]]+(status|diff|show|log|blame|ls-files|ls-tree|rev-parse|rev-list|merge-base|cat-file|grep|shortlog|describe|notes show)([[:space:]]|$)' \
				|| has '^git branch( (-a|-r|-v|-vv|--all|--list|--remotes|--show-current|--contains|--merged|--no-merged)( [^-][^[:space:]]*)?)*$' \
				|| has '^\.claude/scripts/loop\.sh (status|check|task|findings|review-info|verify|test|impact|resolve|lineage|report)([[:space:]]|$)' \
				|| has '^(ls|cat|head|tail|wc|grep|rg|find|tree|stat|file|diff|du|pwd|which|echo)([[:space:]]|$)'; then
				allow "$role read-only command"
			fi
			[ -n "$READONLY_EXTRA_CMDS" ] && has "^($READONLY_EXTRA_CMDS)([[:space:]]|\$)" && allow "$role read-only command (READONLY_EXTRA_CMDS)"
			deny "$role is read-only: git status/diff/show/log/blame/ls-files, loop.sh status|check|task|review-info|verify|test|impact, ls/cat/grep/rg/find only."
		fi
		;;
	builder)
		has '(^|[^[:alnum:]_-])git[[:space:]].*(--git-dir|--work-tree)|(^|[^[:alnum:]_-])git[[:space:]]+-C[[:space:]]' && deny "$role may not point git at another directory."
		has "(^|[^[:alnum:]_-])git([[:space:]]+(-[^[:space:]]+|[^[:space:]-][^[:space:]]*=[^[:space:]]*))*[[:space:]]+($GIT_WRITE)([[:space:]]|\$)" && deny "$role may not run that git command (push/reset/checkout/switch/rebase/merge/tag/config/... are the human's)."
		has '(^|[^[:alnum:]_-])git[[:space:]]+branch([[:space:]]+[^[:space:]]+)*[[:space:]]+(-[a-zA-Z]*[dDmMcCf][a-zA-Z]*|--delete|--move|--copy|--force)([[:space:]]|$)' && deny "$role may not delete or move branches."
		has '(^|[^[:alnum:]_-])git[[:space:]]+stash[[:space:]]+(drop|clear|pop|apply|branch)' && deny "$role may only 'git stash push' (never drop/pop/apply)."
		has '(^|[^[:alnum:]_-])git[[:space:]]+commit([[:space:]]+[^[:space:]]+)*[[:space:]]+(--no-verify|-[a-zA-Z]*n[a-zA-Z]*)([[:space:]]|$)' && deny "$role may not skip git hooks (--no-verify / -n)."
		has '(^|[^[:alnum:]_-])git[[:space:]]+add([[:space:]]+[^[:space:]]+)*[[:space:]]+(-[a-zA-Z]*[Afu][a-zA-Z]*|--all|--force|--update|\.|\./|:/|\*)([[:space:]]|$)' && deny "$role must 'git add' explicit paths (no -A, ., -f, -u)."
		has '^\.claude/scripts/loop\.sh (start|next|log|stop|finish|unlock|new|cr-new|gate)([[:space:]]|$)' && deny "that loop.sh command belongs to the orchestrator, not to $role."
		has '(^|[^[:alnum:]_-])rm[[:space:]]+(-[a-zA-Z]*[rR][a-zA-Z]*[[:space:]]+)*(/|~|\$HOME|\.\.?)([[:space:]]|/?$)' && deny "$role may not delete the repo, home or root."
		if single; then
			case $(gitsub) in
				add) allow "task commit: git add <paths>" ;;
				commit)
					has '^git commit( --amend)? -F \.agent-loop/commit-msg$' && allow "task commit"
					has '^git commit --amend --no-edit$' && allow "task commit (amend)"
					deny "commit with: git commit -F .agent-loop/commit-msg   (or --amend -F / --amend --no-edit). Write the message, with its trailers, to .agent-loop/commit-msg first."
					;;
				restore) has '^git restore( --staged| --worktree| --source=HEAD)*( [^-][^[:space:]]*)+$' && allow "discard own change" ;;
				stash) has "^git stash push -u -m (\"[^\"]*\"|'[^']*')\$" && allow "stash a blocked attempt" ;;
			esac
		else
			has '(^|[^[:alnum:]_-])git[[:space:]]+(add|commit|restore|stash)([[:space:]]|$)' && deny "run git add/commit/restore/stash as a single command (no chaining), so the guard can check it."
		fi
		pass
		;;
	main | other)
		if [ $locked = 1 ]; then
			has "(^|[^[:alnum:]_-])git([[:space:]]+(-[^[:space:]]+|[^[:space:]-][^[:space:]]*=[^[:space:]]*))*[[:space:]]+($GIT_WRITE|add|commit|restore|stash|rm|mv)([[:space:]]|\$)" \
				&& deny "this session is orchestrating a /implement run: it never changes git state — agents do. (Run is over? .claude/scripts/loop.sh unlock)"
		fi
		pass
		;;
	esac
	pass
fi

# ----------------------------------------------------------------- Edit / Write / ...
case $tool in Edit | Write | MultiEdit | NotebookEdit) ;; *) pass ;; esac

paths=$(jq -r '[.tool_input | .. | objects | (.file_path?, .notebook_path?) | strings] | unique | .[]' <<<"$input")
content=$(jq -r '[.tool_input | .. | objects | (.content?, .new_string?, .file_text?, .new_code?, .new_source?) | strings] | join("\n")' <<<"$input")

APPROVAL_FIELDS='^(status:[[:space:]]*approved[[:space:]]*$|(approved|approved-by|sha256|fingerprint|spec-fingerprint|plan-sha256|applied|spec-applied|plan-applied):[[:space:]]*[^[:space:]])'

check_file() { # rel path
	local rel=$1 f sub name st
	case $rel in */../* | ../* | */..) deny "use a normalised path (no '..'): $rel" ;; esac

	case $rel in
	.claude/*)
		case $class in
			main) case $rel in
					.claude/hooks/* | .claude/scripts/* | .claude/settings.json | .claude/loop.conf)
						deny "$rel is part of the agent-loop enforcement — edit it yourself, outside Claude." ;;
				esac
				[ $locked = 1 ] && deny "this session is orchestrating a /implement run; it does not edit files." ;;
			*) deny "agents never edit .claude/ ($rel)." ;;
		esac
		return 0 ;;
	.agent-loop/commit-msg | .agent-loop/note | .agent-loop/scratch/*)
		case $class in reader | writer) deny "$role is read-only." ;; esac
		return 0 ;;
	.agent-loop/*) deny ".agent-loop/ holds loop state; only loop.sh writes it." ;;
	esac

	case $rel in
	"$SPECS_DIR"/*/*)
		sub=${rel#"$SPECS_DIR"/}; F=${sub%%/*}; name=${sub#*/}
		f="$REPO/$rel"
		case $name in
			spec.md | plan.md | tasks.md | brief.md | changes/CR-*.md)
				if [ -f "$f" ]; then
					st=$(fm_get "$f" status)
					[ "$st" = approved ] && deny "$rel is approved and frozen. Changes go through /amend (a change request the user approves)."
				fi
				printf '%s\n' "$content" | grep -Eq "$APPROVAL_FIELDS" \
					&& deny "only approve.sh sets approval fields (status: approved, approved, sha256, fingerprint, ...). Leave them empty; the user approves with /approve."
				;;
		esac
		case $class in reader) deny "$role is read-only." ;; esac
		if [ $locked = 1 ] && [ "$class" != builder ] && [ "$class" != writer ]; then
			[ "$name" = research.md ] || deny "this session is orchestrating a /implement run; it only edits research.md."
		fi
		case $name in
			research.md) return 0 ;;
			spec.md | brief.md) [ "$class" = main ] || [ "$class" = other ] || deny "only the main session writes $name (with the user, via /spec or /quick)." ;;
			plan.md)
				case $role in
					planner) chain_errors spec >/dev/null || deny "spec.md of $F is not approved — the planner stops here. The user must /approve spec first." ;;
					main | other) ;;
					*) deny "only the planner (or the main session) writes plan.md." ;;
				esac ;;
			tasks.md)
				case $role in
					tasker) chain_errors plan >/dev/null || deny "plan.md of $F is not approved — the tasker stops here." ;;
					main | other) ;;
					*) deny "only the tasker (or the main session) writes tasks.md." ;;
				esac ;;
			changes/CR-*.md) case $role in impact-analyst | main | other) ;; *) deny "only the impact-analyst (or the main session) writes change requests." ;; esac ;;
			*) case $role in planner | main | other) ;; *) deny "$role may only write research.md under $SPECS_DIR/." ;; esac ;;
		esac
		return 0 ;;
	"$SPECS_DIR"/*) [ "$class" = main ] || [ "$class" = other ] || deny "$role may not write $rel." ; return 0 ;;
	esac

	# ordinary repository files
	case $class in
		reader | writer) deny "$role is read-only outside its own spec file." ;;
		builder) match_globs "$rel" "$PROTECTED_GLOBS" && deny "$rel is protected (loop.conf PROTECTED_GLOBS) — report it as BLOCKED if the task needs it." ;;
		main | other) [ $locked = 1 ] && deny "this session is orchestrating a /implement run: it never edits code — the implementer does. (Run is over? .claude/scripts/loop.sh unlock)" ;;
	esac
	return 0
}

while IFS= read -r p; do
	[ -n "$p" ] || continue
	case $p in /*) ;; *) p="$cwd/$p" ;; esac
	case $p in
		"$REPO"/*) check_file "${p#"$REPO"/}" ;;
		*) case $class in reader | writer) deny "$role may not write outside the repository." ;; esac ;;
	esac
done <<EOF
$paths
EOF
pass
