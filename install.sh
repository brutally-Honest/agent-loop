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
# kit skills from before the al- prefix (v0.1 and early v0.2). Only the kit's own: a skill of yours
# with the same name (no "allowed-tools: Bash(.claude/scripts/loop.sh *)" line) is left alone.
for s in spec plan plan-feature approve implement amend change fix quick pause resume status answer; do
	d=".claude/skills/$s"
	[ -f "$d/SKILL.md" ] || continue
	if grep -qx "name: $s" "$d/SKILL.md" && grep -qF 'Bash(.claude/scripts/loop.sh *)' "$d/SKILL.md"; then backup "$d"; fi
done
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
if [ -f .claude/loop.conf ]; then
	echo "  kept your .claude/loop.conf"
	if ! grep -q '^PROFILE=' .claude/loop.conf; then
		cp "$KIT/.claude/loop.conf" .claude/loop.conf.v0.2
		echo "  NOTE your loop.conf predates profiles: keys it sets (e.g. MAX_FIX_ROUNDS, PLAN_MAX_LINES) pin those values"
		echo "       whatever the profile. The v0.2 file is in .claude/loop.conf.v0.2 — copy your VERIFY_CMD/TEST_CMD/globs into it"
		echo "       and rename it, or keep yours (loop.sh config shows what applies and why)."
	fi
else cp "$KIT/.claude/loop.conf" .claude/loop.conf; fi

# Rules earlier kit versions added and this one dropped (enforcement is opt-in since v0.2).
# Only these exact strings are removed on upgrade; rules you added yourself always stay.
OLD_KIT_DENY='["Edit(/.claude/hooks/**)","Edit(/.claude/scripts/**)","Edit(/.claude/settings.json)","Edit(/.claude/loop.conf)","Read(.env)","Read(.env.*)","Read(*.pem)","Read(*.key)","Read(id_rsa*)","Read(id_ed25519*)"]'
if [ -f .claude/settings.json ]; then
	tmp=$(mktemp)
	# kit hook entries (they call .claude/hooks/<kit hook>.sh) are replaced, not added twice;
	# every other hook entry is kept as it is
	jq -s --argjson olddeny "$OLD_KIT_DENY" '
		def kithook: [.hooks[]?.command // "" | test("/\\.claude/hooks/(guard|on-command|on-agent-stop|on-prompt)\\.sh")] | any;
		.[0] as $o | .[1] as $n
		| ($o * {permissions: {
				allow: ((($o.permissions.allow // []) + ($n.permissions.allow // [])) | unique),
				deny:  ((($o.permissions.deny  // []) - $olddeny + ($n.permissions.deny // [])) | unique)}})
		| .hooks = (reduce ((($o.hooks // {}) | keys) + ($n.hooks | keys) | unique)[] as $ev (($o.hooks // {});
				.[$ev] = ([(.[$ev] // [])[] | select(kithook | not)] + ($n.hooks[$ev] // []))
				| if .[$ev] == [] then del(.[$ev]) else . end))
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

vcur=$(bash -c '. .claude/loop.conf 2>/dev/null; printf %s "${VERIFY_CMD:-}"')
vsug=$(.claude/scripts/loop.sh suggest-verify 2>/dev/null || true)
if [ -n "$vcur" ]; then vline="VERIFY_CMD is already set: $vcur"
elif [ -n "$vsug" ]; then vline="Set VERIFY_CMD in .claude/loop.conf (required). Suggested for this repo: VERIFY_CMD=\"$vsug\""
else vline="Set VERIFY_CMD in .claude/loop.conf (required): the command that runs your tests, lint and build"; fi

cat <<EOF

Done. Next:
  1. $vline
     (TEST_CMD is optional.) /al-implement refuses to start while VERIFY_CMD is empty.
  2. Pick a profile in .claude/loop.conf: PROFILE="balanced" (default), "fast" or "strict".
     Every other knob is commented there; .claude/scripts/loop.sh config shows what applies.
  3. Commit the kit:   git add .claude .gitignore && git commit -m "chore: add agent-loop kit"
  4. Check the setup:  .claude/scripts/loop.sh doctor
  5. Start Claude Code from the repo root and accept the workspace-trust prompt (hooks need it).
  6. /al-spec <what you want>  or  /al-quick <small change>  — /al-status shows where you are at any time.
EOF
