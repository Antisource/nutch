#!/usr/bin/env bash
# Rehearsal of m513c-worker.sh (prep, pack, repack) on fake folders. Usage: bash m513c-worker-rehearse.sh KITDIR
set -uo pipefail
KIT="$1"; R=$(mktemp -d); fail=0
res() { if grep -q -- "$2" "$R/out.txt"; then echo "CAUGHT/OK  $1  ->  $2"; else echo "NOT AS EXPECTED  $1 (wanted: $2)"; sed 's/^/      | /' "$R/out.txt" | tail -5; fail=1; fi; }
mk() { rm -rf "$R/h" "$R/tmp"; mkdir -p "$R/h/hadoop/logs/userlogs" "$R/tmp/attested-audit" "$R/tmp/attested-records"
  for a in application_1_0001 application_1_0002 application_1_0003; do mkdir -p "$R/h/hadoop/logs/userlogs/$a/container_1"; echo "log of $a" > "$R/h/hadoop/logs/userlogs/$a/container_1/syslog"; done
  touch -d "2026-10-15 18:20:00" "$R/h/hadoop/logs/userlogs/application_1_0001"; touch -d "2026-10-15 18:40:00" "$R/h/hadoop/logs/userlogs/application_1_0002"; touch -d "2026-10-15 18:45:00" "$R/h/hadoop/logs/userlogs/application_1_0003"
  for i in 1 2; do echo "audit $i" > "$R/tmp/attested-audit/tdx-lab-worker-$i-1.tsv"; echo "rec $i" > "$R/tmp/attested-records/tdx-lab-worker-$i-1.tsv"; done; }
run() { ( cd "$KIT" && M513C_HOME="$R/h" M513C_HOST="${HOST_:-tdx-lab-worker}" M513C_ATT_TMP="$R/tmp" bash ops/attested/m513c-worker.sh "$@" ) > "$R/out.txt" 2>&1; echo $?; }
mk; ln -sf "$KIT/ops/attested/audit.sh" "$R/audit.sh" 2>/dev/null
rc=$(run prep); res "T1 prep rotates the old logs" "rotated 2 log file(s)"; res "T1b ... and says what to do next" "M513C-WORKER-PREP-OK"
[ -z "$(ls "$R/tmp/attested-audit"/*.tsv 2>/dev/null)" ] && echo "CAUGHT/OK  T1c the old audit logs were moved out of the folder" || { echo "NOT AS EXPECTED  T1c"; fail=1; }
mk; mkdir -p "$R/h/m513w/window"; rc=$(run prep); res "T2 prep refuses when the window is open already" "M513C-WORKER-STOP: the window is open already"
mk; rc=$(HOST_=tdx-lab run prep); res "T3 prep refuses on the wrong machine" "M513C-WORKER-STOP: this runs on the worker"
mk; mkdir -p "$R/h/m513w/window/saved"; rc=$(run pack run14); res "T4 pack in an open window" "M513C-WORKER-PACK-OK (run14)"
tar tzf "$R/h/run14-worker.tar.gz" > "$R/list.txt"; grep -q "^attested-audit/tdx-lab-worker-1-1.tsv" "$R/list.txt" && grep -q "^attested-records/" "$R/list.txt" && grep -q "^userlogs/application_1_0002/container_1/syslog" "$R/list.txt" && echo "CAUGHT/OK  T4b the pack holds the audit logs, the record logs AND the task logs" || { echo "NOT AS EXPECTED  T4b"; cat "$R/list.txt"; fail=1; }
res "T4c it says how many applications' task logs" "task logs of 3 application(s)"
rc=$(run pack run14); res "T5 pack refuses to overwrite a pack" "exists already"
mk; rc=$(run pack run14); res "T6 pack refuses when the window is not open" "the window is not open on this node"
mk; mkdir -p "$R/h/m513w/window/saved"; rm -rf "$R/h/hadoop/logs/userlogs"; mkdir -p "$R/h/hadoop/logs/userlogs"; rc=$(run pack run14); res "T7 pack refuses when there are no task logs (the gap of version 1)" "no YARN task logs in"
mk; mkdir -p "$R/h/m513w/window/saved"; rm -f "$R/tmp/attested-audit"/*.tsv; rc=$(run pack run14); res "T8 pack refuses when there are no audit logs" "there are no audit logs on this node"
mk; mkdir -p "$R/h/m513w/window/saved"; rc=$(run pack "RUN-14"); res "T9 a bad run name" "RUN must be letters and digits only"
# repack: a pack made without task logs (version 1), completed from the userlogs of the applications started in the window
mk; ( cd "$R/tmp" && tar czf "$R/h/run14-worker.tar.gz" attested-audit attested-records ); sha0=$(sha256sum "$R/h/run14-worker.tar.gz" | cut -c1-64)
rc=$(run repack run14 "2026-10-15 18:33:07" "2026-10-15 19:02:00"); res "T10 repack completes a pack that has no task logs" "M513C-WORKER-REPACK-OK (run14)"; res "T10b ... for the applications of the window only (not the one from 18:20)" "task logs added for 2 application(s): application_1_0002 application_1_0003"
tar tzf "$R/h/run14-worker.tar.gz" > "$R/list.txt"; grep -q "userlogs/application_1_0002" "$R/list.txt" && ! grep -q "userlogs/application_1_0001" "$R/list.txt" && grep -q "^attested-audit/" "$R/list.txt" && echo "CAUGHT/OK  T10c the completed pack has the audit logs, the record logs and exactly the window's task logs" || { echo "NOT AS EXPECTED  T10c"; fail=1; }
[ "$(sha256sum "$R/h/run14-worker-logs-only.tar.gz" | cut -c1-64)" = "$sha0" ] && echo "CAUGHT/OK  T10d the original pack is kept unchanged" || { echo "NOT AS EXPECTED  T10d"; fail=1; }
mkdir -p "$R/x1" "$R/x2"; tar xzf "$R/h/run14-worker.tar.gz" -C "$R/x1"; tar xzf "$R/h/run14-worker-logs-only.tar.gz" -C "$R/x2"; diff -r "$R/x1/attested-audit" "$R/x2/attested-audit" >/dev/null && diff -r "$R/x1/attested-records" "$R/x2/attested-records" >/dev/null && echo "CAUGHT/OK  T10e the wrapper logs in the completed pack are identical to the original's" || { echo "NOT AS EXPECTED  T10e"; fail=1; }
rc=$(run repack run14 "2026-10-15 18:33:07" "2026-10-15 19:02:00"); res "T11 repack refuses to repack twice" "exists already: this pack was completed before"
mk; rc=$(run repack run14 "2026-10-15 18:33:07" "2026-10-15 19:02:00"); res "T12 repack refuses when there is no pack" "there is no .*run14-worker.tar.gz to complete"
mk; ( cd "$R/tmp" && tar czf "$R/h/run14-worker.tar.gz" attested-audit attested-records ); rc=$(run repack run14 "2026-10-15 17:00:00" "2026-10-15 17:30:00"); res "T13 repack refuses when no application was started in the time range" "no application's task logs were written between"
mk; mkdir -p "$R/h/m513w/window/saved"; run pack run14 >/dev/null; rc=$(run repack run14 "2026-10-15 18:33:07" "2026-10-15 19:02:00"); res "T14 repack refuses a pack that has task logs already" "has userlogs already"
mk; ( cd "$R/tmp" && tar czf "$R/h/run14-worker.tar.gz" attested-audit attested-records ); rc=$(run repack run14 "yesterday-ish" "2026-10-15 19:02:00"); res "T15 a bad time" "FROM or TO is not a time"
rc=$(run repack run14 "2026-10-15 19:02:00" "2026-10-15 18:33:07"); res "T16 FROM after TO" "FROM must be before TO"
[ $fail -eq 0 ] && echo "REHEARSAL-PASS: prep, pack and repack pass, and all 12 faults are caught" || echo "REHEARSAL-FAIL"
