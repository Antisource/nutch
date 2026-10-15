# m511w: baby step 5.1.1, part 3: the reserved window. The signed wrapper on both nodes, the pass condition shown on the real HDFS, and the way back

Order (see the runbook in the chat): the master reserves the cluster (tc-busy.sh start), m511-window.sh open master, the test key is copied to the worker,
m511-window.sh open worker, m511-demo.sh on the master (7 attacks, all refused), m511-window.sh close on both nodes, tc-busy.sh stop.
While a window is open a node is NOT the measured stack: the jar and core-site.xml are changed, and everything is restored and proved by close.
cluster-mode.sh and wrapper-jar.sh are the repository's own, unchanged. M511Tools (forge and verify) is for the demonstration only: it is not part of the wrapper or the job.
Unpacking drops the executable flag: run  chmod +x ~/m511wkit/m511w/ops/attested/*.sh  after unpacking.
