#!/usr/bin/env bash
# The end of a session, from Cloud Shell, BEFORE the machines are wiped: collect the state of both VMs (without secrets), bundle it,
# scan the bundle for secrets, print its fingerprint and the next steps. Read-only on the VMs.
#   ops/rebuild/end-of-session.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
Z="${ZONE:-us-central1-a}"; M="${MASTER:-tdx-lab}"; W="${WORKER:-tdx-lab-worker}"
D="$(date -u +%Y%m%d-%H%M)"; B="$HOME/evidence-vm-state-$D"
die() { printf 'END-OF-SESSION-STOP: %s\n' "$*" >&2; exit 1; }
[ ! -e "$B" ] || die "$B already exists"
mkdir -p "$B" || die "cannot create $B"
for spec in "$M:master" "$W:worker"; do n="${spec%%:*}"; r="${spec##*:}"
  echo "== $r ($n)"
  gcloud compute scp "$REPO/ops/attested/vm-state-collect.sh" "$n:~/vm-state-collect.sh" --zone="$Z" --quiet || die "could not copy the collection script to $n"
  gcloud compute ssh "$n" --zone="$Z" --quiet --command="rm -rf ~/vm-state-$r ~/vm-state-$r.tar.gz; bash ~/vm-state-collect.sh $r" | tail -4 || die "the collection failed on $n"
  gcloud compute scp "$n:~/vm-state-$r.tar.gz" "$B/" --zone="$Z" --quiet || die "could not fetch the archive from $n"
done
(cd "$B" && mkdir master worker && tar xzf vm-state-master.tar.gz -C master && tar xzf vm-state-worker.tar.gz -C worker && find . -type f ! -name SHA256SUMS | sort | xargs sha256sum > SHA256SUMS)
echo "== scan for secrets (counts only; every count must be 0)"
echo "private-key blocks: $(grep -rIlE 'BEGIN [A-Z ]*PRIVATE KEY' "$B" | wc -l)"
echo "WireGuard key values: $(grep -rIlE '(Private|Preshared)Key *= *[A-Za-z0-9+/]{40,}' "$B" | wc -l)"
echo "credential-like values: $(grep -rIliE '(password|secret|token|api[_-]?key)["'"'"' ]*[=:]["'"'"' ]*[A-Za-z0-9_+/=-]{16,}' "$B" | wc -l)"
(cd "$HOME" && tar czf "evidence-vm-state-$D.tar.gz" "evidence-vm-state-$D" && sha256sum "evidence-vm-state-$D.tar.gz" | tee "evidence-vm-state-$D.sha256")
echo "files: $(grep -c . "$B/SHA256SUMS") listed, $(find "$B" -type f ! -name SHA256SUMS | wc -l) on disk"
echo "NEXT: if all three counts are 0, download evidence-vm-state-$D.tar.gz from Cloud Shell to your laptop and check its SHA-256 there (keep the value above)."
echo "      Also download any job file you still need (see docs/session-start.md), and keep a second copy of your evidence folder."
