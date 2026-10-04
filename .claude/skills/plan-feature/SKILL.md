---
name: plan-feature
description: Draft the technical plan for the current feature (requires an approved spec), then ask you the open questions. Approving the plan generates the tasks automatically.
disable-model-invocation: true
allowed-tools: Bash(.claude/scripts/loop.sh *) Bash(./.claude/scripts/loop.sh *)
---

# /plan-feature

## Gate (if this failed, the planner does not run)
!`.claude/scripts/loop.sh gate plan`

## Steps
1. Dispatch the **planner** agent (Agent tool `model`: the gate's MODEL) with: `Feature: <FEATURE>. Mode: <MODE>.` — values from the gate output. If CHANGE-REQUESTS lists any, add `Change requests: <ids>`.
2. It returns `PLAN-DRAFTED <n>` plus numbered questions. If n is 0, go to step 4.
3. Ask the user those questions with AskUserQuestion (≤4 per call); put each question's recommended option first, labelled "(Recommended)". Then get the answers into the plan:
   - send them to the same planner with SendMessage: "Mode: revise. Answers: <each question → answer>. Mark each `→ decided: <answer>`, update the affected sections, run loop.sh check plan --draft";
   - if it can't be reached, dispatch a fresh planner with `Feature: <FEATURE>. Mode: revise. Answers: …`.
4. Run `.claude/scripts/loop.sh check plan`. If it reports problems the planner should fix, send them back once.
5. Show the user: the chosen approach (1-2 lines); each alternative with one line on why not; the top risks; whether every AC is covered. End with:
   "Review `specs/<feature>/plan.md`. Type `/approve plan` — tasks are then generated and approved automatically — or tell me what to change."

You never approve and never write code. A hook blocks writes to plan.md unless the spec is approved.
