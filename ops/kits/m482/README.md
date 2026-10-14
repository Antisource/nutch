# m482: baby step 4.8.2 (re-measure after the reboot), kit

Order: m482-pre.sh on the worker, then on the master; reboot both; m482-post.sh on the master, then on the worker.
Every script stops at the first problem. The pre script does not reboot. The post script starts no daemon before the
measurement is proven (replay equals the quote, every digest recomputed).

Files copied byte for byte from branch tip 4ae2015 (blob ids in rehearsal-transcript.txt): rtmr3-extend.sh, treehash.sh,
quote.sh, rtmr3_replay.py, mesh-hadoop-node.sh. check-unchanged-m482.sh is the tip's check-unchanged.sh plus one case (tc-policy)
and one comment line. m482-pre.sh, m482-post.sh and m482-rehearse.sh are new.
Unpacking drops the executable flag: run  chmod +x ~/m482kit/m482/*.sh  after unpacking.
