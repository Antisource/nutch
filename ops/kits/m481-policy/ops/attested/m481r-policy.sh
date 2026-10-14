#!/usr/bin/env bash
# Milestone 4, baby step 4.8.1, part 2a: the collection policy file that the teammate's receipts commit to.
# Her script (make_policy.py, with three small files of her custody package, at her commit 841c1d3) reads the JDK's CA store
# and writes policy.json. The emitter recomputes the certificate-set fingerprint at start-up and refuses to run if it differs,
# so the file must be built on the master and then be checked on EVERY node against that node's own JDK.
#
#   bash ops/attested/m481r-policy.sh build  [POLICY_DIR]               (master; default POLICY_DIR=~/tc-policy)
#   bash ops/attested/m481r-policy.sh verify POLICY_SHA256 [POLICY_DIR] (every node: same file, anchors match this JDK)
# Nothing outside POLICY_DIR (and a temp folder) is touched. An existing policy.json is never overwritten.
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1   # keep the kit folder clean (no __pycache__)
HERE="$(cd "$(dirname "$0")" && pwd)"; KIT="$(cd "$HERE/../.." && pwd)"; SRC="$KIT/policy-src"
MODE="${1:?usage: $0 build [DIR] | verify POLICY_SHA256 [DIR]}"
if [ "$MODE" = build ]; then DIR="${2:-$HOME/tc-policy}"; EXP=""; else EXP="${2:?usage: $0 verify POLICY_SHA256 [DIR]}"; DIR="${3:-$HOME/tc-policy}"; fi
case "$DIR" in /*) ;; *) DIR="$PWD/$DIR" ;; esac
bad=0; ok() { echo "   ok:   $*"; }; no() { echo "   FAIL: $*"; bad=$((bad+1)); }; stop() { echo "M481P-POLICY-STOP: $*"; exit 1; }
fp() { sha256sum "$1" | cut -c1-64; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
echo "m481r-policy $MODE: $(date -u +%FT%TZ) on $(hostname)   dir=$DIR"
echo "== tools and sources"
command -v python3 >/dev/null && ok "python3" || stop "python3 is missing"
command -v keytool >/dev/null && ok "keytool: $(java -version 2>&1 | head -1)" || stop "keytool (the JDK) is missing"
( cd "$KIT" && sha256sum -c m481r-src.sha >"$T/src.log" 2>&1 ) && ok "her four source files are the pinned ones ($(grep -c ': OK' "$T/src.log") of $(grep -c . "$KIT/m481r-src.sha"))" || { cat "$T/src.log"; stop "the source files differ from the pinned ones"; }
mk() { ( cd "$SRC" && python3 ccbot/make_policy.py --from-jdk "$1" --deployment cluster ) 2>&1; }
anchors() { python3 -c "import json,sys; d=json.load(open(sys.argv[1]))['trust_anchors']; print(d['anchor_set_sha256'], d['count'])" "$1"; }
if [ "$MODE" = build ]; then
  echo "== build"
  [ -e "$DIR/policy.json" ] && stop "$DIR/policy.json exists already; it is never overwritten (a measured file): move it away on purpose if you mean to replace it"
  mk "$T/a.json" >"$T/a.log" 2>&1 || { cat "$T/a.log"; stop "make_policy.py failed"; }; ok "built: $(tail -1 "$T/a.log")"
  mk "$T/b.json" >/dev/null 2>&1; cmp -s "$T/a.json" "$T/b.json" && ok "a second build gives identical bytes (deterministic)" || no "two builds differ"
  [ $bad -eq 0 ] || { echo "M481P-POLICY-BUILD-FAILED ($bad)"; exit 1; }
  umask 022; mkdir -p "$DIR" && cp "$T/a.json" "$DIR/policy.json" && chmod 644 "$DIR/policy.json" && chmod 755 "$DIR" && fp "$DIR/policy.json" >"$DIR/policy.json.sha256" || stop "could not write $DIR"
  ok "written: $DIR/policy.json ($(stat -c %s "$DIR/policy.json") bytes, mode $(stat -c %a "$DIR/policy.json"))"
  echo "   policy sha256:     $(fp "$DIR/policy.json")"
  echo "   anchor set / count: $(anchors "$DIR/policy.json")"
  echo "M481P-POLICY-BUILD-OK"
else
  echo "== verify"
  [ -f "$DIR/policy.json" ] || stop "$DIR/policy.json not found"
  [ "$(fp "$DIR/policy.json")" = "$EXP" ] && ok "policy.json is the expected file (${EXP:0:16}...)" || no "policy.json has sha256 $(fp "$DIR/policy.json" | cut -c1-16), expected ${EXP:0:16}"
  [ "$(stat -c %a "$DIR/policy.json")" -ge 644 ] && ok "readable by the NodeManager's user (mode $(stat -c %a "$DIR/policy.json"))" || no "mode $(stat -c %a "$DIR/policy.json") is too restrictive"
  mk "$T/here.json" >"$T/here.log" 2>&1 || { cat "$T/here.log"; stop "make_policy.py failed on this node"; }
  A="$(anchors "$DIR/policy.json")"; H="$(anchors "$T/here.json")"
  [ "$A" = "$H" ] && ok "the policy's certificate set equals this node's JDK store ($H)" || no "the policy has anchors '$A' but this node's JDK gives '$H': the emitter would refuse to start here"
  [ $bad -eq 0 ] && { echo "M481P-POLICY-VERIFY-OK"; exit 0; } || { echo "M481P-POLICY-VERIFY-FAILED ($bad)"; exit 1; }
fi
