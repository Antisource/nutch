#!/usr/bin/env bash
# Rehearsal of the shared cluster setup away from the cluster: a fake home with a fake Hadoop tree, a fake measured job and an
# event log made with the REAL treehash.sh; a fake HDFS that models the wrapper's record files (a plain listing shows them, a
# wrapped listing hides them, a wrapped put makes one); fake YARN and sudo. Run: bash tcs-rehearse.sh
set -uo pipefail
K="$(cd "$(dirname "$0")" && pwd)"; REPO="${1:-/tmp/clfull}"
PASS=0; FAILN=0
chk() { if [ "$2" = 0 ]; then PASS=$((PASS+1)); echo "  pass: $1"; else FAILN=$((FAILN+1)); echo "  FAIL: $1"; fi; }

mkworld() {
  chmod +x "$K"/*.sh; unset FAKE_CHECK_FAIL FAKE_TAMPER FAKE_EFF FAKE_NODES FAKE_HDFS_NORECORD FAKE_RM_LEAVES_RECORD
  T="$(mktemp -d)"; export T; export HOME="$T/home"; mkdir -p "$HOME" "$T/bin" "$T/fh"
  export FAKE_HDFS="$T/fh"; export PATH="$T/bin:$PATH"
  H="$HOME/hadoop"; mkdir -p "$H/bin" "$H/etc/hadoop" "$H/share/hadoop/common/lib" "$H/logs" "$H/libexec"
  echo "<configuration><property><name>fs.hdfs.impl</name><value>org.apache.nutch.attested.AttestedHdfsFileSystem</value></property></configuration>" > "$H/etc/hadoop/core-site.xml"
  echo "export JAVA_HOME=/x" > "$H/etc/hadoop/hadoop-env.sh"; head -c 4000 /dev/urandom > "$H/share/hadoop/common/lib/attested-hdfs.jar"; head -c 9000 /dev/urandom > "$H/share/hadoop/common/lib/hadoop-common.jar"
  echo log > "$H/logs/a.log"; ln -s ../share "$H/libexec/lnk"; chmod 664 "$H/share/hadoop/common/lib/"*.jar
  cat > "$H/bin/hdfs" <<'EOS'
#!/bin/bash
# fake hdfs: files under $FAKE_HDFS; a record is the hidden file .NAME.attested next to the file
PLAIN=0; args=(); while [ $# -gt 0 ]; do if [ "$1" = -D ]; then [[ "$2" == *DistributedFileSystem ]] && PLAIN=1; shift 2; else args+=("$1"); shift; fi; done; set -- "${args[@]}"
R="$FAKE_HDFS"
if [ "$1" = getconf ]; then echo "${FAKE_EFF:-org.apache.nutch.attested.AttestedHdfsFileSystem}"; exit 0; fi
[ "$1" = dfs ] || exit 2; shift; cmd="$1"; shift
case "$cmd" in
  -test) [ "$1" = -d ] && [ -d "$R$2" ] && exit 0; [ "$1" = -e ] && [ -e "$R$2" ] && exit 0; exit 1 ;;
  -mkdir) [ "$1" = -p ] && shift; mkdir -p "$R$1" ;;
  -put) src="$1"; dst="$2"; [ -d "$R$dst" ] && dst="$dst/$(basename "$src")"; if [ "$src" = - ]; then cat > "$R$dst"; else cp "$src" "$R$dst"; fi
        [ "$PLAIN" = 0 ] && [ -z "${FAKE_HDFS_NORECORD:-}" ] && printf 'ATTEST01' > "$R$(dirname "$dst")/.$(basename "$dst").attested"; exit 0 ;;
  -cat) cat "$R$1" ;;
  -rm) shift; f="$R$1"; rm -f "$f"; [ "$PLAIN" = 0 ] && [ -z "${FAKE_RM_LEAVES_RECORD:-}" ] && rm -f "$(dirname "$f")/.$(basename "$f").attested"; exit 0 ;;
  -chown) echo "$1" > "$R$2.owner" 2>/dev/null; [ -d "$R$2" ] && echo "$1" > "$R$2/.owner-meta" ;;
  -chmod) [ -d "$R$2" ] && echo "$1" > "$R$2/.mode-meta" ;;
  -ls) d=0; c=0; [ "$1" = -d ] && { d=1; shift; }; [ "$1" = -C ] && { c=1; shift; }; p="$1"
       if [ "$d" = 1 ]; then o="$(cat "$R$p/.owner-meta" 2>/dev/null || echo "u:g")"; m="$(cat "$R$p/.mode-meta" 2>/dev/null || echo 755)"; echo "drwxr-xr-x   - ${o%%:*} ${o##*:}          0 2026-10-14 15:00 $p (mode $m)"; exit 0; fi
       [ -e "$R$p" ] || exit 1
       for f in "$R$p"/* "$R$p"/.[!.]*; do [ -e "$f" ] || continue; b="$(basename "$f")"; case "$b" in .owner-meta|.mode-meta) continue ;; esac
         if [ "$PLAIN" = 0 ]; then case "$b" in .*.attested) continue ;; esac; fi
         echo "-rw-r--r--   1 u g         10 2026-10-14 15:00 $p/$b"; done ;;
esac
EOS
  cat > "$H/bin/yarn" <<'EOS'
#!/bin/bash
echo "Total Nodes:${FAKE_NODES:-1}"; printf '%s\t%s\t%s\t%s\n' "         Node-Id" "     Node-State" "Node-Http-Address" "Number-of-Running-Containers"
for i in $(seq 1 ${FAKE_NODES:-1}); do printf '%s\t%s\t%s\t%s\n' "hadoop-worker:4284$i" "        RUNNING" "hadoop-worker:8042" "                           0"; done
EOS
  chmod +x "$H/bin/"*
  N="$HOME/m481/patched"; mkdir -p "$N/runtime/deploy/bin" "$N/ops" "$N/seeds"; head -c 7000 /dev/urandom > "$N/runtime/deploy/apache-nutch-1.22.job"; chmod 664 "$N/runtime/deploy/apache-nutch-1.22.job"
  echo '#!/bin/bash' > "$N/runtime/deploy/bin/crawl"; chmod 755 "$N/runtime/deploy/bin/crawl"; cp "$REPO/ops/run-crawl.sh" "$N/ops/run-crawl.sh"
  # the event log of the measurement, made with the real treehash
  { printf 'jdk\t%s\t00\t11\n' "$(printf 'x%.0s' $(seq 1 96) | tr x a)"
    printf 'hadoop-code\t%s\t00\t11\n' "$("$K/treehash.sh" "$H" logs etc/hadoop | awk '{print $2}')"
    printf 'hadoop-conf\t%s\t00\t11\n' "$("$K/treehash.sh" "$H/etc/hadoop" | awk '{print $2}')"
    printf 'nutch-deploy\t%s\t00\t11\n' "$("$K/treehash.sh" "$N/runtime/deploy" | awk '{print $2}')"; } > "$HOME/rtmr3-events.tsv"
  printf '#!/bin/bash\n[ -n "${FAKE_CHECK_FAIL:-}" ] && { echo "hadoop-code CHANGED"; echo SOMETHING-CHANGED; exit 1; }\necho "ALL-UNCHANGED (4 components checked)"\n' > "$T/check.sh"
  printf '#!/bin/bash\nif [ -n "${FAKE_TAMPER:-}" ] && [ "$1" = chown ]; then echo x >> "$FAKE_TAMPER"; fi\nexec "$@"\n' > "$T/bin/sudo"; chmod +x "$T/bin/sudo"
  export TCS_ROOT="$T/opt/tc-shared" TCS_HAD="$H" TCS_NUTCH="$N" TCS_EVENTS="$HOME/rtmr3-events.tsv" TCS_CHECK="$T/check.sh" TCS_SUDO="$T/bin/sudo"
  export TCS_TMPFILES="$T/etc/tmpfiles.d" TCS_TMP="$T/tmp" TCS_HOSTNAME=tdx-lab TCS_USER=rishabsdp17 TCS_OUT="$HOME/tcshared" TC_SHARED="$T/opt/tc-shared"
  mkdir -p "$T/tmp"; chmod +x "$K"/*.sh
}
install() { bash "$K/tcs-install.sh" 2>&1; }
digest_hc() { "$K/treehash.sh" "$1" logs etc/hadoop | awk '{print $2}'; }

echo "=== 1. the install, happy path"
mkworld; before="$(digest_hc "$TCS_HAD")"; out="$(install)"; rc=$?; echo "$out" | tail -6 | cut -c1-170
chk "install exits 0 and says TCS-INSTALL-OK" $([ $rc = 0 ] && grep -q TCS-INSTALL-OK <<<"$out"; echo $?)
chk "the copy's three digests equal the event log" $([ "$(grep -c "the copy's digest equals the measurement" <<<"$out")" = 3 ]; echo $?)
chk "the copy is owned by root and not writable by others" $([ "$(stat -c %U "$TCS_ROOT/hadoop/bin/hdfs")" = root ] && [ -z "$(find "$TCS_ROOT" -perm -0002 ! -type l ! -path "$TCS_ROOT/state")" ]; echo $?)
chk "the original Hadoop tree is untouched (same digest, logs still there)" $([ "$(digest_hc "$TCS_HAD")" = "$before" ] && [ -f "$TCS_HAD/logs/a.log" ]; echo $?)
chk "the logs were not copied, the symbolic link was" $([ ! -e "$TCS_ROOT/hadoop/logs/a.log" ] && [ -L "$TCS_ROOT/hadoop/libexec/lnk" ]; echo $?)
chk "run-crawl.sh and the job are in the shared copy" $(cmp -s "$TCS_ROOT/nutch/ops/run-crawl.sh" "$REPO/ops/run-crawl.sh" && [ -f "$TCS_ROOT/nutch/runtime/deploy/apache-nutch-1.22.job" ]; echo $?)
chk "the five tools and the README are installed and executable" $([ "$(ls "$TCS_ROOT/bin" | wc -l)" = 5 ] && [ -x "$TCS_ROOT/bin/tc-check.sh" ] && [ -f "$TCS_ROOT/README.txt" ]; echo $?)
chk "the wrapper's log folders are mode 1777 and the tmpfiles rule sorts after tmp.conf" $([ "$(stat -c %a "$TCS_TMP/attested-audit")" = 1777 ] && [ "$(stat -c %a "$TCS_TMP/attested-records")" = 1777 ] && [ -f "$TCS_TMPFILES/zz-tc-shared.conf" ] && [ "$(grep -c '^d ' "$TCS_TMPFILES/zz-tc-shared.conf")" = 2 ]; echo $?)
chk "the reservation folder is mode 1777 and INSTALLED.txt names the digests" $([ "$(stat -c %a "$TCS_ROOT/state")" = 1777 ] && grep -q '^nutch-deploy ' "$TCS_ROOT/INSTALLED.txt"; echo $?)
chk "the evidence bundle was packed after the final line" $(tar -xzOf "$HOME/tcs-install-evidence.tar.gz" tcshared/summary.txt | grep -q TCS-INSTALL-OK; echo $?)
SAVE_T="$T"

echo "=== 2. the install's faults: it must stop, and must not have changed more than it should"
f() { mkworld; eval "$2"; out="$(install)"; rc=$?; chk "install fault: $1 -> stops ($3)" $([ $rc != 0 ] && grep -q "$3" <<<"$out"; echo $?); }
f "not the master" 'export TCS_HOSTNAME=tdx-lab-worker' "belongs on the master"; chk "   and nothing was created" $([ ! -e "$TCS_ROOT" ]; echo $?)
f "the shared folder exists already" 'mkdir -p "$TCS_ROOT"; touch "$TCS_ROOT/keep"' "exists already"; chk "   and its content is untouched" $([ -f "$TCS_ROOT/keep" ] && [ ! -d "$TCS_ROOT/hadoop" ]; echo $?)
f "the measured set is not intact" 'export FAKE_CHECK_FAIL=1' "measured set is not intact"; chk "   and nothing was copied" $([ ! -e "$TCS_ROOT" ]; echo $?)
f "the copy is tampered with after copying" 'export FAKE_TAMPER="$TCS_ROOT/hadoop/share/hadoop/common/lib/hadoop-common.jar"' "digest [0-9a-f]* differs from the measurement"
f "the event log lacks nutch-deploy" 'grep -v "^nutch-deploy" "$TCS_EVENTS" > "$T/ev" && mv "$T/ev" "$TCS_EVENTS"' "does not hold exactly one"
f "treehash.sh is not executable (unpacking drops the flag)" 'chmod -x "$K/treehash.sh"' "not executable"
f "a source file is writable by everybody" 'chmod 666 "$TCS_HAD/share/hadoop/common/lib/hadoop-common.jar"' "could be changed by other people"
f "an earlier output folder exists" 'mkdir -p "$TCS_OUT"' "exists already"
f "the job file is missing" 'rm -f "$TCS_NUTCH/runtime/deploy/apache-nutch-1.22.job"' "job folder or ops/run-crawl.sh is missing"
chmod +x "$K"/*.sh

echo "=== 3. the tools"
T="$SAVE_T"; export TC_SHARED="$T/opt/tc-shared" TCS_HAD="$T/home/hadoop" HOME="$T/home" FAKE_HDFS="$T/fh"; export PATH="$T/bin:$PATH"
bin="$TC_SHARED/bin"
# busy marker
a() { TCS_USER=alice bash "$bin/tc-busy.sh" "$@" 2>&1; }; b() { TCS_USER=bob bash "$bin/tc-busy.sh" "$@" 2>&1; }
chk "busy: free at first" $(o=$(a status); grep -q "TC-BUSY: free" <<<"$o"; echo $?)
chk "busy: alice takes it" $(o=$(a start "crawl run1"); grep -q "the cluster is yours" <<<"$o"; echo $?)
chk "busy: bob is refused and told who holds it" $(o=$(b start "my run"); grep -q "TC-BUSY-REFUSED: alice holds" <<<"$o"; echo $?)
chk "busy: bob cannot stop alice's reservation" $(o=$(b stop); grep -q "TC-BUSY-REFUSED" <<<"$o"; echo $?)
chk "busy: alice starting twice is harmless" $(o=$(a start "again"); grep -q "you already hold" <<<"$o"; echo $?)
chk "busy: status shows the holder and the reason" $(o=$(b status); grep -q "held by alice since .*: crawl run1" <<<"$o"; echo $?)
chk "busy: alice stops it, then bob can take it" $(o=$(a stop | grep -q released && b start "bob run"); grep -q "yours now" <<<"$o"; echo $?)
chk "busy: the admin can force-stop" $(o=$(TCS_USER=rishabsdp17 bash "$bin/tc-busy.sh" stop --force 2>&1); grep -q released <<<"$o"; echo $?)
chk "busy: no argument gives the usage" $(o=$(a); grep -q usage <<<"$o"; echo $?)
# user-add (admin) with the fake hdfs as the superuser
ua() { bash "$bin/tc-user-add.sh" "$@" 2>&1; }
chk "user-add: a Linux user gets /user/<name> and the staging folder is 1777" $(ua root | grep -q "TC-USER-ADD-OK" && [ "$(cat "$FAKE_HDFS/tmp/hadoop-yarn/staging/.mode-meta")" = 1777 ] && [ -d "$FAKE_HDFS/user/root" ]; echo $?)
chk "user-add: an unknown Linux user is refused with the reason" $(o=$(ua nosuchuser12345); grep -q "no Linux user" <<<"$o"; echo $?)
chk "user-add: a bad name is refused" $(o=$(ua 'a;b'); grep -q "not a plausible" <<<"$o"; echo $?)
chk "user-add: no argument gives the usage" $(o=$(bash "$bin/tc-user-add.sh" 2>&1); grep -q usage <<<"$o"; echo $?)
chk "user-add: running it twice is harmless" $(o=$(ua root); grep -q "TC-USER-ADD-OK" <<<"$o"; echo $?)
# seed
mkdir -p "$FAKE_HDFS/user/alice"; echo "https://example.org/" > "$T/seed.txt"
sd() { TCS_USER=alice bash "$bin/tc-seed.sh" "$@" 2>&1; }
chk "seed: a seed file is stored with its record" $(o=$(sd "$T/seed.txt" run1); grep -q "TC-SEED-OK.*\.seed\.txt\.attested" <<<"$o"; echo $?)
chk "seed: the same name again is refused" $(o=$(sd "$T/seed.txt" run1); grep -q "exists already" <<<"$o"; echo $?)
chk "seed: a missing local file is refused" $(o=$(sd "$T/nofile" run2); grep -q "no such file" <<<"$o"; echo $?)
chk "seed: a bad name is refused" $(o=$(sd "$T/seed.txt" 'a b'); grep -q "NAME must be" <<<"$o"; echo $?)
chk "seed: a user without a HDFS folder is told whom to ask" $(o=$(TCS_USER=carol bash "$bin/tc-seed.sh" "$T/seed.txt" run1 2>&1); grep -q "ask the admin" <<<"$o"; echo $?)
chk "seed: a missing record is reported, not hidden" $(o=$(FAKE_HDFS_NORECORD=1 sd "$T/seed.txt" run3); grep -q "TC-SEED-WARNING" <<<"$o"; echo $?)
# check
ck() { TCS_USER=alice bash "$bin/tc-check.sh" 2>&1; }
chk "check: a working setup ends with TC-CHECK-OK" $(ck | grep -q TC-CHECK-OK; echo $?)
chk "check: it cleaned up its own test file and record" $([ -z "$(ls -A "$FAKE_HDFS/user/alice" | grep tc-check)" ]; echo $?)
chk "check: no HDFS folder -> FAIL with the remedy" $(o=$(TCS_USER=carol bash "$bin/tc-check.sh" 2>&1); grep -q "ask the admin to run tc-user-add.sh carol" <<<"$o"; echo $?)
chk "check: the wrapper is not the cluster's file system -> FAIL" $(o=$(FAKE_EFF=org.apache.hadoop.hdfs.DistributedFileSystem ck); grep -q "not the wrapper" <<<"$o"; echo $?)
chk "check: no YARN node -> FAIL" $(o=$(FAKE_NODES=0 ck); grep -q "no YARN node is RUNNING" <<<"$o"; echo $?)
chk "check: a record left by the delete is a note, not a failure" $(o=$(FAKE_RM_LEAVES_RECORD=1 ck); grep -q "TC-CHECK-OK" <<<"$o"; echo $?)
chk "check: records that are not made are a failure" $(o=$(FAKE_HDFS_NORECORD=1 ck); grep -q "no record was made" <<<"$o"; echo $?)
chk "env: sourcing it puts the shared hdfs first on the PATH" $(env -i HOME="$HOME" PATH="/usr/bin:/bin" TC_SHARED="$TC_SHARED" bash -c ". $bin/tc-env.sh >/dev/null; [ \"\$(command -v hdfs)\" = \"$TC_SHARED/hadoop/bin/hdfs\" ]"; echo $?)

echo; echo "pass: $PASS   fail: $FAILN"
if [ "$FAILN" = 0 ]; then echo "REHEARSAL-PASS: the install, its 9 faults, the busy marker, the user tool, the seed tool and the self-test pass; $PASS checks"; else echo "REHEARSAL-FAIL"; exit 1; fi
