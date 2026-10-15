# m512w: baby step 5.1.2, part 3: the reserved window. The wrapper with signing and folder binding on both nodes, the folder binding shown on the real HDFS, and the way back

Order (see the runbook in the chat): the master reserves the cluster (tc-busy.sh start), m512-window.sh open master, m512-window.sh open worker (the test key of step 5.1.1 is
already on both nodes), m512-demo.sh on the master (honest renames and ten attacks), m512-window.sh close on both nodes, tc-busy.sh stop.
While a window is open a node is NOT the measured stack: the jar and core-site.xml are changed (the measured settings plus five: signing on and required, test keys allowed,
folder binding on and required); everything is restored and proved by close. The window state is in ~/m512w on each node.
cluster-mode.sh and wrapper-jar.sh are the repository's own, unchanged. M512Tools (forge and verify the whole tree offline) is for the demonstration only: it is not part of the wrapper or the job.
The demonstration makes one small folder tree under /user/<you>/m512-demo-<time> and removes it at the end.
Unpacking drops the executable flag: run  chmod +x ~/m512wkit/m512w/ops/attested/*.sh  after unpacking.
