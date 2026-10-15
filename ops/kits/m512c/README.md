# m512ckit: the combined crawl (15 October 2026): one crawl with signing and folder binding ON and REQUIRED, the job of step 5.1.2, in a reserved window

Order: reserve the cluster; on the worker `m512c-worker.sh prep` (BEFORE the window's open); open the window on both nodes with the kit m512-window; on the master, in tmux, `m512c-run.sh RUN on`
(the crawl, then the offline verification of the whole output with the public key only); on the worker `m512c-worker.sh pack RUN` (during the window); close the window on both nodes; release the cluster;
in Cloud Shell `m512c-analyze.sh RUN`. Run 14 ran exactly this way. Contents: m512c-run.sh (master), m512c-worker.sh (worker), m512c-analyze.sh (Cloud Shell, read-only), their rehearsals, M512Tools.java (the offline
verification, from the window kit), M512TreeGen.java (rehearsal only), audit.sh (the repository's own), and the updated analysis tools nn_audit_compare.py and records_expected.py with their tests (the same files are committed under ops/attested/).

History of the worker script. Version 1 (m512c-worker-v1.sh) is what ran for run 14 (`prep`, `pack`). Its pack held only the two wrapper log folders, while the analysis (like the earlier runs' packs) expects the YARN task
logs (userlogs) too; the analysis of run 14 therefore had one finding, "no task logs from the worker". The task logs could not be added afterwards: the NodeManager deletes the old container logs when it restarts, which
the window's close does (the version 2 `repack` ran on the cluster and found no application logs from the window). Version 2 (m512c-worker.sh) packs the task logs during the window and refuses to pack without them; it was rehearsed
(m512c-worker-rehearse.sh, 24 checks, which fail when version 1's pack command is put back) and its `repack` was tried on the cluster, but its `pack` has not run there yet.
Self-test on the master. The tests and the three rehearsals were first run only in the sandbox. Run on the master, the rehearsal of the run script failed at once, because the master has HADOOP_HOME set and
the rehearsal let the script read the real, plain core-site.xml; the rehearsal now clears the Hadoop environment variables and points the script at its fake home (the other files are unchanged).
Unpacking drops the executable flag: run  chmod +x ops/attested/*.sh  after unpacking.
