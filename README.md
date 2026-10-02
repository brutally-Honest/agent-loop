# agent-loop

Spec → plan → tasks → build → review for Claude Code, where every gate is a script or a hook rather than a sentence in a prompt the model may or may not follow.

Think of a building contract. You sign the blueprint (**spec**). An architect draws the plans (**plan**) and the work schedule (**tasks**). Builders build one room at a time; an inspector checks each room against the blueprint; nothing is signed except by you. If you change your mind mid-build you don't scribble on the blueprint: you issue a **change order** (a change request), and the schedule is re-cut around the rooms already built.

Works in any git repository and any language. The only repo-specific setting is the command that says "the repo is healthy" (`VERIFY_CMD`, e.g. `make verify`).

---

## Commands

| You type | What happens | Gate |
|---|---|---|
| `/spec <rough requirement>` | Asks **local branch (default) or worktree**, creates `<kind>/NNN-slug` + `specs/NNN-slug/`, interviews you, has a critic look for gaps, drafts `spec.md` (draft). | — |
| `/approve spec` | Validates the spec, stamps it approved, commits it. | **only you** — a hook runs it from your keystroke |
| `/plan-feature` | The **planner** drafts `plan.md` (approach, real alternatives with pros/cons, design, AC coverage, test strategy), then you answer its open questions. | spec approved, or nothing runs |
| `/approve plan` | Stamps the plan, then the **tasker** writes `tasks.md`; a hook validates it and approves it **automatically**. | only you |
| `/implement` | Every task: **implementer** → deterministic post-task checks → **reviewer** → ≤2 fix rounds → next. Then a whole-branch review and a report. | spec + plan + tasks approved |
| `/quick <small change>` | One `brief.md` (≤5 ACs, ≤5 steps) → `/approve brief` → the same build/review loop. | brief approved |
| `/amend <what changed>` | The **impact-analyst** drafts a change request; `/approve change` reopens exactly what it changes. | approved, not yet merged |

Everything else is a status check: `.claude/scripts/loop.sh status` (or `! .claude/scripts/loop.sh status` inside Claude Code) always prints where you are and the next step.

---

## Install

### Requirements and where it runs

| Need | Why | Without it |
|---|---|---|
| **Claude Code** with `UserPromptExpansion`, `SubagentStop` and `agent_type` in hook input | `/approve` and the gate hooks, the agent output contracts, per-agent guard rules | Tested on **2.1.287** only. On older versions the hooks may silently not fire. `/approve` then tells you to use the terminal, and the agent contracts aren't enforced. |
| **bash** | All scripts | Written for bash 3.2+ (macOS default); tested on bash 5.2 |
| **git** ≥ 2.23 | `git switch`, worktrees, trailers | — |
| **jq** | Every hook parses its JSON input with it | The guard **denies every Bash/Edit call** (fails closed on purpose) |
| **sha256sum** or **shasum** | Approval hashes | Approvals can't be stamped or checked |
| **POSIX awk, sed, grep** | Parsing specs and tasks | Standard on Linux and macOS |
| Workspace trust accepted in Claude Code | Project allow rules and hooks apply | Prompts for every `loop.sh` call; hooks may be skipped |
| **make** + **python3** | Only `selftest.sh` uses them | The kit itself doesn't need them |

**Where it has actually been tested — no more than this:**

| Platform | Status |
|---|---|
| Linux (Ubuntu, bash 5.2, mawk 1.3.4, GNU coreutils, git 2.43) | **Tested.** `selftest.sh` passes 90/90 checks, and a full end-to-end run in Claude Code 2.1.287 (spec → plan → tasks → implement → `/amend` → rework → PASS), with all agents on haiku. |
| macOS (bash 3.2, BSD awk/sed/grep) | **Not tested.** The scripts avoid bash-4 features and GNU-only flags, and mawk (a strict POSIX awk) passed, but nobody has run it on a Mac yet. Run `./selftest.sh` once; it needs no model calls and prints any check that fails. |
| Windows | **Not tested, not supported natively.** Use WSL. Git Bash might work. |
| Claude Code desktop app / IDE extensions / cloud sessions | **Not tested.** They use the same hooks and settings, so they should behave the same, but only the CLI was exercised. |
| Agents on sonnet/opus (the defaults in the agent files) | **Not tested end to end.** The real runs used haiku for cost; stronger models should follow the contracts more easily, and the hooks enforce them either way. |

```bash
git clone <this kit> ~/agent-loop-kit        # or unzip it
~/agent-loop-kit/install.sh /path/to/your/repo
cd /path/to/your/repo
$EDITOR .claude/loop.conf                    # set VERIFY_CMD (and TEST_CMD if you like)
git add .claude .gitignore && git commit -m "chore: add agent-loop kit"
.claude/scripts/loop.sh doctor               # every line should say ok
claude                                       # from the repo root; accept the workspace-trust prompt
```

Optional: `~/agent-loop-kit/selftest.sh` exercises every gate, check and hook in a throwaway repo, with simulated agents and no model calls. It takes about 15 seconds, needs `python3` and `make`, and should print `all 90 checks passed`. Run it once on your machine (it's the quickest way to catch a platform difference, e.g. macOS bash 3.2 or BSD tools).

`install.sh` is idempotent (re-run it to upgrade). It copies `.claude/{agents,skills,hooks,scripts,templates}`, keeps an existing `loop.conf`, **merges** `.claude/settings.json` (your keys stay; rules and hooks are added once), and adds `.agent-loop/`, `.claude/worktrees/` and `.claude/agent-loop-backup-*/` to `.gitignore`. Anything it would overwrite, including the old `/run-feature` command and `agent-bash-guard.sh`, goes to `.claude/agent-loop-backup-<timestamp>/`.

Why each step matters:
- **Commit the kit.** Clean-tree checks would otherwise trip on it, and a worktree branched from `main` needs the kit inside it.
- **Accept workspace trust.** Until you do, Claude Code doesn't apply the project's allow rules, and in some setups it skips project hooks.
- **Write an `AGENTS.md` or `CLAUDE.md`.** Optional, but every agent reads it for your conventions and hard rules.

---

## The full flow

```
 you                          agents                          scripts / hooks (deterministic)
 ───                          ──────                          ───────────────────────────────
 /spec "rate-limit per tenant"
   branch or worktree? ──▶                                    loop.sh new → feat/012-rate-limit, specs/012-…/spec.md (draft)
   answer 2-4 rounds ◀── interview, spec-critic finds gaps
 review spec.md
 /approve spec ─────────────────────────────────────────────▶ approve.sh: validate → stamp sha256 → commit
 /plan-feature ─────────────────────────────────────────────▶ gate: spec approved? (no → nothing runs)
                              planner drafts plan.md ───────▶ stop hook: plan checks pass, "PLAN-DRAFTED n"
   answer open questions ◀──
 /approve plan ─────────────────────────────────────────────▶ approve.sh: validate → stamp → commit
                              tasker writes tasks.md ───────▶ stop hook: tasks checks pass → auto-approve → commit
 /implement ────────────────────────────────────────────────▶ gate: all three approved, clean tree, verify green
                              per task:
                              implementer (tests first) ────▶ stop hook + post-task: trailers, scope, tests touched, verify
                              reviewer (fresh, read-only) ──▶ PASS / FIX (≤2 rounds) / ESCALATE
                              …next task…
                              branch review ────────────────▶ report
 read the report, open the PR
```

### 1. `/spec <rough requirement>`
- **Branch first.** Claude asks one question card: *where* (Local branch (Recommended) / Worktree), *kind* (feat/fix/refactor/chore, best guess first) and *name* (slug suggestions). Say "worktree" or pass `--worktree` to skip the location question. `loop.sh new` then creates `<kind>/NNN-slug` from the base branch, plus `specs/NNN-slug/spec.md` and `research.md`. In worktree mode it creates `.claude/worktrees/NNN-slug` and Claude moves into it.
- **Interview.** 2-4 rounds of multiple-choice questions grounded in your code: problem and goal, in/out of scope, behaviour, edge cases, constraints. The spec is yours: anything Claude proposes that you didn't confirm is marked `[ASSUMED]`, and anything unanswered is `[NEEDS CLARIFICATION: …]`. Approval refuses while either remains.
- **Critic.** The `spec-critic` agent hunts for vague or untestable ACs, missing failure cases and contradictions, and you answer what matters.
- Acceptance criteria look like `- **AC1** — When <trigger>, the system shall <observable result>.`

### 2. `/approve spec`
Typed by you, executed by a hook. `approve.sh` refuses if a section is empty, an AC isn't phrased as an observable "shall", an AC id from an earlier version disappeared, or a marker remains. On success it writes `status: approved`, a sha256 of the body and a fingerprint of the contract sections into the frontmatter, then commits `specs/NNN-slug/` as `docs(NNN-slug): approve spec v1`.

### 3. `/plan-feature`
Blocked unless the spec is approved. The planner reads the spec and your code, then fills `plan.md`. The check enforces: ≥2 real alternatives as `### A1 — name`, exactly one `(chosen)`, each with Pros and Cons; every AC in `## AC coverage`; no coverage percentage; ≤200 lines (`PLAN_MAX_LINES`). Unlike the spec, the plan is drafted first and **then** you're asked its open questions, each with a recommended default. Your answers are written in as `→ decided: …`, and approval refuses while any question is undecided.

### 4. `/approve plan` → tasks, automatically
The plan is stamped. Claude then runs the tasker, which writes ordered tasks:

```markdown
### T001 — Add per-tenant limiter
- Do: internal/ratelimit/limiter.go, wire into middleware
- Tests: TestLimiter_AllowsUnderLimit (AC1); TestLimiter_RejectsOverLimit (AC2); TestLimiter_ConcurrentBurst (E3)
- AC: AC1, AC2
- Commit: feat(ratelimit): add per-tenant limiter
- Depends: —
```

When the tasker finishes, a hook validates the file: every task has Do/Tests/AC/Commit; tests name behaviours and edge cases (anything about "coverage" or a percentage is rejected); every AC is covered; commits are conventional; dependencies point backwards. If it passes, the hook approves it (`approved-by: auto`) and commits. You don't touch it. If it fails three times, it stays a draft and `loop.sh check tasks` shows why; fix it and `/approve tasks`.

**tasks.md never changes after approval.** Progress lives in git (`Task: T001` commit trailers) and in `.agent-loop/<feature>/`. `loop.sh status` shows it.

### 5. `/implement`
The main session becomes the orchestrator. It holds a **run lock** for its session id, so a hook stops it from editing code or changing git state; agents do the work. `loop.sh` is the state machine: after each step it prints one `ACTION …` line, and the orchestrator does exactly that.

```
loop.sh next ──▶ ACTION implement T001 ──▶ implementer ──▶ loop.sh log T001 implementer 'DONE T001 a1b2c3'
                                                             │ post-task checks (script, not the agent's word)
                                          ACTION review T001 ◀┘   fail → ACTION fix T001 post-task 1/2
reviewer ──▶ loop.sh log T001 reviewer 'PASS' ──▶ ACTION next      FIX → ACTION fix T001 review 1/2
                                                                   3rd failure → ACTION stop fix-limit
```

- **Implementer** (one task, fresh context): reads `loop.sh task T001`, writes the failing tests first, implements the smallest change, runs a correctness pass (error paths, resource lifetimes, concurrency, tenant identity from the server), runs `verify`, does a **mutation check** (breaks each guard on purpose and confirms a test fails), and commits with the trailers `Task:`, `Feature:` and `AC:`. It can't finish until line 1 says `DONE|BLOCKED|NEEDS-HUMAN` *and* the repo matches the claim.
- **Post-task checks** (`loop.sh`, deterministic): new commits exist and all carry the trailers; the tree is clean; nothing under `.claude/` or `specs/` changed (except `research.md`); no protected file changed; a test file was added or changed if the task names tests; approvals are intact; and `VERIFY_CMD` is green, **run by the script** rather than taken from the agent. Changes to watched files (Makefile, go.mod, lint config…), deleted tests, and new `t.Skip`, `.only` or `nolint` markers are passed to the reviewer as WATCH lines.
- **Reviewer** (fresh, read-only): judges against `spec.md` + `AGENTS.md`, never against plan or tasks. It checks AC → `file:line` → test mapping, correctness, security, scope in both directions and test quality, addresses every WATCH line, runs `verify`, and answers `PASS`, `FIX` (numbered must-fix findings) or `ESCALATE`. Cosmetic issues are notes, never FIX.
- **Kinds:** for a **fix**, the first task carries the failing regression test. For a **refactor**, behaviour and existing tests stay unchanged, and modified tests become WATCH lines. A **chore** has no behaviour change.
- After the last task: a **branch review** against the whole spec, then the report.

### When a run stops

| Stop | What it means | You do |
|---|---|---|
| `BLOCKED T003 Q2` | The spec or plan was silent or contradictory, a protected file or unplanned dependency was needed, or verify stayed red. The implementer added `**Q2** (open)` to `research.md`, committed it, and stashed its attempt (`git stash list`). | Answer Q2 in `research.md` (change `(open)` to `(answered)` and write the answer), then `/implement`. Your edit is committed for you, and the run resumes at T003. |
| `fix-limit T003` | Two fix rounds didn't satisfy the checks or the reviewer. | Read the findings in the report and `.agent-loop/<f>/run.log`. Fix it by hand, or drop it (`git reset --hard <base>` is printed) and `/amend` the task. Then `/implement`. |
| `escalate T003` | The reviewer found something only you can decide: the spec is wrong or silent, a check was weakened, or an AC conflicts with a hard rule. | `/amend` if the spec must change; otherwise fix and `/implement`. |
| `pre-task …` | Verify was red on HEAD, the tree was dirty, approvals no longer matched, or a change request is pending. | Fix what it names, then `/implement`. |
| `contract …` | An agent's output didn't match its contract even after 3 tries, or a step was logged out of order. | `/implement` again; it resumes from the recorded state. |
| `NEEDS-HUMAN` (not a stop) | A task has a `Manual:` check. Its code is committed and the run continues. | Do the check listed in the report. |

The loop never pushes, merges or approves; those are yours.

---

## `/quick` — small change, same discipline

```
/quick fix the off-by-one in pagination        → fix/013-pagination-off-by-one + specs/013-…/brief.md
/approve brief                                 → stamped; the build starts immediately
```
`brief.md` has Change, ≤5 ACs, Out of scope, Approach, and ≤5 steps each naming its tests. `loop.sh check brief` refuses anything bigger ("too big for /quick — use /spec"), so the size gate is code too. The **quick-builder** implements the whole brief; the same post-task checks and the same reviewer apply (one unit `Q`, ≤2 fix rounds, no branch review). It uses a local branch by default; pass `--worktree` for a worktree. Run `/quick` again on that branch to resume after a stop.

---

## When the spec changes midway, or later

What other tools do, from their docs, issue trackers and community threads:

- **GitHub Spec Kit:** either a new spec per change (the first spec acts as the PRD, each later one as a change request), or edit the spec and re-run `/plan` and `/tasks`, which overwrites them. Community extensions add *reconcile* (fold code drift back into the spec and append remediation tasks), *archive* (merge a finished feature's delta into a living project spec), and a *lifecycle* lock (freeze specs after finalization; only refine or bugfix).
- **Kiro:** selective regeneration. Change a task and only tasks regenerate; change the design and design plus tasks rebuild; change scope and everything reruns from requirements. "Sync/Update tasks" maps new requirements to new tasks and marks finished ones. Users reported updates reformatting the task list and overwriting whole requirement files, and asked for the agent to *prompt* for a spec update instead of "fixing" code that no longer matches.
- **BMAD:** a *correct-course* workflow assesses impact (stories to modify, create or cancel; artifact conflicts) and produces a change proposal before re-planning. A reported bug: it rewrote the acceptance criteria of already-completed stories in place, losing the record of what was built.
- **OpenSpec:** every change is a proposal with spec deltas (ADDED/MODIFIED/REMOVED), merged into the main spec when archived.
- **SPECLAN:** approved specs are locked. Changes go through change requests with their own review; on approval the spec is updated in place and the CR archived.

This kit combines those lessons and makes each one a check:

| When | What you do | What happens deterministically |
|---|---|---|
| **Before approval** | Keep talking to `/spec` (or `/quick`), or edit the file. | Nothing to manage: it's a draft. |
| **After approval, before merge** (mid-build or between tasks) | `/amend <what changed>`; review the change request; `/approve change`. | 1. `loop.sh cr-new` scaffolds `specs/<f>/changes/CR-001.md`. 2. The **impact-analyst** fills it: the exact AC **delta** (`ADDED`/`MODIFIED`/`REMOVED`), the done tasks and commits it hits (from the `AC:` trailers via `loop.sh impact`), and the **scope**, meaning the most upstream artifact that must change (spec, plan or tasks). `check change` rejects a delta that references unknown ACs, reuses an id, or omits an impacted done task. 3. While a CR is a draft, `/implement` refuses to run. 4. `/approve change` reopens only that artifact (version +1, `previous:` set to its approval commit, changelog line). 5. Claude applies the delta. Re-approving checks it was applied *exactly*: added ACs present, modified text changed, removed ACs **struck through, never deleted**. 6. **Cascade:** if the spec's contract sections changed, the plan and tasks reopen; if only the problem wording changed, they stay valid. 7. In amend mode the planner changes only what the CR requires. The tasker must copy every **done** task byte for byte (compared with the previous approved version), add rework tasks (`AC: AC2 (rework)`) or removal tasks (`AC: AC4 (remove)`), and number new tasks after the old ones. 8. `/implement` resumes at the first open task. |
| **Code drifted from the spec** (hand edits, a hotfix) | `/amend --reconcile` | The impact-analyst compares the code with every AC and proposes, per divergence, either a spec update (code is right) or remediation tasks (spec is right). You decide with `/approve change`. |
| **After merge** | `/spec --supersedes 012 <the change>` | Merged specs are history and stay untouched: `/amend` refuses once `specs/012-…` exists on the base branch. The new spec records `supersedes: 012-…`, and its ACs say which old ACs they replace. `loop.sh lineage` prints the chain. |
| **Manual escape hatch** | `.claude/scripts/approve.sh reopen spec --reason "…"` (terminal) | Reopens and commits, with the reason in the changelog. Use it when you edited an approved file by hand and want to keep that edit. |

**Other agents you could add later** (not included, each with a clear trigger):

| Agent | Run it | What it does |
|---|---|---|
| drift-detector | nightly, or after merges to main (as a scheduled task) | For every merged spec, checks each AC still has a passing test and the code path still exists; opens a reconcile CR when not. |
| archivist / living-spec keeper | after a merge | Folds the feature's ACs into one current system spec under `docs/` (what Spec Kit's *archive* and OpenSpec's *archive* do), so "what does the system do now" doesn't require reading a chain of specs. |
| retrospective | after a merge | Compares spec v1 with what shipped (CRs, fix rounds, ESCALATEs, blocked questions) and records lessons for the next spec. |
| consistency analyzer | before approving the plan | A semantic spec↔plan↔tasks cross-check (Spec Kit's `/analyze`). The scripts already do the structural part. |
| security reviewer | in the branch review, for auth/tenant/payment features | A second read-only reviewer focused only on auth, tenancy, injection and secrets. |

---

## What is enforced, and how

| Rule | Mechanism |
|---|---|
| Only you approve | `approve.sh` runs only from the `/approve` **UserPromptExpansion hook** (it fires only for commands you type) or from your terminal. guard.sh and a permission deny rule block it for Claude, and the skills set `disable-model-invocation`. |
| Approved files are frozen | guard.sh denies edits. Independently, "approved" is only trusted if the body's sha256 matches **and** the last commit touching the file is an approval commit. Any change by any route shows up as `tampered:…`, and every gate stops. |
| Agents stop at their gate | `/plan-feature`, `/implement` and `/amend` are blocked by a hook gate before Claude sees them, and checked again by the skill's own `!` gate. guard.sh denies the planner writing `plan.md` without an approved spec, and the tasker writing `tasks.md` without an approved plan. |
| Agents report in a fixed format | The **SubagentStop** hook blocks an agent from finishing until line 1 matches its contract and the repo matches the claim. After 3 blocked attempts it lets the agent go, logs the failure, and `loop.sh` stops the run on the next step. |
| "Done" is proven, not claimed | post-task checks plus `VERIFY_CMD` run by `loop.sh`. |
| Fix rounds are limited | `loop.sh` counts them (`MAX_FIX_ROUNDS`) and stops at the third failure. |
| The orchestrator doesn't code | A session-scoped run lock; guard.sh denies its edits and git writes while the lock is held. |
| The reviewer can't change anything | guard.sh allows it no edits and only single, allow-listed read commands (no `;`, `|`, `>`, `$(…)`, `-exec`, `--output`). |
| Implementers can't cut corners | guard.sh blocks push, reset, checkout, rebase, merge, tag, `git add -A`/`.`, `--no-verify`, edits to `.claude/` and `PROTECTED_GLOBS`, and `rm -rf` of the repo. Commits must use `git commit -F .agent-loop/commit-msg`. |
| Secrets stay unread | Permission deny rules for `.env*`, `*.pem`, `*.key`, `id_*`. |
| History is never rewritten | Done tasks are byte-compared on amend; AC ids are never deleted; merged specs can't be amended. |

**How it was tested.** The scripts ran under bash 5.2 with mawk, a strict POSIX awk, and are written for bash 3.2 and BSD tools, but **macOS itself is untested**: run `selftest.sh`. The whole flow also ran for real in Claude Code 2.1.287 with all agents forced to haiku: `/approve` refusing and approving through the hook; `/plan-feature` blocked by its gate; a real planner, then a real tasker whose tasks were auto-approved; `/implement` with a real implementer, reviewer and branch review; then `/amend` → `/approve change` → `/approve spec` (plan and tasks reopened) → amend-mode plan and tasks (T001 kept byte-identical, rework task T002 added) → `/implement` to PASS. In those runs the stop hook sent back chatty final messages from the planner, implementer and reviewer until line 1 met its contract, and the guard turned a chained `git add && git commit -m "$(…)"` into the allowed `-F` form.

**Honest limits.** The guard reads command text, so a determined process (say, a Python script that writes files) could slip past it. That's why approvals are also proven by hash and git history at every gate: tampering can't be hidden, only detected. For OS-level isolation, turn on Claude Code's sandbox (`/sandbox`). Hooks need `jq`, workspace trust and a recent Claude Code; without `jq` the guard denies everything on purpose (fail closed). Tasks run one at a time.

---

## Files

```
.claude/
  agents/      spec-critic · planner · tasker · implementer · quick-builder · reviewer · impact-analyst
  skills/      spec · plan-feature · approve · implement (+ LOOP.md, the orchestrator procedure) · quick · amend
  hooks/       guard.sh (PreToolUse) · on-command.sh (UserPromptExpansion) · on-agent-stop.sh (SubagentStop)
  scripts/     loop.sh (state machine) · approve.sh (human-only) · validate.sh · lib.sh
  templates/   spec · plan · tasks · brief · research · cr
  loop.conf    your settings
  settings.json
install.sh · selftest.sh · README.md       (kit root, not copied into your repo)
specs/NNN-slug/        spec.md | brief.md, plan.md, tasks.md, research.md, changes/CR-nnn.md   (committed)
.agent-loop/NNN-slug/  run.log, state, verify.log, per-task base/rounds/findings              (gitignored)
```

| Agent | Model | Tools | Writes |
|---|---|---|---|
| spec-critic | sonnet | Read, Grep, Glob | nothing |
| planner | opus | + Bash (read-only), Write, Edit | plan.md, research.md |
| tasker | sonnet | same | tasks.md, research.md |
| implementer | inherit | Read, Edit, Write, Bash, Grep, Glob | code, tests, research.md |
| quick-builder | sonnet | same | code, tests, research.md |
| reviewer | opus | Read, Grep, Glob, Bash (read-only) | nothing |
| impact-analyst | opus | + Bash (read-only), Write, Edit | changes/CR-nnn.md, research.md |

## `loop.sh` reference

| Command | Use |
|---|---|
| `status [feature]` | Where things stand and the next step |
| `check spec\|plan\|tasks\|brief [--draft]`, `check change [CR-nnn]` | The exact checks approval runs |
| `report` | The last run's report |
| `impact AC2 AC4` | Tasks and commits that implement those ACs |
| `lineage` | supersedes chain |
| `verify`, `test <args>` | Run `VERIFY_CMD` / `TEST_CMD` |
| `doctor` | Setup check |
| `unlock` | Release a run lock left by a crashed session |
| `new`, `gate`, `start`, `next`, `log`, `stop`, `finish`, `task`, `review-info`, `findings`, `post-check`, `cr-new`, `resolve` | Used by the skills and agents |

## Configuration (`.claude/loop.conf`)

| Key | Default | Meaning |
|---|---|---|
| `VERIFY_CMD` | `make verify` | Tests + lint + build. Must not modify files. |
| `TEST_CMD` | empty | Lets agents run a subset: `loop.sh test ./pkg -run TestX` |
| `BASE_BRANCH` | auto | origin/HEAD, then main, master, trunk, develop |
| `MAX_FIX_ROUNDS` | 2 | Per task |
| `PLAN_MAX_LINES` | 200 | "Not verbose", made concrete |
| `QUICK_MAX_ACS` / `QUICK_MAX_STEPS` | 5 / 5 | Size gate for `/quick` |
| `PROTECTED_GLOBS` | `.githooks/* .github/workflows/*` | No agent may change these |
| `WATCHED_GLOBS` | Makefile, go.mod, package.json, lint configs… | Allowed, but every change is shown to the reviewer |
| `TEST_GLOBS` | `*_test.go *.test.* *.spec.* test_*.py tests/* …` | What counts as a test file |
| `READONLY_EXTRA_CMDS` | empty | Extra read-only commands for the read-only agents, e.g. `go list\|go vet` |

## Troubleshooting

- **"guard needs jq"**: install jq. The guard fails closed on purpose.
- **`/approve` says "no approve.sh output"**: the hook didn't run (folder not trusted, or hooks disabled). Run `.claude/scripts/approve.sh spec` in a terminal, then check `/hooks`.
- **Why was something denied?** Start Claude with `AGENT_LOOP_DEBUG=1 claude`; every hook input is appended to `.agent-loop/hook-debug.log`.
- **Claude asks before editing spec.md / brief.md** (e.g. when applying a change request): that's your normal edit permission. Approve it, or run with `acceptEdits`. The agents set their own `permissionMode`.
- **Agents keep asking permission for build commands**: add them to `.claude/settings.local.json` `permissions.allow`, e.g. `"Bash(go test *)"`, `"Bash(npm run *)"`.
- **A run lock blocks your normal edits** (a crashed `/implement`): `.claude/scripts/loop.sh unlock`.
- **Rebased the feature branch?** Approvals survive (they're matched by commit message and hash). A stopped task restarts from the new HEAD.

## Coming from `/run-feature`

`install.sh` moves `run-feature.md`, `agent-bash-guard.sh` and your old `implementer.md`/`reviewer.md` into the backup folder. What carried over: approvals the agents can't fake, a reviewer that judges only against the spec, ≤2 fix rounds, BLOCKED questions in `research.md` with a stashed attempt, NEEDS-HUMAN, a run log, and a branch review. What's new: the hash-locked approvals, hook-enforced output contracts, script-run verify, mutation checks, the correctness and security review, `/quick`, and change requests. Finish features already in flight with the old command from the backup folder, or start them again with `/spec`. The old `tasks.md` format doesn't pass the new checks.
