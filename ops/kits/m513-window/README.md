# m513w: step 5.1.3, part 3: the window with the REAL signing key (one crawl with signing services, hardware quotes and a key list)

Order (the runbook is in the chat): self-test of this kit on the master (a read-only block); reserve the cluster; on the worker m513c-worker.sh prep (BEFORE the window's open);
m513-window.sh open master, then worker (each starts that node's signing service, which makes its key in memory and gets the hardware quote for it); in Cloud Shell m513-keylist-sync.sh
(exchanges the two key bundles and checks the quotes' binding; the Intel signature check of the quotes is done on the laptop with go-tdx-guest's check); on the master, in the same session,
m513c-run.sh run15 on (the crawl, then the offline verification of the whole output against the key list, a negative control with a partial list, and the service's audit log); on the worker
m513c-worker.sh pack run15 (during the window); m513-window.sh close worker and master (each stops its service: the key disappears); in Cloud Shell m513c-analyze.sh run15.
Files: m513-window.sh, m513c-run.sh, m513c-analyze.sh, m513-keylist-sync.sh and their rehearsals; m513c-worker.sh (the worker script of the kit m512c, version 2, pointed at the 5.1.3 window folder: its pack takes the task logs during the window, so its pack branch
runs on the cluster for the first time); quote.sh and verify-binding.sh (the repository's attest/ scripts, unchanged); m513_bundle_extract.py (takes a key bundle apart); M513Tools.java (the offline verifier with
the key list); M513TreeGen.java and M513ToolsTest.java (tests and rehearsals); cluster-mode.sh, wrapper-jar.sh, audit.sh (as in the earlier kits); rehearsal/FakeHdfsCli.java (a stand-in for the rehearsal).
The signing service is part of the wrapper jar of step 5.1.3 (org.apache.nutch.attested.KeyService); it runs as the same user as the fetcher in this first window (a separate user is a later hardening step).
Unpacking drops the executable flag: run  chmod +x ~/m513wkit/m513w/ops/attested/*.sh  after unpacking.
