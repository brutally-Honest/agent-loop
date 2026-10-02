---
name: spec
description: Start a feature from a rough requirement — creates the branch (or a worktree), interviews you, and drafts specs/NNN-slug/spec.md as a draft. Re-run on a feature branch to keep refining the draft.
argument-hint: "<rough requirement, in your words> [--worktree] [--supersedes NNN]"
disable-model-invocation: true
allowed-tools: Bash(.claude/scripts/loop.sh *) Bash(./.claude/scripts/loop.sh *)
---

# /spec

Requirement, in the user's words: $ARGUMENTS

## Where things stand
!`.claude/scripts/loop.sh status`

## Rules
- The spec is the user's. You ask, they decide. Never invent a requirement. Anything you propose that they haven't confirmed carries `[ASSUMED]`; anything unanswered is `[NEEDS CLARIFICATION: …]`. Approval refuses while either remains.
- You never approve — only the user can, by typing `/approve spec` (a hook applies it). A hook also stops you from setting approval fields.
- Write only `specs/<feature>/spec.md` and `research.md`. No plan, no code.

## 1. Branch — only when "Where things stand" shows no feature on this branch
- If it shows a feature whose spec.md is **approved**: stop. Tell the user approved specs are frozen and changes go through `/amend`.
- If it shows a **draft** spec: skip to step 2 and refine it with the new input.

Otherwise ask ONE AskUserQuestion call with these questions:
1. "Where should this work live?" — options `Local branch (Recommended)` and `Worktree`. Leave this question out and use a worktree only when the user's text explicitly asks for one (e.g. `--worktree`).
2. "What kind of change is this?" — feat / fix / refactor / chore, your best guess first.
3. "Short name for the branch and folder?" — 2-3 kebab-case slugs you derive from the requirement.

Then run `.claude/scripts/loop.sh new <kind> <slug>` adding `--worktree` if chosen and `--supersedes <NNN>` if the user passed it. It creates the branch `<kind>/<NNN-slug>` from the base branch plus `specs/<NNN-slug>/spec.md` (draft) and `research.md`.
If it prints `WORKTREE <path>`, call EnterWorktree with `path: <path>`. If that tool isn't available, tell the user to run `cd <path> && claude` and `/spec` there, and stop.

## 2. Interview
2-4 rounds of AskUserQuestion, at most 4 questions per call. Read the code first, so the options you offer are concrete and grounded in what exists; the user can always answer "Other". Cover, in order, only what the requirement doesn't already answer:
- the problem, who has it, and what "done" looks like → Problem, Goal;
- what's in and explicitly out → Non-goals;
- for each capability, the trigger and the observable result → acceptance criteria;
- edge cases and failures that apply: empty or huge input, duplicates and retries, concurrency, auth and tenant boundaries, a dependency down, time zones → Edge cases;
- constraints: performance budgets, compatibility, security, data → Constraints.
By kind: **fix** — repro steps, expected vs actual; AC1 is the fixed behaviour. **refactor** — the structural goal, plus ACs for behaviour that must NOT change. **chore** — what must still work afterwards.

## 3. Draft
Fill spec.md (keep the frontmatter as is; replace each <!-- hint --> with content):
- ACs numbered `- **AC1** — When <trigger>, the system shall <observable result>.` — behaviour, not implementation; each one traceable to something the user said.
- Edge cases `- **E1** — <situation> → <expected> (ACn)`.
Run `.claude/scripts/loop.sh check spec --draft` and fix the format errors it lists.

## 4. Critic pass
Dispatch the **spec-critic** agent: "Spec: specs/<feature>/spec.md". If it returns `GAPS`, ask the user the questions that matter (AskUserQuestion, ≤4 per call) and update the spec.

## 5. Hand back
Run `.claude/scripts/loop.sh check spec` (the approval check). Show the user: the AC list (one line each), the non-goals, and anything the check still reports. End with:
"Review `specs/<feature>/spec.md`. Type `/approve spec` to approve it, or tell me what to change."
