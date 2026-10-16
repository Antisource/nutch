#!/usr/bin/env bash
# Milestone 5, step 5.1.3: run in CLOUD SHELL, after the window is open on BOTH nodes. It takes the key bundle that each node's signing service made
# (~/tc-keyservice/*.attestkey), checks each one (the key id is the hash of the public key, the quote's REPORTDATA is the SHA-512 of the key statement,
# and attest/verify-binding.sh says MATCH), puts both bundles into the key list of both nodes (~/tc-keys/list), checks them there with the node's own jar,
# and keeps the two quotes for the Intel signature check on your laptop (go-tdx-guest's check). It changes nothing else.
#   bash m513-keylist-sync.sh [WORKDIR]       default ~/keylist-sync (must not exist yet)
# Test hooks (rehearsal only): M513_GCLOUD (a stand-in for gcloud), M513_ZONE, M513_MASTER, M513_WORKER.
set -uo pipefail
GC="${M513_GCLOUD:-gcloud}"; Z="${M513_ZONE:-us-central1-a}"; MASTER="${M513_MASTER:-tdx-lab}"; WORKER="${M513_WORKER:-tdx-lab-worker}"
W="${1:-$HOME/keylist-sync}"; KIT="$(cd "$(dirname "$0")" && pwd)"
bad=0
say()  { echo "$*" | tee -a "$W/summary.txt"; }
ok()   { say "   ok:   $*"; }
no()   { say "   FAIL: $*"; bad=$((bad+1)); }
stop() { say "M513-SYNC-STOP: $*"; exit 1; }
[ -e "$W" ] && { echo "M513-SYNC-STOP: $W exists already; remove it or give another folder" >&2; exit 1; }
for t in xxd sha512sum python3; do command -v "$t" >/dev/null || { echo "M513-SYNC-STOP: $t is missing here (attest/verify-binding.sh needs it)" >&2; exit 1; }; done
mkdir -p "$W/bundles" "$W/quotes" || exit 1
say "m513-keylist-sync: $(date -u +%FT%TZ)"
JAR='~/hadoop/share/hadoop/common/lib/attested-hdfs.jar'
say "== take the bundles of the two services"
for N in "$MASTER" "$WORKER"; do
  mkdir -p "$W/bundles/$N"
  $GC compute scp "$N:~/tc-keyservice/*.attestkey" "$W/bundles/$N/" --zone="$Z" >"$W/scp-$N.log" 2>&1 || stop "cannot fetch the bundle of $N (is its window open and its service running?)"
  n=$(ls "$W/bundles/$N"/TDX-*.attestkey 2>/dev/null | wc -l)
  [ "$n" = 1 ] && ok "$N: one TDX bundle ($(basename "$(ls "$W/bundles/$N"/TDX-*.attestkey)" .attestkey))" || stop "$N has $n TDX bundles in ~/tc-keyservice, expected exactly 1"
done
MB="$(ls "$W/bundles/$MASTER"/TDX-*.attestkey)"; WB="$(ls "$W/bundles/$WORKER"/TDX-*.attestkey)"
[ "$(basename "$MB")" != "$(basename "$WB")" ] && ok "the two machines have two different keys" || stop "both machines report the same key"
say "== check each bundle here: the quote's REPORTDATA against the key statement, twice"
for p in "$MASTER:$MB" "$WORKER:$WB"; do
  N="${p%%:*}"; B="${p#*:}"
  python3 "$KIT/m513_bundle_extract.py" "$B" "$W/quotes/$N" >"$W/extract-$N.txt" 2>&1 && grep -q '^EXTRACT-MATCH' "$W/extract-$N.txt" && ok "$N: the quote's REPORTDATA equals the SHA-512 of the key statement" || no "$N: the quote does not match its statement (see $W/extract-$N.txt)"
  bash "$KIT/verify-binding.sh" "$W/quotes/$N/statement.txt" "$W/quotes/$N/quote.bin" 2>&1 | grep -q '^MATCH' && ok "$N: attest/verify-binding.sh says MATCH" || no "$N: attest/verify-binding.sh does not say MATCH"
  mv "$W/quotes/$N/quote.bin" "$W/quotes/quote-$N.bin" 2>/dev/null; mv "$W/quotes/$N/statement.txt" "$W/quotes/statement-$N.txt" 2>/dev/null
done
[ $bad -eq 0 ] || stop "a bundle does not match its quote: nothing was put into any key list"
say "== put both bundles into the key list of both nodes, and check them there with the node's own jar"
for N in "$MASTER" "$WORKER"; do
  $GC compute ssh "$N" --zone="$Z" --command='mkdir -p ~/tc-keys/list' >"$W/ssh-$N.log" 2>&1 || stop "cannot reach $N"
  $GC compute scp "$MB" "$WB" "$N:~/tc-keys/list/" --zone="$Z" >>"$W/scp-$N.log" 2>&1 || stop "cannot put the bundles into the key list of $N"
  for B in "$MB" "$WB"; do
    id="$(basename "$B" .attestkey)"
    $GC compute ssh "$N" --zone="$Z" --command="java -cp $JAR org.apache.nutch.attested.AttestedKeyTool bundle-verify ~/tc-keys/list/$id.attestkey" >"$W/verify-$N-$id.txt" 2>&1 && grep -q '^BUNDLE-OK' "$W/verify-$N-$id.txt" && ok "$N: its key list holds $id and the node's own jar verifies it" || no "$N: $id does not verify there (see $W/verify-$N-$id.txt)"
  done
done
{ cd "$W/quotes" && sha256sum quote-*.bin statement-*.txt > SHA256SUMS; }
tar czf "$W/../keylist-sync-quotes.tar.gz" -C "$W" quotes bundles summary.txt 2>/dev/null && ok "the quotes and the bundles are packed: $W/../keylist-sync-quotes.tar.gz"
if [ $bad -eq 0 ]; then
  say "M513-SYNC-OK (both bundles are in both key lists; the two quotes bind their keys; next: the Intel signature check of the quotes on your laptop)"
  say "   laptop: download $W/quotes/quote-$MASTER.bin and quote-$WORKER.bin, then:  & \"\$HOME\\go\\bin\\check.exe\" -in <quote-file> -inform bin -get_collateral=true -check_crl=true"
else
  say "M513-SYNC-FAILED ($bad): see the FAIL lines above"
fi
[ $bad -eq 0 ]
