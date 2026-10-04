# Changelog

## v0.2

### Changed — what you'll notice
- **Opt-in enforcement.** Outside a kit build nothing blocks you, Claude or your own agents: the kit, specs and code are all editable. Kit agents are always constrained; approvals are always yours (Claude can't run `approve.sh`, write approval stamps or commit an `approve` subject). The v0.1 permission denies for kit files and secret reads are gone; `install.sh` removes them on upgrade, and secret-file protection now applies to kit agents only.
- **Profiles and overrides.** `PROFILE=fast|balanced|strict` plus per-key overrides at run (`/implement` flags), task (`Model:`, `Review:`, `Verify:`), feature (`plan.md` frontmatter) and repo (`loop.conf`) level. `loop.sh config [T002]` and `/status --config` show each value and where it came from. `MAX_FIX_ROUNDS` is now `FIX_ROUNDS` (the old name still works).
- **Faster tasks.** The script runs verify once per `VERIFY` policy; implementers run targeted tests only and reviewers never run verify. `REVIEW=risk` (balanced) reviews only risky tasks; the branch review still runs. Fix rounds continue the same implementer. Agents start from a context pack (`loop.sh task <ID>`): the task, the full text of its ACs and edge cases, the plan paragraphs that name them, answered questions, recent commits, its settings.
- **Planner and tasker merged.** `/plan` (was `/plan-feature`, kept as an alias) writes plan.md **and** tasks.md; `/approve plan` approves both in one commit when tasks pass the checks (`AUTO_APPROVE_TASKS=on`). Tasks gain `Size: S|M|L` (picks the model via `SIZE_MODELS`) and `Risk: low|high`.
- **Approvals follow the contract, not the whole file.** Edits outside the contract sections, hand commits, and reordering/splitting not-started tasks keep approvals valid. A contract edit is named ("AC2 changed since you approved spec.md") with `/change --adopt` and the exact `git checkout` to undo it. Specs need only Goal and Acceptance criteria (briefs: Change and Acceptance); your own sections are kept. A long plan is a warning, not a refusal. Trailers are optional (`TRAILERS=off`). `--here` puts a feature on the current branch; any branch name works.
- **Everything from chat.** New `/status`, `/change` (replaces `/amend`, kept as an alias), `/fix`, `/answer`, `/pause`, `/resume`. BLOCKED questions, reviewer ESCALATEs and leftover work after an interruption are question cards; the build stops only when nobody can answer. Errors say what happened and what to type.
- **Pause and resume.** Typing any message pauses a running build (the current task finishes); `pause now` also stops kit agents at their next tool call; Esc works as usual; `loop.sh pause [--now]` from a terminal. `/resume` continues from any session and handles pending reviews, work committed before the pause, and uncommitted work (continue / discard / keep). Commits you make while paused are yours, not the task's.

### Removed
- The **tasker** agent (the planner does its job).
- The v0.1 rule that approved files are frozen for the main session, and "tampered" states: contract fingerprints replace them.
- `loop.sh unlock` from the docs (still there as an escape hatch).

### What the Claude Code checks (V1–V4) changed
Checked on Claude Code 2.1.289.
- **V1 holds** — the Agent tool's `model` overrides a subagent's frontmatter model, so models are chosen per dispatch (no per-model agent copies).
- **V2 does not fully hold** — a slash command typed while a turn runs is processed only after the turn ends, and a whole build is one turn, so `/pause` can't interrupt a running build. A plain message does reach it, at the orchestrator's next tool boundary, so **typing any message is the in-chat pause**; Esc and `loop.sh pause --now` are the immediate paths.
- **V3 holds** — SendMessage continues a finished agent with its context (used for fix rounds, plan revisions and answered questions).
- **V4 holds, with a limit** — agent frontmatter accepts `effort:`, but the Agent tool has no per-dispatch effort, so there are no `EFFORT_*` settings; set it in the agent files if you want it.

### Also found while building it
- `/plan`, `/status` and `/resume` share their names with Claude Code built-ins; the kit's commands win in a repo with the kit, hiding the built-ins there (see README, Honest limits).
- Background agents' completion notices arrive as prompts; the auto-pause hook ignores them.
- `BATCH_SMALL` (one implementer for several small tasks) is reserved but not built.

### Upgrading from v0.1
Re-run `install.sh`. Your `loop.conf` is kept; if it predates profiles you get `loop.conf.v0.2` next to it — keys your old file sets (e.g. `MAX_FIX_ROUNDS`) pin those values whatever the profile. Features approved under v0.1 stay approved (their whole-body hashes are still honoured until the next approval).
