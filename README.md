# agent-loop

Spec → plan → tasks → build → review for Claude Code, where every gate is a script or a hook rather than a sentence in a prompt the model may or may not follow.

Think of a building contract. You sign the blueprint (**spec**). An architect draws the plans and the work schedule (**plan** + **tasks**). Builders build one room at a time; the site manager (a script) checks each room is really finished; an inspector looks at the risky rooms and at the whole house; nothing is signed except by you. Change your mind about a room nobody has built yet and you just redraw it; change one that's already built and you issue a **change order**.

Works in any git repository and any language. The one repo-specific setting is the command that says "the repo is healthy" (`VERIFY_CMD`, e.g. `npm run lint && npm test` or `go vet ./... && go test ./...`). It has no default: `/al-implement` refuses to start until you set it, and `loop.sh suggest-verify` guesses one from your repo.

**v0.2 in one paragraph:** the kit stays out of your way until you start a build — outside a kit run you (and Claude, and your other agents) can edit anything. A task costs one implementer plus script checks; reviewers look at risky tasks and at the whole branch. Every speed/cost knob is a setting you can override per run, task, feature or repo. Approvals survive edits that don't touch the contract. Everything — status, changes, fixes, answers, pause and resume — is a chat command. See [CHANGELOG.md](CHANGELOG.md).

---

## Quick start

```bash
git clone <this kit> ~/agent-loop-kit
~/agent-loop-kit/install.sh /path/to/your/repo
cd /path/to/your/repo
.claude/scripts/loop.sh suggest-verify       # a guess from package.json / go.mod / Makefile / ...
$EDITOR .claude/loop.conf                    # set VERIFY_CMD (required); PROFILE if not "balanced"
git add .claude .gitignore && git commit -m "chore: add agent-loop kit"
.claude/scripts/loop.sh doctor               # every line should say ok
claude                                       # from the repo root; accept the workspace-trust prompt
```

Then, in Claude Code:

```
/al-spec rate-limit requests per tenant      → branch + interview + spec.md (draft)
/al-approve spec                             → stamped by a hook from your keystroke
/al-plan                                     → plan.md + tasks.md, then its open questions
/al-approve plan                             → approves the plan and the tasks in one go
/al-implement                                → builds task by task until done or your input is needed
```

Small change? `/al-quick fix the off-by-one in pagination` → `/al-approve brief` → it builds.

---

## Commands

Every kit command starts with `al-`, so none of them shadows a Claude Code built-in or a skill of yours.

| You type | What happens |
|---|---|
| `/al-spec <requirement> [--here\|--worktree] [--supersedes NNN]` | Creates `<kind>/NNN-slug` (or uses the current branch with `--here`) and `specs/NNN-slug/`, interviews you, drafts `spec.md`. Run it again on the branch to keep refining the draft. |
| `/al-quick <small change> [--here\|--worktree]` | One `brief.md` (≤5 ACs, ≤5 steps) instead of spec/plan/tasks. `/al-approve brief` builds it right away. |
| `/al-approve [spec\|plan\|tasks\|brief\|change]` | Validates and stamps the artifact — **only from your keystroke** (a hook runs `approve.sh`; Claude can't). `/al-approve plan` also approves a valid tasks.md. No argument = whatever is waiting. |
| `/al-plan` | The planner drafts `plan.md` **and** `tasks.md` (approach, real alternatives, design, AC coverage, test strategy; tasks with size and risk), then asks you its open questions. |
| `/al-implement [flags]` | Builds the approved tasks. Flags apply to this run only — see [Profiles and overrides](#profiles-and-overrides). |
| `/al-status [--config]` | Where the feature stands and the next step; `--config` adds every setting and where it came from. |
| `/al-change [spec\|plan\|tasks] <what> [--adopt] [--reconcile]` | Change approved work. Nothing built yet → the artifact reopens and Claude edits it. Something built → a change request with its impact on done tasks, for you to `/al-approve change`. `--adopt` turns your own edit of the spec into that change request. |
| `/al-fix <bug>` | Unmerged feature → adds `Tnnn — fix: <bug>` to tasks.md and builds it now. Merged (or no feature) → starts a `/al-quick` fix on `fix/NNN-…`. If the "bug" is what the spec asks for, Claude says so and suggests `/al-change`. |
| `/al-answer <Qn> <text>` | Answers the question a build stopped on; the blocked task gets its stashed attempt back. Then `/al-resume`. |
| `/al-pause [now]` | Pauses this session's build: after the current task, or (`now`) with agents stopped at their next tool call. See [Pause and resume](#pause-and-resume). |
| `/al-resume [flags]` | Continues a paused, interrupted or stopped build — from any session. Same as `/al-implement`. |

Questions the build needs from you while you're there (a task BLOCKED on a question, a reviewer's ESCALATE, leftover work after an interruption) come as **question cards** in the chat. The build only stops when nobody can answer.

From a terminal, `.claude/scripts/loop.sh status | config | pause [--now] | report | impact AC2` work at any time.

---

## Profiles and overrides

Every speed/cost knob is a setting. For each task, the first layer that sets it wins:

| # | Layer | Where | Example |
|---|---|---|---|
| 1 | **run** | `/al-implement` flags (this run only) | `/al-implement --review none --model T004=opus` |
| 2 | **task** | fields in the task block | `- Model: haiku`, `- Review: always`, `- Verify: full` |
| 3 | **feature** | `plan.md` frontmatter (`brief.md` for /al-quick), lower-kebab keys | `review: none`, `fix-rounds: 1` |
| 4 | **repo** | `.claude/loop.conf` | `REVIEW="every"` |
| 5 | **profile** | `PROFILE` in any layer above, else `balanced` | `PROFILE="fast"` |
| 6 | kit default | | |

`.claude/scripts/loop.sh config [T002]` (or `/al-status --config`) prints every key's value **and where it came from**, e.g. `MODEL=haiku (task)`, `REVIEW=risk (profile:balanced)`.

| Key | Values | fast | balanced | strict |
|---|---|---|---|---|
| `REVIEW` | `none` `branch` `risk` `every` | `branch` | `risk` | `every` |
| `VERIFY` | `targeted` `task` `every-N` `end` `off` | `every-3` | `task` | `task` |
| `FIX_ROUNDS` | 0–3 | 1 | 2 | 2 |
| `MUTATION` | `off` `risk` `every` | `off` | `risk` | `every` |
| `CRITIC` (spec critique) | `off` `self` `agent` | `off` | `self` | `agent` |
| `MODEL_PLANNER` | `haiku` `sonnet` `opus` | sonnet | opus | opus |
| `MODEL_IMPLEMENTER` | 〃 | sonnet | sonnet | sonnet |
| `MODEL_REVIEWER` (task reviews) | 〃 | sonnet | sonnet | opus |
| `MODEL_BRANCH_REVIEWER` | 〃 | sonnet | opus | opus |
| `MODEL_QUICK` | 〃 | sonnet | sonnet | sonnet |
| `MODEL_IMPACT` | 〃 | sonnet | sonnet | sonnet |
| `SIZE_MODELS` | `S=… M=… L=…` | `S=haiku M=sonnet L=sonnet` | `S=haiku M=sonnet L=opus` | `S=sonnet M=sonnet L=opus` |
| `AUTO_APPROVE_TASKS` | `on` `off` | on | on | off |
| `TRAILERS` | `on` `off` | on | on | on |
| `REVIEW_LINES` (risk trigger) | number | 300 | 150 | — |
| `REVIEW_GLOBS` (risk trigger) | globs | `""` | `WATCHED_GLOBS` | — |
| `PLAN_MAX_LINES` (warning only) | number | 200 | 200 | 200 |

The implementer's model for a task: run `--model T002=…` > the task's `Model:` > `SIZE_MODELS[Size]` (when the task has `Size:`) > `MODEL_IMPLEMENTER`. Every `ACTION implement|review|fix` line carries the resolved `model=…`, and the orchestrator passes it to the Agent tool.

**What the knobs do**
- **`VERIFY`** — the script runs `VERIFY_CMD`, never an agent. `task`: after every task. `every-N`: after every Nth task. `targeted` / `end`: once, before the branch review. `off`: never (the report warns). Whenever the branch isn't proven green before the branch review, it runs then; red sends the last task back for a fix. Implementers only run the tests their task touches; reviewers never run verify.
- **`REVIEW`** — `none`: no reviewer at all (implement + tests + script verify). `branch`: no task reviews, one branch review. `risk`: a task gets a reviewer only if it says `Risk: high` or `Review: always`, changes more than `REVIEW_LINES` lines, touches a watched file (Makefile, lint config, package.json…), deleted a test or added a skip, or touches `REVIEW_GLOBS`. `every`: every task. `Review: skip` on a task skips it under `risk` and `every`. The branch review runs unless `REVIEW=none`; a /al-quick change is reviewed once unless `REVIEW=none`. The reason ("reviewed: changed package.json", "skipped: low risk (20 changed lines…)") goes to the run log and the report.
- **`MUTATION`** — the implementer breaks each guard its tests claim to cover and checks a test fails. `risk`: only for `Risk: high` tasks. The task's context pack says which.
- **`CRITIC`** — `self`: `/al-spec` runs the critic's checklist itself; `agent`: the spec-critic agent; `off`: skipped.
- **`FIX_ROUNDS`** — fix rounds go back to the **same** implementer (it keeps its context); a new one only if it can't be reached.

**Flags:** `/al-implement --profile fast|balanced|strict --review … --verify … --fix-rounds N --mutation … --model T002=haiku,T004=opus,implementer=sonnet,reviewer=opus,branch-reviewer=…`. A wrong flag or value is refused before anything runs, with the valid values. A resumed run keeps its flags unless you give new ones.

---

## Every scenario

| Situation | You do | What happens |
|---|---|---|
| **Start** a feature | `/al-spec <requirement>` | Question card: new branch (default), this branch, or a worktree; kind; name. Then 2-4 rounds of questions, the critic pass (per `CRITIC`), and `spec.md`. Only Goal and Acceptance criteria are required; any other section, yours included, is kept. |
| | `/al-quick <change>` | A brief instead; too big (>5 ACs or steps) → it says use `/al-spec`. |
| **Spec** ready | `/al-approve spec` | Checks (ACs as observable "shall" behaviour, unique ids, no `[ASSUMED]` / `[NEEDS CLARIFICATION]`), stamps, commits. |
| Fix a typo in an approved spec | just edit it (and commit) | Nothing to approve: only the contract sections (Goal, Non-goals, ACs, Edge cases, Constraints — `CONTRACT_SECTIONS`) count. |
| Changed an AC by hand | `/al-change --adopt` (or undo: `git checkout <sha> -- spec.md`) | `/al-implement` and `/al-status` name the change ("AC2 changed since you approved spec.md") and print both ways out. |
| **Plan** | `/al-plan`, answer its questions | plan.md + tasks.md; `/al-approve plan` approves both (tasks too when `AUTO_APPROVE_TASKS=on` and they pass the checks; otherwise they stay a draft and it says what to fix). |
| Reorder / split / retitle tasks not started yet | edit tasks.md | No re-approval (with `AUTO_APPROVE_TASKS=on`); the next `/al-implement` re-checks it. Done tasks are frozen; new ids come after the highest one. With `off`: `/al-approve tasks`. |
| **Build** | `/al-implement [flags]` | Per task: implementer (targeted tests, commit) → script checks + verify per policy → reviewer if policy says → fix rounds → next. Then the branch review and a report. |
| A task needs an answer | answer the card | The implementer recorded `Qn` in research.md and stashed its attempt; your answer is written in and committed, the attempt comes back, the same task continues. Away? `/al-answer Qn <text>`, then `/al-resume`. |
| The reviewer escalates | pick on the card | *Change the spec* (build pauses; `/al-change …`), *I'll fix the code* (build pauses; fix, `/al-resume` — the task is reviewed again), *Accept as is* (the task passes and the accepted risk goes in the report). |
| Fix rounds used up | fix by hand, or drop it | The report shows the attempt and its base; fix it and `/al-resume`, or `git reset --hard <base>`, edit the task, `/al-resume`. |
| **Change** something approved | `/al-change <what>` | Nothing built yet → reopened and edited, then `/al-approve …`. Built → change request (AC delta, impacted done tasks, what reopens) → `/al-approve change` → reopened artifacts are revised; done tasks stay byte-identical and rework becomes new tasks. |
| Code drifted from the spec | `/al-change --reconcile` | The impact-analyst proposes, per divergence, a spec update or remediation tasks. |
| **Bug** | `/al-fix <bug>` | See [Commands](#commands). |
| **Pause** | type anything, Esc, `/al-pause`, or `loop.sh pause` | See below. |
| Your own commits mid-feature | commit as usual | Fine between tasks and while paused: the next task starts from HEAD and checks only its own commits. |
| **Ship** | read the report, open the PR | The loop never pushes, merges or approves. |
| After merge | `/al-spec --supersedes NNN <change>` | Merged specs are history; the new spec records what it replaces (`loop.sh lineage`). |
| Housekeeping | `/al-status`, `loop.sh report`, `loop.sh impact AC2`, `loop.sh doctor` | |

### Pause and resume

| Path | Effect |
|---|---|
| **Type any message** while a build runs | The build pauses (a hook does it): the current task finishes, then the loop stops and Claude does what you asked. `pause now` as the message also stops the agents. Claude Code delivers your message at the orchestrator's next tool boundary — usually when the current agent returns. |
| **Esc** | Claude Code's own interrupt, immediate. The next message or kit command treats the build as paused; nothing to unlock. |
| `/al-pause` / `/al-pause now` | The same as a message, when typed between turns (see [Honest limits](#honest-limits)). |
| `.claude/scripts/loop.sh pause [--now]` | From another terminal, at any moment. `--now`: every kit agent's next tool call is denied with "agent-loop is paused", so they end within one call; their uncommitted work stays. |
| `/al-resume` | Takes the build over (any session) and handles what it finds: a task boundary → next task; a task implemented but not reviewed → reviewed if policy says; a task that committed before the pause → checked as if it had reported DONE; uncommitted work from an interrupted task → a card: **Continue** (an implementer finishes that diff), **Discard** (stashed as `Tn discarded on resume`, the task starts over), **Keep as my change**; your commits while paused → accepted; contract edits while paused → named, as above. |

---

## What is enforced, and when

Enforcement is **opt-in**: nothing constrains the main session unless it is running a kit build. Kit agents are always constrained. Approvals are always yours.

| Rule | When | Mechanism |
|---|---|---|
| Only you approve | always | `approve.sh` runs only from the `/al-approve` (or `/al-change` reopen) **UserPromptExpansion hook** — it fires only for commands you type — or from your terminal. guard.sh and a `Bash(*approve.sh*)` deny rule block it for Claude and every agent; Claude can't write `status: approved` or the approval stamps into `specs/`, nor commit an `approve` subject. |
| An approval means what it says | always | An artifact is approved only if the **latest approval commit** for it recorded a contract fingerprint equal to the file's **current** one. The record is in the commit body, so hand-edited frontmatter can't validate itself. |
| The main session is free | outside a build | You, Claude and your other agents (Explore, general-purpose, your own) can edit code, specs and the kit itself. |
| The orchestrator only orchestrates | during a build, in that session | A run flag (`.agent-loop/<f>/lock` = its session id): guard.sh denies its code edits, git writes and file-writing shell commands; it may call `loop.sh`. Typing a message releases it (the build pauses). |
| Kit agents stay in their lane | always | implementer / quick-builder: code anywhere except `specs/` (bar research.md), `.claude/` and `PROTECTED_GLOBS`; git only in the exact shapes a task commit needs (no push, reset, checkout, rebase, `add -A`, `--no-verify`); commits via `git commit -F .agent-loop/commit-msg`; no full verify (the script owns it). reviewer / spec-critic: read-only, single allow-listed commands. planner: plan.md and tasks.md, only once the spec is approved. impact-analyst: the change request. None of them reads `.env*`, `*.pem`, `*.key`, `id_*`. |
| Agents report in a fixed format | always | The **SubagentStop** hook blocks an agent until line 1 matches its contract and the repo matches the claim (3 tries, then the run stops). |
| "Done" is proven, not claimed | during a build | Post-task checks (commits, trailers, clean tree, no kit/spec/protected changes, tests touched, approvals valid) and `VERIFY_CMD`, run by `loop.sh`. |
| Fix rounds are limited | during a build | `loop.sh` counts them (`FIX_ROUNDS`). |
| History isn't rewritten | always | Done task blocks are compared byte for byte; AC ids are struck, never deleted; merged specs can't be changed. |

---

## Honest limits

- **The spec is the ceiling.** Reviewers judge against the approved spec. A spec that is wrong or silent gets built faithfully; the interview, the critic and ESCALATE reduce that, they don't remove it.
- **The guard reads command text.** A determined process (a script that writes files, or a commit with a hand-made `approve` subject and record) could slip past it. Approval records make tampering *visible* at every gate, not impossible. For OS-level isolation, use Claude Code's sandbox (`/sandbox`). Outside a build the main session is deliberately unguarded.
- **`/al-pause` can't interrupt a running build turn** (checked on 2.1.289: a slash command typed mid-turn runs only after the turn ends, and the whole build is one turn). A *plain* message does reach the build mid-turn — at the orchestrator's next tool boundary, i.e. after the current agent returns. Esc and `loop.sh pause --now` are the immediate paths. A graceful pause releases the run flag at once, so the orchestrator is unguarded while it finishes the current task.
- **Prompts that Claude Code itself generates** (background-agent `<task-notification>`s, command output) also reach the prompt hook, with no field saying so; the hook recognises them by their opening tag. A new kind of generated prompt could pause a build until the hook learns it.
- **Models per dispatch, effort per agent file.** The Agent tool's `model` overrides an agent's frontmatter (checked), so models are per run/task/feature. Reasoning effort can only be set in an agent's frontmatter (`effort: low|medium|high|xhigh|max`, checked), not per dispatch — so there are no `EFFORT_*` settings.
- **`REVIEW=risk` trusts its triggers.** A low-risk task that is subtly wrong is only seen by the branch review (or by nobody with `REVIEW=none`). Mark tasks `Risk: high` generously.
- **`TRAILERS=off`** keeps the task ↔ commit map only in local state (`.agent-loop/<f>/commits`); a fresh clone can't rebuild it.
- **Squash merges** flatten the task commits and their trailers on the base branch; `impact` and per-task history are only on the feature branch (approvals and specs survive in `specs/`).
- **`BATCH_SMALL`** (one implementer for several small tasks) is reserved, not built.
- Tasks run one at a time. Hooks need `jq`, workspace trust and a recent Claude Code; without `jq` the guard denies everything on purpose.

---

## Requirements and platforms

| Need | Why | Without it |
|---|---|---|
| **Claude Code** with `UserPromptExpansion`, `UserPromptSubmit`, `SubagentStop` and `agent_type` in hook input | `/al-approve` and the gate hooks, auto-pause, the agent output contracts, per-agent guard rules | Tested on **2.1.289**. On older versions hooks may silently not fire; `/al-approve` then tells you to use the terminal. |
| **bash** | All scripts | Written for bash 3.2+ (macOS default); tested on bash 5.2 |
| **git** ≥ 2.23 | `git switch`, worktrees, trailers | — |
| **jq** | Every hook parses its JSON input with it | The guard **denies every call** (fails closed on purpose) |
| **sha256sum** or **shasum** | Approval fingerprints | Approvals can't be stamped or checked |
| **POSIX awk, sed, grep** | Parsing specs and tasks | Standard on Linux and macOS |
| Workspace trust | Project allow rules and hooks apply | Prompts for every `loop.sh` call; hooks may be skipped |
| **python3** + **make** | Only `selftest.sh` | The kit itself doesn't need them |

| Platform | Status |
|---|---|
| Linux (Ubuntu, bash 5.2, mawk 1.3.4, GNU coreutils) | **Tested.** `selftest.sh` passes 379/379 checks. Real headless runs in Claude Code 2.1.289 with every agent on haiku: `/al-quick` → `/al-approve brief` → build; `/al-spec` → `/al-approve spec` → `/al-plan` → `/al-approve plan` (one commit for plan + tasks) → `/al-implement --profile fast --model T001=haiku`; `/al-change` on a built feature → change request → `/al-approve change` → spec, plan and tasks revised with the done task untouched → build; a build paused mid-task and `/al-resume`d. |
| macOS (bash 3.2, BSD tools) | **Not tested.** The scripts avoid bash-4 features and GNU-only flags, and pass under mawk. Run `./selftest.sh` once. |
| Windows | Not supported natively. Use WSL. |
| Claude Code desktop / IDE / cloud | **Not tested.** Same hooks and settings; only the CLI was exercised. |
| Agents on sonnet/opus | **Not tested end to end in v0.2** (the real runs used haiku for cost). |

`./selftest.sh` exercises every gate, check and hook in a throwaway repo with simulated agents and no model calls. It takes about a minute and a half and should print `all 379 checks passed`.

`install.sh` is idempotent (re-run it to upgrade). It copies `.claude/{agents,skills,hooks,scripts,templates}`, keeps an existing `loop.conf` (a pre-v0.2 one gets a `loop.conf.v0.2` next to it), **merges** `.claude/settings.json` — your keys and rules stay, the kit's hook entries are replaced rather than duplicated, and the deny rules v0.1 added (edits of the kit, secret reads) are removed — and gitignores `.agent-loop/`, `.claude/worktrees/` and its backup folders. Anything it overwrites goes to `.claude/agent-loop-backup-<timestamp>/`. Your own templates go in `.claude/templates.local/<name>.md`.

---

## Files

```
.claude/
  agents/      planner · implementer · quick-builder · reviewer · impact-analyst · spec-critic
  skills/      al-spec · al-quick · al-approve · al-plan · al-implement (+ LOOP.md) · al-status · al-change
               al-fix · al-answer · al-pause · al-resume
  hooks/       guard.sh (PreToolUse) · on-command.sh (UserPromptExpansion) · on-prompt.sh (UserPromptSubmit)
               on-agent-stop.sh (SubagentStop)
  scripts/     loop.sh (state machine) · approve.sh (yours only) · validate.sh · lib.sh
  templates/   spec · plan · tasks · brief · research · cr      (templates.local/ overrides them)
  loop.conf    your settings
  settings.json
install.sh · selftest.sh · README.md · CHANGELOG.md    (kit root, not copied into your repo)
specs/NNN-slug/        spec.md | brief.md, plan.md, tasks.md, research.md, changes/CR-nnn.md   (committed)
.agent-loop/NNN-slug/  run.log, state, run.conf, verify.log, commits, per-task base/rounds/findings (gitignored)
```

| Agent | Model (per settings) | Writes |
|---|---|---|
| spec-critic | frontmatter (sonnet) | nothing |
| planner | `MODEL_PLANNER` | plan.md, tasks.md, research.md |
| implementer | per task (see above) | code, tests, research.md |
| quick-builder | `MODEL_QUICK` | code, tests, research.md |
| reviewer | `MODEL_REVIEWER` / `MODEL_BRANCH_REVIEWER` | nothing |
| impact-analyst | `MODEL_IMPACT` | changes/CR-nnn.md, research.md |

## `loop.sh` reference

| Command | Use |
|---|---|
| `status [feature]` | Where things stand and the next step |
| `config [TASK]`, `cfg KEY` | Effective settings and their source |
| `pause [--now]` | Pause the build from any terminal |
| `check spec\|plan\|tasks\|brief [--draft]`, `check change [CR-nnn]` | The exact checks approval runs |
| `report` | The last run's report |
| `impact AC2 AC4` | Tasks and commits that implement those ACs |
| `lineage` | supersedes chain |
| `verify`, `test <args>` | Run `VERIFY_CMD` / `TEST_CMD` |
| `doctor`, `suggest-verify` | Setup check; a `VERIFY_CMD` guess |
| `task <ID>` | A task's context pack (what agents start from) |
| `new`, `gate`, `start`, `next`, `log`, `stop`, `finish`, `answer`, `accept`, `dirty`, `add-fix`, `cr-new`, `findings`, `review-info`, `post-check`, `resolve` | Used by the skills, hooks and agents |

## Configuration (`.claude/loop.conf`)

Besides the [profile keys](#profiles-and-overrides):

| Key | Default | Meaning |
|---|---|---|
| `PROFILE` | `balanced` | The defaults for every profile key |
| `VERIFY_CMD` | empty (**required**) | Tests + lint + build; exit 0 = green. Must not modify files. Empty = `/al-implement` refuses, `doctor` fails, `loop.sh verify` is red. |
| `TEST_CMD` | empty | Lets agents run a subset: `loop.sh test ./pkg -run TestX` |
| `BASE_BRANCH` | auto | origin/HEAD, then main, master, trunk, develop |
| `CONTRACT_SECTIONS` | `Goal\|Non-goals\|Acceptance criteria\|Edge cases\|Constraints` | Spec sections an approval covers |
| `QUICK_MAX_ACS` / `QUICK_MAX_STEPS` | 5 / 5 | Size gate for `/al-quick` |
| `PROTECTED_GLOBS` | `.githooks/* .github/workflows/*` | No agent may change these |
| `WATCHED_GLOBS` | Makefile, go.mod, package.json, lint configs… | Allowed, but every change is shown to the reviewer (and triggers a review under `REVIEW=risk`) |
| `TEST_GLOBS` | `*_test.go *.test.* *.spec.* test_*.py tests/* …` | What counts as a test file |
| `READONLY_EXTRA_CMDS` | empty | Extra read-only commands for read-only agents, e.g. `go list\|go vet` |

## Troubleshooting

- **"guard needs jq"**: install jq. The guard fails closed on purpose.
- **`/al-approve` says the hook didn't run**: the folder isn't trusted or hooks are off. Run `.claude/scripts/approve.sh spec` in a terminal, then check `/hooks`.
- **Why was something denied, or why did the build pause?** Start Claude with `AGENT_LOOP_DEBUG=1 claude`; every hook input is appended to `.agent-loop/hook-debug.log`, and `.agent-loop/<f>/run.log` has the build's story.
- **Agents keep asking permission for build commands**: add them to `.claude/settings.local.json` `permissions.allow`, e.g. `"Bash(go test *)"`, `"Bash(npm run *)"`.
- **A crashed session left a build "running"**: type anything in a session, or `/al-resume`; `loop.sh unlock` is the last-resort escape hatch.
- **Rebased the feature branch?** Approvals survive (they're found by commit message and fingerprint). A stopped task restarts from the new HEAD.
