#!/usr/bin/env bash
# Rehearsal of m481r-policy.sh with the exact commands used on the nodes (relative paths, from the kit folder) and deliberate faults.
# Usage: bash m481r-policy-rehearse.sh KITDIR      (needs python3 and a JDK with keytool)
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1
KIT="$1"; R=$(mktemp -d); fail=0
res() { if grep -q "$2" "$R/out.txt"; then echo "CAUGHT/OK  $1  ->  $2"; else echo "NOT AS EXPECTED  $1 (wanted: $2)"; sed 's/^/      | /' "$R/out.txt" | tail -5; fail=1; fi; }
export HOME="$R/home"; mkdir -p "$HOME"
cd "$KIT"
bash ops/attested/m481r-policy.sh build >"$R/out.txt" 2>&1; res "T1 build with the default folder, relative script path" "M481P-POLICY-BUILD-OK"
SHA=$(cat "$HOME/tc-policy/policy.json.sha256")
bash ops/attested/m481r-policy.sh verify "$SHA" >"$R/out.txt" 2>&1; res "T2 verify on the same node" "M481P-POLICY-VERIFY-OK"
bash ops/attested/m481r-policy.sh build >"$R/out.txt" 2>&1; res "T3 a second build must refuse to overwrite" "never overwritten"
mkdir -p "$R/bad1" && cp "$HOME/tc-policy/policy.json" "$R/bad1/" && printf ' ' >> "$R/bad1/policy.json"
bash ops/attested/m481r-policy.sh verify "$SHA" "$R/bad1" >"$R/out.txt" 2>&1; res "T4 a policy file changed by one byte" "M481P-POLICY-VERIFY-FAILED"
mkdir -p "$R/bad2" && python3 - "$HOME/tc-policy/policy.json" "$R/bad2/policy.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["trust_anchors"]["anchor_set_sha256"] = "sha256:" + "0" * 64
open(sys.argv[2], "w").write(json.dumps(d, sort_keys=True, indent=2))
PY
SHA2=$(sha256sum "$R/bad2/policy.json" | cut -c1-64)
bash ops/attested/m481r-policy.sh verify "$SHA2" "$R/bad2" >"$R/out.txt" 2>&1; res "T5 a node whose JDK has a different certificate set (right file, wrong anchors)" "the emitter would refuse to start here"
bash ops/attested/m481r-policy.sh verify "$SHA" "$R/nothere" >"$R/out.txt" 2>&1; res "T6 a missing policy file" "M481P-POLICY-STOP: .*not found"
cp -r "$KIT" "$R/kit2" && echo "# changed" >> "$R/kit2/policy-src/ccbot/make_policy.py" && ( cd "$R/kit2" && HOME="$R/home2" bash ops/attested/m481r-policy.sh build ) >"$R/out.txt" 2>&1; res "T7 a changed source file" "M481P-POLICY-STOP: the source files differ"
bash ops/attested/m481r-policy.sh verify "$SHA" /does/not/exist >"$R/out.txt" 2>&1; res "T8 a policy folder that does not exist" "not found"
[ $fail -eq 0 ] && echo "REHEARSAL-PASS: the build and the verify pass, and all 6 faults are caught" || echo "REHEARSAL-FAIL"
