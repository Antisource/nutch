# m521w: the live window of step 5.2.1: the wrapper with the admission of keys by their quote, on the real VMs

What it shows, on the master and the worker, with the keys and the hardware quotes of THIS window:
1. each node's signing service makes its key in memory and gets its quote; before anything restarts, the node's own bundle must be ADMITTED by its fresh live quote (the Intel chain, the signatures and the reference file);
2. the admission is switched on in core-site.xml (13 settings; the reference file is pinned by its SHA-256, so a changed file stops the wrapper);
3. (m521-live.sh, on the master) a real file is written and read back through the wrapper; the key list's audit file shows each key of the window ADMITTED with the registers that were checked;
   the new folder, copied with the plain client, verifies offline with only admitted keys; a ROGUE signing service with a fake quote puts its bundle into the live key list: the list REFUSES it and writes why,
   the honest file still reads, and the rogue bundle is removed again; and one edit on the live quote flips each decision (an edited reference refuses it, mrtd out of the enforce list admits it, a flipped bit is refused).
Everything is off by default; the window is the only place where it is on. As in every window, the node is NOT the measured stack until `close` (ADR-029).

Order (the runbook is in the message that delivered this kit): self-test on the master (m521w-selftest.sh), reserve the cluster, worker prep is not needed (no crawl), open master, open worker,
exchange the bundles in Cloud Shell (m513-keylist-sync.sh, unchanged), Intel check of the two quotes on the laptop, m521-live.sh on the master, close master, close worker, release.
Unpacking drops the executable flag: run  chmod +x ops/attested/*.sh  after unpacking.
Files: m521-window.sh (open|close ROLE), m521-live.sh, fake-quote.sh (plays the rogue key), M521Tools.java (the offline tree verifier with admission), reference-measurements-m521.txt (the reference file),
testdata/ (the two real bundles of run 15, for the rehearsals), the rehearsals (m521-window-rehearse.sh 47 checks, m521-live-rehearse.sh 22 checks, m513-keylist-sync-rehearse.sh 16 checks) and the tools of the earlier window
kit that are unchanged (cluster-mode.sh, wrapper-jar.sh, quote.sh, verify-binding.sh, audit.sh, m513_bundle_extract.py, m513-keylist-sync.sh).
