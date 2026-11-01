#!/usr/bin/env bash
# A done task's block is compared with the tasks.md named by "previous:" only while
# tasks.md is a draft (a re-plan). Once an approved change request has changed the done
# task and tasks.md is approved again, the check must not stop the loop.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
mk_repo

F=001-demo
T=specs/$F/tasks.md
git switch -q -c "feat/$F"
mkdir -p "specs/$F"
cat > "$T" <<'EOF'
---
feature: 001-demo
status: approved
version: 1
---
# Tasks — 001-demo

## Tasks

### T001 — Demo task
- Do: add a test
- Tests: TestDemo
- AC: AC1
- Commit: feat(demo): add a demo
- Depends: —
- Size: S
- Risk: low
EOF
git add specs && git commit -q -m "docs($F): add tasks"
prev=$(git rev-parse HEAD)

# the change request reworded the done task; tasks.md v2 names v1 as previous
sed -i.bak 's/^- Do: add a test$/- Do: add a test and a second case/' "$T" && rm -f "$T.bak"
lib() { bash -c '. .claude/scripts/lib.sh; al_init; F='"$F"'; . .claude/scripts/validate.sh; '"$1"; }
lib "fm_set $T previous $prev; fm_set $T version 2; state_set T001 PASS"
git commit -q -am "docs($F): revise tasks for the change"

t "approved tasks.md: a changed done task is not an error"
assert_not_contains "$(lib "check_tasks $T")" "T001 is done" "check_tasks"

t "draft tasks.md (a re-plan): the done task must keep its approved block"
lib "fm_set $T status draft"
assert_contains "$(lib "check_tasks $T")" "T001 is done — keep its block exactly as approved in $prev" "check_tasks"

done_tests
