---
name: implement
description: Build the approved feature (or quick brief) — implementer → reviewer → fix loop per task — until everything passes or your input is needed. Works for feat, fix, refactor and chore.
disable-model-invocation: true
allowed-tools: Bash(.claude/scripts/loop.sh *) Bash(./.claude/scripts/loop.sh *)
---

# /implement

## Gate (if this failed, nothing runs)
!`.claude/scripts/loop.sh gate implement`

Your session id: ${CLAUDE_SESSION_ID}

Read `${CLAUDE_SKILL_DIR}/LOOP.md` and follow it exactly.
