---
name: plan-feature
description: Alias of /plan — draft the plan and tasks for the current feature (requires an approved spec).
disable-model-invocation: true
allowed-tools: Bash(.claude/scripts/loop.sh *) Bash(./.claude/scripts/loop.sh *)
---

# /plan-feature (alias of /plan)

## Gate (if this failed, the planner does not run)
!`.claude/scripts/loop.sh gate plan`

Read `.claude/skills/plan/SKILL.md` and follow its Steps exactly, using the gate output above.
