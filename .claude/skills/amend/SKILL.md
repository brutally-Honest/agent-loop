---
name: amend
description: Alias of /change — change approved work through a reopen or a change request.
argument-hint: "[spec|plan|tasks] <what changes and why> [--adopt] [--reconcile]"
disable-model-invocation: true
allowed-tools: Bash(.claude/scripts/loop.sh *) Bash(./.claude/scripts/loop.sh *)
---

# /amend (alias of /change)

The change, in the user's words: $ARGUMENTS

Read `.claude/skills/change/SKILL.md` and follow it exactly — the hook ran the same gate for /amend.
