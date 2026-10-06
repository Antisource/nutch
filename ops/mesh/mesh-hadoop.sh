#!/usr/bin/env bash
# Run in Cloud Shell: move Hadoop onto the WireGuard mesh and close the ordinary network to Hadoop ports.
set -euo pipefail
Z=us-central1-a
M=tdx-lab; W=tdx-lab-worker
n() { gcloud compute ssh "$1" --zone=$Z --command="bash ~/mesh-hadoop-node.sh $2 $3"; }
echo "== send the node script"
gcloud compute scp mesh-hadoop-node.sh $M:~/ --zone=$Z
gcloud compute scp mesh-hadoop-node.sh $W:~/ --zone=$Z
echo "== checks on both nodes"
n $M pre master
n $W pre worker
echo "== stop Hadoop (worker first, then master)"
n $W stop worker
n $M stop master
echo "== point the names hadoop-master and hadoop-worker at the mesh"
n $M hosts master
n $W hosts worker
echo "== apply the firewall (undoes itself in 150 seconds unless confirmed)"
n $M fw master
n $W fw worker
echo "== confirm we can still log in, then keep the firewall"
n $M keep master
n $W keep worker
echo "== start Hadoop (master first, then worker)"
n $M start master
sleep 15
n $W start worker
sleep 40
echo "== report: master"
n $M report master
echo "== report: worker"
n $W report worker
echo "== done"
