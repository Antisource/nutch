#!/usr/bin/env bash
# Run in Cloud Shell: set up a two-node WireGuard mesh (master 10.10.0.1, worker 10.10.0.2).
set -euo pipefail
Z=us-central1-a
M=tdx-lab; W=tdx-lab-worker
MVPC=10.128.0.2; WVPC=10.128.0.5; MMESH=10.10.0.1; WMESH=10.10.0.2
echo "== send the node scripts"
gcloud compute scp wg-node-prep.sh wg-node-up.sh $M:~/ --zone=$Z
gcloud compute scp wg-node-prep.sh wg-node-up.sh $W:~/ --zone=$Z
echo "== install tools and create keys (public keys only come back)"
PUB_M="$(gcloud compute ssh $M --zone=$Z --command='bash ~/wg-node-prep.sh' | tail -1)"
PUB_W="$(gcloud compute ssh $W --zone=$Z --command='bash ~/wg-node-prep.sh' | tail -1)"
echo "master public key length ${#PUB_M}, worker public key length ${#PUB_W} (both must be 44)"
[ "${#PUB_M}" -eq 44 ] && [ "${#PUB_W}" -eq 44 ] || { echo "ABORT: unexpected key length" >&2; exit 1; }
echo "== bring up wg0"
gcloud compute ssh $M --zone=$Z --command="bash ~/wg-node-up.sh $MMESH $PUB_W $WVPC $WMESH"
gcloud compute ssh $W --zone=$Z --command="bash ~/wg-node-up.sh $WMESH $PUB_M $MVPC $MMESH"
echo "== test the mesh"
gcloud compute ssh $M --zone=$Z --command="ping -c 3 -W 2 $WMESH; sudo wg show wg0 | grep -E 'interface|peer|endpoint|allowed|handshake|transfer'"
gcloud compute ssh $W --zone=$Z --command="ping -c 3 -W 2 $MMESH; sudo wg show wg0 | grep -E 'interface|peer|endpoint|allowed|handshake|transfer'"
echo "== done"
