#!/usr/bin/env bash
# Run in Cloud Shell: make the nodes' Google internal names resolve to the mesh, restart Hadoop, run a test job.
set -euo pipefail
Z=us-central1-a
M=tdx-lab; W=tdx-lab-worker
n() { gcloud compute ssh "$1" --zone=$Z --command="bash ~/mesh-names-node.sh $2 $3"; }
echo "== send the node script"
gcloud compute scp mesh-names-node.sh $M:~/ --zone=$Z
gcloud compute scp mesh-names-node.sh $W:~/ --zone=$Z
echo "== checks"
n $M pre master
n $W pre worker
echo "== stop Hadoop (worker first, then master)"
n $W stop worker
n $M stop master
echo "== map the nodes' internal names to the mesh"
n $M names master
n $W names worker
echo "== start Hadoop (master first, then worker)"
n $M start master
sleep 15
n $W start worker
sleep 40
echo "== report"
n $M report master
echo "== test job: Pi example (containers must launch over the mesh)"
n $M pitest master
echo "== counters"
n $M counters master
n $W counters worker
echo "== done"
