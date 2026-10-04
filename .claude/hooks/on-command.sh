#!/usr/bin/env bash
# on-command.sh — UserPromptExpansion hook for the workflow commands you type.
#
# Fires only when YOU type the command (UserPromptExpansion never fires for Claude's own
# tool calls, and every workflow skill sets disable-model-invocation), before Claude sees it:
#   /approve ...        runs approve.sh with your arguments. Refused -> the command is blocked
#                       and you see why; approved -> approve.sh's output goes to Claude's context.
#   /plan-feature       runs `loop.sh gate plan`      } a failed gate blocks the command with its
#   /implement          runs `loop.sh gate implement` } reason, so no agent starts. (The skills
#   /amend              runs `loop.sh gate amend`     } run the same gate again as a backstop.)
set -u
input=$(cat)
command -v jq >/dev/null 2>&1 || exit 0
name=$(jq -r '.command_name // ""' <<<"$input")
args=$(jq -r '.command_args // ""' <<<"$input")
cwd=$(jq -r '.cwd // ""' <<<"$input")
name=${name##*:}; name=${name##*/}
case $name in approve | plan-feature | implement | amend) ;; *) exit 0 ;; esac
[ -n "$cwd" ] && cd "$cwd" 2>/dev/null
[ -n "${AGENT_LOOP_DEBUG:-}" ] && { r=$(git rev-parse --show-toplevel 2>/dev/null) && mkdir -p "$r/.agent-loop" && printf '%s on-command %s\n' "$(date -u +%H:%M:%S)" "$input" >> "$r/.agent-loop/hook-debug.log"; }

scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../scripts"

block() { jq -cn --arg r "$1" '{decision:"block", reason:$r}'; exit 0; }

if [ "$name" != approve ]; then
	gate=$name; [ "$name" = plan-feature ] && gate=plan
	gargs=""; [ "$gate" = implement ] && gargs=$args   # run flags are checked here, before Claude sees them
	set -f
	# shellcheck disable=SC2086
	out=$("$scripts/loop.sh" gate "$gate" $gargs 2>&1) || block "/$name stopped by its gate — nothing ran:
$out"
	exit 0
fi

set -f
# shellcheck disable=SC2086
out=$("$scripts/approve.sh" $args 2>&1); rc=$?
set +f
if [ $rc -ne 0 ]; then
	block "Not approved. approve.sh said:
$out"
fi
jq -cn --arg c "approve.sh output (the user's /approve was applied by the hook):
$out" '{hookSpecificOutput:{hookEventName:"UserPromptExpansion", additionalContext:$c}}'
exit 0
