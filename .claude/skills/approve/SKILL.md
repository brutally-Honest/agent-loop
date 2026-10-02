---
name: approve
description: Approve the current spec, plan, tasks, quick brief or change request. The approval is applied by a hook from your own keystroke — Claude cannot approve anything.
argument-hint: "[spec|plan|tasks|brief|change] [feature]   (no argument = whatever is waiting)"
disable-model-invocation: true
allowed-tools: Bash(.claude/scripts/loop.sh *) Bash(./.claude/scripts/loop.sh *)
---

# /approve

Your session id: ${CLAUDE_SESSION_ID}

The approval already happened — or was refused — before you read this. When the user typed `/approve $ARGUMENTS`, a UserPromptExpansion hook ran `.claude/scripts/approve.sh` and added its output to your context as "approve.sh output". If it refused, the user saw why and you never got this prompt.

- **No "approve.sh output" in your context:** the hook didn't run (hooks disabled, untrusted folder, or an older Claude Code). Say so, and tell the user to run `.claude/scripts/approve.sh $ARGUMENTS` in their own terminal. Stop there. Never try to approve by editing files or by running approve.sh — both are blocked.
- **Otherwise** relay the APPROVED / REOPENED lines in one or two sentences, then act on what was approved:

| Approved | You do |
|---|---|
| spec | Say the next step from its NEXT line (usually `/plan-feature`). |
| plan | Generate the tasks now: run `.claude/scripts/loop.sh gate tasks`, then dispatch the **tasker** with `Feature: <id>. Mode: <MODE from the gate>.` (+ `Change requests: <ids>` if the gate lists any). When it finishes, run `.claude/scripts/loop.sh status`. tasks.md approved → list the tasks (id — title, one line each) and end with "Type `/implement` to build it." Still a draft → show `.claude/scripts/loop.sh check tasks` and tell the user to fix tasks.md and type `/approve tasks`. |
| tasks | "Type `/implement` to build it." |
| brief | Build it now: read `.claude/skills/implement/LOOP.md` and follow it exactly, using the session id above. |
| change | Follow its NEXT line. Scope **spec**: edit spec.md (or brief.md) to apply the CR's Delta exactly — new ACs added, modified AC text replaced, removed ACs struck through as `- ~~**ACn**~~ — removed in vN (CR-nnn): reason`, never deleted — run `.claude/scripts/loop.sh check spec` (or `check brief`), summarise the diff, and ask the user to `/approve spec` (or `/approve brief`). Scope **plan**: tell the user to run `/plan-feature`. Scope **tasks**: run `.claude/scripts/loop.sh gate tasks`, dispatch the **tasker** with Mode amend and the CR id, then report as for plan. |
