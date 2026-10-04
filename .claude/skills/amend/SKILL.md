---
name: amend
description: Change approved work — a spec, plan or tasks that are frozen — mid-build or before merge, through an impact-analysed change request you approve. Add --reconcile when the code drifted from the spec. For changes after merge, use /spec --supersedes NNN.
argument-hint: "<what changed and why> [--reconcile]"
disable-model-invocation: true
allowed-tools: Bash(.claude/scripts/loop.sh *) Bash(./.claude/scripts/loop.sh *)
---

# /amend

Change request, in the user's words: $ARGUMENTS

## Gate (if this failed, no change request is created)
!`.claude/scripts/loop.sh gate amend`

## Steps
1. If the request is vague, ask ONE AskUserQuestion call (≤3 questions): what exactly changes; why; what should happen to behaviour that's already built (keep, rework, remove).
2. Run `.claude/scripts/loop.sh cr-new`. It prints the CR id and file (or the existing draft CR, which you revise instead).
3. Dispatch the **impact-analyst** (Agent tool `model`: the gate's MODEL) with: `Feature: <feature>. CR: <id>. Mode: <reconcile if --reconcile was given, else amend>. Request: <the user's words plus their answers, verbatim>.`
4. It returns `CR-DRAFTED <id>`. Show the user: class and scope; the Delta lines; the impact on done tasks (one line each); the recommendation. End with:
   "Type `/approve change` to accept it — this reopens the <scope>, and the build stays paused until it's approved again — or tell me what to change."

Nothing is reopened until the user types `/approve change`. You never edit approved files; a hook blocks it.
