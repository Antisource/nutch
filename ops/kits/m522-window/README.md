# m522w: baby step 5.2.2, the doorman for the TEST mesh wg1 (a short run on the real nodes; the production mesh wg0 and Hadoop are not touched)

What it shows: each node of the policy table makes a fresh node bundle (its WireGuard public key and requested mesh address, bound by a hardware quote made now); the doorman (the Java code of the jar: binding, policy table,
freshness, genuine quote, reference file) decides; a ROGUE node with a fake quote is refused; only the admitted nodes become peers of the test mesh wg1 (10.20.0.0/24, UDP 51821), which runs the node's own attested key;
the build proves the key in use, that the peers are exactly the admitted ones, that each node reaches the other over wg1, that the peers have handshaken, and that wg0 is unchanged; then wg1 is taken down again.
No jar is swapped, no daemon is restarted and no core-site.xml changes: the measured stack is checked unchanged before and after.
Files: mesh-admit.sh (admit | build | down, run in Cloud Shell), wg1-node-up.sh and wg1-node-down.sh (run on the nodes by mesh-admit.sh), mesh-peers-m522.txt (the policy table), reference-measurements-m521.txt (the reference),
testdata/ (the two real node bundles, for the rehearsal), mesh-admit-rehearse.sh (29 checks, 15 faults), m522w-selftest.sh. node-attest.sh is not in this kit: it is already on both nodes (~/m522ckit, the capture kit).
Unpacking drops the executable flag: run  chmod +x ops/attested/*.sh  after unpacking.
