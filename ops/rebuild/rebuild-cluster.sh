#!/usr/bin/env bash
# Rebuild the lab cluster from nothing, from Cloud Shell. Run from a clone of the repository:
#   ops/rebuild/rebuild-cluster.sh [--dry-run] [STAGE ...]
# Stages, in order (default: all of them):
#   provision   create the two TDX VMs if they do not exist (same machine type, image and internal addresses as before); not needed when the VMs are there
#   ship        copy this repository's ops/ folder to both VMs
#   base        packages, host names, Hadoop 3.4.3, its settings                                    (node-base.sh)
#   hadoop      format the NameNode, start the daemons, wait for the cluster, create /user/<you>, run Pi (node-hadoop.sh)
#   mesh        the WireGuard mesh, Hadoop onto the mesh, the firewall, names (the scripts in ops/mesh); skipped if the mesh is already up
#   build       the two snapshot libraries and the crawler job from git                              (node-wrapper.sh)
#   wrapper     the wrapper's jar on both nodes, then the wrapped configuration                      (node-wrapper.sh)
#   suite       the test suite with its pass table                                                   (node-suite.sh)
#   status      what runs where
# A stage that has already succeeded is safe to run again. Settings (environment): PROJECT, ZONE, MASTER, WORKER,
# MASTER_VPC, WORKER_VPC, REF.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
PROJECT="${PROJECT:-training-custody}"; Z="${ZONE:-us-central1-a}"; M="${MASTER:-tdx-lab}"; W="${WORKER:-tdx-lab-worker}"
MVPC="${MASTER_VPC:-10.128.0.2}"; WVPC="${WORKER_VPC:-10.128.0.5}"
DRY=0; [ "${1:-}" = "--dry-run" ] && { DRY=1; shift; }
STAGES=("$@"); [ ${#STAGES[@]} -gt 0 ] || STAGES=(provision ship base hadoop mesh build wrapper suite)
KIT='~/rebuild-kit/ops/rebuild'
say() { printf '\n######## %s\n' "$*"; }
die() { printf 'REBUILD-STOP: %s\n' "$*" >&2; exit 1; }
run() { if [ "$DRY" = 1 ]; then echo "  [dry run] $*"; else "$@"; fi; }
node() { local n="$1"; shift; run gcloud compute ssh "$n" --zone="$Z" --quiet --command="$*" || die "a command on $n failed: $*"; }
EV="MASTER_VPC=$MVPC WORKER_VPC=$WVPC"
# Is the WireGuard mesh already there? Prints up (on both nodes, and they reach each other), none (on neither) or half.
mesh_probe() { gcloud compute ssh "$1" --zone="$Z" --quiet --command="echo \"wg0=\$(ip link show wg0 > /dev/null 2>&1 && echo 1 || echo 0) ping=\$(ping -c 1 -W 2 $2 > /dev/null 2>&1 && echo 1 || echo 0)\"" 2> /dev/null | tail -1; }
mesh_state() {
  [ "$DRY" = 1 ] && { echo "none|dry run"; return; }
  a="$(mesh_probe "$M" 10.10.0.2)"; b="$(mesh_probe "$W" 10.10.0.1)"
  d="$M: ${a:-no answer}; $W: ${b:-no answer}"
  if [ "$a" = "wg0=1 ping=1" ] && [ "$b" = "wg0=1 ping=1" ]; then echo "up|$d"
  elif [ "${a%% *}" = "wg0=0" ] && [ "${b%% *}" = "wg0=0" ]; then echo "none|$d"
  else echo "half|$d"; fi
}
for st in "${STAGES[@]}"; do
  case "$st" in
  provision)
    say "provision"
    for spec in "$M:$MVPC" "$W:$WVPC"; do n="${spec%%:*}"; ip="${spec##*:}"
      if [ "$DRY" = 0 ] && gcloud compute instances describe "$n" --zone="$Z" --project="$PROJECT" > /dev/null 2>&1; then echo "  $n exists; left alone"
      else run gcloud compute instances create "$n" --project="$PROJECT" --zone="$Z" --machine-type=c3-standard-4 --confidential-compute-type=TDX --maintenance-policy=TERMINATE --image-family=ubuntu-2204-lts --image-project=ubuntu-os-cloud --boot-disk-size=50GB --private-network-ip="$ip" || die "could not create $n (is $ip free, and is TDX available in $Z?)"; fi
    done
    for n in "$M" "$W"; do
      for i in $(seq 1 24); do run gcloud compute ssh "$n" --zone="$Z" --quiet --command=true > /dev/null 2>&1 && break; [ "$DRY" = 1 ] && break; sleep 10; done
    done ;;
  ship)
    say "ship the kit"
    run tar czf /tmp/rebuild-kit.tgz -C "$REPO" ops || die "could not pack the kit"
    for n in "$M" "$W"; do
      run gcloud compute scp /tmp/rebuild-kit.tgz "$n:~/rebuild-kit.tgz" --zone="$Z" --quiet || die "could not copy the kit to $n"
      node "$n" "rm -rf ~/rebuild-kit && mkdir ~/rebuild-kit && tar xzf ~/rebuild-kit.tgz -C ~/rebuild-kit"
    done ;;
  base)
    say "base install"
    node "$M" "$EV bash $KIT/node-base.sh master"; node "$W" "$EV bash $KIT/node-base.sh worker" ;;
  hadoop)
    say "Hadoop up"
    node "$M" "bash $KIT/node-hadoop.sh master format || true"
    node "$M" "bash $KIT/node-hadoop.sh master start"; [ "$DRY" = 1 ] || sleep 15
    node "$W" "bash $KIT/node-hadoop.sh worker start"
    node "$M" "bash $KIT/node-hadoop.sh master wait"
    node "$M" "bash $KIT/node-hadoop.sh master init-hdfs"; node "$M" "bash $KIT/node-hadoop.sh master pitest" ;;
  mesh)
    say "the mesh (the existing scripts in ops/mesh; they expect $M at $MVPC and $W at $WVPC)"
    res="$(mesh_state)"; st="${res%%|*}"; MESH_DETAIL="${res#*|}"
    case "$st" in
      up) echo "  the mesh is already up on both nodes and they reach each other ($MESH_DETAIL); skipping" ;;
      half) die "the mesh is half there ($MESH_DETAIL). Check that both machines answer. On a node that has wg0 but cannot reach its peer, run 'sudo wg-quick down wg0' (or fix the peer by hand). Then run this stage again." ;;
      *) ( cd "$REPO/ops/mesh" && run bash mesh-up.sh && run bash mesh-hadoop.sh && run bash mesh-names.sh ) || die "the mesh stage failed; the firewall undoes itself after 150 seconds unless confirmed" ;;
    esac ;;
  build)
    say "build the libraries and the job"
    node "$M" "bash $KIT/node-wrapper.sh deps" && node "$M" "bash $KIT/node-wrapper.sh build" ;;
  wrapper)
    say "the wrapper on both nodes"
    node "$M" "bash $KIT/node-wrapper.sh jar"
    run gcloud compute scp "$M:~/attested-hdfs.jar" /tmp/attested-hdfs.jar --zone="$Z" --quiet || die "could not fetch the jar"
    run gcloud compute scp /tmp/attested-hdfs.jar "$W:~/attested-hdfs.jar" --zone="$Z" --quiet || die "could not send the jar"
    node "$W" "bash $KIT/node-wrapper.sh install-jar ~/attested-hdfs.jar"
    node "$M" "bash $KIT/node-wrapper.sh mode"; node "$W" "bash $KIT/node-wrapper.sh mode" ;;
  suite) say "the suite"; node "$M" "bash $KIT/node-suite.sh" ;;
  status) say "status"; node "$M" "bash $KIT/node-hadoop.sh master status"; node "$W" "bash $KIT/node-hadoop.sh worker status" ;;
  *) die "unknown stage '$st' (stages: provision ship base hadoop mesh build wrapper suite status)" ;;
  esac
done
echo; echo "REBUILD-STAGES-DONE: ${STAGES[*]}"
