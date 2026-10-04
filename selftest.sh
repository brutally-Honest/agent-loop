#!/usr/bin/env bash
# selftest.sh — exercise every deterministic part of the kit in a throwaway repo.
# No Claude involved: agents are simulated with plain git commands, hooks are fed the
# same JSON Claude Code sends. Takes ~20s. Exit code 0 = all checks passed.
#
#   ./selftest.sh            (needs bash, git, jq, make)
set -uo pipefail
KIT=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/agent-loop-selftest.XXXXXX")
X=$(mktemp -d "${TMPDIR:-/tmp}/agent-loop-selftest-x.XXXXXX") # scratch outside the test repo
trap 'rm -rf "$X"' EXIT
pass=0 fail=0
ok()   { if "$@" >/dev/null 2>&1; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL (expected success): $*"; fi; }
bad()  { if "$@" >/dev/null 2>&1; then fail=$((fail+1)); echo "FAIL (expected refusal): $*"; else pass=$((pass+1)); fi; }
has()  { if printf '%s' "$2" | grep -q -- "$3"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL $1: expected '$3' in:"; printf '%s\n' "$2" | sed 's/^/    /' | head -8; fi; }
cd "$T" || exit 1
git init -q -b main && git config user.email selftest@example.com && git config user.name selftest && git config commit.gpgsign false
mkdir -p src tests
echo 'add() { echo $(( $1 + $2 )); }' > src/calc.sh
printf '. ./src/calc.sh\n[ "$(add 2 3)" = 5 ] || exit 1\n' > tests/calc_test.sh
printf 'verify:\n\t@for t in tests/*_test.sh; do sh $$t || exit 1; done\n' > Makefile
git add -A && git commit -qm init
inst=$("$KIT/install.sh" .) || { echo "install failed"; exit 1; }

echo "== VERIFY_CMD: no default, never a silent green"
has "install prints the suggestion" "$inst" 'Suggested for this repo: VERIFY_CMD="make verify"'
has "suggest-verify: Makefile verify target" "$(.claude/scripts/loop.sh suggest-verify)" "^make verify$"
bad .claude/scripts/loop.sh doctor
has "doctor names the fix" "$(.claude/scripts/loop.sh doctor)" 'FAIL  VERIFY_CMD is not set'
bad .claude/scripts/loop.sh verify
sv() { # files... -> suggestion from a scratch repo holding those files
	local d; d=$(mktemp -d "$X/sv.XXXXXX"); (cd "$d" && git init -q && for f in "$@"; do case $f in *=*) printf '%s\n' "${f#*=}" > "${f%%=*}" ;; *) : > "$f" ;; esac; done && "$KIT/.claude/scripts/loop.sh" suggest-verify)
}
has "suggest: pnpm scripts in fixed order, npm placeholder test skipped" \
	"$(sv 'package.json={"scripts":{"test":"vitest run","build":"tsc","lint":"eslint ."}}' pnpm-lock.yaml)" '^pnpm run lint && pnpm run build && pnpm run test$'
[ -z "$(sv 'package.json={"scripts":{"test":"echo \"Error: no test specified\" && exit 1"}}')" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL suggest: npm init placeholder test should be ignored"; }
has "suggest: go" "$(sv go.mod=module\ x)" '^go vet ./... && go test ./...$'
has "suggest: node + go monorepo" "$(sv 'package.json={"scripts":{"test":"jest"}}' go.mod)" '^npm run test && go vet ./... && go test ./...$'
has "suggest: python" "$(sv pyproject.toml)" '^pytest -q$'
[ -z "$(sv README.md)" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL suggest: unknown repo should print nothing"; }

sed 's/^VERIFY_CMD=.*/VERIFY_CMD="make -s verify"/' .claude/loop.conf > .claude/loop.conf.new && mv .claude/loop.conf.new .claude/loop.conf
git add .claude .gitignore && git commit -qm "chore: kit"
L=.claude/scripts/loop.sh A=.claude/scripts/approve.sh G=.claude/hooks/guard.sh
stop() { printf '{"agent_type":"%s","agent_id":"%s","cwd":"%s","last_assistant_message":%s}' "$1" "$2" "$T" "$(jq -Rsn --arg m "$3" '$m')" | .claude/hooks/on-agent-stop.sh; }
guard() { # role tool-json  -> decision
	local rj=""; [ "$1" = main ] || rj="\"agent_type\":\"$1\","
	local d
	d=$(printf '{%s"tool_name":"%s","tool_input":%s,"cwd":"%s","session_id":"%s"}' "$rj" "$2" "$3" "$T" "${4:-s0}" | $G | jq -r '.hookSpecificOutput.permissionDecision // "none"' 2>/dev/null)
	echo "${d:-none}"
}
ge() { guard "$1" Edit "{\"file_path\":\"$T/$2\",\"old_string\":$(jq -Rn --arg c "$3" '$c'),\"new_string\":$(jq -Rn --arg c "$4" '$c')}" "${5:-s0}"; }
gr() { guard "$1" Read "{\"file_path\":\"$T/$2\"}" "${3:-s0}"; }
gb() { guard "$1" Bash "{\"command\":$(jq -Rn --arg c "$2" '$c')}" "${3:-s0}"; }
gw() { guard "$1" Write "{\"file_path\":\"$T/$2\",\"content\":$(jq -Rn --arg c "${3:-x}" '$c')}" "${4:-s0}"; }
fill() { python3 - "$@" 2>/dev/null || { echo "python3 is needed by selftest only"; exit 1; }; }
set_section() { # file heading text  (puts text right under "## heading")
	awk -v h="## $2" -v t="$3" '{ print } $0 == h { print t }' "$1" > "$1.n" && mv "$1.n" "$1"
}

echo "== doctor"; ok $L doctor

echo "== /spec: new feature, draft spec, gates"
out=$($L new feat subtract); has new "$out" "BRANCH feat/001-subtract"
F=001-subtract D=specs/$F
bad $L gate plan
bad $A spec
set_section $D/spec.md Problem "Users can add but not subtract."
set_section $D/spec.md Goal "A sub function exists."
set_section $D/spec.md Non-goals "- No multiplication."
set_section $D/spec.md "Acceptance criteria" "- **AC1** — When sub is called with 5 and 3, the system shall print 2.
- **AC2** — When the result is negative, it prints it [ASSUMED]"
set_section $D/spec.md "Edge cases" "- **E1** — 0 - 0 → 0 (AC1)"
out=$($A spec 2>&1); has "approve refuses [ASSUMED] + no shall" "$out" "unresolved marker"
awk '{ sub(/it prints it \[ASSUMED\]/, "the system shall print the negative number"); print }' $D/spec.md > x && mv x $D/spec.md
ok $A spec
has "spec approved" "$($L status)" "spec.md   approved v1"

echo "== guard"
[ "$(gb main ".claude/scripts/approve.sh spec")" = deny ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL guard: main may not run approve.sh"; }
for c in "planner|$D/spec.md|deny" "main|$D/spec.md|none" "Explore|$D/spec.md|none" "implementer|$D/spec.md|deny" "implementer|src/calc.sh|none" "implementer|$D/plan.md|deny" "implementer|.claude/hooks/guard.sh|deny" \
	"implementer|.githooks/pre-commit|deny" "reviewer|src/calc.sh|deny" "tasker|$D/tasks.md|deny" "planner|$D/plan.md|none" "implementer|.agent-loop/commit-msg|none" "implementer|.agent-loop/$F/state|deny"; do
	r=${c%%|*}; rest=${c#*|}; p=${rest%%|*}; e=${rest##*|}
	d=$(gw "$r" "$p"); [ "$d" = "$e" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL guard: $r write $p → $d (expected $e)"; }
done
[ "$(gw planner $D/plan.md $'---\nstatus: approved\n---')" = deny ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL guard: approval fields"; }
while IFS='|' read -r r c e; do
	d=$(gb "$r" "$c"); [ "$d" = "$e" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL guard: $r '$c' → $d (expected $e)"; }
done <<'EOF'
reviewer|git diff HEAD~1..HEAD|allow
reviewer|rm src/calc.sh|deny
reviewer|git status && rm -rf src|deny
reviewer|git diff --output=/tmp/x|deny
implementer|git add src/calc.sh|allow
implementer|git add -A|deny
implementer|git add .|deny
implementer|git commit -F .agent-loop/commit-msg|allow
implementer|git commit -m x|deny
implementer|git commit --no-verify -F .agent-loop/commit-msg|deny
implementer|git push|deny
implementer|git -c a=b push|deny
implementer|make && git push origin main|deny
implementer|git reset --hard HEAD~1|deny
implementer|git checkout -- src/calc.sh|deny
implementer|.claude/scripts/loop.sh log T001 reviewer PASS|deny
implementer|.claude/scripts/loop.sh verify|allow
implementer|go test ./...|none
EOF

echo "== opt-in enforcement: free outside a run, kit agents always constrained"
eq() { [ "$2" = "$3" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL $1: got $2, expected $3"; }; }
eq "main edits the kit outside a run" "$(ge main .claude/scripts/loop.sh 'set -uo pipefail' 'set -euo pipefail')" none
eq "main edits loop.conf outside a run" "$(gw main .claude/loop.conf 'VERIFY_CMD=x')" none
eq "main edits an approved spec's body" "$(ge main $D/spec.md 'Users can add but not subtract.' 'Users can add, not subtract.')" none
eq "main rewrites an approved spec keeping its frontmatter" "$(gw main $D/spec.md "$(cat $D/spec.md)")" none
eq "main edits source outside a run" "$(gw main src/calc.sh)" none
eq "main may not stamp status: approved" "$(ge main $D/plan.md 'status: draft' 'status: approved')" deny
eq "other agents may not stamp sha256" "$(ge general-purpose $D/spec.md 'sha256:' 'sha256: abc')" deny
eq "implementer may not edit the kit" "$(ge implementer .claude/scripts/loop.sh 'a' 'b')" deny
eq "implementer may not edit spec.md" "$(ge implementer $D/spec.md 'Users' 'People')" deny
eq "non-kit agent may edit spec.md outside a run" "$(ge Explore $D/spec.md 'Users' 'People')" none
for r in main implementer reviewer general-purpose; do
	eq "$r may not run approve.sh" "$(gb $r ".claude/scripts/approve.sh spec")" deny
	eq "$r may not run approve.sh (abs path)" "$(gb $r "bash $T/.claude/scripts/approve.sh spec")" deny
done
eq "main may not forge an approval commit" "$(gb main "git commit -m 'docs(x): approve spec v1'")" deny
eq "implementer may not read .env" "$(gr implementer .env)" deny
eq "reviewer may not cat a key" "$(gb reviewer "cat deploy/server.key")" deny
eq "main may read .env (its own permission rules apply)" "$(gr main .env)" none
eq "main runs git freely outside a run" "$(gb main "git commit -am wip")" none

echo "== /plan-feature"
ok $L gate plan
stop planner p1 "PLAN-DRAFTED 0" | grep -q '"block"' && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL planner contract should block an empty plan"; }
fill $D/plan.md <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
for h,t in [("Summary","Add sub()."),("Context","src/calc.sh."),("Approach","Shell arithmetic."),
            ("Alternatives considered","### A1 — arithmetic (chosen)\n- Pros: simple\n- Cons: ints\n### A2 — bc\n- Pros: decimals\n- Cons: dependency"),
            ("Design","sub() in calc.sh"),("AC coverage","| AC1 | calc.sh | sub_test |\n| AC2 | calc.sh | neg_test |"),
            ("Test strategy","sub_test (AC1), neg_test (AC2), zero (E1)"),("Risks","none"),
            ("Open questions","- **Q1** — More than two args? (recommended: no)")]:
    s=s.replace("## "+h+"\n","## "+h+"\n"+t+"\n",1)
open(p,'w').write(s)
PY
out=$(stop planner p2 "PLAN-DRAFTED 1"); [ -z "$out" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL planner contract: $out"; }
out=$($A plan 2>&1); has "plan approval needs decided questions" "$out" "not decided"
awk '{ sub(/\(recommended: no\)/, "(recommended: no) → decided: no"); print }' $D/plan.md > x && mv x $D/plan.md
ok $A plan

echo "== tasks (auto-approved by the tasker's stop hook)"
ok $L gate tasks
fill $D/tasks.md <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
s=s.replace("## Tasks\n","""## Tasks

### T001 — Add sub
- Do: sub() in src/calc.sh
- Tests: sub_basic (AC1), sub_zero (E1)
- AC: AC1
- Commit: feat(calc): add sub
- Depends: —

### T002 — Negative results
- Do: cover negatives
- Tests: sub_negative (AC2)
- AC: AC2
- Commit: test(calc): cover negative results
- Depends: T001
- Manual: run sub 3 5 in a real terminal
""",1)
open(p,'w').write(s)
PY
out=$(stop tasker t1 "TASKS-READY 2"); [ -z "$out" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL tasker stop: $out"; }
has "tasks auto-approved" "$($L status)" "tasks.md  approved v1"
has "auto-approve commit" "$(git log -1 --format=%s)" "auto-approve tasks v1"

echo "== /implement loop"
cp .claude/loop.conf "$X/conf.bak"
sed 's/^VERIFY_CMD=.*/VERIFY_CMD=""/' "$X/conf.bak" > .claude/loop.conf
bad $L gate implement
has "gate names the missing VERIFY_CMD" "$($L gate implement 2>&1)" 'suggested from this repo: VERIFY_CMD="make verify"'
cp "$X/conf.bak" .claude/loop.conf
ok $L gate implement
has start "$($L start --session s1)" "ACTION next"
[ "$(gw main src/calc.sh x s1)" = deny ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL locked orchestrator may not edit code"; }
[ "$(gb main "git commit -am x" s1)" = deny ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL locked orchestrator may not commit"; }
eq "run flag holds the session id" "$(cut -d' ' -f1 .agent-loop/$F/lock)" s1
eq "orchestrator runs loop.sh" "$(gb main ".claude/scripts/loop.sh next" s1)" allow
eq "orchestrator may not write files via bash" "$(gb main "echo x > src/calc.sh" s1)" deny
eq "orchestrator may not edit the kit either" "$(ge main .claude/loop.conf a b s1)" deny
eq "approve.sh denied during a run too" "$(gb main ".claude/scripts/approve.sh spec" s1)" deny
eq "another session is not the orchestrator" "$(gw main src/calc.sh x s9)" none
eq "a non-kit agent is free during a run" "$(gw Explore src/calc.sh x s1)" none
eq "kit agent still constrained during a run" "$(ge implementer $D/spec.md a b s1)" deny
prompt() { printf '{"session_id":"%s","cwd":"%s","prompt":%s}' "$1" "$T" "$(jq -Rn --arg p "$2" '$p')" | .claude/hooks/on-prompt.sh; }
eq "a kit command doesn't pause the run" "$(prompt s1 '/status')" ""
eq "another session's prompt doesn't pause it" "$(prompt s9 'hello')" ""
has "a plain prompt pauses the run" "$(prompt s1 'actually, rename sub to minus')" "build was paused"
bad test -f .agent-loop/$F/lock
eq "after the auto-pause the main session edits code" "$(gw main src/calc.sh x s1)" none
has "paused run: next says pause" "$($L next)" "ACTION pause"
has "restart clears the pause" "$($L start --session s1)" "ACTION next"
has next "$($L next)" "ACTION implement T001"
echo 'sub() { echo $(( $1 - $2 )); }' >> src/calc.sh
printf 'feat(calc): add sub\n' > .agent-loop/commit-msg; git add src/calc.sh && git commit -qF .agent-loop/commit-msg
has "implementer contract: trailers + tests" "$(stop implementer i1 "DONE T001 x")" "lacks the trailer"
printf '. ./src/calc.sh\n[ "$(sub 5 3)" = 2 ] || exit 1\n' > tests/sub_test.sh
printf 'feat(calc): add sub\n\nTask: T001\nFeature: %s\nAC: AC1\n' $F > .agent-loop/commit-msg
git add tests/sub_test.sh && git commit -q --amend -F .agent-loop/commit-msg
out=$(stop implementer i1 "DONE T001 x"); [ -z "$out" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL implementer stop: $out"; }
has "DONE → review" "$($L log T001 implementer "DONE T001 x")" "ACTION review T001"
has "reviewer contract" "$(stop reviewer r1 "Looks good to me")" '"block"'
has "FIX → fix round" "$($L log T001 reviewer FIX)" "ACTION fix T001 review 1/2"
echo '# reviewed' >> src/calc.sh; git add src/calc.sh && git commit -q --amend --no-edit
has "fix DONE → review" "$($L log T001 implementer "DONE T001 x")" "ACTION review T001"
has "PASS → next" "$($L log T001 reviewer PASS)" "ACTION next"
has "PASS twice is refused" "$($L log T001 reviewer PASS)" "ACTION stop contract"
has "next T002" "$($L next)" "ACTION implement T002"
printf '. ./src/calc.sh\n[ "$(sub 3 5)" = -2 ] || exit 1\n' > tests/neg_test.sh
printf 'test(calc): cover negative results\n\nTask: T002\nFeature: %s\nAC: AC2\n' $F > .agent-loop/commit-msg
git add tests/neg_test.sh && git commit -qF .agent-loop/commit-msg
has "NEEDS-HUMAN → next" "$($L log T002 implementer "NEEDS-HUMAN T002 x")" "ACTION next"
has "branch review" "$($L next)" "ACTION review BRANCH"
has "finish" "$($L log BRANCH reviewer PASS)" "ACTION finish"
out=$($L finish); has report "$out" "check by hand: run sub 3 5"; has report "$out" "Branch review: PASS"
bad test -f .agent-loop/$F/lock

echo "== tamper detection (approved file edited and committed outside approve.sh)"
echo "sneaky" >> $D/tasks.md; git commit -qam "chore: tweak"
has tamper "$($L status)" "tampered"
bad $L gate implement
git reset -q --hard HEAD~1

echo "== /amend: change request → reopen → cascade → done tasks frozen → verify red → fix limit"
ok $L gate amend
has cr-new "$($L cr-new)" "CR CR-001"
C=$D/changes/CR-001.md
fill $C <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
s=s.replace("scope:\n","scope: spec\n",1).replace("class:\n","class: scope-change\n",1).replace("<title>","sub rejects text")
for h,t in [("Request","sub must reject non-numbers"),("Why","users pass text"),
            ("Delta","- ADDED AC3 — When sub gets a non-number, the system shall print error.\n- MODIFIED AC1 — When sub is called with 5 and 3, the system shall print 2 and a newline. (was: print 2)"),
            ("Impact","| T001 (AC1) | done | rework | rework task |"),("Recommendation","reopen spec")]:
    s=s.replace("## "+h+"\n","## "+h+"\n"+t+"\n",1)
open(p,'w').write(s)
PY
out=$(stop impact-analyst a1 "CR-DRAFTED CR-001"); [ -z "$out" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL impact-analyst stop: $out"; }
bad $L gate implement
ok $A change
has "spec reopened" "$($L status)" "spec.md   draft v2"
out=$($A spec 2>&1); has "delta must be applied" "$out" "does not apply CR-001"
awk '{ sub(/the system shall print 2\./, "the system shall print 2 and a newline."); print } /\*\*AC2\*\*/ { print "- **AC3** — When sub gets a non-number, the system shall print error." }' $D/spec.md > x && mv x $D/spec.md
out=$($A spec 2>&1); has "cascade" "$out" "REOPENED plan.md v2"
awk '{ print } /^\| AC2 \|/ { print "| AC3 | calc.sh | sub_text |" }' $D/plan.md > x && mv x $D/plan.md
ok $A plan
fill $D/tasks.md <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
s=s.replace("- Do: sub() in src/calc.sh","- Do: sub() in src/calc.sh REWRITTEN")
open(p,'w').write(s)
PY
has "done tasks are frozen" "$($L check tasks)" "T001 is done"
git checkout -q $D/tasks.md
fill $D/tasks.md <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
s=s.replace("\n## Changelog","""
### T003 — Validate input, newline
- Do: validate args
- Tests: sub_text (AC3), sub_newline (AC1)
- AC: AC3, AC1 (rework)
- Commit: feat(calc): validate input
- Depends: T001

## Changelog""",1)
open(p,'w').write(s)
PY
out=$(stop tasker t2 "TASKS-READY 3"); [ -z "$out" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL amend tasker stop: $out"; }
out=$($L status); has "CR applied" "$out" "applied"; has "T003 todo" "$out" "T003  todo"
$L start --session s1 >/dev/null
has "resume at T003" "$($L next)" "ACTION implement T003"
echo 'sub() { echo broken; }' >> src/calc.sh; echo 'echo ok' > tests/text_test.sh
printf 'feat(calc): validate input\n\nTask: T003\nFeature: %s\nAC: AC3, AC1\n' $F > .agent-loop/commit-msg
git add src/calc.sh tests/text_test.sh && git commit -qF .agent-loop/commit-msg
has "verify red → fix" "$($L log T003 implementer "DONE T003 x")" "ACTION fix T003 post-task 1/2"
$L log T003 implementer "DONE T003 x" >/dev/null
has "fix limit" "$($L log T003 implementer "DONE T003 x")" "ACTION stop fix-limit T003"
$L stop "fix-limit" >/dev/null

echo "== /quick + /approve hook"
git checkout -q main
has quick "$($L new fix tiny --quick)" "BRANCH fix/002-tiny"
Q=specs/002-tiny/brief.md
set_section $Q Change "Document zero."
set_section $Q Acceptance "- **AC1** — When sub 0 0 runs, the system shall print 0."
set_section $Q "Out of scope" "- floats"
set_section $Q Approach "tests only"
set_section $Q Steps "- **S1** — add test — Tests: zero_test"
out=$(printf '{"command_name":"approve","command_args":"brief","cwd":"%s"}' "$T" | .claude/hooks/on-command.sh)
has "approve hook" "$out" "APPROVED brief v1"
out=$(printf '{"command_name":"approve","command_args":"","cwd":"%s"}' "$T" | .claude/hooks/on-command.sh)
has "approve hook refuses" "$out" '"block"'
out=$(printf '{"command_name":"plan-feature","command_args":"","cwd":"%s"}' "$T" | .claude/hooks/on-command.sh)
has "gate hook blocks /plan-feature on a quick feature" "$out" '"block"'
has "quick next" "$($L start --session s2 >/dev/null; $L next)" "ACTION implement Q"

cat > "$X/gen.py" <<'PY2'
import sys, os
kind, d, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
def put(path, pairs, fm=""):
    s = open(path).read()
    for h, t in pairs:
        s = s.replace("## " + h + "\n", "## " + h + "\n" + t + "\n", 1)
    if fm:
        s = s.replace("status: draft\n", "status: draft\n" + fm + "\n", 1)
    open(path, "w").write(s)
if kind == "spec":
    acs = "\n".join("- **AC%d** — When step %d runs, the system shall print %d." % (i, i, i) for i in range(1, n + 1))
    put(d + "/spec.md", [("Problem", "p"), ("Goal", "g"), ("Non-goals", "- none"), ("Acceptance criteria", acs),
                         ("Edge cases", "- **E1** — empty → nothing (AC1)")])
elif kind == "plan":
    cov = "\n".join("| AC%d | src | t%d |" % (i, i) for i in range(1, n + 1))
    put(d + "/plan.md", [("Summary", "s"), ("Context", "c"), ("Approach", "a"),
                         ("Alternatives considered", "### A1 — x (chosen)\n- Pros: p\n- Cons: c\n### A2 — y\n- Pros: p\n- Cons: c"),
                         ("Design", "d"), ("AC coverage", cov), ("Test strategy", "t"), ("Risks", "r")], os.environ.get("FM", ""))
elif kind == "tasks":
    b = ""
    for i in range(1, n + 1):
        x = os.environ.get("TX%d" % i, "")
        b += "### T%03d — step %d\n- Do: src/s%d.sh\n- Tests: t%d (AC%d)\n- AC: AC%d\n- Commit: feat(x): step %d\n- Depends: —\n%s\n" % (i, i, i, i, i, i, i, x + "\n" if x else "")
    s = open(d + "/tasks.md").read().replace("## Tasks\n", "## Tasks\n\n" + b, 1)
    open(d + "/tasks.md", "w").write(s)
PY2
mkfeat() { # slug ntasks [plan frontmatter lines] -> an approved feature on its branch; FF DD FN set. TXn = extra lines for task n
	local slug=$1 n=$2
	git checkout -q main
	FF=$($L new feat "$slug" | awk '$1 == "FEATURE" { print $2 }'); DD=specs/$FF; FN=${FF%%-*}
	python3 "$X/gen.py" spec "$DD" "$n" && $A spec >/dev/null || { echo "mkfeat: spec"; return 1; }
	$L gate plan >/dev/null && FM="${3:-}" python3 "$X/gen.py" plan "$DD" "$n" && $A plan >/dev/null || { echo "mkfeat: plan"; return 1; }
	$L gate tasks >/dev/null; python3 "$X/gen.py" tasks "$DD" "$n" && $A tasks >/dev/null || { echo "mkfeat: tasks"; $L check tasks; return 1; }
}
impl() { # id [extra lines] — a simulated implementer: a source file + a test, one commit with the trailers
	local id=$1 k=${2:-1}
	awk -v n="$k" -v id="$id" 'BEGIN { for (i = 1; i <= n; i++) print "echo " id " " i }' > "src/$FN-$id.sh"
	printf 'exit 0\n' > "tests/${FN}_${id}_test.sh"
	printf 'feat(x): %s\n\nTask: %s\nFeature: %s\nAC: AC1\n' "$id" "$id" "$FF" > .agent-loop/commit-msg
	git add "src/$FN-$id.sh" "tests/${FN}_${id}_test.sh" && git commit -qF .agent-loop/commit-msg
}

echo "== overrides: run > task > feature > repo > profile"
TX2="- Model: haiku" mkfeat noreview 2 "review: none" || exit 1
has "task layer" "$($L config T002)" "MODEL=haiku (task)"
has "feature layer" "$($L config)" "REVIEW=none (feature)"
has "profile layer" "$($L config T001)" "MODEL=sonnet (profile:balanced)"
has "repo layer" "$($L config)" "PROFILE=balanced (repo)"
has "bogus flag refused" "$($L start --session s3 --review bogus 2>&1)" "use one of: none branch risk every"
has "bogus model refused" "$($L start --session s3 --model T002=gpt 2>&1)" "haiku sonnet opus"
has "unknown flag refused" "$($L start --session s3 --turbo 2>&1)" "unknown flag"
bad test -f .agent-loop/$FF/lock
has "/implement hook refuses bad flags" "$(printf '{"command_name":"implement","command_args":"--review bogus","cwd":"%s"}' "$T" | .claude/hooks/on-command.sh)" '"block"'
has "start with run flags" "$($L start --session s3 --model T002=opus)" "ACTION next"
has "run layer" "$($L config T002)" "MODEL=opus (run)"
has "ACTION carries the model" "$($L next)" "ACTION implement T001 model=sonnet"
impl T001
out=$($L log T001 implementer "DONE T001 x"); has "review: none → no reviewer" "$out" "passes without a review"; has "→ next" "$out" "ACTION next"
has "run model for T002" "$($L next)" "ACTION implement T002 model=opus"
impl T002
has "T002 no reviewer" "$($L log T002 implementer "DONE T002 x")" "ACTION next"
has "no branch review" "$($L next)" "ACTION finish"
has "report says reviews off" "$($L finish)" "Reviews: off"
bad test -f .agent-loop/$FF/run.conf
has "run flags end with the run" "$($L config T002)" "MODEL=haiku (task)"

echo "== profiles"
git checkout -q main
cp .claude/loop.conf "$X/conf.p"
while IFS='|' read -r prof want; do
	sed "s/^PROFILE=.*/PROFILE=\"$prof\"/" "$X/conf.p" > .claude/loop.conf
	out=$($L config)
	for kv in $want; do has "$prof: $kv" "$out" "^$(printf '%s' "$kv" | tr '~' ' ')"; done
	eq "$prof: nothing but PROFILE comes from the repo" "$(printf '%s\n' "$out" | grep -c '(repo)$')" 1
done <<'EOF'
fast|REVIEW=branch VERIFY=every-3 FIX_ROUNDS=1 MUTATION=off CRITIC=off MODEL_PLANNER=sonnet MODEL_IMPLEMENTER=sonnet MODEL_REVIEWER=sonnet MODEL_BRANCH_REVIEWER=sonnet MODEL_QUICK=sonnet MODEL_IMPACT=sonnet SIZE_MODELS=S=haiku~M=sonnet~L=sonnet AUTO_APPROVE_TASKS=on TRAILERS=on REVIEW_LINES=300 REVIEW_GLOBS= PLAN_MAX_LINES=200
balanced|REVIEW=risk VERIFY=task FIX_ROUNDS=2 MUTATION=risk CRITIC=self MODEL_PLANNER=opus MODEL_IMPLEMENTER=sonnet MODEL_REVIEWER=sonnet MODEL_BRANCH_REVIEWER=opus MODEL_QUICK=sonnet MODEL_IMPACT=sonnet SIZE_MODELS=S=haiku~M=sonnet~L=opus AUTO_APPROVE_TASKS=on TRAILERS=on REVIEW_LINES=150 REVIEW_GLOBS=Makefile~go.mod PLAN_MAX_LINES=200
strict|REVIEW=every VERIFY=task FIX_ROUNDS=2 MUTATION=every CRITIC=agent MODEL_PLANNER=opus MODEL_IMPLEMENTER=sonnet MODEL_REVIEWER=opus MODEL_BRANCH_REVIEWER=opus MODEL_QUICK=sonnet MODEL_IMPACT=sonnet SIZE_MODELS=S=sonnet~M=sonnet~L=opus AUTO_APPROVE_TASKS=off TRAILERS=on PLAN_MAX_LINES=200
EOF
cp "$X/conf.p" .claude/loop.conf
has "an invalid repo setting stops the run, naming where it is" "$(printf 'FIX_ROUNDS=9\n' >> .claude/loop.conf; git checkout -q feat/$FF; $L start --session s4 2>&1)" "FIX_ROUNDS=9 (set in: repo)"
cp "$X/conf.p" .claude/loop.conf

echo "== install.sh upgrade over a v0.1 settings.json"
U=$(mktemp -d "$X/up.XXXXXX"); (cd "$U" && git init -q)
mkdir -p "$U/.claude"
cat > "$U/.claude/settings.json" <<'JSON'
{"permissions":{"allow":["Bash(make *)"],"deny":["Bash(*approve.sh*)","Edit(/.claude/hooks/**)","Edit(/.claude/scripts/**)","Edit(/.claude/settings.json)","Edit(/.claude/loop.conf)","Read(.env)","Read(.env.*)","Read(*.pem)","Read(*.key)","Read(id_rsa*)","Read(id_ed25519*)","Bash(rm -rf *)"]},
 "hooks":{"PreToolUse":[{"matcher":"Bash|Edit|Write|MultiEdit|NotebookEdit","hooks":[{"type":"command","command":"${CLAUDE_PROJECT_DIR}/.claude/hooks/guard.sh","args":[],"timeout":30}]},{"matcher":"Bash","hooks":[{"type":"command","command":"my-own-hook.sh"}]}],
 "UserPromptExpansion":[{"matcher":"approve|plan-feature|implement|amend","hooks":[{"type":"command","command":"${CLAUDE_PROJECT_DIR}/.claude/hooks/on-command.sh","args":[],"timeout":300}]}]}}
JSON
"$KIT/install.sh" "$U" >/dev/null
us=$(cat "$U/.claude/settings.json")
eq "upgrade drops every v0.1 kit deny" "$(jq -c '[.permissions.deny[] | select(startswith("Edit(") or startswith("Read("))] | length' <<<"$us")" 0
eq "upgrade keeps the user's deny" "$(jq -c '.permissions.deny | index("Bash(rm -rf *)") != null' <<<"$us")" true
eq "upgrade keeps the approve.sh deny" "$(jq -c '.permissions.deny | index("Bash(*approve.sh*)") != null' <<<"$us")" true
eq "upgrade keeps the user's hook" "$(jq -c '[.hooks.PreToolUse[].hooks[].command] | index("my-own-hook.sh") != null' <<<"$us")" true
eq "upgrade has one guard entry" "$(jq -c '[.hooks.PreToolUse[].hooks[].command | select(test("guard.sh"))] | length' <<<"$us")" 1
eq "upgrade has one on-command entry" "$(jq -c '[.hooks.UserPromptExpansion[].hooks[].command] | length' <<<"$us")" 1
eq "upgrade adds the prompt hook" "$(jq -c '[.hooks.UserPromptSubmit[].hooks[].command | select(test("on-prompt.sh"))] | length' <<<"$us")" 1
"$KIT/install.sh" "$U" >/dev/null
eq "install is idempotent" "$(cat "$U/.claude/settings.json")" "$us"

echo
if [ "$fail" = 0 ]; then echo "selftest: all $pass checks passed"; cd / && rm -rf "$T"; exit 0; fi
echo "selftest: $pass passed, $fail FAILED — repo kept for inspection at $T"
exit 1
