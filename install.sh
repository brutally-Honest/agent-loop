#!/usr/bin/env bash
# install.sh — copy the agent-loop kit into a git repository (idempotent; re-run to upgrade).
#
#   ./install.sh /path/to/repo
#
# - copies .claude/{agents,skills,hooks,scripts,templates}; keeps your .claude/loop.conf if present
# - merges .claude/settings.json (your keys kept; permission rules and hooks added, deduplicated)
# - adds .agent-loop/, .claude/worktrees/ and .claude/agent-loop-backup-*/ to .gitignore
# - moves anything it would overwrite (and the old /run-feature + agent-bash-guard.sh) to
#   .claude/agent-loop-backup-<timestamp>/
set -euo pipefail
KIT=$(cd "$(dirname "$0")" && pwd)
[ $# -ge 1 ] || { echo "usage: $0 /path/to/repo" >&2; exit 1; }
cd "$1"
repo=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "$1 is not inside a git repository" >&2; exit 1; }
cd "$repo"
command -v jq >/dev/null 2>&1 || { echo "jq is required (the hooks use it): install jq first" >&2; exit 1; }

ts=$(date +%Y%m%d-%H%M%S)
bk=".claude/agent-loop-backup-$ts"
backup() {
	[ -e "$1" ] || return 0
	mkdir -p "$bk/$(dirname "$1")"
	mv "$1" "$bk/$1"
	echo "  backed up $1 -> $bk/$1"
}

echo "Installing agent-loop into $repo"
for f in .claude/commands/run-feature.md .claude/hooks/agent-bash-guard.sh; do backup "$f"; done
for f in $(cd "$KIT" && find .claude/agents .claude/skills .claude/hooks .claude/scripts .claude/templates -type f); do
	if [ -e "$f" ] && ! cmp -s "$KIT/$f" "$f"; then backup "$f"; fi
done

mkdir -p .claude
for d in agents skills hooks scripts templates; do
	mkdir -p ".claude/$d"
	(cd "$KIT/.claude/$d" && find . -type f) | while IFS= read -r f; do
		mkdir -p ".claude/$d/$(dirname "$f")"
		cp "$KIT/.claude/$d/$f" ".claude/$d/$f"
	done
done
chmod +x .claude/hooks/*.sh .claude/scripts/*.sh
if [ -f .claude/loop.conf ]; then echo "  kept your .claude/loop.conf"; else cp "$KIT/.claude/loop.conf" .claude/loop.conf; fi

if [ -f .claude/settings.json ]; then
	tmp=$(mktemp)
	jq -s '
		.[0] as $o | .[1] as $n
		| ($o * {permissions: {
				allow: ((($o.permissions.allow // []) + ($n.permissions.allow // [])) | unique),
				deny:  ((($o.permissions.deny  // []) + ($n.permissions.deny  // [])) | unique)}})
		| .hooks = (reduce ($n.hooks | keys[]) as $ev (($o.hooks // {});
				.[$ev] = (((.[$ev] // []) + $n.hooks[$ev]) | unique)))
	' .claude/settings.json "$KIT/.claude/settings.json" > "$tmp"
	if jq -e --slurpfile a "$tmp" '. == $a[0]' .claude/settings.json >/dev/null; then
		echo "  .claude/settings.json already up to date"
	else
		mkdir -p "$bk"
		cp .claude/settings.json "$bk/settings.json.before"
		cat "$tmp" > .claude/settings.json
		echo "  merged .claude/settings.json (previous copy in $bk/)"
	fi
	rm -f "$tmp"
else
	cp "$KIT/.claude/settings.json" .claude/settings.json
fi

touch .gitignore
for l in '.agent-loop/' '.claude/worktrees/' '.claude/agent-loop-backup-*/'; do
	grep -qxF "$l" .gitignore || { echo "$l" >> .gitignore; echo "  .gitignore += $l"; }
done

cat <<EOF

Done. Next:
  1. Set VERIFY_CMD (and optionally TEST_CMD) in .claude/loop.conf
  2. Commit the kit:   git add .claude .gitignore && git commit -m "chore: add agent-loop kit"
  3. Check the setup:  .claude/scripts/loop.sh doctor
  4. Start Claude Code from the repo root and accept the workspace-trust prompt (hooks need it).
  5. /spec <what you want>   or   /quick <small change>
EOF
