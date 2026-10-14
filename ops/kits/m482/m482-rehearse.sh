#!/usr/bin/env bash
# Rehearsal of m482-pre.sh and m482-post.sh away from the cluster, with stand-ins for the tools that need a TDX guest,
# root or Hadoop (sudo, xxd, uname, jps, yarn, hdfs, iptables, grub-editenv, quote ...). Run: bash m482-rehearse.sh
# The real helper scripts (rtmr3-extend.sh, treehash.sh, rtmr3_replay.py, mesh-hadoop-node.sh, check-unchanged-m482.sh) run UNCHANGED.
set -uo pipefail
K="$(cd "$(dirname "$0")" && pwd)"
PASS=0; FAILN=0
chk() { if [ "$2" = 0 ]; then PASS=$((PASS+1)); echo "  pass: $1"; else FAILN=$((FAILN+1)); echo "  FAIL: $1"; fi; }
POLSHA=""; JOBSHA=""

# ---- build a fake node: $1 = role ----
mknode() {
  ROLEX="$1"; T="$(mktemp -d)"; export T
  export HOME="$T/home"; export M482_OUT="$HOME/m482"; mkdir -p "$HOME" "$T/bin" "$T/fake" "$M482_OUT"
  F="$T/fake"; export F
  # fake world
  mkdir -p "$HOME/hadoop/bin" "$HOME/hadoop/etc/hadoop" "$HOME/hadoop/logs" "$T/jdk/bin" "$T/jetc" "$HOME/tc-policy"
  echo hadoop-binary > "$HOME/hadoop/bin/hadoop"; echo conf > "$HOME/hadoop/etc/hadoop/core-site.xml"; echo log > "$HOME/hadoop/logs/x.log"
  echo java > "$T/jdk/bin/java"; echo sec > "$T/jetc/java.security"
  printf 'policy-json-bytes\n' > "$HOME/tc-policy/policy.json"; printf 'whatever\n' > "$HOME/tc-policy/policy.json.sha256"
  POLSHA="$(sha256sum "$HOME/tc-policy/policy.json" | cut -c1-64)"
  mkdir -p "$HOME/m481/patched/runtime/deploy/bin" "$HOME/m481/patched/ops/attested" "$HOME/m481/patched/seeds"
  head -c 3000 /dev/urandom > "$HOME/m481/patched/runtime/deploy/apache-nutch-1.22.job"; echo bin > "$HOME/m481/patched/runtime/deploy/bin/crawl"
  echo drv > "$HOME/m481/patched/ops/run-crawl.sh"; echo seed > "$HOME/m481/patched/seeds/seed.txt"
  JOBSHA="$(sha256sum "$HOME/m481/patched/runtime/deploy/apache-nutch-1.22.job" | cut -c1-64)"
  # old chain from the last boot (must be moved aside)
  mkdir -p "$HOME/measured"; echo old > "$HOME/measured/jdk.manifest"; printf 'jdk\tdead\t00\t11\n' > "$HOME/rtmr3-events.tsv"
  mkdir -p /tmp/attested-audit; echo log > /tmp/attested-audit/a.log   # the wrapper logs that a reboot clears
  # measurement files
  export TDX_MEAS="$T/meas"; mkdir -p "$TDX_MEAS"; for r in mrtd rtmr0 rtmr1 rtmr2 rtmr3; do head -c 48 /dev/zero > "$TDX_MEAS/$r:sha384"; done
  export RTMR3_PATH="$TDX_MEAS/rtmr3:sha384"
  export JDK_DIR="$T/jdk" JAVA_ETC="$T/jetc" HADOOP_DIR="$HOME/hadoop" M482_NUTCH_DIR="$HOME/m481/patched" M482_CCEL="$T/ccel"; echo ccel > "$T/ccel"
  export M482_GRUB_CFG="$T/grub.cfg"; echo "menuentry 'Ubuntu, with Linux 6.17.0-1022-gcp' {" > "$M482_GRUB_CFG"
  export M482_FW_BACKUP="$T/iptables-after-reboot-m482" M482_SLEEP=0 M482_QUOTE="$T/bin/fakequote"
  [ "$ROLEX" = master ] && export M482_HOSTNAME=tdx-lab || export M482_HOSTNAME=tdx-lab-worker
  # fake state
  echo "6.17.0-1022-gcp" > "$F/kernel"
  printf 'saved_entry=Advanced options for Ubuntu>Ubuntu, with Linux 6.8.0-1067-gcp\nnext_entry=\n' > "$F/grubenv"
  : > "$F/apps"; : > "$F/pending-fw"
  if [ "$ROLEX" = master ]; then printf '100 NameNode\n101 ResourceManager\n' > "$F/daemons"; else printf '200 DataNode\n201 NodeManager\n' > "$F/daemons"; fi
  # ---- stand-ins ----
  cat > "$T/bin/sudo" <<'EOS'
#!/bin/bash
if [ "$1" = dd ]; then for a in "$@"; do case "$a" in of=*) tgt="${a#of=}";; esac; done
  if [ "${tgt:-}" = "$RTMR3_PATH" ]; then python3 -c '
import sys, hashlib
t = sys.argv[1]; d = sys.stdin.buffer.read(48); old = open(t, "rb").read(48)
open(t, "wb").write(hashlib.sha384(old + d).digest())' "$tgt"; exit $?; fi; fi
exec "$@"
EOS
  cat > "$T/bin/xxd" <<'EOS'
#!/bin/bash
if [ "$1" = "-r" ]; then python3 -c 'import sys; sys.stdout.buffer.write(bytes.fromhex("".join(sys.stdin.read().split())))'
else python3 -c 'import sys; print(open(sys.argv[2],"rb").read().hex())' "$@"; fi
EOS
  echo '#!/bin/bash
[ "$1" = "-r" ] && cat "$F/kernel" || /bin/uname "$@"' > "$T/bin/uname"
  echo '#!/bin/bash
{ cat "$F/daemons"; echo "999 Jps"; }' > "$T/bin/jps"
  cat > "$T/bin/hadoopd" <<'EOS'
#!/bin/bash
# usage: hadoopd <yarn|hdfs> --daemon <start|stop> <name>
act="$3"; case "$4" in namenode) n=NameNode;; resourcemanager) n=ResourceManager;; datanode) n=DataNode;; nodemanager) n=NodeManager;; esac
if [ "$act" = start ]; then [ -e "$F/nostart" ] && exit 1; echo "$RANDOM $n" >> "$F/daemons"; else [ -e "$F/nostop" ] && exit 0; grep -v " $n\$" "$F/daemons" > "$F/d2"; mv "$F/d2" "$F/daemons"; fi
EOS
  cat > "$T/bin/yarn" <<'EOS'
#!/bin/bash
if [ "$1" = application ]; then echo "Total number of applications (application-types: [], states: [RUNNING] and tags: []):$(wc -l < "$F/apps")"; cat "$F/apps"; exit 0; fi
exec "$(dirname "$0")/hadoopd" yarn "$@"
EOS
  echo '#!/bin/bash
exec "$(dirname "$0")/hadoopd" hdfs "$@"' > "$T/bin/hdfs"
  cat > "$T/bin/iptables" <<'EOS'
#!/bin/bash
S="$F/ipt"
case "$1" in
  -S) cat "$S" ;;
  -F) grep -v -- '^-A INPUT' "$S" > "$F/i2"; mv "$F/i2" "$S" ;;
  -A) shift; echo "-A $*" >> "$S" ;;
  -P) sed -i "s/^-P $2 .*/-P $2 $3/" "$S" ;;
  *) echo "iptables stand-in: unsupported $*" >&2; exit 2 ;;
esac
EOS
  echo '#!/bin/bash
cat "$F/ipt"' > "$T/bin/iptables-save"
  echo '#!/bin/bash
echo "$*" >> "$F/systemd-run.txt"' > "$T/bin/systemd-run"
  echo '#!/bin/bash
[ "$1" = list ] && cat "$F/grubenv"' > "$T/bin/grub-editenv"
  echo '#!/bin/bash
sed -i "s|^next_entry=.*|next_entry=$1|" "$F/grubenv"' > "$T/bin/grub-reboot"
  echo '#!/bin/bash
[ -e "$F/nowg" ] && exit 1; exit 0' > "$T/bin/ip"
  echo '#!/bin/bash
echo "interface: wg0"' > "$T/bin/wg"
  echo '#!/bin/bash
echo "no server running"; exit 1' > "$T/bin/tmux"
  cat > "$T/bin/keytool" <<'EOS'
#!/bin/bash
[ -e "$F/fewcerts" ] && n=100 || n=121
for i in $(seq 1 $n); do echo "Certificate fingerprint (SHA-256): $(printf '%064x' $i)"; done
EOS
  cat > "$T/bin/fakequote" <<'EOS'
#!/bin/bash
[ -e "$F/quotefail" ] && { echo "quote failed" >&2; exit 1; }
IN="$1"; OUT="$2"; sha512sum "$IN" | cut -d' ' -f1 | python3 -c 'import sys; sys.stdout.buffer.write(bytes.fromhex(sys.stdin.read().strip()))' > "$OUT.reportdata"
python3 -c '
import sys
rt = open(sys.argv[1], "rb").read(48); rd = open(sys.argv[2], "rb").read(64)
q = bytearray(1024); q[520:568] = rt; q[568:632] = rd
open(sys.argv[3], "wb").write(bytes(q))' "$RTMR3_PATH" "$OUT.reportdata" "$OUT"
echo "quote written: $OUT"
EOS
  chmod +x "$T"/bin/*
  export PATH="$T/bin:$PATH"
  fw_default > "$F/ipt"; FW_BACKUP="$T/fwb0" FW_KEEP_FILE="$T/keep0" bash "$K/mesh-hadoop-node.sh" fw "$ROLEX" >/dev/null 2>&1   # the pre-reboot firewall comes from the REAL fw step
  # fix: the stand-in sudo for "sudo grep" etc. just execs
  for f in rtmr3-extend.sh treehash.sh mesh-hadoop-node.sh quote.sh; do chmod +x "$K/$f" 2>/dev/null; done
}
fw_default() { printf '%s\n' "-P INPUT ACCEPT" "-P FORWARD ACCEPT" "-P OUTPUT ACCEPT"; }
pre()  { bash "$K/m482-pre.sh" "$@"; }
post() { bash "$K/m482-post.sh" "$@"; }
# simulate the reboot: kernel stays 6.17, daemons gone, firewall back to default, RTMR3 zero, one-time boot consumed
reboot_sim() { : > "$F/daemons"; fw_default > "$F/ipt"; head -c 48 /dev/zero > "$RTMR3_PATH"; sed -i 's|^next_entry=.*|next_entry=|' "$F/grubenv"; rm -f "$HOME/quote-"*; }

for ROLE in master worker; do
  echo "=== 2. happy path, $ROLE: pre, reboot, post"
  mknode "$ROLE"
  A=(); [ "$ROLE" = master ] && A=("$JOBSHA")
  out="$(pre "$ROLE" "$POLSHA" "${A[@]}" 2>&1)"; rc=$?; echo "$out" | tail -4 | cut -c1-150
  chk "pre $ROLE exits 0 and prints M482-PRE-OK" $([ $rc = 0 ] && grep -q 'M482-PRE-OK' <<<"$out"; echo $?)
  chk "pre $ROLE armed exactly one boot into 6.17 and kept the pin" $(grep -qx 'next_entry=Advanced options for Ubuntu>Ubuntu, with Linux 6.17.0-1022-gcp' "$F/grubenv" && grep -q '^saved_entry=.*6.8.0-1067' "$F/grubenv"; echo $?)
  chk "pre $ROLE stopped the daemons" $([ ! -s "$F/daemons" ]; echo $?)
  chk "pre $ROLE saved the firewall, the wrapper logs and a bundle" $([ -s "$M482_OUT/pre-$ROLE/iptables-S.txt" ] && [ -s "$M482_OUT/pre-$ROLE/tmp-attested-audit.tar.gz" ] && [ -s "$M482_OUT/evidence-m482-pre-$ROLE.tar.gz" ]; echo $?)
  chk "pre $ROLE bundle was made after the last line (it holds the M482-PRE-OK line)" $(tar -xzOf "$M482_OUT/evidence-m482-pre-$ROLE.tar.gz" "pre-$ROLE/summary.txt" | grep -q M482-PRE-OK; echo $?)
  reboot_sim
  out="$(post "$ROLE" "$POLSHA" 2>&1)"; rc=$?; echo "$out" | tail -12 | cut -c1-160
  chk "post $ROLE exits 0 and prints M482-POST-OK" $([ $rc = 0 ] && grep -q 'M482-POST-OK' <<<"$out"; echo $?)
  want=6; [ "$ROLE" = master ] && want=9
  chk "post $ROLE measured $want events" $([ "$(wc -l < "$HOME/rtmr3-events.tsv")" = $want ]; echo $?)
  names="$(cut -f1 "$HOME/rtmr3-events.tsv" | tr '\n' ' ')"
  exp="jdk java-settings java-ca-fingerprints hadoop-code hadoop-conf tc-policy "; [ "$ROLE" = master ] && exp="${exp}nutch-deploy driver seeds "
  chk "post $ROLE event names and order: $names" $([ "$names" = "$exp" ]; echo $?)
  chk "post $ROLE old chain moved aside, not deleted" $(grep -q dead "$M482_OUT/old-chain-$ROLE/rtmr3-events.tsv" && [ -f "$M482_OUT/old-chain-$ROLE/measured/jdk.manifest" ]; echo $?)
  chk "post $ROLE firewall equals the one before the reboot and was kept" $(cmp -s "$M482_OUT/pre-$ROLE/iptables-S.txt" "$M482_OUT/post-$ROLE/iptables-S.after.txt" && [ -e /tmp/fw-keep ]; echo $?)
  chk "post $ROLE wrote the firewall backup under the NEW name, with the state before the step" $(grep -q 'INPUT ACCEPT' "$M482_FW_BACKUP"; echo $?)
  chk "post $ROLE replay: chain consistent, quote MATCH, REPORTDATA YES" $(grep -q 'chain consistent: True' "$M482_OUT/post-$ROLE/replay.txt" && grep -q -- '-> MATCH$' "$M482_OUT/post-$ROLE/replay.txt" && grep -q 'REPORTDATA = SHA-512 of this log: YES' "$M482_OUT/post-$ROLE/replay.txt"; echo $?)
  chk "post $ROLE check-unchanged says ALL-UNCHANGED for $want components" $(grep -q "ALL-UNCHANGED ($want components checked)" "$M482_OUT/post-$ROLE/check-unchanged.txt"; echo $?)
  chk "post $ROLE started 2 daemons" $([ "$(wc -l < "$F/daemons")" = 2 ]; echo $?)
  chk "post $ROLE bundle holds the final line and 6 kit helpers" $(tar -xzOf "$HOME/evidence-m482-$ROLE.tar.gz" "evidence-m482-$ROLE/post/summary.txt" | grep -q M482-POST-OK && [ "$(tar -tzf "$HOME/evidence-m482-$ROLE.tar.gz" | grep -c '/kit/')" -ge 8 ]; echo $?)
  cp "$HOME/rtmr3-events.tsv" "/tmp/m482-events-$ROLE.tsv"
  # tamper after the measurement: the check must see it
  echo "x" >> "$HOME/tc-policy/policy.json"
  NUTCH_DIR="$M482_NUTCH_DIR" POLICY_DIR="$HOME/tc-policy" RTMR3_LOG="$HOME/rtmr3-events.tsv" bash "$K/check-unchanged-m482.sh" > "$T/cu.txt" 2>&1; rc=$?
  chk "a change to policy.json after the measurement is reported (tc-policy CHANGED, exit 1)" $([ $rc = 1 ] && grep -q '^tc-policy CHANGED' "$T/cu.txt"; echo $?)
done
t1="$(awk -F'\t' '$1=="tc-policy"{print $2}' /tmp/m482-events-master.tsv)"; t2="$(awk -F'\t' '$1=="tc-policy"{print $2}' /tmp/m482-events-worker.tsv)"
echo "=== 3. both nodes measure the same policy folder"; chk "the tc-policy digest is equal on master and worker" $([ -n "$t1" ] && [ "$t1" = "$t2" ]; echo $?)

echo "=== 4. faults: the scripts must stop, and must not have started or changed more than they should"
fault_pre() { # name role setup-cmd expect-text
  mknode "$2"; A=(); [ "$2" = master ] && A=("$JOBSHA"); eval "$3"
  out="$(pre "$2" "${PS:-$POLSHA}" "${AA:-${A[@]:-}}" 2>&1)"; rc=$?
  chk "pre fault: $1 -> stops ($4)" $([ $rc != 0 ] && grep -q "$4" <<<"$out"; echo $?)
  unset PS AA
}
fault_pre "wrong machine" master 'export M482_HOSTNAME=tdx-lab-worker' 'belongs to'
fault_pre "wrong policy" worker 'PS=$(printf "%064d" 0)' 'pinned one'
fault_pre "wrong job" master 'AA=$(printf "%064d" 1)' 'job is'
fault_pre "a Hadoop application is running" master 'echo "application_1791873617149_0099   crawl   MAPREDUCE" > "$F/apps"' 'applications are running'
fault_pre "a one-time boot is already pending" worker 'sed -i "s|^next_entry=.*|next_entry=something|" "$F/grubenv"' 'already pending'
fault_pre "the 6.17 menu entry is missing" worker ': > "$M482_GRUB_CFG"' 'expected 1'
fault_pre "the boot pin is not on 6.8" worker 'sed -i "s/6.8.0-1067/6.17.0-1022/" "$F/grubenv"' 'not on a 6.8'
fault_pre "the firewall is not the mesh firewall" worker 'fw_default > "$F/ipt"' 'not the mesh firewall'
fault_pre "wg0 is down" worker 'touch "$F/nowg"' 'wg0 is not up'
mknode worker; mkdir -p "$M482_OUT/pre-worker"; out="$(pre worker "$POLSHA" 2>&1)"; rc=$?; chk "pre fault: the saved state exists from an earlier run -> stops, changes nothing" $([ $rc != 0 ] && grep -q 'exists already' <<<"$out" && grep -q '^next_entry=$' "$F/grubenv"; echo $?)
mknode worker; touch "$F/nostop"; out="$(pre worker "$POLSHA" 2>&1)"; rc=$?; chk "pre fault: a daemon does not stop -> stops and says how to cancel the armed boot" $([ $rc != 0 ] && grep -q 'unset next_entry' <<<"$out"; echo $?)

fault_post() { # name role setup-cmd expect-text expect-no-daemons(0/1)
  mknode "$2"; A=(); [ "$2" = master ] && A=("$JOBSHA"); pre "$2" "$POLSHA" "${A[@]:-}" >/dev/null 2>&1; reboot_sim; eval "$3"
  out="$(post "$2" "${PS:-$POLSHA}" 2>&1)"; rc=$?
  chk "post fault: $1 -> stops ($4)" $([ $rc != 0 ] && grep -q "$4" <<<"$out"; echo $?)
  [ "$5" = 1 ] && chk "   and no daemon was started" $([ ! -s "$F/daemons" ]; echo $?)
  unset PS
}
fault_post "the one-time boot did not happen (kernel 6.8)" worker 'echo 6.8.0-1069-gcp > "$F/kernel"' 'expected 6.17' 1
fault_post "RTMR3 is not zero" worker 'head -c 48 /dev/urandom > "$RTMR3_PATH"' 'not zero' 1
fault_post "wrong policy" worker 'PS=$(printf "%064d" 0)' 'not the pinned' 1
fault_post "the firewall differs from the one before" worker 'printf "%s\n" "-A INPUT -j ACCEPT" >> "$M482_OUT/pre-worker/iptables-S.txt"' 'differs from the one saved' 1
fault_post "no saved state" worker 'rm -rf "$M482_OUT/pre-worker"' 'missing' 1
fault_post "the CA store has 100 certificates, not 121" worker 'touch "$F/fewcerts"' 'expects 121' 1
fault_post "the quote fails" worker 'touch "$F/quotefail"' 'quote failed' 1
fault_post "the firewall backup name exists already" worker 'touch "$M482_FW_BACKUP"' 'must not be overwritten' 1
fault_post "an old-chain folder exists" worker 'mkdir -p "$M482_OUT/old-chain-worker"' 'exists already' 1
fault_post "wrong machine" master 'export M482_HOSTNAME=tdx-lab-worker' 'belongs to' 1
fault_post "the master's build lacks seeds" master 'rm -rf "$HOME/m481/patched/seeds"' 'lacks' 1
fault_post "a helper tool is not executable (unpacking drops the flag)" worker 'chmod -x "$K/treehash.sh"' 'not executable' 1
fault_post "a daemon cannot start" worker 'touch "$F/nostart"' 'starting the daemons failed' 0

rm -rf /tmp/attested-audit /tmp/fw-keep
echo
echo "pass: $PASS   fail: $FAILN"
if [ "$FAILN" = 0 ]; then echo "REHEARSAL-PASS: pre and post run for both roles; $PASS checks pass, including all the faults"; else echo "REHEARSAL-FAIL"; exit 1; fi
