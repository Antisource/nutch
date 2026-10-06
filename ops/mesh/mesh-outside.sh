#!/usr/bin/env bash
# Run in Cloud Shell: show that Hadoop traffic over the ordinary network is refused, and that the firewall counted the drops.
set -uo pipefail
Z=us-central1-a
M=tdx-lab; W=tdx-lab-worker
MVPC=10.128.0.2; WVPC=10.128.0.5; MMESH=10.10.0.1; WMESH=10.10.0.2
drops() { gcloud compute ssh "$1" --zone=$Z --command="sudo iptables -L INPUT -v -n -x | grep multiport | awk '{print \$1}'" 2>/dev/null | tail -1; }
echo "== send the test script"
gcloud compute scp mesh-outside-node.sh $M:~/ --zone=$Z
gcloud compute scp mesh-outside-node.sh $W:~/ --zone=$Z
MB="$(drops $M)"; WB="$(drops $W)"
echo "Hadoop-port drop rule before: master $MB packets, worker $WB packets"
echo "== from the worker to the master"
gcloud compute ssh $W --zone=$Z --command="bash ~/mesh-outside-node.sh worker $MVPC $MMESH"
echo "== from the master to the worker"
gcloud compute ssh $M --zone=$Z --command="bash ~/mesh-outside-node.sh master $WVPC $WMESH"
MA="$(drops $M)"; WA="$(drops $W)"
echo "== Hadoop-port drop rule after"
echo "master: $MB -> $MA packets (these were the worker's tries over the ordinary network)"
echo "worker: $WB -> $WA packets (these were the master's tries over the ordinary network)"
echo "== done"
