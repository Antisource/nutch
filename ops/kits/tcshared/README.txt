SHARED, MEASURED CLUSTER CLIENT  (/opt/tc-shared)             set up 14 October 2026

What this is
  A read-only copy of the Hadoop client, its configuration (with the wrapper as the cluster's file system), the wrapper's jar
  and the measured crawl job. It is byte for byte the stack that was measured on 14 October (the install proved it by recomputing
  the measured digests on the copy). Nobody can change it except root, so what you run here is what the quote covers.

Your first five minutes
  source /opt/tc-shared/bin/tc-env.sh          # puts hdfs, yarn and hadoop on your PATH, pointing at the shared copy
  tc-check.sh                                  # one command: is my setup working? it ends with TC-CHECK-OK
  tc-seed.sh my-seeds.txt run1                 # puts your seed file into /user/<you>/seeds-run1 WITH its record
  tc-busy.sh start "crawl run1 with receipts"  # take the cluster (rule 4); tc-busy.sh stop when you are done
  cd /opt/tc-shared/nutch && ops/run-crawl.sh /user/<you>/seeds-run1 /user/<you>/crawl-run1
      (the same script and parameters as every earlier crawl; copy it to your own folder if you need to add -D options,
       for example the three receipt settings; the job and the cluster stay the measured ones)

The rules (the ones you asked for)
  1. Only the measured job runs on the cluster. Do not run another job file. A new job means a new build and a new measurement.
  2. Run tc-busy.sh start before you start and tc-busy.sh stop when you finish. Look at tc-busy.sh status before you start.
  3. Nobody runs anything during someone else's measurement, a timing pair, or a reboot. If the marker is taken, do not start.
  4. Clean up your own HDFS folder (/user/<you>) when you are done; do not touch other people's.
  5. Do not log in as another person, and do not change anything outside your home folder and /user/<you>.

Things to know
  - The marker is an agreement, not a lock the system enforces: Hadoop's simple authentication lets anyone use any name.
    Per-user folders are bookkeeping, not security.
  - The receipt settings are inputs, not changes to the job: -D tc.receipts.enabled=true -D tc.nonce=<random hex>
    -D tc.policy.file=/home/rishabsdp17/tc-policy/policy.json  (the tasks read the policy on the worker, where that path exists).
  - hdfs dfsadmin refuses the wrapper's file system. For admin commands add  -D fs.hdfs.impl=org.apache.hadoop.hdfs.DistributedFileSystem
  - The wrapper writes its logs to /tmp/attested-audit and /tmp/attested-records; those folders are shared and writable for
    everybody. The audit of a run compares the logs of that run, so the owner of the measurement moves old logs aside before a run.
  - Your jobs run in containers on the worker as the cluster's own user; your files in HDFS belong to you.
