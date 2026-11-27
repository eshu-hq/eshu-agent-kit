#!/usr/bin/env bash
# Offline behavioral suite for trigger precision/recall evals (issue #117):
# name+description-only catalog, zero body leak, confusion math, rubric,
# PATH-stubbed claude/agy/muse routers, validation, starter suite, /debrief join.
# Hermetic: nothing here calls a real model or the network.
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPLAY="${KIT_DIR}/scripts/replay-eval.sh"
DEBRIEF="${KIT_DIR}/scripts/debrief.sh"
LIB="${KIT_DIR}/scripts/lib"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
export XDG_DATA_HOME="${work}/xdg" HOME="${work}/home" TMPDIR="${work}/tmp" PYTHONDONTWRITEBYTECODE=1
mkdir -p "${XDG_DATA_HOME}" "${HOME}" "${TMPDIR}" "${work}/bin" "${work}/log" "${work}/cache"

passed=0
failed=0
ok() {
	printf 'ok - %s\n' "$1"
	passed=$((passed + 1))
}
no() {
	printf 'not ok - %s\n' "$1"
	failed=$((failed + 1))
}

rc=0
run() { # run trigger with args; stdout/stderr land in ${work}/out and ${work}/err
	bash "${REPLAY}" trigger "$@" >"${work}/out" 2>"${work}/err"
	rc=$?
	if rg -q 'unknown subcommand' "${work}/err"; then rc=99; fi
}
runs() { # runs "desc" WANT ARGS... : run, then assert the exit code
	local desc="$1" want="$2"
	shift 2
	run "$@"
	rc_is "${desc}" "${want}"
}
rc_is() { # rc_is "desc" WANT
	if [ "${rc}" -eq "$2" ]; then ok "$1"; else no "$1 (rc=${rc}, want $2: $(tail -c 200 "${work}/err"))"; fi
}
check() { # check "desc" ARGV... ; python assertions on stdin, with d = json of ARGV[1]
	local desc="$1" code
	shift
	code="import json,sys
try:
    d = json.load(open(sys.argv[1]))
except ValueError:
    d = None
$(cat)"
	if python3 -c "${code}" "$@" 2>"${work}/pyerr"; then ok "${desc}"; else no "${desc}: $(tail -n 3 "${work}/pyerr")"; fi
}
mksuite() { printf '%s\n' "$2" >"${work}/$1.json"; }

# --- Fixture catalog: plain, double-quoted, and block-scalar descriptions ---
mkskill() { # mkskill ROOT NAME DESCRIPTION-LINES
	mkdir -p "$1/$2"
	printf -- '---\nname: %s\n%s\n---\n\n# %s\n\nBODY-SENTINEL-117 stays in the body.\n' "$2" "$3" "$2" >"$1/$2/SKILL.md"
}
CAT="${work}/cat"
mkskill "${CAT}" code-review 'description: Use when reviewing a diff before merge, with severity findings and merge readiness.'
mkskill "${CAT}" queue-tuning 'description: "Use when tuning the \"worker\" queue: leases, retries, and backlog throughput."'
mkskill "${CAT}" graph-truth 'description: >
  Use when graph edges
  need proof of truth from evidence.'
LAY1="${work}/lay1"
LAY2="${work}/lay2"
mkskill "${LAY1}/eshu" code-review 'description: First copy of the review skill.'
mkskill "${LAY1}/eshu" graph-truth 'description: Layered graph skill.'
mkskill "${LAY2}" code-review 'description: Second copy wins.'
mkdir -p "${work}/emptycat"

# 1. Catalog loads name + description for all three shapes; flat and layered; later wins.
python3 - "${LIB}" "${CAT}" "${LAY1}" "${LAY2}" <<'PYEOF' && ok "catalog loads plain, quoted, block-scalar descriptions; flat and layered; later dir wins" || no "catalog loader shapes and precedence"
import sys
sys.path.insert(0, sys.argv[1])
import replay_trigger as t
cat = t.load_catalog([sys.argv[2]])
assert sorted(cat) == ["code-review", "graph-truth", "queue-tuning"], sorted(cat)
assert cat["code-review"]["description"].startswith("Use when reviewing a diff before merge"), cat["code-review"]
assert cat["queue-tuning"]["description"] == 'Use when tuning the "worker" queue: leases, retries, and backlog throughput.', cat["queue-tuning"]
assert cat["graph-truth"]["description"] == "Use when graph edges need proof of truth from evidence.", cat["graph-truth"]
assert all(set(v) >= {"name", "description"} for v in cat.values())
assert not any("BODY-SENTINEL" in str(v) for v in cat.values())
layered = t.load_catalog([sys.argv[3]])
assert sorted(layered) == ["code-review", "graph-truth"], sorted(layered)
merged = t.load_catalog([sys.argv[3], sys.argv[4]])
assert merged["code-review"]["description"] == "Second copy wins.", merged["code-review"]
assert merged["graph-truth"]["description"] == "Layered graph skill."
PYEOF

# 2. Zero body leak: decider-cmd stdin and a stubbed claude stdin/argv never see the body.
cat >"${work}/decider.py" <<'PYEOF'
#!/usr/bin/env python3
import json, os, sys
raw = sys.stdin.read()
with open(os.environ["STUB_LOG"], "a") as fh:
    fh.write(raw + "\n")
payload = json.loads(raw)
for key, val in json.load(open(os.environ["STUB_MAP"])).items():
    if key in payload["prompt"]:
        if val == "__EXIT1__":
            sys.exit(1)
        print(json.dumps({"skills": val}))
        sys.exit(0)
print(json.dumps({"skills": []}))
PYEOF
chmod +x "${work}/decider.py"
cat >"${work}/fake_harness.py" <<'PYEOF'
#!/usr/bin/env python3
import json, os, sys, time
harness, args = sys.argv[1], sys.argv[2:]
stdin = sys.stdin.read() if harness == "claude" else ""
prompt = stdin
if harness == "agy":
    prompt = next(a[3:] for a in args if a.startswith("-p="))
elif harness == "muse":
    prompt = open(args[args.index("--prompt-file") + 1]).read()
for name, text in (("stdin", stdin), ("argv", json.dumps(args)), ("prompt", prompt),
                   ("cwd", os.getcwd()), ("ls", json.dumps(sorted(os.listdir("."))))):
    with open(os.path.join(os.environ["STUB_LOG_DIR"], harness + "." + name), "a") as fh:
        fh.write(text + "\n")
reply = '{"skills": []}'
for key, val in json.load(open(os.environ["STUB_MAP"])).items():
    if key in prompt:
        if val == "__EXIT1__":
            sys.stderr.write("boom\n")
            sys.exit(1)
        if val == "__SLEEP__":
            time.sleep(5)
            sys.exit(0)
        if val == "__GARBAGE__":
            reply = "I would pick code-review."
        elif val == "__FENCED__":
            reply = '```json\n{"skills": ["code-review"]}\n```'
        else:
            reply = json.dumps({"skills": val})
        break
if harness == "claude":
    print(json.dumps({"type": "result", "result": reply, "is_error": False, "usage": {}}))
elif harness == "agy":
    print(json.dumps({"status": "SUCCESS", "response": reply}))
else:
    print(json.dumps({"payload_type": "run.terminal.completed", "payload": {"text": reply, "terminal": "completed"}}))
PYEOF
for h in claude agy muse; do
	printf '#!/usr/bin/env bash\nexec python3 "%s/fake_harness.py" %s "$@"\n' "${work}" "${h}" >"${work}/bin/${h}"
	chmod +x "${work}/bin/${h}"
done
export STUB_LOG="${work}/log/decider.log" STUB_LOG_DIR="${work}/log" STUB_MAP="${work}/map.json"

mksuite math '{"version":1,"cases":[
{"id":"m1","kind":"positive","prompt":"m1 review the diff","expect":["code-review"]},{"id":"m2","kind":"positive","prompt":"m2 review another diff","expect":["code-review"]},
{"id":"m3","kind":"negative","prompt":"m3 rename a variable","expect":[],"reject":["code-review"]},{"id":"m4","kind":"negative","prompt":"m4 write a poem","expect":[],"reject":["code-review","queue-tuning"]},
{"id":"m5","kind":"competing","prompt":"m5 retry storm in the queue","expect":["queue-tuning"],"reject":["code-review"]},
{"id":"m6","kind":"competing","prompt":"m6 tune leases","expect":["queue-tuning"],"reject":["code-review"]}]}'
printf '%s\n' '{"m1":["code-review"],"m2":[],"m3":["code-review"],"m4":["graph-truth"],"m5":["code-review"],"m6":["queue-tuning"]}' >"${work}/map.json"
runs "decider-cmd run over the math suite exits 0" 0 --suite "${work}/math.json" --skills-dir "${CAT}" --decider-cmd "${work}/decider.py" --json-out "${work}/math.out.json"
[ -s "${work}/log/decider.log" ] && ! rg -q 'BODY-SENTINEL-117' "${work}/log/decider.log" "${work}/math.out.json" "${work}/out" &&
	ok "decider-cmd stdin and outputs never contain the SKILL.md body" || no "decider-cmd stdin and outputs never contain the SKILL.md body"
check "payload is {prompt, skills:[{name,description}]} sorted by name" "${work}/log/decider.log" <<'PYEOF'
first = json.loads(open(sys.argv[1]).readline())
assert set(first) == {"prompt", "skills"}, set(first)
names = [s["name"] for s in first["skills"]]
assert names == ["code-review", "graph-truth", "queue-tuning"], names
assert all(set(s) == {"name", "description"} for s in first["skills"])
PYEOF

# 3. Math: exact TP/FP/FN/TN, precision/recall/F1 to 4 decimals.
check "confusion counts and metrics are exact" "${work}/math.out.json" <<'PYEOF'
assert d["kind"] == "trigger-eval" and d["version"] == 1 and d["decider"] == "cmd" and d["mode"] == "custom"
assert d["cases"] == 6 and d["trials"] == 6 and d["errors"] == 0, d
ps = {r["skill"]: r for r in d["per_skill"]}
a, b, c = ps["code-review"], ps["queue-tuning"], ps["graph-truth"]
assert (a["tp"], a["fp"], a["fn"], a["tn"]) == (1, 2, 1, 2), a
assert (a["precision"], a["recall"], a["f1"]) == (0.3333, 0.5, 0.4), a
assert (a["trigger_rate"], a["false_trigger_rate"]) == (0.5, 0.5), a
assert (a["positives"], a["negatives"]) == (2, 4), a
assert (b["tp"], b["fp"], b["fn"], b["tn"]) == (1, 0, 1, 1), b
assert (b["precision"], b["recall"], b["f1"]) == (1.0, 0.5, 0.6667), b
assert (b["trigger_rate"], b["false_trigger_rate"]) == (0.3333, 0.0), b
o = d["overall"]
assert (o["tp"], o["fp"], o["fn"], o["tn"]) == (2, 2, 2, 3), o
assert (o["precision"], o["recall"], o["f1"], o["macro_f1"]) == (0.5, 0.5, 0.5, 0.5333), o
assert len(a["description_sha"]) == 12
fps = sorted((x["case_id"], x["skill"]) for x in d["false_positives"])
assert fps == [("m3", "code-review"), ("m5", "code-review")], fps
fns = sorted((x["case_id"], x["skill"]) for x in d["false_negatives"])
assert fns == [("m2", "code-review"), ("m5", "queue-tuning")], fns
assert all(x["repeat"] == 1 for x in d["false_positives"])
# a skill only ever selected on unlabelled cases: counted apart, never FP, all metrics null
assert (c["unlabeled_triggers"], c["tp"], c["fp"], c["fn"], c["tn"]) == (1, 0, 0, 0, 0), c
assert all(c[k] is None for k in ("precision", "recall", "f1", "trigger_rate", "false_trigger_rate")), c
PYEOF

# 4. Zero denominators: null where undefined, 0.0 where the skill never fires on positives.
mksuite zero '{"version":1,"cases":[
{"id":"z1","kind":"positive","prompt":"z1 review","expect":["code-review"]},{"id":"z2","kind":"negative","prompt":"z2 nothing","expect":[],"reject":["queue-tuning"]},
{"id":"z3","kind":"negative","prompt":"z3 graph","expect":[],"reject":["graph-truth"]}]}'
printf '%s\n' '{"z3":["graph-truth"]}' >"${work}/map.json"
runs "zero-denominator suite exits 0" 0 --suite "${work}/zero.json" --skills-dir "${CAT}" --decider-cmd "${work}/decider.py" --json-out "${work}/zero.out.json"
check "never-selected skill: precision null, recall 0.0, F1 0.0; negatives-only: recall null" "${work}/zero.out.json" <<'PYEOF'
ps = {r["skill"]: r for r in d["per_skill"]}
a, b, c = ps["code-review"], ps["queue-tuning"], ps["graph-truth"]
assert (a["precision"], a["recall"], a["f1"]) == (None, 0.0, 0.0), a
assert (a["trigger_rate"], a["false_trigger_rate"]) == (0.0, None), a
assert (b["precision"], b["recall"], b["f1"]) == (None, None, None), b
assert (c["precision"], c["recall"], c["f1"]) == (0.0, None, 0.0), c
assert (c["trigger_rate"], c["false_trigger_rate"]) == (1.0, 1.0), c
PYEOF

# 5. reject:["*"] expansion, unknown names uncounted.
mksuite star '{"version":1,"cases":[
{"id":"w1","kind":"negative","prompt":"w1 chat","expect":[],"reject":["*"]},
{"id":"w2","kind":"competing","prompt":"w2 review","expect":["code-review"],"reject":["*"]}]}'
printf '%s\n' '{"w1":["queue-tuning"],"w2":["code-review","graph-truth","ghost-skill"]}' >"${work}/map.json"
runs "reject:[*] suite exits 0" 0 --suite "${work}/star.json" --skills-dir "${CAT}" --decider-cmd "${work}/decider.py" --json-out "${work}/star.out.json"
check "reject:[*] covers every catalog skill outside expect; unknown names are listed, not counted" "${work}/star.out.json" <<'PYEOF'
ps = {r["skill"]: r for r in d["per_skill"]}
q = lambda s: (ps[s]["tp"], ps[s]["fp"], ps[s]["fn"], ps[s]["tn"])
assert q("code-review") == (1, 0, 0, 1), q("code-review")
assert q("queue-tuning") == (0, 1, 0, 1), q("queue-tuning")
assert q("graph-truth") == (0, 1, 0, 1), q("graph-truth")
assert "ghost-skill" not in ps
assert d["unknown_selected"] == [{"case_id": "w2", "skill": "ghost-skill", "repeat": 1}], d["unknown_selected"]
o = d["overall"]
assert (o["tp"], o["fp"], o["fn"], o["tn"]) == (1, 2, 0, 3), o
PYEOF

# 6. Rubric: deterministic, name+description only, threshold-driven.
mksuite rubric '{"version":1,"cases":[
{"id":"r1","kind":"positive","prompt":"review this diff for merge readiness and severity","expect":["code-review"]},{"id":"r2","kind":"positive","prompt":"tune worker queue leases and retries","expect":["queue-tuning"]},
{"id":"r3","kind":"negative","prompt":"write a poem about autumn leaves","expect":[],"reject":["*"]}]}'
runs "rubric run exits 0 (default harness is rubric)" 0 --suite "${work}/rubric.json" --skills-dir "${CAT}" --threshold 0.5 --json-out "${work}/rub1.json"
run --suite "${work}/rubric.json" --skills-dir "${CAT}" --threshold 0.5 --json-out "${work}/rub2.json"
check "rubric picks the lexical matches and mislabels nothing" "${work}/rub1.json" <<'PYEOF'
assert (d["decider"], d["mode"], d["threshold"], d["repeats"]) == ("rubric", "lexical-rubric", 0.5, 1), d
o = d["overall"]
assert (o["tp"], o["fp"], o["fn"]) == (2, 0, 0) and o["f1"] == 1.0, o
PYEOF
python3 - "${work}/rub1.json" "${work}/rub2.json" <<'PYEOF' && ok "two rubric runs are identical apart from recorded_at" || no "two rubric runs are identical apart from recorded_at"
import json, sys
docs = []
for p in sys.argv[1:]:
    d = json.load(open(p))
    d.pop("recorded_at")
    docs.append(json.dumps(d, sort_keys=True))
assert docs[0] == docs[1]
PYEOF
run --suite "${work}/rubric.json" --skills-dir "${CAT}" --threshold 1.0 --json-out "${work}/rub3.json"
check "a stricter threshold turns the 0.8-coverage positive into a false negative" "${work}/rub3.json" <<'PYEOF'
assert d["overall"]["fn"] == 1 and d["threshold"] == 1.0, d["overall"]
PYEOF
python3 - "${LIB}" "${CAT}" <<'PYEOF' && ok "empty prompt tokens trigger nothing, even at threshold 0" || no "empty prompt tokens trigger nothing"
import sys
sys.path.insert(0, sys.argv[1])
import replay_trigger as t
cat = t.load_catalog([sys.argv[2]])
assert t.rubric_select("a to", cat, 0.0) == []
assert t.rubric_select("", cat, 0.0) == []
PYEOF

# 7. Live path: PATH-stubbed claude/agy/muse; router prompt; errors excluded from counts.
mksuite live '{"version":1,"cases":[
{"id":"live-1","kind":"positive","prompt":"live-1 review it","expect":["code-review"]},{"id":"live-2","kind":"positive","prompt":"live-2 tune it","expect":["queue-tuning"]},
{"id":"live-3","kind":"negative","prompt":"live-3 chat","expect":[],"reject":["code-review"]},
{"id":"live-4","kind":"negative","prompt":"live-4 chat","expect":[],"reject":["graph-truth"]}]}'
printf '%s\n' '{"live-1":["code-review"],"live-2":"__GARBAGE__","live-3":"__EXIT1__","live-4":[]}' >"${work}/map.json"
for h in claude agy muse; do
	rm -f "${work}/live-${h}.json"
	PATH="${work}/bin:${PATH}" run --suite "${work}/live.json" --skills-dir "${CAT}" --harness "${h}" --json-out "${work}/live-${h}.json"
	rc_is "${h}: unparseable reply and non-zero exit make the run exit 1" 1
	[ ! -e "${work}/live-${h}.json" ] && ok "${h}: a failed run writes no --json-out file" || no "${h}: a failed run writes no --json-out file"
	PATH="${work}/bin:${PATH}" run --suite "${work}/live.json" --skills-dir "${CAT}" --harness "${h}" --allow-errors --json-out "${work}/live-${h}.json"
	rc_is "${h}: --allow-errors turns the error exit into 0" 0
	check "${h}: router-prompt mode, errored trials excluded from confusion counts" "${work}/live-${h}.json" "${h}" <<'PYEOF'
assert d["decider"] == sys.argv[2] and d["mode"] == "router-prompt", (d["decider"], d["mode"])
assert d["trials"] == 4 and d["errors"] == 2, (d["trials"], d["errors"])
o = d["overall"]
assert (o["tp"], o["fp"], o["fn"], o["tn"]) == (1, 0, 0, 1), o
q = {r["skill"]: r for r in d["per_skill"]}["queue-tuning"]
assert q["fn"] == 0 and q["recall"] is None, q
PYEOF
done
[ -s "${work}/log/claude.argv" ] && [ -s "${work}/log/agy.argv" ] && [ -s "${work}/log/muse.prompt" ] &&
	! rg -q 'BODY-SENTINEL-117' "${work}/log/claude.stdin" "${work}/log/claude.argv" "${work}/log/agy.argv" "${work}/log/muse.prompt" &&
	rg -q 'queue-tuning' "${work}/log/claude.stdin" && rg -q -- '--disable-slash-commands' "${work}/log/claude.argv" &&
	! rg -q -- 'append-system-prompt' "${work}/log/claude.argv" &&
	ok "routers see names+descriptions only: no body in stdin, argv or prompt file; no skill injection flags" || no "routers see names+descriptions only"
[ "$(sort -u "${work}/log/claude.ls" "${work}/log/agy.ls" "${work}/log/muse.ls")" = "[]" ] &&
	ok "every live harness runs in an empty working directory" || no "every live harness runs in an empty working directory"
printf '%s\n' '{"live-1":"__FENCED__"}' >"${work}/map.json"
mksuite fenced '{"version":1,"cases":[{"id":"live-1","kind":"positive","prompt":"live-1 review","expect":["code-review"]}]}'
PATH="${work}/bin:${PATH}" run --suite "${work}/fenced.json" --skills-dir "${CAT}" --harness claude --json-out "${work}/fenced.out.json"
check "a fenced JSON reply parses" "${work}/fenced.out.json" <<'PYEOF'
assert d["errors"] == 0 and d["overall"]["tp"] == 1, d["overall"]
PYEOF
printf '%s\n' '{"live-1":"__SLEEP__"}' >"${work}/map.json"
PATH="${work}/bin:${PATH}" run --suite "${work}/fenced.json" --skills-dir "${CAT}" --harness claude --timeout 1
rc_is "a harness timeout is an errored trial and fails the run" 1
PATH="${work}/bin:${PATH}" run --suite "${work}/fenced.json" --skills-dir "${CAT}" --harness claude --timeout 1 --allow-errors --json-out "${work}/sleep.out.json"
check "timeout trial is counted as an error, not a non-trigger" "${work}/sleep.out.json" <<'PYEOF'
assert d["errors"] == 1 and d["overall"]["fn"] == 0, d
PYEOF
printf '%s\n' '{"m1":"__EXIT1__"}' >"${work}/map.json"
runs "a failing decider-cmd trial fails the run by default" 1 --suite "${work}/math.json" --skills-dir "${CAT}" --decider-cmd "${work}/decider.py"
runs "a failing decider-cmd trial is kept with --allow-errors" 0 --suite "${work}/math.json" --skills-dir "${CAT}" --decider-cmd "${work}/decider.py" --allow-errors --json-out "${work}/cmderr.json"
check "failing decider-cmd trial is excluded from counts" "${work}/cmderr.json" <<'PYEOF'
assert d["errors"] == 1 and d["trials"] == 6, d
PYEOF

# 8. Validation exits 2.
runs "a stray positional argument exits 2 instead of silently running rubric" 2 --suite "${work}/math.json" --skills-dir "${CAT}" stray --harness claude
bad() { # bad "desc" 'suite json'
	mksuite bad "$2"
	run --suite "${work}/bad.json" --skills-dir "${CAT}"
	rc_is "$1" 2
}
bad "unknown skill in the suite exits 2" '{"version":1,"cases":[{"id":"x","kind":"positive","prompt":"p","expect":["no-such-skill"]}]}'
rg -q 'no-such-skill' "${work}/err" && ok "unknown-skill error names the skill" || no "unknown-skill error names the skill"
bad "duplicate case id exits 2" '{"version":1,"cases":[{"id":"x","kind":"positive","prompt":"p","expect":["code-review"]},{"id":"x","kind":"positive","prompt":"q","expect":["code-review"]}]}'
bad "positive with empty expect exits 2" '{"version":1,"cases":[{"id":"x","kind":"positive","prompt":"p","expect":[]}]}'
bad "negative with empty reject exits 2" '{"version":1,"cases":[{"id":"x","kind":"negative","prompt":"p","expect":[],"reject":[]}]}'
bad "negative with a non-empty expect exits 2" '{"version":1,"cases":[{"id":"x","kind":"negative","prompt":"p","expect":["code-review"],"reject":["graph-truth"]}]}'
bad "competing without reject exits 2" '{"version":1,"cases":[{"id":"x","kind":"competing","prompt":"p","expect":["code-review"]}]}'
bad "skill in both expect and reject exits 2" '{"version":1,"cases":[{"id":"x","kind":"competing","prompt":"p","expect":["code-review"],"reject":["code-review"]}]}'
bad "empty cases exits 2" '{"version":1,"cases":[]}'
bad "unknown kind exits 2" '{"version":1,"cases":[{"id":"x","kind":"maybe","prompt":"p","expect":["code-review"]}]}'
bad "an evals-keyed file is not a trigger suite (exits 2)" '{"version":1,"evals":[{"id":"x","kind":"positive","prompt":"p","expect":["code-review"]}]}'
runs "--decider-cmd with a live --harness exits 2" 2 --suite "${work}/math.json" --skills-dir "${CAT}" --decider-cmd "${work}/decider.py" --harness claude
runs "an empty catalog exits 2" 2 --suite "${work}/math.json" --skills-dir "${work}/emptycat"
runs "a missing suite file exits 2" 2 --suite "${work}/no-such.json" --skills-dir "${CAT}"
runs "threshold outside 0..1 exits 2" 2 --suite "${work}/math.json" --skills-dir "${CAT}" --threshold 1.5
runs "repeats below 1 exits 2" 2 --suite "${work}/math.json" --skills-dir "${CAT}" --repeats 0
runs "an unknown harness exits 2" 2 --suite "${work}/math.json" --skills-dir "${CAT}" --harness gemini

# 9. Aliases resolve in suites and decider replies (default overlay map and --aliases).
mksuite alias '{"version":1,"cases":[
{"id":"a1","kind":"positive","prompt":"a1 review","expect":["eshu-code-review"]},
{"id":"a2","kind":"positive","prompt":"a2 graph","expect":["graph-truth"]}]}'
printf '%s\n' '{"a1":["eshu-code-review"],"a2":["kit:graph-truth"]}' >"${work}/map.json"
run --suite "${work}/alias.json" --skills-dir "${CAT}" --decider-cmd "${work}/decider.py" --json-out "${work}/alias.out.json"
check "eshu-code-review and a prefixed name resolve to catalog skills" "${work}/alias.out.json" <<'PYEOF'
o = d["overall"]
assert (o["tp"], o["fp"], o["fn"]) == (2, 0, 0) and d["unknown_selected"] == [], d
PYEOF
printf 'legacy-queue\tqueue-tuning\n' >"${work}/aliases.tsv"
mksuite alias2 '{"version":1,"cases":[{"id":"a3","kind":"positive","prompt":"a3 queue","expect":["legacy-queue"]}]}'
printf '%s\n' '{"a3":["legacy-queue"]}' >"${work}/map.json"
run --suite "${work}/alias2.json" --skills-dir "${CAT}" --decider-cmd "${work}/decider.py" --aliases "${work}/aliases.tsv" --json-out "${work}/alias2.out.json"
check "--aliases loads a custom alias map" "${work}/alias2.out.json" <<'PYEOF'
assert d["overall"]["tp"] == 1 and d["unknown_selected"] == [], d
PYEOF

# 10. --repeats triples the trials and the counts.
run --suite "${work}/rubric.json" --skills-dir "${CAT}" --threshold 0.5 --repeats 3 --json-out "${work}/rep.json"
check "--repeats 3 triples trials and confusion counts" "${work}/rep.json" <<'PYEOF'
assert d["cases"] == 3 and d["trials"] == 9 and d["repeats"] == 3, d
assert d["overall"]["tp"] == 6, d["overall"]
PYEOF

# 11. Committed starter suite: structure only, no numeric pins.
runs "starter suite runs under the offline rubric against the kit skills" 0 --suite "${KIT_DIR}/evals/triggers.json" --json-out "${work}/starter.json"
check "starter suite covers the six tuned skills with positive, negative, and competing cases" "${KIT_DIR}/evals/triggers.json" "${KIT_DIR}" <<'PYEOF'
import glob, re
names = set()
for p in glob.glob(sys.argv[2] + "/skills/**/SKILL.md", recursive=True):
    m = re.search(r"^name:\s*(\S+)", open(p).read(), re.M)
    if m:
        names.add(m.group(1))
assert set(d) == {"version", "cases"} and d["version"] == 1, set(d)
for c in d["cases"]:
    for s in c.get("expect", []) + c.get("reject", []):
        assert s == "*" or s in names, (c["id"], s)
for s in ("correlation-truth", "diagnostic-rigor", "golang-engineering", "performance-rigor", "postgres-rigor", "telemetry-coverage-discipline"):
    pos = [c for c in d["cases"] if c["kind"] == "positive" and s in c["expect"]]
    neg = [c for c in d["cases"] if c["kind"] == "negative" and (s in c["reject"] or "*" in c["reject"])]
    com = [c for c in d["cases"] if c["kind"] == "competing" and (s in c["expect"] or s in c["reject"])]
    assert pos and neg and com, (s, len(pos), len(neg), len(com))
PYEOF
# 12. /debrief consumes trigger JSON.
python3 - "${work}/trig" <<'PYEOF'
import json, os, sys
os.makedirs(sys.argv[1])
def row(skill, p, r, f):
    return {"skill": skill, "tp": 1, "fp": 0, "fn": 0, "tn": 1, "precision": p, "recall": r, "f1": f, "trigger_rate": 0.5, "false_trigger_rate": 0.0}
for name, decider, at, f1, extra in (("rubric-new", "rubric", "2026-11-20", 0.5, True), ("rubric-old", "rubric", "2026-11-01", 0.1, False), ("claude", "claude", "2026-11-10", 0.9, False)):
    rows = [row("code-review", f1, f1, f1)] + ([row("graph-truth", True, float("nan"), 0.25)] if extra else [])
    mode = "router-prompt" if decider == "claude" else "lexical-rubric"
    json.dump({"kind": "trigger-eval", "version": 1, "decider": decider, "mode": mode, "recorded_at": at + "T00:00:00+00:00", "per_skill": rows}, open(os.path.join(sys.argv[1], name + ".json"), "w"))
PYEOF
cat >"${work}/ablation.json" <<'EOF'
{"skill":"code-review","win_rate":0.7,"noise_band":0.1,"pass_rate_with":0.9,"cross_pairs":6,"harness":"claude","recorded_at":"2026-11-15T00:00:00+00:00"}
EOF
cat >"${work}/hooks.jsonl" <<'EOF'
{"harness":"muse","session":"s1","ts":"2026-11-20T10:00:00+00:00","type":"skill-load","detail":{"skill":"code-review"}}
{"harness":"muse","session":"s1","ts":"2026-11-20T10:01:00+00:00","type":"skill-load","detail":{"skill":"graph-truth"}}
{"harness":"muse","session":"s1","ts":"2026-11-20T10:02:00+00:00","type":"skill-load","detail":{"skill":"debrief"}}
EOF
agg() { # agg OUT ARGS...
	local out="$1"
	shift
	bash "${DEBRIEF}" aggregate --since 2026-11-01 --cache-dir "${work}/cache" --log "${work}/hooks.jsonl" --out "${out}" "$@" >/dev/null 2>"${work}/err"
	rc=$?
}
mkdir -p "${work}/trig-inf"
printf '{"kind":"trigger-eval","decider":"rubric","per_skill":[{"skill":"code-review","tp":Infinity,"fp":-1,"fn":"x","tn":2}]}' >"${work}/trig-inf/inf.json"
agg "${work}/agg-inf.json" --trigger-evals "${work}/trig-inf"
rc_is "non-finite trigger counts are tolerated, not a traceback" 0
agg "${work}/agg.json" --trigger-evals "${work}/trig"
rc_is "aggregate --trigger-evals accepts a directory of trigger JSON" 0
check "rows carry trigger fields: newest per (skill, decider), live preferred over rubric, bad numbers null" "${work}/agg.json" <<'PYEOF'
rows = {r["skill"]: r for r in d["skill_table"]}
cr = rows["code-review"]
assert (cr["trigger_decider"], cr["trigger_precision"], cr["trigger_recall"], cr["trigger_f1"]) == ("claude", 0.9, 0.9, 0.9), cr
per = d["trigger_evals"]["per_skill"]["code-review"]
assert per["rubric"]["f1"] == 0.5, per
gt = rows["graph-truth"]
assert (gt["trigger_decider"], gt["trigger_precision"], gt["trigger_recall"], gt["trigger_f1"]) == ("rubric", None, None, 0.25), gt
dbf = rows["debrief"]
assert dbf["trigger_decider"] is None and dbf["trigger_precision"] is None and dbf["trigger_f1"] is None, dbf
PYEOF
agg "${work}/agg-none.json"
check "without --trigger-evals the aggregate stays backward compatible" "${work}/agg-none.json" <<'PYEOF'
assert d["trigger_evals"] is None
assert all(r["trigger_decider"] is None and r["trigger_f1"] is None for r in d["skill_table"])
PYEOF
agg "${work}/agg-abl.json" --trigger-evals "${work}/ablation.json"
[ "${rc}" -ne 0 ] && rg -q 'trigger-eval' "${work}/err" &&
	ok "an ablation summary passed to --trigger-evals exits non-zero naming the kind" || no "an ablation summary passed to --trigger-evals exits non-zero (rc=${rc})"
agg "${work}/agg-miss.json" --trigger-evals "${work}/no-such-trigger.json"
[ "${rc}" -ne 0 ] && ok "a missing --trigger-evals path exits non-zero" || no "a missing --trigger-evals path exits non-zero"
agg "${work}/agg-evals.json" --evals "${work}/ablation.json" --evals "${work}/trig/rubric-new.json"
check "trigger JSON passed to --evals leaves win_rate rows untouched" "${work}/agg-evals.json" <<'PYEOF'
cr = {r["skill"]: r for r in d["skill_table"]}["code-review"]
assert cr["eval_win_rate"] == 0.7 and cr["eval_pairs"] == 6, cr
assert d["evals"]["per_skill"].keys() == {"code-review"}, d["evals"]
PYEOF
agg "${work}/agg-evals2.json" --evals "${work}/trig/rubric-new.json"
check "trigger JSON alone through --evals creates no win_rate rows" "${work}/agg-evals2.json" <<'PYEOF'
assert all(r["eval_win_rate"] is None for r in d["skill_table"]), d["skill_table"]
PYEOF
cat >"${work}/syn.json" <<'EOF'
{"at_a_glance":{"working":"Good","hindering":"None","quick_wins":"None","ambitious":"None"},"project_areas":[],"narrative_paragraphs":[],"key_insight":"Ok","wins_intro":"","big_wins":[],"friction_intro":"","friction_categories":[],"agents_md_additions":[],"features_to_try":[],"usage_patterns":[],"horizon_intro":"","horizon_workflows":[]}
EOF
bash "${DEBRIEF}" render --aggregate "${work}/agg.json" --synthesis "${work}/syn.json" --out "${work}/with.html" >/dev/null 2>&1 &&
	bash "${DEBRIEF}" render --aggregate "${work}/agg-none.json" --synthesis "${work}/syn.json" --out "${work}/without.html" >/dev/null 2>&1 &&
	python3 - "${work}/with.html" "${work}/without.html" <<'PYEOF' && ok "render shows the trigger card naming the decider, and omits it when trigger_evals is null" || no "render shows the trigger card naming the decider, and omits it when trigger_evals is null"
import sys
w = open(sys.argv[1], encoding="utf-8").read()
n = open(sys.argv[2], encoding="utf-8").read()
assert "Trigger Precision / Recall" in w and "Trigger Precision / Recall" not in n
card = w[w.index("Trigger Precision / Recall"):]
assert "claude" in card and "rubric" in card and "router-prompt" in card
PYEOF

printf '\n%d passed, %d failed\n' "${passed}" "${failed}"
[ "${failed}" -eq 0 ]
