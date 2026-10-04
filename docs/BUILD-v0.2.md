# agent-loop v0.2 — build brief

You are building v0.2 of **agent-loop**, a Claude Code kit (agents, skills, hooks, bash scripts) that runs a
spec → plan → tasks → implement loop with deterministic gates. Repo: `brutally-Honest/agent-loop`, branch from
`main` at `e50cf8a` (v0.1 + VERIFY_CMD fix).

v0.1 works but is too slow, too rigid and blocks the user outside the loop. v0.2 keeps the guarantees that matter
and drops the rest. **Everything in "Decisions" below is agreed with the owner — don't re-litigate it.** Where this
brief says "verify first", check the Claude Code behaviour before building on it, and if it doesn't hold, pick the
fallback named there and note it in the README's honest-limits section.

---

## 0. Before you start

### Workspace

```bash
cd ~/code/agent-loop && git pull && git log --oneline -1   # expect e50cf8a
git switch -c v0.2
claude --setting-sources user
```

`--setting-sources user` matters. This repo's `.claude/` **is** the kit, so a normal `claude` session loads the
kit's own hooks and permission denies and they block you from editing `.claude/scripts`, `.claude/hooks`, etc.
Loading only user settings turns them off for the build session. (Phase 1 also removes most of that friction for
good.)

### Read first, in this order
1. `README.md` — the whole thing, especially "What is enforced, and how" and "Honest limits".
2. `.claude/scripts/lib.sh`, `loop.sh`, `validate.sh`, `approve.sh` — the deterministic core.
3. `.claude/hooks/guard.sh`, `on-command.sh`, `on-agent-stop.sh`.
4. `.claude/skills/*/SKILL.md` and `.claude/skills/implement/LOOP.md`.
5. `.claude/agents/*.md`, `.claude/templates/*.md`, `.claude/loop.conf`, `.claude/settings.json`.
6. `install.sh`, `selftest.sh`.

### Hard constraints (unchanged from v0.1)
- **Portability:** bash 3.2 (macOS default), POSIX awk (test with mawk), BSD-safe sed/grep. No `sed -i`, no
  `grep -P`, no `readlink -f`, no associative arrays, no `${var,,}`. `jq` is the only non-POSIX dependency.
- **Approvals come only from the user's keystroke.** `approve.sh` runs from a UserPromptExpansion hook when the
  user types `/approve …`, or from the user's terminal. Claude (main session or any agent) must never be able to
  run it or forge its effect.
- **Kit agents never push, merge, rebase, reset, or edit the kit / approval fields.**
- `selftest.sh` stays green after every phase; add checks for every new behaviour.
- One commit per phase, conventional subject (`feat(loop): …`, `refactor(guard): …`), body says what and why.

### Known Claude Code facts (verified on 2.1.287 in v0.1)
- PreToolUse hook input has `agent_type` (= the agent file's frontmatter `name`) and `agent_id` for subagents;
  absent for the main session. Output `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow|deny","permissionDecisionReason":"…"}}`.
- UserPromptExpansion fires only for slash commands the **user** typed; can block (`decision: block`, `reason`) or
  add `additionalContext`. Matcher is a regex on the command name.
- SubagentStop: `decision: block` + `reason` sends the agent back; `last_assistant_message`, `stop_hook_active`.
- Skills: `disable-model-invocation: true`; `` !`cmd` `` injection (a failing command aborts the skill);
  `${CLAUDE_SESSION_ID}`, `${CLAUDE_SKILL_DIR}`, `$ARGUMENTS`; `allowed-tools`.
- Subagents can't use AskUserQuestion — only the main session can.
- Hooks need workspace trust; project `allow` rules need it too. `deny` beats `allow`.

### Verify first (unknowns — check before building on them)
| # | Question | How to check | If it doesn't hold |
|---|---|---|---|
| V1 | Does the Agent tool's `model` parameter override a custom subagent's frontmatter `model`? | Dispatch `implementer` with `model: haiku` in a scratch repo; check the transcript/model used | Generate per-model agent variants at install time (`implementer-haiku.md`, …) and dispatch by name |
| V2 | Does UserPromptExpansion / UserPromptSubmit fire for a prompt typed **while a turn is running** (queued), and when? | Start a long `/implement` in a scratch repo, type `/pause`, watch a debug log in the hook | `/pause` becomes graceful-at-turn-end only; document Esc + `loop.sh pause` (terminal) as the immediate paths |
| V3 | Can SendMessage continue a finished subagent with its context (already used by `/plan-feature` revise)? | Existing v0.1 flow | Fall back to a new agent with the findings (v0.1 behaviour) |
| V4 | Does agent frontmatter support a per-agent reasoning-effort key? | Claude Code docs / `claude --help` / try it | Skip `EFFORT_*` keys; model choice only |

Record the answers at the top of your phase-1 commit body.

---

## Decisions (agreed)

| Area | Decision |
|---|---|
| Enforcement | **Opt-in.** Nothing is enforced on the main session unless a kit run is active. Kit subagents are always constrained. Approval-by-keystroke and "Claude can't run approve.sh" are always on. |
| Default profile | `balanced` (owner may switch the shipped default to `fast` — one line in `loop.conf`) |
| Overrides | 5 layers: run flags > task fields > feature (`plan.md` frontmatter) > repo `loop.conf` > profile defaults. Effective config is inspectable. |
| Reviews | Configurable `REVIEW=none\|branch\|risk\|every`. `none` = implement + tests + script verify, **no reviewer at all**. Balanced default = `risk` + branch review. |
| Verify | Run **once per task, by the script**. Implementer runs targeted tests only. Reviewer never re-runs verify. |
| Fix rounds | Continue the **same** implementer (SendMessage); fresh agent only as fallback. |
| Planner + tasker | **Merged.** The planner writes plan.md and tasks.md; `/approve plan` approves the plan and auto-approves tasks (if `AUTO_APPROVE_TASKS=on`) in the same keystroke. |
| Models | Per agent type in `loop.conf`, per task via `Model:` field / planner `Size:` hint, per run via `--model`. |
| Rigidity | Approval validity = contract fingerprint, not whole-file hash. Non-contract edits allowed. Contract edits → offered as a change, not an error. Not-started tasks freely editable. Minimal required spec sections. Optional trailers. `--here` (use current branch). |
| Commands | `/spec` `/plan` `/approve` `/implement` `/change` `/fix` `/quick` `/pause` `/resume` `/status` `/answer`. No terminal needed for normal use. `/plan-feature` and `/amend` stay as aliases. |
| BLOCKED / ESCALATE | Asked inline as question cards when the user is present; stop only when unattended. |
| Pause | `/pause` (graceful: finish current task), `/pause now` (agents stopped at next tool call), Esc (native). One `/resume` handles every leftover state. |
| Out of scope for v0.2 | Parallel task execution, `/reorder` as a separate command (editable not-started tasks cover it), global `~/.claude` install, multi-repo/hub mode. |

---

## Phase 1 — Opt-in enforcement

**Goal:** with the kit installed, the user can prompt Claude (or use another agent, or edit by hand) to change
anything, and nothing blocks them. Rules apply only inside kit commands.

| Change | Detail |
|---|---|
| Run flag | `.agent-loop/<f>/lock` becomes the "run active" flag (content: session id, start time). Created by `loop.sh start`, removed by `stop`/`finish`/`pause`. |
| `guard.sh` main session | If no run flag for this session → **allow everything** (exit 0 with no decision), except: any command invoking `approve.sh` → deny; writes that set approval fields (`status: approved`, `approved:`, `sha256:`, `fingerprint:`) in `specs/**` frontmatter → deny. With a run flag for this session → today's orchestrator rules (no code edits, no git writes, only `loop.sh` calls). |
| `guard.sh` kit agents | Unchanged: `implementer`, `quick-builder`, `reviewer`, `spec-critic`, `planner`, `impact-analyst` (and any new kit agent) keep their per-role rules always. Unknown `agent_type` (user's own agents, Explore, general-purpose…) → allow, like the main session outside a run. |
| `settings.json` | Remove the permission denies that block normal prompts: `Edit` of `.claude/hooks/**`, `.claude/scripts/**`, `settings.json`, `loop.conf`, and the secret `Read` denies. Keep `Bash(*approve.sh*)` deny. Move secret-file protection into `guard.sh` for kit agents only. |
| `install.sh` upgrade | The settings merge is a union today, so old deny rules would survive an upgrade. Remove the exact v0.1 kit deny entries during merge (list them explicitly; never remove user-added rules). |
| Auto-pause on plain prompt | New `UserPromptSubmit` hook `on-prompt.sh`: if a run flag exists for this session and the prompt is not a kit command (`/status`, `/pause`, `/resume`, `/answer`, `/implement`, `/approve`…), convert the run to paused (see phase 6) and add context "agent-loop run paused; /resume to continue". Depends on V2 — if the event doesn't fire for queued prompts, it still applies to the next prompt after Esc. |
| `on-command.sh` | Matcher extended to the new commands as they arrive in later phases. |

**Acceptance**
- With no kit command running, a main-session `Edit` of `.claude/scripts/loop.sh`, of an approved `spec.md` body,
  and of any source file is allowed.
- During a run (flag present, same session) the main session cannot edit `src/…` or `git commit`.
- A kit `implementer` can't edit `.claude/**` or `specs/<f>/spec.md` at any time; a non-kit agent can (outside a run).
- `Bash(.claude/scripts/approve.sh spec)` is denied for main session and every agent, run or no run.
- Setting `status: approved` in a spec's frontmatter via Edit/Write is denied for Claude.
- `install.sh` over a v0.1 install leaves no v0.1 kit deny rules and keeps a user-added deny rule.

---

## Phase 2 — Overrides and profiles

**Goal:** every speed/cost knob is a setting, resolvable per run, task, feature and repo.

### Config resolution
Add `cfg <KEY> [TASK_ID]` to `lib.sh`. Precedence, first hit wins:
1. **Run:** `.agent-loop/<f>/run.conf` (`KEY=value` lines) written by `loop.sh start` from flags.
2. **Task:** fields in the task block — `Model:`, `Review:` (`skip|always`), `Verify:` (`targeted|full`).
3. **Feature:** `plan.md` frontmatter keys (`profile:`, `review:`, `verify:`, `fix-rounds:`, `mutation:`).
4. **Repo:** `.claude/loop.conf`.
5. **Profile defaults** (from the effective `PROFILE`).
6. **Kit defaults.**

`PROFILE` itself resolves through layers 1, 3, 4, then defaults to `balanced`.

### Keys
| Key | Values | fast | balanced | strict |
|---|---|---|---|---|
| `REVIEW` | `none` `branch` `risk` `every` | `branch` | `risk` | `every` |
| `VERIFY` | `targeted` `task` `every-N` `end` `off` | `every-3` | `task` | `task` |
| `FIX_ROUNDS` | 0–3 | 1 | 2 | 2 |
| `MUTATION` | `off` `risk` `every` | `off` | `risk` | `every` |
| `CRITIC` | `off` `self` `agent` | `off` | `self` | `agent` |
| `MODEL_PLANNER` | `haiku` `sonnet` `opus` | sonnet | opus | opus |
| `MODEL_IMPLEMENTER` | 〃 | sonnet | sonnet | sonnet |
| `MODEL_REVIEWER` (task) | 〃 | sonnet | sonnet | opus |
| `MODEL_BRANCH_REVIEWER` | 〃 | sonnet | opus | opus |
| `MODEL_QUICK` | 〃 | sonnet | sonnet | sonnet |
| `MODEL_IMPACT` | 〃 | sonnet | sonnet | sonnet |
| `SIZE_MODELS` | `S=… M=… L=…` | `S=haiku M=sonnet L=sonnet` | `S=haiku M=sonnet L=opus` | `S=sonnet M=sonnet L=opus` |
| `AUTO_APPROVE_TASKS` | `on` `off` | on | on | off |
| `TRAILERS` | `on` `off` | on | on | on |
| `REVIEW_LINES` | number (risk trigger) | 300 | 150 | — |
| `REVIEW_GLOBS` | globs (risk trigger) | `""` | `WATCHED_GLOBS` | — |
| `PLAN_MAX_LINES` | number (warning) | 200 | 200 | 200 |

Model resolution for an implementer dispatch: run `--model T002=…` > task `Model:` > `SIZE_MODELS[Size]` (only if
the task has `Size:`) > `MODEL_IMPLEMENTER`.

### Commands
- `/implement [flags]` → skill passes `$ARGUMENTS` to `loop.sh start --session <id> <flags>`. Flags:
  `--profile P`, `--review R`, `--verify V`, `--fix-rounds N`, `--mutation M`, `--model T002=haiku,T004=opus,implementer=sonnet,reviewer=opus`.
  Unknown flag/value → refuse with the list of valid ones. Flags apply to this run only (`run.conf`, deleted on finish).
- `loop.sh config [TASK]` → prints every key's effective value **and where it came from** (`run`, `task`, `feature`, `repo`, `profile:balanced`, `default`). Also exposed through `/status --config`.
- `ACTION` lines carry the resolved model: `ACTION implement T002 model=haiku`, `ACTION review T002 model=sonnet`,
  `ACTION review BRANCH model=opus`. `LOOP.md`: pass that model to the Agent tool (see V1 fallback).
- `REVIEW=none`: after a successful post-task check the task goes straight to `PASS`; no task review, no branch
  review; `finish` reports "reviews: off".

**Acceptance**
- `loop.sh config T002` shows `MODEL=haiku (task)` when T002 has `Model: haiku`, and `MODEL=opus (run)` when the
  run was started with `--model T002=opus`.
- A feature with `review: none` in plan.md frontmatter runs every task without `ACTION review …` and finishes with no branch review.
- `--review bogus` is refused with the valid values listed.
- Profiles change the defaults exactly as in the table (selftest asserts each column).

---

## Phase 3 — Speed

**Goal:** a task costs close to "one prompt that writes tests + code". No redundant runs or agents.

| # | Change | Detail |
|---|---|---|
| S1 | Verify once, by the script | Implementer runs only targeted tests (`loop.sh test <args>` when `TEST_CMD` is set, else the repo's test command scoped to touched packages). Remove "run full verify until green" from `implementer.md` and `quick-builder.md`. `post_task` runs `VERIFY_CMD` per `VERIFY`: `task` = every task; `every-N` = every Nth task + always before `finish`; `targeted` = never per task, once before `finish`; `end` = once before `finish`; `off` = never (warn in report). If the full verify before finish fails → `ACTION fix <last task> post-task`. Remove verify from `reviewer.md`; `review-info` prints the script's verify result for the reviewed range. |
| S2 | Risk-based review | With `REVIEW=risk`, a task gets `ACTION review` only if any of: task field `Review: always`; `Risk: high`; changed lines > `REVIEW_LINES`; a WATCH line exists; a touched path matches `REVIEW_GLOBS`. Otherwise `PASS` after post-task. `Review: skip` on a task skips it under `risk` and `every`. Branch review runs unless `REVIEW=none`. Record the reason ("reviewed: watched file package.json" / "skipped: low risk") in run.log and the report. |
| S3 | Same implementer for fixes | `LOOP.md`: keep the implementer's agent id per task; on `ACTION fix …` send the findings via SendMessage to that agent; if unreachable, dispatch a new one (v0.1 prompt). Reviewer stays fresh every time. |
| S4 | Merge planner + tasker | `planner.md` writes plan.md **and** tasks.md (task block gains `- Size: S\|M\|L` and `- Risk: low\|high`; `Model:`/`Review:` optional). Final line `PLAN-DRAFTED <open questions> <tasks>`. `on-agent-stop.sh` validates both (`check plan --draft`, `check tasks --draft`). `/approve plan` → `approve.sh plan` approves the plan, then validates tasks.md and, if `AUTO_APPROVE_TASKS=on`, stamps it in the **same commit** (`docs(F): approve plan vN + tasks vN`). If tasks fail validation: plan approved, tasks stay draft, the output says what to fix. Amend/change mode: the planner does plan and tasks together. Delete `tasker.md`; keep `approve.sh tasks` for `AUTO_APPROVE_TASKS=off`. Rename `/plan-feature` → `/plan` (keep alias). |
| S5 | Context pack | `loop.sh task <ID>` prints: the task block; the full text of its ACs and E-ids (from spec.md); the plan's Approach + the Design paragraphs and AC-coverage rows that mention those ACs; answered research questions; last 3 task commits (subject + first body line); the effective model/review/verify for the task. Agents start from it and read more only when needed (say so in `implementer.md`/`reviewer.md`). |
| S6 | Mutation / critic by config | `MUTATION`: `off` removes the step; `risk` only for `Risk: high` tasks (the context pack says which). `CRITIC`: `off` = skip; `self` = the `/spec` skill runs a short self-critique checklist (the spec-critic's list) in the main session before hand-off; `agent` = today's spec-critic agent. |
| S7 | Fewer cold starts (optional, default off) | `BATCH_SMALL=on`: consecutive `Size: S` tasks with no review requirement go to one implementer in one dispatch, still one commit per task; `log` accepts `DONE T002 sha, T003 sha`. Build only if time allows; leave the key documented as experimental. |

**Acceptance (selftest, simulated agents)**
- With `VERIFY=task`, exactly one `VERIFY_CMD` run is logged per task by the script; the reviewer prompt contains no verify step.
- With `VERIFY=every-3` and 5 tasks, verify runs after T003 and before finish only.
- With `REVIEW=risk`, a 20-line task touching only `src/` gets no review; a task touching `package.json` does; a `Risk: high` task does.
- `/approve plan` with valid tasks produces one commit stamping both files; with invalid tasks the plan is approved and tasks stay draft.
- `loop.sh task T002` output includes the AC text and the effective model.

---

## Phase 4 — Loosened rigidity

| # | Change | Detail |
|---|---|---|
| R1 | Approval validity = contract fingerprint | An artifact is **approved** when its frontmatter says so **and** the most recent approval commit for that file (subject contains `: approve ` / `: auto-approve `) recorded a fingerprint equal to the file's **current** contract fingerprint. Later non-contract edits (other commits included) don't invalidate it. Contract sections: spec — `CONTRACT_SECTIONS` (default `Goal\|Non-goals\|Acceptance criteria\|Edge cases\|Constraints`); plan — `Approach\|Alternatives considered\|Design\|AC coverage\|Test strategy`; tasks — done-task blocks byte-identical + the validator passes + `plan` link intact. Store the fingerprint in the approval commit body as well as frontmatter, so forged frontmatter can't validate itself. |
| R2 | Contract edits offered as a change | When any kit command finds an approved artifact whose contract changed, it doesn't error: it prints what changed (AC ids added/modified/removed) and the two ways out — `/change --adopt` (turn the edit into a change request, see phase 5) or `git checkout -- <file>` (revert). |
| R3 | Not-started tasks editable | Reorder, merge, split, retitle, change fields of tasks that aren't done — no re-approval while `AUTO_APPROVE_TASKS=on`; the next `/implement` gate re-validates and proceeds (or says what's invalid). New ids must not reuse done/removed ids. With `AUTO_APPROVE_TASKS=off`, edits need `/approve tasks`. |
| R4 | Minimal required sections | `check_spec` requires only **Goal** and **Acceptance criteria** (non-empty, AC format, unique ids, no `[ASSUMED]`/`[NEEDS CLARIFICATION]`). Other kit sections optional. Unknown sections allowed and preserved. Template override: if `.claude/templates.local/<name>.md` exists, `render` uses it. Same for brief (Change + Acceptance required). |
| R5 | Plan size warns | `PLAN_MAX_LINES` exceeded → warning in `check plan`, never a refusal. |
| R6 | Optional trailers | `TRAILERS=off`: `post_task` takes `base..HEAD` as the task's commits and records them in `.agent-loop/<f>/commits` (`sha task`); `impact`/`report`/reviewer `review-info` read that map. Trailer checks skipped. Document: the task↔commit map then lives only in local state. |
| R7 | `--here` and free branch names | `/spec --here …` and `/quick --here …` use the current branch (refuse on the base branch). Feature resolution: fast path `<kind>/NNN-slug`; otherwise find the feature whose spec/brief frontmatter `branch:` equals the current branch (`new` writes `branch:`). |
| R8 | Hand commits tolerated | Between tasks, any user commits are fine: the next task's base is HEAD; checks only look at the task's own range. Make sure no check fails because a user commit touched `specs/` or `.claude/` outside a task range. |

**Acceptance**
- Fixing a typo in an approved spec's Problem section and committing it leaves the spec approved; `/implement` proceeds.
- Changing AC2 text in an approved spec makes `/implement` stop with "AC2 changed since approval — `/change --adopt` or `git checkout …`", not a generic error.
- Swapping two not-started tasks in tasks.md and running `/implement` works without re-approval; editing a done task's block is refused with the reason.
- A spec with only Goal + ACs approves. A spec with an extra `## Agnosticism check` section approves and keeps it.
- `--here` on `my-branch` creates the feature on `my-branch`; later commands resolve it.
- With `TRAILERS=off` a full run passes and `loop.sh impact AC1` still lists the commits.

---

## Phase 5 — User experience

| # | Change | Detail |
|---|---|---|
| U1 | `/status` | Runs `loop.sh status` (and `--config` → `loop.sh config`). No terminal needed. |
| U2 | `/change <what> [--adopt] [--reconcile]` | Replaces `/amend` (alias kept). The UserPromptExpansion hook decides deterministically: **nothing built yet** for the affected artifact → run `approve.sh reopen <spec\|plan>` (the user's keystroke covers it); Claude then edits the reopened file per the request and asks for `/approve …`. **Something built** → v0.1 change-request flow (impact-analyst, `/approve change`, cascade, frozen done tasks). `--adopt` → the impact-analyst builds the CR from the diff between the last approved version and the working file (the user's hand edit). `--reconcile` → unchanged from v0.1. After merge → refuse with `/spec --supersedes NNN`. |
| U3 | `/fix <bug>` | Not merged → append `T<next> — fix: <bug>` (Size S, `Review` per profile) to tasks.md as a not-started task (allowed by R3) and run it immediately. Merged → start a `/quick` fix on `fix/NNN-slug`. If the bug is really a spec change (the report says the behaviour matches the spec) → say so and suggest `/change`. |
| U4 | Inline BLOCKED | `loop.sh log` on `BLOCKED Tn Qk` returns `ACTION ask Qk`. The orchestrator shows AskUserQuestion with the question and the options from research.md (+ "Other"). On an answer: `loop.sh answer Qk "<text>"` writes it under the question, flips `(open)`→`(answered)`, commits research.md, pops the task's stash (by its `Tn blocked on Qk` message) and returns `ACTION implement Tn`. Unattended (no answer / tool unavailable) → `ACTION stop` as v0.1. |
| U5 | `/answer Qk <text>` | Same as U4's answer step, for when the run has stopped; then resumes with `/resume`. |
| U6 | Inline ESCALATE | `ACTION ask-escalate Tn`: card with the reviewer's question and options — *Change the spec* (→ pause + tell user `/change …`), *I'll fix the code* (→ pause), *Accept as is* (→ `loop.sh accept Tn "<reason>"` marks PASS, logs the accepted risk, continues). |
| U7 | Plain-language errors | Every `die` in `loop.sh`, `approve.sh`, gates and hooks: one line *what happened*, one line *do this:* with the exact command. Remove internal words (fingerprint, chain, art_state) from user-facing text; keep them in debug output. |
| U8 | Wrong-command guidance | Any kit command used at the wrong point says which command fits (e.g. `/implement` with a draft spec → "approve the spec first: `/approve spec`, then `/plan`"). |

**Acceptance**
- `/change` on a feature with an approved spec and no done tasks reopens the spec without an impact-analyst run.
- `/change` with done tasks produces a CR as in v0.1.
- `/change --adopt` after a hand edit of AC2 produces a CR whose Delta is `MODIFIED AC2`.
- `/fix` on an unmerged feature appends a task and runs it; on a merged one creates `fix/NNN-…`.
- Selftest simulates BLOCKED → `answer` → the same task re-dispatched with its stash restored.
- No user-facing message contains "fingerprint", "chain_errors" or "art_state".

---

## Phase 6 — Pause and resume

| Path | Behaviour |
|---|---|
| `/pause` (graceful) | UserPromptExpansion hook runs `loop.sh pause`: writes `.agent-loop/<f>/paused` (`mode=graceful`). `loop.sh next` returns `ACTION pause` → orchestrator runs `loop.sh stop 'paused'`-equivalent that keeps state and releases the run flag. The current agent finishes its task first. |
| `/pause now` | `mode=now`. `guard.sh` denies **every** tool call from kit agents with "agent-loop paused — stop and report", and denies the main session's Agent-tool dispatches. Agents end within one tool call; their uncommitted work stays in the tree. |
| Esc | Native interrupt. The run flag stays; it's treated as paused on the next kit command or plain prompt (phase 1 auto-pause). No `unlock` needed. |
| Terminal | `loop.sh pause [--now]` works at any moment from another terminal (independent of V2). |
| `/resume` (= `/implement` on a paused feature) | Takes over the run (any session), clears `paused`, then handles the state below. |

| State found on resume | Action |
|---|---|
| Paused at a task boundary | `ACTION next` |
| Task `IMPLEMENTED`, not reviewed | Review it if policy requires, else PASS; continue |
| Uncommitted changes from an interrupted task | AskUserQuestion: **Continue** (new implementer: "finish this diff for Tn") / **Discard** (`git stash push -u -m "Tn discarded on resume"`, redo Tn) / **Keep as my change** (leave it, user commits; Tn re-runs from new HEAD) |
| User commits made while paused | Accept; next task's base = HEAD |
| Contract edits while paused | Phase 4 R2 message |

Keep `loop.sh unlock` as a hidden escape hatch; drop it from user docs.

**Acceptance**
- `pause` (graceful) during a simulated run: the current task completes, the next `next` returns `ACTION pause`, the flag is released, `resume` continues at the following task.
- `pause --now`: a simulated kit agent's next tool call is denied with the paused reason; resume offers continue/discard/keep for the dirty tree.
- After Esc (flag left behind), a plain prompt auto-pauses and the main session can edit code.

---

## Phase 7 — Docs and polish

- README rewritten around the v0.2 command set:
  1. Quick start.
  2. Commands (one table).
  3. Profiles and overrides (the tables from phase 2, plus `loop.sh config`).
  4. Every-scenario table (start / spec / plan / build stops / change / fix / pause / ship / housekeeping).
  5. What's enforced and when (the opt-in table).
  6. Honest limits, updated: remove what v0.2 fixed; add whatever V1–V4 turned out to be; keep "spec is the ceiling", the regex-guard caveat, untested platforms, squash-merge caveat.
  7. Requirements and platforms.
- `install.sh` "Next" text updated (profile line, `/status`).
- `loop.conf` shipped with every key, grouped and commented, profile line at the top.
- Selftest count in README matches.

---

## How to test

1. `./selftest.sh` after every phase (simulated agents, no model calls, ~20 s). Add checks for every acceptance line above.
2. After phases 3, 5 and 6, a **real smoke run** in a throwaway repo where the kit's hooks are active:
   ```bash
   T=$(mktemp -d) && cd "$T" && git init -q -b main && npm init -y >/dev/null
   # add a tiny function + jest test, "test": "jest --passWithNoTests"
   ~/code/agent-loop/install.sh . && sed -i.bak 's/^VERIFY_CMD=.*/VERIFY_CMD="npm test"/' .claude/loop.conf
   git add -A && git commit -qm "chore: init"
   claude -p "/quick add a subtract function" --permission-mode acceptEdits   # headless, from the repo root
   ```
   Then drive a full `/spec` → `/plan` → `/approve` → `/implement --profile fast --model T001=haiku` sequence the
   same way (one `claude -p` per user turn, `--resume` to stay in the session). The scratch repo must be trusted
   for hooks to run; remove its trust entry afterwards. Long runs exceed tool timeouts — start them with
   `nohup … &` and poll the log.
3. Check portability-sensitive code with `bash --posix` where practical and `mawk`.

## Deliverables
- 7 commits on `v0.2` (one per phase), selftest green at each.
- README and `loop.conf` updated.
- A short `CHANGELOG.md` entry for v0.2 listing user-visible changes and anything V1–V4 forced to change.
- Do not push; the owner reviews and pushes.
