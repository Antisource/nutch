# Milestone 4: storage integrity (handoff Stage B)

Date: 7 October 2026. Times are UTC. Status: **steps 4.1 to 4.6 done; steps 4.7 and 4.8 open** (section 4); the recon for step 4.7 is done (section 21).
Written when step 4.3 closed and extended when step 4.4 closed (section 18), when step 4.5 closed (section 19) and when step 4.6 closed (section 20); the recon for step 4.7 is section 21. It is extended as the later steps close.

## 1. Goal

The handoff's Stage B (items 4 to 6): hash chunks on write and verify on read, with metadata taken from records; task records and job manifests; the staging folder, and the job and configuration digests. The pass condition of each step is in section 4.
This report covers steps 4.1 to 4.3: every file written through the wrapper is hashed when it is closed, a record of it is kept next to it, and every read through the wrapper is checked against that record.
Naming: steps are numbered 4.k. During the work the steps were called B0 to B5; section 4 maps the old labels to the numbers.

## 2. Background (first principles)

- **A chunk and its fingerprint.** A file is cut into chunks of a fixed size (here 16,384 bytes). Each chunk gets a fingerprint, a SHA-256 hash: 32 bytes that change if any single byte of the chunk changes.
- **A Merkle root.** The chunk fingerprints are combined in pairs, then the results in pairs, up to one 32-byte number, the root. The tree is the one of RFC 6962 (Certificate Transparency): a leaf is the hash of a chunk with a 0x00 byte in front, an inner node is the hash of its two children with a 0x01 byte in front, and a tree of n leaves splits at the largest power of two below n. One root stands for the whole file, and later it lets someone prove that one chunk belongs to it.
- **A record.** The file's length, its chunk size, the fingerprint of every chunk and the root. Here the record is kept in a small hidden file next to the data file, named `.NAME.attested` (a **companion file**). Hadoop does the same with its `.NAME.crc` checksum files.
- **Verifying on read.** When a file is opened, its record is read and the length is compared. Then each chunk is hashed as it is read and compared with the record before any of its bytes are handed on. A mismatch stops the read with a verification error, so the task fails instead of using changed data.
- **Why next to the file.** A companion file moves with its folder when the folder is renamed, which Hadoop does constantly while committing output.
- **What it does not give.** The records are not signed (a later stage). Someone who rewrites a file and its record together passes. Section 13 lists the limits.
- **An analogy.** The record is a tamper sticker on a sealed parcel. Plain HDFS tools can open the parcel without knowing about the sticker; the wrapper checks the sticker every time it hands the parcel on.

## 3. How the design was decided

Step 4.1 read what run 6 left in storage and how Nutch and Hadoop write their files (section 5). Three decisions followed (see [decisions.md](decisions.md), ADR-021 to ADR-023):

1. The record is kept next to the file as a companion file (ADR-021).
2. A record is made when each file is closed, by the wrapper, tagged with the task attempt id; the commit hook is not the source (ADR-022). This is a new question for the mentor (question 13, to be added to the list sent on 6 October); it has not been asked yet.
3. A file without a record is allowed but logged for now; the end state is to refuse it (ADR-023).

Everything the mentor may change sits behind a setting (section 6), and the record format is versioned (`ATTEST01`), so signing can add fields later instead of replacing the format.

## 4. Steps and status

| Step | Name | Handoff item | Depends on | Status | Result |
|---|---|---|---|---|---|
| 4.1 | Recon of what the crawl writes and reads | 4 | step 3.6 | Done | Section 5 |
| 4.2 | Hash every written file and record its Merkle root (observe only) | 4 | 4.1 | Done | Run 7; commit `686c277ae` (sections 9, 15) |
| 4.3 | Keep a record next to each file and verify every read against it | 4 | 4.2 | Done | Run 8 and the tamper test; commit `67c56f5a7` (sections 10, 11, 15) |
| 4.4 | Run Hadoop's file-system contract tests against the wrapper | 4 | none | Done | Section 18; the wrapper fix `26da09f1c` and the tests `e72d1ed05` (section 15) |
| 4.5 | Answer length, existence and listings from records, never from storage | 4 | 4.3 | Done | Baby steps: 4.5.1 metadata from records (`4deed2b33`); 4.5.2 the NameNode's audit log turned on and compared with the wrapper's log (`4ebf7570f`; the mentor, 7 October; ADR-026); section 19 |
| 4.6 | Check the job file and configuration digests at the start of each task | 6 | 4.2 | Done | Changed by the mentor on 7 October (ADR-027): a task hashing its own job file is not a security check, so the digests are checked where the NodeManager reads the files. Baby steps: 4.6.1 the wrapper's classes on Hadoop's classpath on both nodes (`fcffad09d`); 4.6.2 both lookups set as final in the site configuration, with a switch back to the plain configuration (`fcffad09d`, and `bef3a6452` for the audit tools); 4.6.3 the NodeManager's read is checked against its record and a swapped file is refused (`9ef0f405d`, `28c811ff4`); section 20 |
| 4.7 | Task records and job manifests; speculative execution off | 5 | 4.3 | Open | Depends on the answer to question 13 and on the naming agreement with teammate S. Recon done on 9 October (section 21): what the wrapper sees of task attempts, and a failed attempt provoked on purpose |
| 4.8 | Milestone report; re-measure after a reboot (ADR-020) | | 4.4 to 4.7 | Open | Firewall rules must be saved first; nothing unmeasured is described as measured (ADR-029); the crawl that follows is run as a pair with an unwrapped control in the same hour (ADR-028) |

Old working labels: B0 = 4.4, B1 = 4.2, B2 = 4.3, B3 = 4.5, B4 = 4.6, B5 = 4.7.

Order of the open steps (after the mentor's answers of 7 October, ADR-026; the whole plan is in [milestone-plan.md](milestone-plan.md)): the numeric order: 4.6 (done on 9 October), then 4.7, then 4.8. Step 4.5 was done before 4.6 because the two do not depend on each other, and the wrapper's code should be finished before it is put on Hadoop's classpath, where every later change means a redeployment and a restart of daemons.

## 5. Recon findings

Source: the listing taken after run 6, the wrapper's 111 logs of that run, and the Nutch and Hadoop source.

| Finding | Evidence | Consequence |
|---|---|---|
| The crawl's output is tiny: 54 files, 333,948 bytes in all; 32 files under 1 KB, 22 between 1 KB and 1 MB, none above 1 MB; the largest is about 81 KB | the listing after run 6 | The chunk size must be a setting, and tests need a small one (16 KiB) so that the larger files span several chunks |
| Most wrapper traffic is job staging, not data: 270 of 364 creates, 27 uploads of the 134 MB job file | the wrapper's logs | Staging is its own class; it is the code supply chain (handoff item 6) |
| Two writing patterns. Committer-managed: the crawl database, the link database and the generate output (written under `_temporary`, then renamed). Direct: content, crawl_fetch, parse_data, parse_text, crawl_parse, the WARC files, robotstxt and crawldiagnostics (created at their final path) | creates without renames in the logs; `FetcherOutputFormat`, `ParseOutputFormat` and `WarcOutputFormat` use the final output path | A record cannot be made only at commit; it is made when each file is closed |
| The commit hook set by configuration does not reach every output format: `ParseOutputFormat` creates its own `FileOutputCommitter` | the source | The wrapper is the one place that sees every file (ADR-022) |
| Renames are frequent: 37 into the crawl database and 15 into the link database | the logs | A record must follow its file |
| Hadoop 3.4.3 commits with algorithm 2 by default | `mapred-default.xml`; Nutch's configuration files do not override it; the cluster's own `mapred-site.xml` was not read | A failed job can leave partial output in place |

## 6. What was built

Classes in `src/java/org/apache/nutch/attested/` (all inside the job file):

| Class | Role |
|---|---|
| `MerkleHasher` | Streaming Merkle root of a byte stream (RFC 6962 tree); keeps only a few hashes unless asked to keep every chunk's hash |
| `HashingOutputStream` | Passes every byte to the real stream and to the hasher; at close it writes the record |
| `AttestedRecords` | The local record log, one file per program in `/tmp/attested-records` (step 4.2's output) |
| `AttestedSidecar` | The companion file: format `ATTEST01` (8 bytes, 4-byte chunk size, 8-byte length, 32-byte root, 4-byte chunk count, then 32 bytes per chunk); finding, reading and checking it |
| `VerifyingInputStream` | Reads whole chunks, hashes each one, compares with the record, then serves the bytes; supports seek and positioned reads |
| `AttestedHdfsFileSystem` (changed) | Hashes on create; keeps the companion file; verifies on open and openFile; moves the companion file on rename; deletes it with the file; drops it when a file is appended to, truncated or concatenated; hides companion files from its listings; sends `copyFromLocalFile` through its own create so that uploads are hashed |

Settings (job configuration; defaults in the code):

| Setting | Default | Meaning |
|---|---|---|
| `attested.hash.enabled` | true | hash every file written through the wrapper |
| `attested.hash.chunk.size` | 16384 | chunk size in bytes |
| `attested.records.dir` | `/tmp/attested-records` | where the local record log is written |
| `attested.sidecar.enabled` | true | keep a companion file next to each file |
| `attested.verify.reads` | true | verify reads against the record |
| `attested.verify.missing` | warn | a file without a record: `allow`, `warn` (log it) or `fail` |

The audit log (`/tmp/attested-audit`) gains new information: each OPEN line says `verify=ok`, `verify=missing`, `verify=skipped`, `verify=off` or `verify=bypassed`, and a refused read writes a `VERIFY-FAIL` line. The start-up (INIT) line shows the settings in force.

Tools in `ops/attested/`:

| Tool | Role |
|---|---|
| `merkle_root.py` | An independent implementation of the same root, written recursively, used to cross-check the Java code and to re-hash stored files |
| `records_expected.py` | Replays the records and the audit log's renames and deletes and compares the result with a listing of storage; reports files without a record, with a wrong length, appended to, vanished, or without a companion file |
| `records_verify.sh` | Re-hashes every file with `merkle_root.py` through the plain HDFS client and compares with the recorded root |
| `verify_summary.py` | Counts how every read was verified; lists reads without a record; reports verification failures |
| `tamper-demo.sh`, `tamper_verify.py` | The tamper test on the real cluster and its proof from the audit logs (section 11) |

The wrapper's unverified read paths are listed in section 13.

## 7. Tests

The fake-HDFS tests were first run on a development machine with the Hadoop 3.4.1 client libraries, then on the master (Java 11, Hadoop 3.4.3, real HDFS), and again with the wrapper classes taken from the built job file.

| Step | fake HDFS | MapReduce (local) | hashing | real HDFS | cross-check |
|---|---|---|---|---|---|
| 4.2 | 47 of 47 | 8 of 8 | 18 of 18 | 46 of 46 | Java and Python agree on 9 sizes |
| 4.3 | 85 of 85 | 12 of 12 | 18 of 18 | 84 of 84 | Java and Python agree on 9 sizes |

New checks in step 4.3 (38 on the real HDFS): a record next to every file for all sizes (0, 1, 16,383, 16,384, 16,385, 100,000 and 3 MB plus 17 bytes); reads, openFile reads, seeks and positioned reads; a changed byte (earlier chunks still read, the changed chunk fails, the original bytes put back verify again); a shortened and a lengthened file; four kinds of damaged record; a missing record under each policy; verification switched off; renames, folder renames, deletes, overwrites, copies and appends; and a MapReduce job that fails on a changed input and completes again once the bytes are put back. One check states a known limit as a test: a file and its record rewritten together are accepted.

## 8. The jobs

| Run | Job file | Entries | Difference from the run before |
|---|---|---|---|
| 5 (measured) | `bbd30ad90d357ca1` | 1029 | |
| 6 | `ddc415a5d87c9e6b` | 1033 | four wrapper entries (step 3.3) |
| 7 | `8fdd7cdadd6a7e11` | 1036 | seven entries more than run 5: the wrapper's folder and six classes; nothing else differs |
| 8 | `a092d5fab91d4b73` | 1041 | five new classes and three changed classes against run 7; nothing else differs |
| step 4.4 | `dea47c6d41729bef` | 1041 | used only for the contract tests, not for a crawl; three changed classes against run 8's job, nothing added or removed (section 18) |

Runs 7 and 8 were built in the scratch clone `~/m3-build` (not measured; the folder keeps its Milestone 3 name). **Run 6's job file was not kept.** A saved copy meant to be run 6's job was already the rebuilt job (fingerprint `1828836b2be42a3d`, 1036 entries); the likely cause is that the build step ran twice, which was not verified. Only the fingerprint and the comparison outputs of run 6 remain, so later jobs are compared with the measured run 5 job. The copy is kept as `job-not-run6-already-new-code.job` in the evidence folder.

## 9. Run 7 (step 4.2): hashing, observe only

| Item | Result |
|---|---|
| Date and duration | 7 Oct, 07:25:08 to 07:35:51 (10 min 43 s); run 6 took 10 min 42 s |
| Crawl | 3 iterations, no failures; okhttp 19, old plugin 0; 22 worker task logs list okhttp, 0 the old plugin |
| Storage audit | `AUDIT-CLEAN`; the listing grew from 1182 to 1369 paths |
| Records | 54 files left under `crawl-run7`, 54 with a matching record |
| Independent re-hash | 54 verified, 0 mismatched |
| Start-up lines | 300 in 111 programs; hashing on, chunk 16384 in all 300 |
| Volume hashed | 391 records and 3,498.8 MB; of these, job staging 297 files and 3,498.4 MB (the 134.8 MB job file uploaded 27 times) |
| Pages | the same 8 URLs as run 6 (`SAME-PAGES`); 7 of 8 identical; `www.zyte.com` differs (their site redeployed: `dpl_6K3M...` to `dpl_J25tWhywpx6QetrVxFP7wgdX7PPC`); the live site then served the newer one |
| Crawl database | 259 URLs, 249 unfetched, 8 fetched, 2 redirects, as in run 6 |
| Evidence | `evidence-run7.tar.gz`, `evidence-run7-audit.tar.gz` |

The records of this step were local log files only; nothing was enforced.

## 10. Run 8 (step 4.3): verification on

| Item | Result |
|---|---|
| Date and duration | 7 Oct, 09:16:02 to 09:26:59 (10 min 57 s), about 14 seconds more than run 7 (one run; not conclusive) |
| Crawl | 3 iterations, no failures; okhttp 19, old plugin 0; 22 worker task logs (from the 27 applications) list okhttp, 0 the old plugin, 0 a verification failure |
| Storage audit | `AUDIT-CLEAN`: the listing grew from 1377 to 1699 paths; 322 added, 0 removed, 0 changed, all explained by the wrapper's log (the companion files are among them) |
| Records | 54 of 54 files have a matching record; none without a companion file |
| Independent re-hash | 54 verified, 0 mismatched |
| How reads were verified | 157 opens: 156 verified, 1 without a record (the seed file `seeds-run8/seed.txt`, put there by the command-line client, on the allowed list), 0 verification failures; no read used a bypassed path |
| Start-up lines | 300 in 111 programs; sidecar, verify and policy `warn` in all 300 |
| Pages | the same 8 URLs as run 7; 7 of 8 identical; `www.zyte.com` differs again (deployment id `dpl_J25t...` to `dpl_2HdZ2H4ohADyL4QEFsb3pBbNMGvT`); the live site at 12:06 served the newer one |
| Crawl database | 259 URLs, 249 unfetched, 8 fetched, 2 redirects (read in the tamper test's control step) |
| Files fetched from storage for the evidence | 18 data files (9 named `.warc.gz`; the others include the `.cdx.gz` index files), each with a hidden companion file; the command-line wildcard fetch copies hidden files too |
| Evidence | `evidence-run8.tar.gz`, `evidence-run8-audit.tar.gz` |

The worker's 56 kept applications include earlier ones; only the 27 started after 09:15 belong to run 8. A first count over all kept logs showed 44 for okhttp; counting only the applications started since 09:15 gave 22, which fits run 7's logs still being kept.

## 11. The tamper test

**The test.** One byte of one real data file, the crawl database part `crawl-run8/crawldb/current/part-r-00000/data` (25,681 bytes, fingerprint `106b0314d29c1212`), is changed with the plain HDFS client, keeping the length (byte 12,840, inside chunk 0). A reader job (`nutch readdb -stats`) then runs through the wrapper. The original bytes are put back at the end, and the script restores them on exit even when a step fails.

| Attempt | Script | Client-side result | Proof from the audit logs |
|---|---|---|---|
| 1 | first version (`49cd6eb3...`) | `FAIL`: it looked for the error text in the client's console | `tamper_verify.py` on the saved logs: `TAMPER-PROVEN` (job `job_1791273797493_0123`) |
| 2 | committed version (`bbb2892e...`) | `PASS` (job `job_1791273797493_0126`) | `TAMPER-PROVEN` |

What the logs show, in both attempts: one `VERIFY-FAIL` line, written on the worker, for the changed file with `chunk=0 hash does not match the record`; none for any other path; three verified opens of the file (the control read, the open of the changed file, which succeeded because the length was unchanged and then failed on the changed chunk, and the read after the original bytes were put back). The failed task ended with `ChecksumException: Attested verification failed`. The restored file has the original fingerprint and the reader succeeded again.

**What went wrong with the script.** The reader's client console only reports that a map task failed; the reason is in the audit and task logs of the machine that ran the task. The first script looked for the reason on the client and printed `FAIL` although the wrapper had worked. Its tests used stand-in commands written from the same assumption, so they could not reveal it. The committed script proves only the client side; `tamper_verify.py` proves the reason from the collected logs of both machines (a `VERIFY-FAIL` for the changed file naming a chunk, none elsewhere, at least two verified opens).
A known cosmetic fault remains in the committed script: its console label "absolute path" prints the path as typed (the real `hdfs dfs -ls` prints paths as typed). A corrected version was prepared but not run, so it is not committed.

**What it shows.** A one-byte change made behind the wrapper's back, on real crawl data, is refused when a job reads it. **What it does not show.** Rewriting the file and its record together is not detected (section 13); only one file was tampered with.

## 12. Cost

- **Time.** 10 min 42 s (run 6, no hashing), 10 min 43 s (run 7, hashing), 10 min 57 s (run 8, hashing and verification). One run each.
- **Hashing.** 3,498.8 MB hashed in run 7, almost all of it the 27 uploads of the job file. The crawl's own data is about 0.4 MB. CPU use was not measured.
- **Storage.** A companion file is 56 bytes plus 32 bytes per chunk: 88 bytes for a file of up to 16,384 bytes, 216 bytes for five chunks. In run 8 both sizes occur.
- **Memory.** The hasher keeps every chunk's hash while a file is written (32 bytes per chunk); for very large files a larger chunk size is needed.

## 13. What was not done

- **The records are not signed.** A file and its record rewritten together are accepted; there is a test that states this. Signing is Stage C.
- **Unverified read paths.** `copyToLocalFile` (marked `verify=bypassed`; not used by the crawl), opening by path handle, and any program that does not use the wrapper.
- **Files created through the builder API** (`createFile`) were not hashed at the time of runs 7 and 8; none occurred (every kept file has a record). Step 4.4 fixed this (section 18).
- **A file without a record** is read with a warning (policy `warn`). In run 8 only the seed file was read that way. A file whose writer was killed before closing it has no record.
- **Metadata is checked against the records, which are not signed** (step 4.5, section 19). A length that differs from the record, a recorded file that is gone and a file without a record are found; a change that keeps the length is found only by reading the file; someone who rewrites a file and its record together is not caught (step 4.7 and Milestone 5).
- **The NameNode's audit log is on since 8 October** (section 19.6): reads and changes made behind the wrapper's back are found by comparing it with the wrapper's log. Until step 4.6, the NodeManager's reads of the job file are expected to show as unexplained; this has not yet been seen on a crawl.
- **No task records or job manifests** (step 4.7). The job file is not checked in a security-relevant way yet: step 4.6 was changed by the mentor on 7 October (ADR-027) and is not done.
- **The NodeManager still reads the job file through plain HDFS** until step 4.6 is done.
- **Plain tools see the companion files**, and consumers that list directories without skipping hidden files will see them.
- **The logs and records are plain files** on the provider's machines.
- **Runs 6 to 8 are not covered by the measurement** (ADR-020). The measured set is unchanged. One new crawl on measured code is needed after the re-measurement; the earlier runs stay as development history.
- **One tampered file** and one kind of change were run on the cluster; the unit tests cover more kinds on both fake and real HDFS.

## 14. Differences from the handoff (to apply to the handoff later)

1. Records are made by the wrapper when each file is closed, tagged with the task attempt id, and not by the commit hook: Nutch's fetch, parse and WARC outputs are written directly to their final path, and its parse output creates its own committer, so the hook set by configuration does not see them all. The committer stays an optional extra for manifests (question 13).
2. The record is kept in a companion file next to the data file, not yet in a signed record and a ledger.
3. Metadata from records is not yet done.

## 15. Evidence and scripts

| Bundle | Files | Fingerprint (12 hex) | Contents |
|---|---|---|---|
| `evidence-run7.tar.gz` | 41 | `039bf4e444a1` | the 18 WARC and index files, the crawl log, both listings, the expected-records list and the independent re-hash, the job comparison, the page and deployment checks, the test log and build log |
| `evidence-run7-audit.tar.gz` | 231 | `cff63506b114` | listings, the audit and records checks, all wrapper and record logs of both machines, the start-up and volume checks, the worker's task-log check, the zip of files that ran |
| `evidence-run8.tar.gz` | 71 | `5b06c2117a7c` | the 18 WARC and index files and their companion files, the crawl log, both listings, the expected-records list and the independent re-hash, the job comparison, the page and deployment checks, the test log and build log, both tamper attempts with their logs and consoles, the two zips of files that ran |
| `evidence-run8-audit.tar.gz` | 299 | `72a754d5cf9f` | listings, the three checks (audit, records, verification summary), all audit and record logs of both machines, both tamper attempts' audit logs and task logs and their proofs, the start-up check, the worker's task-log check |
| `evidence-m44.tar.gz` | 31 | `5abecb377dfc` | both contract runs (with the fixed job, and with run 8's job) with their results, comparisons, libraries and wrapper logs; the failed first attempt; the consoles; the job comparison; the test and build logs; the two zips; the list of fingerprints that the cluster verified |
| `evidence-m45.tar.gz` | 18 | `c0ce9afbe28c` | the contract run with the new job (results, comparison, libraries, wrapper logs), its console and audit summary, the job comparison, the unit-test logs (also from inside the job file), the build log, the zip and its list, both job fingerprints |
| `evidence-m452.tar.gz` | 41 | `73be072ddce3` | the NameNode audit log's `status`, `check` and `on` outputs, the whole probe folder (ground truth, the NameNode's real lines, the wrapper's logs, the comparison), the tool's tests, the change to `hadoop-env.sh`, a summary of the audit log, the three zips and their lists |

Each bundle was compared on the laptop with its `.sha256` file (`MATCH`) and unpacked into `tdx-evidence\extracted` (16 folders now).

Commits: `686c277ae` (step 4.2, 9 files) and `67c56f5a7` (step 4.3, 10 files). Both were gated: before each commit the 15 and then 20 files were checked identical to the files that ran (on the master, in the build folder and in the tests folder, on the laptop, and in a fresh clone from GitHub). The 20 files and their fingerprints (first 16 hex digits), as they were for runs 7 and 8 (step 4.4 later changed four of them; see section 18):

| File | Fingerprint |
|---|---|
| `src/java/org/apache/nutch/attested/AttestedAudit.java` | `65cfaf7b3ad30312` |
| `src/java/org/apache/nutch/attested/AttestedHdfs.java` | `da8f232f3f4ab477` |
| `src/java/org/apache/nutch/attested/AttestedHdfsFileSystem.java` | `b196c0c86158b2b9` |
| `src/java/org/apache/nutch/attested/AttestedRecords.java` | `b6299279c91da363` |
| `src/java/org/apache/nutch/attested/AttestedSidecar.java` | `913e1e5e5b754e7d` |
| `src/java/org/apache/nutch/attested/HashingOutputStream.java` | `12c3f3b1a75b69ae` |
| `src/java/org/apache/nutch/attested/MerkleHasher.java` | `2857e6b82be8a071` |
| `src/java/org/apache/nutch/attested/VerifyingInputStream.java` | `199d84d5f26c96e2` |
| `ops/run-crawl-attested.sh` | `b689ba5185081f1e` |
| `ops/attested/AttestedFsSmoke.java` | `a3e2e030809d7b09` |
| `ops/attested/audit.sh` | `83276048b8beaf27` |
| `ops/attested/audit_compare.py` | `94f41044346888c8` |
| `ops/attested/build-and-test.sh` | `8f3545b7cdf0960a` |
| `ops/attested/job_compare.py` | `a20960a0cc1aa3a1` |
| `ops/attested/merkle_root.py` | `9fdda6bcdd3aa0eb` |
| `ops/attested/records_expected.py` | `adb615a374067e70` |
| `ops/attested/records_verify.sh` | `37aeab6185cb6e35` |
| `ops/attested/tamper-demo.sh` | `bbb2892e47221725` |
| `ops/attested/tamper_verify.py` | `75954a6cd66703dc` |
| `ops/attested/verify_summary.py` | `3e8ac8a8c1edf95f` |

Step 4.4 added two more code commits, kept apart from the documents: `26da09f1c` (the wrapper fix, 4 files) and `e72d1ed05` (the contract tests, 22 files); section 18 lists their files and fingerprints.

Step 4.5 added two more code commits, kept apart from the documents: `4deed2b33` (baby step 4.5.1, 3 files) and `4ebf7570f` (baby step 4.5.2, 4 new scripts); section 19 lists their files and fingerprints.

How a verified crawl is run (every step is a script): rotate the logs on both nodes; put the seeds into HDFS; take the "before" listing; run `ops/run-crawl-attested.sh`; take the "after" listing; check the worker's task logs; copy both listings and both nodes' audit and record logs to Cloud Shell; run `audit_compare.py`, `records_expected.py` (with `--require-sidecars`) and `verify_summary.py` (with `--allow-missing` for the seed folder); copy `expected.tsv` back and run `records_verify.sh` on the master. The tamper test follows (rotate the logs first), then `tamper_verify.py` on the collected logs.

## 16. Decisions taken at this milestone

ADR-021 (keep the record next to the file), ADR-022 (records from the wrapper when a file is closed), ADR-023 (a file without a record is allowed but logged for now), ADR-024 (naming, the commit gate, and verifying assumptions before writing checks), ADR-025 (rehearse code with the real libraries; documents and programs in separate commits), ADR-026 to ADR-029 (the mentor's answers of 7 October), ADR-030 (the checks of answers about files). See [decisions.md](decisions.md).

## 17. Lessons from this milestone

The mistakes are in [guide-pitfalls-and-lessons.md](guide-pitfalls-and-lessons.md) (mistake log 46 to 54). The main one: checks were written from assumptions about other tools' output (what the client prints, how `ls` shows a path) and tested with stand-ins built from the same assumptions, so the tests could not find them. From now on a real sample is read first, and proofs rely on what our own code writes.

## 18. Step 4.4: Hadoop's file-system contract tests

Date: 7 October 2026. Status: **done**. Commits: `26da09f1c` (the wrapper fix) and `e72d1ed05` (the tests).

### 18.1 What they are, in plain words

Hadoop ships a standard list of checks that every file system it supports must pass: create, open, rename, delete, make a folder, file status, seek, append, concat, set times, content summary, copy from local, path handles, unbuffer, vectored reads. It is like a driving test: the same list for every file system. The pass condition of this step: the tests that apply to HDFS pass through the wrapper, or each failure is explained. "Behaves like plain HDFS" is shown by running the same suite twice on the real cluster, once through the plain HDFS client (the control) and once through the wrapper, and comparing the two test by test.

### 18.2 How it was run

- **17 test classes:** Create, Open, Rename, Delete, Mkdir, GetFileStatus, Seek, Append, Concat, SetTimes, ContentSummary, CopyFromLocal, Unbuffer, VectoredRead, StreamIOStatistics, PathHandle and Etag. Left out on purpose: the root-directory tests (they work on the root of the file system), lease recovery, safe mode, the multipart uploader and bulk delete.
- **Safety.** Hadoop's tests delete their test folder after every test. The folder is `/user/rishabsdp17/contract-tests-m44`. The contract class and the script both refuse any folder that is not dedicated (an absolute path of at least three parts whose last part contains "contract-tests"); the script stops if the folder already exists; the root-directory option is off in the options file. The options file is Hadoop 3.4.3's own `contract/hdfs.xml` with that one change; the inventory found no such file in the cluster's tests jar, so it was taken from the source of the same version.
- **Libraries.** `hadoop-common-3.4.3-tests.jar`, JUnit 4.13.2 and hamcrest 1.3 (both from Hadoop's own `tools/lib`), and AssertJ 3.12.2, which the master downloaded from Maven Central and checked against the sha1 published next to it; its SHA-256 is recorded in `libs.txt`.
- **The wrapper under test** comes from the job file, so the tests exercise the classes that were built; the script checks the job's fingerprint and all 33 files against the list in the zip before it does anything.
- **Tools** (in `ops/attested/`): `contract-tests.sh` (the run), `contract_compare.py` (the comparison), and in `contract/` the contract class `AttestedHdfsContract`, the runner `ContractRunner` and the 17 test classes.

### 18.3 The rehearsal, and what it found before the cluster run

The development machine had no JUnit, AssertJ or Hadoop test classes, so the first version was only type-checked against stand-ins. That was not enough (section 18.4). The second version was rehearsed with the real things: JUnit 4.13.2, hamcrest 1.3 and AssertJ 3.14.0 (from Ubuntu packages), Hadoop 3.4.3's contract sources from GitHub (tag `rel/release-3.4.3`, with a few newer helper classes compiled from the same tag), the wrapper over a fake HDFS, both modes, and the comparison tool. It found:

| Finding | Meaning |
|---|---|
| The builder forms of `append` and `create` went straight to the real client | A real defect: a file changed through the builder kept its old record, so reading it failed; a file created through the builder was not hashed |
| The wrapper's streams offered no I/O statistics and no `unbuffer` | Behavior differences from the plain HDFS streams |
| The runner merged the variants of parameterized tests | `PathHandle` showed 28 tests where JUnit ran 56 |

After the fixes the rehearsal showed no test that passes on plain and fails through the wrapper (before the fixes: 5). The one class that could not be rehearsed was `VectoredRead`, which needs a newer Hadoop API; it ran first on the cluster.

### 18.4 The first attempt

The first run on the master stopped at compilation, before any test ran and before anything in HDFS was touched: `PathHandle` and `VectoredRead` are parameterized tests whose constructors take arguments, and the stand-ins had assumed none. The compiler output is kept in the evidence (`contract-m44-attempt1-compile-failed/compile.txt`).

### 18.5 Results on the real cluster

| Item | Result |
|---|---|
| Job and files | job `dea47c6d41729bef`; the 33 files identical to the list; started 14:34:31 |
| Tests per mode | 255 |
| Passed in both modes | 238 |
| Failed in both modes | 16 (the same 16) |
| Skipped in both modes | 1 (the same one) |
| Passed on plain HDFS but failed through the wrapper | 0 |
| Missing from one of the runs | 0 |
| Verdict | `CONTRACT-SAME-AS-HDFS` |

Per class (pass / fail / skip, the same in both modes): Append 8 / 0 / 0, Concat 5 / 0 / 0, ContentSummary 2 / 0 / 0, CopyFromLocal 15 / 0 / 0, Create 11 / 5 / 0, Delete 8 / 0 / 0, Etag 0 / 3 / 1, GetFileStatus 20 / 0 / 0, Mkdir 8 / 0 / 0, Open 27 / 0 / 0, PathHandle 56 / 0 / 0, Rename 7 / 3 / 0, Seek 18 / 0 / 0, SetTimes 1 / 0 / 0, StreamIOStatistics 0 / 5 / 0, Unbuffer 6 / 0 / 0, VectoredRead 46 / 0 / 0.

### 18.6 The 16 failures that plain HDFS shares

| Tests | Count | Cause |
|---|---|---|
| Create (5), Rename (3), StreamIOStatistics (1) | 9 | The NameNode refuses block sizes below 1 MiB (`dfs.namenode.fs-limits.min-block-size=1048576`); the tests ask for 1024 or 8000 bytes |
| Etag | 3 | HDFS has no etag support |
| StreamIOStatistics | 4 | Plain HDFS's streams offer no statistics (`Expecting actual not to be null`); the wrapper now returns exactly what the plain stream returns |

The three Rename tests that fail on both sides (rename over an existing file, rename of a folder into an existing folder, ancestors after a rename) would have exercised the wrapper's moving of record files. Our own unit tests cover renames of files, of folders and into folders, but not rename over an existing file; this is a coverage gap (section 18.10).

### 18.7 The sensitivity check: could the comparison have caught a defect?

The same suite ran with run 8's job, which has the wrapper as it was before the fixes. It reported `CONTRACT-DIFFERENCES (10)` (totals: plain 238 / 16 / 1, the old wrapper 228 / 26 / 1): `Append.testBuilderAppendToExistingFile`, `Append.testBuilderAppendToEmptyFile`, and `PathHandle.testChanged` in all four option sets (each twice). All ten have one cause, the builder defect. The wrapper's own log agrees: the old job logged exactly 10 refused reads. With the fixed job the comparison reports none. So the comparison can detect a wrapper defect on this cluster, and the pass of the fixed job means something.

### 18.8 What the wrapper logged during the wrapped runs

| Item | Fixed job | Run 8's job |
|---|---|---|
| Audit lines | 1669 (CREATE 535, MKDIRS 337, DELETE 327, INIT 255, OPEN 126, RENAME 41, APPEND 23, COPYFROMLOCAL 20, CONCAT 4, SETATTR 1) | 1649 (CREATE 533, MKDIRS 337, DELETE 309, INIT 255, OPEN 116, RENAME 41, APPEND 23, COPYFROMLOCAL 20, VERIFY-FAIL 10, CONCAT 4, SETATTR 1) |
| Opens verified | 111 | 109 |
| Opens without a record | 15 | 7 |
| Reads refused (VERIFY-FAIL) | 0 | 10 |
| Record lines | 283 | 263 |

The contract tests ran with the wrapper's defaults (records and verification on), which is consistent with the companion files not disturbing listings and renames (an inference).

### 18.9 The fix

The new job `dea47c6d41729bef` was built on 7 October from the 33 verified files. Against run 8's job it has the same 1041 entries; exactly three classes differ (`AttestedHdfsFileSystem`, `HashingOutputStream`, `VerifyingInputStream`) and nothing is added or removed. The changes:

1. `createFile` and `appendFile` return builders that call the wrapper's own `create` and `append` (Hadoop's own factory), so files created through the builder are hashed and a file appended to through the builder loses its old record.
2. The streams pass on the real stream's I/O statistics, so callers see what they see without the wrapper.
3. The input stream supports `unbuffer` and reports that capability.
4. In the runner, the second variant of a repeated test name is kept (`name#2`).

The wrapper's own tests after the fix: fake HDFS 91 of 91, MapReduce 12 of 12, hashing 18 of 18, Java and Python agree on 9 sizes, real HDFS 90 of 90 (the earlier 84 plus six new checks: builder create, create over an existing file, builder append, statistics parity for reads and writes, unbuffer).

### 18.10 Limits of this step

- One small cluster (one DataNode), one run per mode; the same tests were not repeated.
- Nine tests (Create 5, Rename 3 and one statistics test) fail on plain HDFS too because of the NameNode's minimum block size, so they say nothing about the wrapper; the cluster setting was not changed.
- The Etag and statistics tests fail on plain HDFS here, so they say nothing about the wrapper; the statistics parity is covered by the unit tests.
- The contract suite does not test the wrapper's own additions (records, verification, hiding of companion files) or `copyToLocalFile`; those rest on the tests of steps 4.2 and 4.3.
- AssertJ 3.12.2 ran on the cluster, 3.14.0 in the rehearsal.
- The root-directory, lease-recovery, safe-mode, multipart-upload and bulk-delete tests are not part of the suite.
- The sensitivity run used the old job for the contract tests only; it is not a crawl.

### 18.11 Evidence and commits

The bundle `evidence-m44.tar.gz` is listed in section 15. It was compared on the laptop with its `.sha256` file (`MATCH`) and unpacked (17 folders in `tdx-evidence\extracted` now). The files that ran are listed in `m44b-expected.sha` (33 lines), and the script verified them at the start of each run.

The wrapper fix, `26da09f1c` (4 files):

| File | Fingerprint |
|---|---|
| `src/java/org/apache/nutch/attested/AttestedHdfsFileSystem.java` | `3e7bcb81ad26467d` |
| `src/java/org/apache/nutch/attested/HashingOutputStream.java` | `94de417078879f14` |
| `src/java/org/apache/nutch/attested/VerifyingInputStream.java` | `45e938a63ae7e1ab` |
| `ops/attested/AttestedFsSmoke.java` | `bcc72cbd53fbfd6b` |

The contract tests, `e72d1ed05` (22 files):

| File | Fingerprint |
|---|---|
| `ops/attested/contract-tests.sh` | `c4587c9a9667276f` |
| `ops/attested/contract/AttestedHdfsContract.java` | `68a4f5f667c9d832` |
| `ops/attested/contract/ContractRunner.java` | `a09e4385c1f268af` |
| `ops/attested/contract/TestAttestedContractAppend.java` | `6863e125eb893c7d` |
| `ops/attested/contract/TestAttestedContractConcat.java` | `e1f72836f57a3cff` |
| `ops/attested/contract/TestAttestedContractContentSummary.java` | `c8c3a197ece421ec` |
| `ops/attested/contract/TestAttestedContractCopyFromLocal.java` | `f61e3655e4935f88` |
| `ops/attested/contract/TestAttestedContractCreate.java` | `b36c6d4d6541c37e` |
| `ops/attested/contract/TestAttestedContractDelete.java` | `9782dfe16bd60da8` |
| `ops/attested/contract/TestAttestedContractEtag.java` | `d6ed42710b7e6b88` |
| `ops/attested/contract/TestAttestedContractGetFileStatus.java` | `2b85d8a2f4b2629b` |
| `ops/attested/contract/TestAttestedContractMkdir.java` | `b582856745cdf0bd` |
| `ops/attested/contract/TestAttestedContractOpen.java` | `e8a1e67c496e9265` |
| `ops/attested/contract/TestAttestedContractPathHandle.java` | `f043645c33171ab9` |
| `ops/attested/contract/TestAttestedContractRename.java` | `579fd8cd486ce0f1` |
| `ops/attested/contract/TestAttestedContractSeek.java` | `bd33f1e6e38a5fd4` |
| `ops/attested/contract/TestAttestedContractSetTimes.java` | `5d0b8138022c9d6f` |
| `ops/attested/contract/TestAttestedContractStreamIOStatistics.java` | `b50249324f1e2b28` |
| `ops/attested/contract/TestAttestedContractUnbuffer.java` | `f90fa403e5024cba` |
| `ops/attested/contract/TestAttestedContractVectoredRead.java` | `0c0696ae5fa9ff99` |
| `ops/attested/contract/resources/contract/attested-hdfs.xml` | `03c92bead0302ba9` |
| `ops/attested/contract_compare.py` | `ece2afb1263e910b` |

Before each commit the files were checked identical to the list the cluster had verified, on the laptop, and afterwards in a fresh clone from GitHub, which also confirmed that neither commit touches `docs/`. The zips `m44-files.zip` (the first attempt) and `m44b-files.zip` (the final set) are in the bundle; an intermediate `m44-update1.zip` was withdrawn before it was used.

### 18.12 Lessons from this step

- Code that depends on real libraries is rehearsed with those libraries before it is sent, and the message says what could not be rehearsed (ADR-025).
- A check is only trusted after it has caught a known fault; here, the old job.
- A file list is verified by the script that uses it, not by a pasted command.
- The mistakes are in [guide-pitfalls-and-lessons.md](guide-pitfalls-and-lessons.md) (mistake log 55 to 62).

## 19. Step 4.5: answers about files come from the records, and the NameNode's audit log

Date: 8 October 2026. Status: **done**. Commits: `4deed2b33` (baby step 4.5.1, the checks in the wrapper) and `4ebf7570f` (baby step 4.5.2, the NameNode's audit log and its comparison).

### 19.1 What it is, in plain words

Imagine asking a warehouse clerk how long a roll of cloth is. A dishonest clerk can shorten the roll or hide it, and nobody notices until someone unrolls it. Until now the wrapper answered "how long is this file?" and "does it exist?" from HDFS, which is the party we do not trust; it only read a file's record when the file was opened. **Baby step 4.5.1** makes the wrapper ask the notary, the file's record, which stores its length, and complain when HDFS disagrees. **Baby step 4.5.2** switches on the NameNode's own audit log. Every request to HDFS passes the NameNode, so its log shows what happened whoever did it, and a request that bypassed the wrapper shows up there even though the wrapper never saw it.

### 19.2 Baby step 4.5.1: how the wrapper answers

| Situation | What the wrapper does |
|---|---|
| A file's length in HDFS differs from its record | Refuses the answer (setting `attested.metadata.mismatch`, default `fail`), whichever way it was asked: `getFileStatus`, `exists`, any listing or glob |
| A record exists but its file is gone | Refuses in the same way; it looks again after 25 ms, so a delete that is just finishing is not a false alarm |
| A file exists with no record | Allowed and logged once, following the existing setting `attested.verify.missing` (default `warn`) |
| A directory, or a change made through the wrapper | Never a finding; the remembered length is dropped when the wrapper changes a record |
| Another program rewrote the file and its record | Not a finding: before refusing on a mismatch the wrapper reads the record again |

The settings are `attested.metadata.check` (default true), `attested.metadata.mismatch` (default `fail`) and `attested.metadata.cache.seconds` (default 10, the time a record's length is remembered when no listing can vouch for it). Findings go to the audit log as `META-FAIL`, `META-MISSING` and `META-ORPHAN`, once per file per program (a refusal under `fail` is logged each time).

Only `getFileStatus`, `listStatus`, `listStatusIterator` and the two `listLocatedStatus` methods needed changing: Hadoop's `exists`, `isFile`, `isDirectory`, `getContentSummary`, `listFiles` and `globStatus` are inherited from `FileSystem` and go through them (checked on the 3.4.1 client classes). A check reads only the first 20 bytes of a record (the new `AttestedSidecar.readLength`); a listing is read in full before it is returned, so that the records in it can be seen; a path that is not found costs one more check.

### 19.3 Tests

In the development environment (a fake HDFS and Hadoop's real contract-test classes; not part of the evidence) the wrapper's tests and a rehearsal of the contract tests passed first. On the master the wrapper's tests ran on 8 October with 26 new checks:

| Mode | Result |
|---|---|
| fake HDFS | 117 of 117 (the earlier 91 and the 26 new checks) |
| MapReduce on the fake HDFS | 12 of 12 |
| hashing | 18 of 18; Java and Python agree on 9 sizes |
| real HDFS | 116 of 116 (the earlier 90 and the 26 new checks) |

The same counts passed again with the wrapper classes taken from inside the new job file. The 26 new checks tamper through the plain client and require the wrapper to refuse or log it: a changed length, a removed file, a file slipped in; they also cover each setting and the off switch, rename, delete and rewrite through the wrapper (no false findings), and a rewrite by another program.

### 19.4 The job

The new job `901f01df3423857a` was built on 8 October from the 33 verified files. Against the previous job (`dea47c6d41729bef`) it has 1043 entries instead of 1041: two classes added (`AttestedHdfsFileSystem$3` and `AttestedHdfsFileSystem$CachedLength`), four changed (`AttestedHdfsFileSystem`, `AttestedHdfsFileSystem$1`, `AttestedHdfsFileSystem$2` and `AttestedSidecar`), none removed. This was predicted before the build by compiling the old and the new sources.

### 19.5 Hadoop's contract tests with the new job

| Item | Result |
|---|---|
| Tests per mode | 255 |
| Passed, failed, skipped | 238 / 16 / 1 in both modes, the same as in step 4.4 |
| Passed on plain HDFS but failed through the wrapper | 0; verdict `CONTRACT-SAME-AS-HDFS` |
| Wrapper audit lines | 1680 (1669 with the previous job); the difference is 11 `META-MISSING` lines |
| Opens | 126; 111 verified; 0 refused |

The 11 `META-MISSING` lines are all explained: eight come from the four `testChanged` tests (each asks about two files that were appended to through the builder, which drops the record by design), one from `testSyncable` (a file asked about while it was still being written), and two from the files `target` and `renamed` of the append tests. There was no `META-FAIL` and no `META-ORPHAN`. The rehearsal had shown 13; two tests (`testCreatedFileIsVisibleOnFlush`, `testCreatedFileIsImmediatelyVisible`) fail on the real cluster at the create because of the block-size minimum (section 18.6), so they never wrote a file. This run shows that the checks raise no false alarm on Hadoop's own tests; that they catch tampering is shown by the 116 checks above.

### 19.6 Baby step 4.5.2: the NameNode's audit log

Before the change the running NameNode carried the logger `INFO,NullAppender`, which discards the log (Hadoop's default). The definition of the file appender `RFAAUDIT` (writing `hdfs-audit.log` in the logs folder, up to 20 files of 256 MB) was already in `log4j.properties`, so the change is one setting in `hadoop-env.sh`, `HDFS_AUDIT_LOGGER=INFO,RFAAUDIT`, and a NameNode restart. The script `nn-audit.sh` does it with `status`, `check`, `on` and `off`: `on` refuses if a YARN application is running, HDFS is in safe mode or no DataNode is live; it backs up `hadoop-env.sh` and the NameNode's metadata folder (9384 KB), restarts the NameNode, verifies the logger, `ls /`, the DataNode count, a line in the audit log and `fsck`, and rolls back by itself if any of it fails. It was rehearsed in the development environment with stand-ins for `hdfs`, `yarn` and `ps` (23 checks, including each failure path; not part of the evidence).

On the master, `check` printed `NN-AUDIT-CHECK-OK` with one live DataNode, which is by design (the worker is the only DataNode; replication is 1), and `on` printed `NN-AUDIT-ON-OK: the NameNode runs with INFO,RFAAUDIT; 1 DataNode(s) are back; fsck is HEALTHY`. The change to `hadoop-env.sh` is exactly four added lines (a blank line, our marker, the export and our end marker). The real log's format is tab-separated: `timestamp INFO FSNamesystem.audit: allowed=true`, then `ugi=`, `ip=`, `cmd=`, `src=`, `dst=`, `perm=` and `proto=rpc`, in UTC. The first 12 minutes produced 120 lines: `getfileinfo` 67, `rename` 11, `open` 11, `safemode_get` 9, `create` 8, `datanodeReport` 5, `delete` 4 and `listStatus` 2, with `mkdirs`, `fsck` and `slowDataNodesReport` once each.

### 19.7 The probe and the comparison

Every client on the master shows in the NameNode's log with the same user (`rishabsdp17`) and address (`10.10.0.1`), so wrapper and plain requests cannot be told apart by those fields. The comparison tool `nn_audit_compare.py` therefore matches by operation, path and time: a NameNode event (an open of a data file, a create, append, truncate, concat, delete, rename, mkdirs or set call) is explained when the wrapper logged the same operation on the same path within 3000 ms, and each wrapper line explains one event only; the wrapper's reads of its own record files are skipped. The probe script `nn-audit-probe.sh` plays a known workload in one folder: 8 operations through the wrapper and 5 straight through the plain client.

The real result: the probe ran 13 operations without failure. The tool read 97 NameNode lines and 18 wrapper lines and compared 25 events: 18 were explained and **7 were unexplained, exactly the plain operations**: the open of `w-read`, the create and rename of `p-new`, the create, rename and delete of `p-gone`, and the rename of `w-renamed-dst` to `p-moved` (a `-put` is a create of a `._COPYING_` file and a rename). The other 62 `getfileinfo` and 1 `listStatus` lines were only counted. There was no false alarm and no wrapper line left over. The tool's 18 tests, which use a data set in the real format, also passed on the master.

### 19.8 What it changes elsewhere

`hadoop-env.sh` is part of the Hadoop configuration, so the measured set changes and the re-measurement (step 4.8, ADR-020, ADR-029) must cover it; the post-run check that the measured files are unchanged is expected to report that file, and has not been run since. The NameNode audit log is now on for every later run, wrapped or not, so they stay comparable with each other; runs 6 to 8 had none.

### 19.9 Limits of this step

- The records are not signed: a file and its record rewritten together are accepted. A change that keeps the length is found only by reading the file.
- A listing is read in full before it is returned; `getFileLinkStatus` is not checked (the HDFS paths here have no symbolic links).
- The comparison needs the machines' clocks to agree within its window (3 s by default) and counts a file of more than ten blocks as several reads, because the HDFS client asks the NameNode again while it reads.
- The NameNode's log is a plain file on the provider's machine, like the wrapper's logs.
- Only the probe's workload was run against the tool on the cluster; no crawl has been compared yet. The first crawl compared is expected to show the NodeManager's reads of the job file, which step 4.6 changes. (Done on 9 October: run 9, section 20.6.)
- The cost of the checks was not measured: each file question reads a record header (remembered for 10 s) and a missing path costs one more check. The paired runs of ADR-028 measure it.

### 19.10 Evidence and commits

The bundles `evidence-m45.tar.gz` and `evidence-m452.tar.gz` are listed in section 15; both were compared on the laptop (`MATCH`) and unpacked (19 folders in `tdx-evidence\extracted` now). Before each commit the files were checked identical to the lists the cluster verified, on the laptop, and afterwards in a fresh clone from GitHub, which also confirmed that neither commit touches `docs/`.

Baby step 4.5.1, `4deed2b33` (3 files, all modified):

| File | Fingerprint |
|---|---|
| `ops/attested/AttestedFsSmoke.java` | `736dca0dd88c89c5` |
| `src/java/org/apache/nutch/attested/AttestedHdfsFileSystem.java` | `5dcbbd3687f7653a` |
| `src/java/org/apache/nutch/attested/AttestedSidecar.java` | `6b3e8d48a999a2d0` |

Baby step 4.5.2, `4ebf7570f` (4 new scripts):

| File | Fingerprint |
|---|---|
| `ops/attested/nn-audit-probe.sh` | `13b0b18437d292dc` |
| `ops/attested/nn-audit.sh` | `7aed642cfec3fe20` |
| `ops/attested/nn_audit_compare.py` | `a67893f29ffb7cb0` |
| `ops/attested/test_nn_audit_compare.py` | `3377b934fc2c8605` |

### 19.11 Lessons from this step

- A read command for this step assumed a file name and a layout that had not been checked; it was caught before it was sent, and the step used the code and a probe that makes its own data instead.
- A limit was written down before it was tested, and the test showed the tool is stricter than the text said (each wrapper line explains one event only); a stated limit is tested first.
- Every script is run with `bash -n` and rehearsed with stand-ins before it goes to the master; an apostrophe inside a `${VAR:?message}` was found that way.
- The mistakes are in [guide-pitfalls-and-lessons.md](guide-pitfalls-and-lessons.md) (mistake log 63 to 69).

## 20. Step 4.6: the wrapper becomes the cluster's own file system

Date: 8 and 9 October 2026. Status: **done**. Commits: `fcffad09d` (baby steps 4.6.1 and 4.6.2: the jar tool and the switch), `bef3a6452` (the audit tools use the plain client), `9ef0f405d` (baby step 4.6.3: the NodeManager swap demo) and `28c811ff4` (the NameNode comparison tool).

### 20.1 What it is, in plain words

Until now the wrapper was a guard that only some visitors walked past: a job had to ask for it with two `-D` options. Anything that did not ask, and above all the NodeManager (the worker's helper that fetches a job's code and settings before every task), used plain HDFS and was never checked. The mentor's point (ADR-027) was that a check run by the task itself does not count, because a swapped job file can skip it. The check has to stand where Hadoop itself reads.

So the guard was moved to the front door. The wrapper's classes were put into Hadoop's own library folder, and the cluster's own settings now say that `hdfs://` is served by the wrapper. Everyone who reads those settings, the NodeManager included, passes the guard. The three baby steps are: 4.6.1 the wrapper's classes on Hadoop's classpath; 4.6.2 both lookups set as final in `core-site.xml`, with a switch back to the plain file; 4.6.3 the NodeManager's own read is checked against its record and refuses a swapped file.

### 20.2 Baby step 4.6.1: the classes on Hadoop's classpath

| Item | Value |
|---|---|
| The jar | `attested-hdfs.jar`, 34,217 bytes, SHA-256 `f0d96a83759a55fe...` (full value in the evidence), built by `ops/attested/wrapper-jar.sh build` from the 13 wrapper classes inside the job file `apache-nutch-1.22.job` (`901f01df3423857a`, 1,043 entries); the build is deterministic and the script compares the jar with the job file class by class (`CLASSES-SAME`) |
| Where it is | `~/hadoop/share/hadoop/common/lib/` on both nodes (copied from the master and checked by fingerprint); Hadoop puts that folder on the classpath of its commands, its daemons and its containers; `hadoop classpath --glob` lists the jar once |
| Self-test | `hdfs dfs -ls /` with the wrapper switched on and no job file on the classpath: `JAR-LOADS-FROM-LIB-OK` on both nodes |
| Stage 2: containers | the Pi example (2 maps, 10 samples), whose own jar holds no wrapper class, with the wrapper switched on by `-D`: it finished (20.1 s) and the worker wrote 4 wrapper log files and 8 start-up lines (7 opens, all `verify=ok`), so the task containers load the wrapper from the library folder; the start-up line shows `from=...attested-hdfs.jar` |
| Rehearsal | 19 of 19 with the real wrapper classes and stand-ins for `hadoop` and `hdfs` |

The library copy wins on the classpath, so the classes in the job file and in the jar must be the same. `wrapper-jar.sh verify <job file>` checks it, and it is part of the procedure before every crawl (section 20.7 and [cluster-configuration.md](cluster-configuration.md) section 16).

### 20.3 Baby step 4.6.2: both lookups final, and the switch

`ops/attested/cluster-mode.sh` keeps two versions of `core-site.xml` in `~/cluster-mode` on each node. PLAIN (`d7e7dffd27def2a0`) is the file as it was. WRAPPED (`1c335707555b2427`) is the same file plus two properties, `fs.hdfs.impl=org.apache.nutch.attested.AttestedHdfsFileSystem` and `fs.AbstractFileSystem.hdfs.impl=org.apache.nutch.attested.AttestedHdfs`, both marked `final`. The two nodes' files are identical. `wrapped` and `plain` put a version in place after a backup. With `--restart` the script restarts the node's daemons in Hadoop's order (the NameNode and ResourceManager on the master, the DataNode and NodeManager on the worker), checks that every daemon is back and that `hdfs dfs -ls /` and `yarn node -list` work, and **puts the previous file back by itself if a check fails**. With `--restart-yarn` it restarts only the node's YARN daemon, which is the quick switch for the control runs.

**What `final` does and does not do.** It was tested with Hadoop's own configuration classes: a later settings file (a job's `job.xml`) cannot override a final property, but code that calls `conf.set` and a command-line `-D` option can. So `final` closes the route the mentor named (a job's settings file switching the wrapper off in the NodeManager or in a task container) and no more. Our audit tools use `-D` on purpose (below).

**The first attempt failed and rolled back.** On 8 October at 08:39 UTC the script installed the WRAPPED file on the master, restarted the NameNode, and reported `safe mode did not end`. It restored the plain file and restarted, and the cluster was as before (the NameNode and ResourceManager had new pids). The cause was found in Hadoop 3.4.3's source: `hdfs dfsadmin` insists on a real `DistributedFileSystem` (`AdminHelper.checkAndGetDFS`; 22 of the tool's commands use it) and fails for the wrapper, which is a `FilterFileSystem`; the script's own safe-mode check was such a command. The rehearsal had missed it because its stand-in for `dfsadmin` did not model that constraint. The script's admin calls now use the plain client. The second attempt succeeded: the master took about 72 s (08:58:41 to 08:59:53 UTC, the new NameNode pid 535595) and the worker 18 s (09:01:40 to 09:01:58).

**A bug the rehearsal found before it mattered.** The first version's rollback printed `ROLLED-BACK` without restarting the NodeManager that had failed to start, because it restarted and verified only the daemons that were still running. The script now notes the node's daemons once before any change and uses that list for the restart, the verification and the rollback. The rehearsal passes 21 of 21 and has a check for exactly this.

**Proof with no `-D` anywhere** (8 October, 09:05 UTC): the NameNode and ResourceManager ran under new pids; `hdfs dfs -ls /` worked; the Pi example with no options finished (23.7 s) and the master wrote 4 wrapper log files (7 start-up lines) and the worker 5 (12 start-up lines), **all with `from=...attested-hdfs.jar`**; the admin tool failed under the wrapper with `is not an HDFS file system` and worked with the plain client; no leftover temporary folder.

**The switch both ways** (YARN-only restarts, seconds): in plain mode the Pi example worked (18.5 s) and neither node wrote a wrapper log file; back in wrapped mode it worked again (21.9 s) with wrapper logs on both nodes. The single Pi timings are noise, not a result. The cluster was left in wrapped mode.

**The scripts that talk to HDFS.** With the wrapper as the default, a plain `hdfs dfs` goes through it, which would hide the record files from the audit's listing, make the re-hash read through the wrapper, and turn the tamper demo's "behind the wrapper's back" into an ordinary wrapped write. Five scripts therefore ask for the plain client (`-D fs.hdfs.impl=org.apache.hadoop.hdfs.DistributedFileSystem`): `audit.sh`, `records_verify.sh`, `tamper-demo.sh`, `nn-audit.sh` and `nn-audit-probe.sh`. `contract-tests.sh` is unchanged (its two HDFS calls are harmless through the wrapper). The two scripts of `ops/mesh/` also call `dfsadmin`, but they run only together with a network change, so they were not edited; they need plain mode (limitations row 61). Rehearsals: `nn-audit.sh` 23 of 23 (the unfixed version fails 16 of them), `audit.sh` and `records_verify.sh` 11 of 11 with `tamper-demo.sh` (14 of 14 after its path fix). On the cluster in wrapped mode: `nn-audit.sh check` OK; the plain listing showed 1,756 paths and the ordinary one (through the wrapper) 1,594, the 162 hidden paths being record files, with nothing seen only by the ordinary listing; the probe gave the numbers of step 4.5.2 again (97 NameNode lines, 25 events compared, 18 explained, 7 unexplained, the 7 being the probe's 5 plain operations). The `on` and `off` branches of `nn-audit.sh` were not run again; its changed `safemode wait` line is covered by the rehearsal, and the same command ran for real in `cluster-mode.sh`. The tamper demo also makes its printed path absolute now (a relative path from `hdfs` is taken relative to the user's home) and stops if the path does not exist; this closes the cosmetic fault noted in section 11, and it ran for real in run 9's tamper test.

### 20.4 Baby step 4.6.3: the NodeManager reads through the wrapper, and refuses a swapped file

**Over a whole crawl.** In run 9 (section 20.5) the NodeManager's own process (pid 180161) opened the four files of every job, `job.jar`, `job.xml`, `job.split` and `job.splitmetainfo`, 27 times each, 108 opens in all, every one `verify=ok`. The NameNode saw the same 108 opens from the worker's address (section 20.6). Before step 4.6 the NodeManager read these files through plain HDFS, unchecked. This answers the handoff's open question whether Hadoop's job loader reads the staging directory through a wrapped file system: it does, now. (The per-file counts were made from the NodeManager's wrapper log with the one-line `awk` in [cluster-configuration.md](cluster-configuration.md) section 16; the bundle holds the log.)

**The swap demo** (`ops/attested/nm-swap-demo.sh`). A job can hand a file to its tasks through the distributed cache, and the NodeManager fetches that file itself. The script stores a 3,920-byte file through the wrapper (its record is made), runs the Pi example with `-files <that file>` (control, must succeed), changes one byte (byte 1,960) with the plain client keeping the length, runs the same job (must fail), puts the original back and runs it again (must succeed). It always restores the file and removes its folder, and the final version also removes the temporary folder that the failed Pi job leaves behind, but never one that existed before.

| Run | Date | Tampered job | Client side | The NodeManager's own log |
|---|---|---|---|---|
| 1 | 8 October, 15:15 UTC | `job_1791450997865_0003` | PASS: control ok, tampered job failed (`Failed to download resource ... dc-file`), restored fingerprint `850ef14c833d730c` equals the original | pid 176992: an open `verify=ok` (15:15:52), an open `verify=ok` and `VERIFY-FAIL chunk=0 hash does not match the record` in the same second (15:16:15), an open `verify=ok` (15:16:24) |
| 2 | 9 October, 13:49 UTC | `job_1791450997865_0036` | PASS, the same fingerprint; the failed job's temporary folder was removed and the older leftover was not | pid 201543 (after a restart): the same four lines (13:49:49, 13:50:13 twice, 13:50:21); exactly one refusal in the clean folder |

The three verified opens per run are the control, the open of the changed file (it succeeds because the length still agrees with the record, and the hash check then fails on the changed chunk), and the restored read. This is the same pattern as in run 8's tamper test. The first run's NodeManager lines were found in the rotated folder, not the clean one (section 20.7). Rehearsals: the first version 11 of 11, the final version 15 of 15.

### 20.5 Run 9: the integration crawl (not covered by the measurement)

Run 9 ran on 9 October from 05:08:18 to 05:19:48 UTC (11 min 30 s; the rounds started at 05:08:43, 05:11:59 and 05:15:55), with `ops/run-crawl.sh`, the original script with **no wrapper options at all**, so everything it did through the wrapper came from the cluster's own settings. It ran 27 MapReduce jobs (27 job uploads on the master, 27 sets of job files read by the NodeManager) and exited 0. It is **not covered by the measurement** (ADR-029), it has no unwrapped control in the same hour, and its wall time is not a result; it proves the procedure. The seed file was stored through the wrapper too, so it has a record (57 bytes and an 88-byte record); run 8 needed an exemption for it.

| Check | Result |
|---|---|
| Storage before and after (`audit_compare.py`, nothing exempted) | `AUDIT-CLEAN`: 1,787 paths before, 2,109 after, 322 added, all explained by the wrapper's logs, none removed or changed; 117 log files (24 master, 93 worker: 92 containers and the NodeManager), 2,308 lines |
| Expected records (`records_expected.py`, run 9's two folders, record files required) | `RECORDS-COMPLETE`: 55 files judged, 55 with a matching record |
| Verification summary (`verify_summary.py`, nothing exempted) | `VERIFY-CLEAN`: 265 opens, all `verify=ok`, 0 failures |
| Independent re-hash through the plain client (`records_verify.sh`) | `RECORDS-VERIFIED`: 55 verified, 0 mismatched |
| NameNode comparison | `NN-AUDIT-COMPARE-CLEAN` with two stated rules (section 20.6) |
| Tamper test (`tamper-demo.sh`, then `tamper_verify.py` on both nodes' logs) | `TAMPER-PROVEN`: byte 12,927 of 25,854 changed in `crawl-run9/crawldb/current/part-r-00000/data`; the reader job failed (`job_1791450997865_0033`); one `VERIFY-FAIL chunk=0 hash does not match the record` from a container on the worker, none for any other path; three verified opens; the restored fingerprint `da0efcc0da0e3565` equals the original; the map task and the ApplicationMaster both logged `ChecksumException` |

The wrapper's operations: on the master 244 creates, 189 attribute changes, 45 mkdirs, 42 deletes, 27 renames, 27 uploads of job files and no opens; on the worker 540 creates, 265 opens, 234 renames, 135 deletes, 81 attribute changes and 66 mkdirs. The merged totals equal the sums of the nodes.

### 20.6 The NameNode comparison of run 9

The first comparison, over the window from the log rotation (8 October 15:43) to the end of the crawl (9 October 05:21), was not clean: 26 unexplained `open` events from the master's address and 27 wrapper lines (`COPYFROMLOCAL`) with no NameNode event. They were understood from the data before the tool was changed:

- The wrapper's `copyFromLocalFile` logs a `COPYFROMLOCAL` line and then copies through its own `create`, which logs a `CREATE` line: two wrapper lines for one upload, one NameNode `create`. All 27 such lines had a `CREATE` line for the same file in the same JVM within 3 s.
- A job's client creates `job.jar`, then asks the NameNode where the input files' blocks are, then creates `job.split`. HDFS audits that question as `open`. All 26 events were `open`, from the master, inside the submission window of one of the 27 jobs, on the next job's input files (the seed file, the crawl database, the segment parts).

`nn_audit_compare.py` now has two rules, on unless `--strict` is given, each printed as its own line and never merged into "explained": a **companion line** is accepted only if the other line of the same upload (same JVM, same file, within the window) was itself matched to a NameNode event; a **submission lookup** is accepted only for an `open` by the same client address that created the job's `job.jar` before it and its `job.split` after it (both times taken from the NameNode's own log), never for a create, delete or rename. Tests: 36 of 36 (the 18 earlier ones unchanged, 18 new).

| Run of the tool on run 9 | Result |
|---|---|
| Default rules | 1,894 events compared: 1,868 explained by the wrapper's log, 26 known (submission lookups), **0 unexplained**; 27 companion lines; the wrapper's 1,895 non-start-up lines are 1,868 matched plus 27 companions, so nothing is left over on either side; `NN-AUDIT-COMPARE-CLEAN` |
| `--strict` | 26 unexplained and 27 wrapper lines not shown: `FINDINGS (26)`, as before the rules |
| Negative control: the largest wrapper log (the NodeManager's, `tdx-lab-worker-180161-...`) removed | 108 unexplained: `FINDINGS (108)`; on screen they were exactly 27 each of `job.jar`, `job.xml`, `job.split` and `job.splitmetainfo` from the worker's address, so the NodeManager's reads are explained only by its own wrapper lines, with no exception |
| Changes to storage | the NameNode's creates, renames, deletes and mkdirs (784, 261, 177 and 111) equal the wrapper's |

**81 requests were reported as denied, and none was.** All 81 were `delete`, all from the worker's address, on paths already gone (history `_tmp` files and `_temporary` folders), and the NameNode's own log has no permission error in the window. In Hadoop 3.4.3's `FSNamesystem.delete` the audit line carries the result of the delete, so `allowed=false` means nothing was deleted as well as permission denied. The tool now lists such lines as "deletes that removed nothing" and keeps `DENIED` for other commands.

**What the rule does not prove.** The NameNode cannot tell a block-location lookup from a read, so the 26 events rest on timing and structure. The DataNode's `HDFS_READ` lines would give a second look, but the DataNode here logged 3,155 lines in the window and none of them is a read, so that check could not be made for run 9 (limitations row 60). A plain read hidden inside a submission window would look like a lookup; what changes storage (creates, renames, deletes, mkdirs) is matched exactly.

### 20.7 What it changes elsewhere

- **The cluster is in wrapped mode.** The plain mode exists for the unwrapped control runs of ADR-028 (`cluster-mode.sh plain`, then `wrapped` again) and for the mesh scripts.
- **The procedure of a crawl changes** ([cluster-configuration.md](cluster-configuration.md) section 16): on the worker, rotate the logs and then restart the NodeManager before the crawl, and collect the container logs right after it. The first rotation moved the NodeManager's open log file, and it went on writing into the archive; the NodeManager's reads of the swap demo were found there, not in the clean folder. `audit.sh rotate` now warns about a process that wrote a moved file and still runs (rehearsed 6 of 6; it named the NodeManager, pid 180161, on 9 October at 06:00, and is silent when none runs).
- **The measured set changes**: `core-site.xml` on both nodes and the jar in the library folders (and `hadoop-env.sh` on the master since step 4.5). The re-measurement of step 4.8 must cover them, and the firewall rules must be saved first. Runs 6 to 9 are not covered by the measurement.

### 20.8 Limits of this step

- A final setting does not stop code that calls `conf.set` in its own JVM, or a person who types `-D`; the audit tools use `-D` for the plain client on purpose (row 59).
- The 26 submission lookups of run 9 rest on timing; the DataNode does not log reads (row 60).
- The admin tool, and the two mesh scripts, need plain mode (row 61).
- The NodeManager's wrapper log stays open while it runs; the procedure restarts it, and the tool only warns (row 62).
- Run 9's container logs are not preserved: with log aggregation off, YARN deletes them after its retention time (3 hours by default) and they expired before collection. They were checked at 05:24 UTC (184 files, 92 containers, none mentioning a refusal or an exception); that result is in the session notes, not in a file (row 63).
- The classes exist twice (the job file and the library jar), and the library copy wins (row 64).
- The `on` and `off` branches of `nn-audit.sh` were not run again in their changed form (rehearsal only).
- Run 9 has no unwrapped control and no timing result; the cost of the checks stays unmeasured until the paired runs (ADR-028).
- The NodeManager's reads were seen on one worker only, where every container ran.

### 20.9 Evidence and commits

The bundles `evidence-m46-cluster.tar.gz` (`f17d700d...`, 827 files and its `SHA256SUMS`) and `evidence-m46-run9.tar.gz` (`fb23a3a4...`, 353 files and its `SHA256SUMS`) were compared on the laptop (`MATCH`, every file identical to its list) and unpacked (21 folders in `tdx-evidence\extracted` now). The run 9 bundle has a `NOTES.txt` that says what is not preserved. Before the commits, the ten files were checked identical to the copies that ran (from the zips in the bundle and the tool's folder in Cloud Shell), on the laptop at each commit, and afterwards in a fresh clone from GitHub, which also confirmed that none of the four commits touches `docs/`. The message of the fourth commit lost a space before `(step 4.6.3)` when it was passed through PowerShell; it was left as it is.

| Commit | File | Fingerprint |
|---|---|---|
| `fcffad09d` (new) | `ops/attested/wrapper-jar.sh` | `156fa0303bad491a` |
| `fcffad09d` (new) | `ops/attested/cluster-mode.sh` | `203038fdee3bd764` |
| `bef3a6452` | `ops/attested/audit.sh` | `0e8026d6deedf08b` |
| `bef3a6452` | `ops/attested/records_verify.sh` | `6dc2a7bd361b7b28` |
| `bef3a6452` | `ops/attested/tamper-demo.sh` | `12a633b7b978ebc2` |
| `bef3a6452` | `ops/attested/nn-audit.sh` | `404dd5d9717989b5` |
| `bef3a6452` | `ops/attested/nn-audit-probe.sh` | `be7f2ac749b99d7f` |
| `9ef0f405d` (new) | `ops/attested/nm-swap-demo.sh` | `97f56cd7b3f47c99` |
| `28c811ff4` | `ops/attested/nn_audit_compare.py` | `694e3c6c848d564f` |
| `28c811ff4` | `ops/attested/test_nn_audit_compare.py` | `98a40deb0aaba20c` |

### 20.10 Lessons from this step

- A stand-in written from the same assumption as the script cannot find that assumption's error: the first switch failed on a tool constraint the stand-in did not model. The stand-in now behaves like the real tool.
- A rollback must be checked against the state expected before the change, not against whatever is running afterwards.
- Moving a file does not stop a running process from writing into it; before saying something was not logged, look at where a running writer writes.
- A label has to say what the source says: `allowed=false` on a delete is not "denied". The tool was fixed after the source and the data were read.
- A count is given with its source: "about 40 jobs" was withdrawn, and the real number (27) was confirmed from two independent sources.
- Three of my own new checks were wrong (a substring that missed a parenthesis, a pattern that matched the older leftover, a wrong expected path); the tool was right each time, and the checks were fixed after the output was read.
- Task logs expire: collect them right after a run.
- The mistakes are in [guide-pitfalls-and-lessons.md](guide-pitfalls-and-lessons.md) (mistake log 70 to 78).

### 20.11 The branch builds our job (added 9 October 2026)

Teammate S's TLS patch (step 5.3) has to be built into the same job, so the branch must be buildable by someone else. One file stood in the way: `conf/effective_tld_names.dat`, Mozilla's Public Suffix List, was packed into our job but had never been committed (limitations row 43). Nutch treats a file of that name in `conf/` as an optional override of the older list inside one of its libraries, so a build from a clean checkout would silently have used another list. It is one identical file (334,832 bytes, 16,501 lines, SHA-256 `73c95828f5f62a3f...`, snapshot `2026-09-30_20-56-07_UTC`) in the measured tree, in the scratch clone and inside both jobs, so committing it changes nothing about the job. It was committed as a new file, mode 100644, in `30cd062da`, through the usual gate, and checked from a fresh clone of GitHub.

The test: a fresh clone of the branch at `30cd062da` on the master (`~/clean-build`, 0 changes in the working tree, the list present), then `ant runtime`, which finished with `BUILD SUCCESSFUL` in 33 seconds (the warm dependency cache; the first build took 6 min 30 s). Its job was compared with the job of run 9.

| Comparison | Result |
|---|---|
| `job_compare.py` (CRC-32 of every entry, nested jars by content) | 1,043 entries in both jobs; only in the old job: none; only in the new job: none; same name with different content: none |
| `job_sha_compare.py` (SHA-256 of every entry and of every file inside the nested jars) | 584 plain entries and 82,875 files inside 360 nested jars in both jobs, 0 differences: `JOBS-SAME-BY-SHA256`; 61 nested jars differ in their container bytes but not in their contents |
| The job files themselves | run 9's job `901f01df3423857a` (134,808,775 bytes) and the clean build's job `962047605787971a` (134,808,756 bytes): not byte-identical |

The second tool was added because CRC-32 catches accidental differences, not a deliberate change; it is new in `ops/attested/job_sha_compare.py` (fingerprint `173690075992b57d`) and was rehearsed on made-up jobs before it ran on the real ones.

**What this shows.** Someone who clones the branch and runs `ant runtime` gets, file by file, the job we crawled with. **What it does not show.** The two job files are not byte-identical, which is normal for a rebuild (probably the Nutch plugin jars, rebuilt with new timestamps; that reading is an interpretation, the tool shows only that the 61 differ in container bytes alone): what a rebuild reproduces is the content, and a measurement or a fingerprint of a job belongs to one specific build. The test ran on the master only, with the same Java and Ant versions and a warm cache; a cold build on another machine, and the build by teammate S, were not tried. The jobs of runs 6 to 9 are still not covered by the measurement (ADR-029).

The evidence is the bundle `evidence-m46-cleanbuild.tar.gz` (`5b2b85d0adf5aaed...`, 5 files and its `SHA256SUMS`): the build log, both comparisons, the clone's state with the full fingerprints of both jobs, and the zip of the tool that ran.

## 21. Step 4.7, recon: what the wrapper sees of task attempts (9 October 2026)

Date: 9 October 2026. Status: **the recon is done; the build of step 4.7 is open.** It waits for question 13 to the mentor (may the wrapper be the main source of task records) and for the agreement with teammate S on the naming of her evidence files; both are drafted and were not answered when this was written. The recon changed nothing on the cluster except one deliberate test job (section 21.4).

### 21.1 What step 4.7 needs, in plain words

Step 4.7 asks for **task records** (which task attempt wrote which files, with their hashes), **job manifests** (which files a job's output consists of) and speculative execution off. The open question is where the records come from: the wrapper, which already sees every file operation, or the output committer. Before designing anything, the logs of run 9 and one deliberate failure were read to see what the wrapper already sees.

### 21.2 What run 9's wrapper logs show

| Finding | Value |
|---|---|
| How a task's output is committed | 72 of the 261 renames have an attempt id in their source, each moving one file from `.../_temporary/1/_temporary/attempt_.../part-r-N/data` straight to its final folder (`.../part-r-N/data`), and the 72 creates inside attempt folders equal the 72 attempt-to-final renames. Files therefore reach the final folder at **task commit**, which is the version 2 style of Hadoop's output committer (an inference from the shapes; Nutch does not set the version) |
| The records travel with their files | the `.data.attested` and `.index.attested` companions are renamed beside `data` and `index` |
| Retries and speculative copies | 21 tasks showed attempt ids in the wrapper's paths, all with attempt number 0, and none had a second attempt: **run 9 had no retry and no speculative copy**, so no failure path had ever appeared in our logs |
| The job commit | the ApplicationMaster creates `COMMIT_SUCCESS` and its record in each job's staging folder: 54 lines, 2 per job over 27 jobs. The output `_SUCCESS` marker is never created (0 creates, 0 paths in the after-listing), because Nutch's own `nutch-default.xml` sets `mapreduce.fileoutputcommitter.marksuccessfuljobs` to false and the core jobs repeat it |
| The cleanup | 54 deletes of `_temporary` folders, two per job (the second finds nothing, which is why the NameNode comparison lists deletes that removed nothing) |
| The 189 renames without an attempt id | the job-history files written by the ApplicationMaster (`.summary_tmp`, `_conf.xml_tmp` and `.jhist_tmp`, 27 each, records beside them) and Nutch's own directory renames that install a new crawl database (`crawldb/current` to `old` 7 times, `old` to `old.old` 6 times, the new directory to `current` 6 times); the saved list shows only the 8 most frequent shapes |
| A path is not a stable identity | Nutch renames output directories after a job, so a path recorded at task commit is stale a few seconds later; the Merkle root and length of a file are stable |
| Speculative execution in Nutch's code | off in the fetcher's maps, the indexer's reduces, the injector and the host-database update; **on** in two places of `Generator2` (which turns it off in a third); Hadoop's own default (on) elsewhere. Code in a job can always set it again |

### 21.3 A by-product: the wrapper's record size

The job counters of two runs match the record format exactly: a record is a 56-byte header plus 32 bytes per 16 KiB chunk (the 57-byte seed has an 88-byte record: one chunk). The first test run wrote 601,171,960 bytes (600,000,000 of data and 1,171,960 of record, 36,622 chunks) and the second 1,502,929,752 bytes (1,500,000,000 and 2,929,752, 91,553 chunks); the records cost 0.195 percent in bytes. The counter counts only the committed attempt's bytes.

### 21.4 The failure-injection test

The test uses Hadoop's TeraGen example with one map task that writes one big file through the output committer, fails the first attempt on purpose with `mapred job -fail-task`, and lets the task run again (`ops/attested/attempt-failure-demo.sh`, rehearsed 16 of 16 with stand-ins; `ops/attested/attempt_timeline.py` shows what the wrapper logged for the job, in time order, with the attempts named).

**The first run did not inject a failure.** The job (`job_1791450997865_0038`, 600 MB) had already finished when `-fail-task` was called at 15:54:25: the client reported the application completed and failed trying to reach a job history server, which does not run on this cluster, and the demo reported `FAIL` correctly. The script's guard had checked that the client program was alive, not that the job was running, and the client lived about 30 seconds longer retrying the history server. The guard now asks the cluster, the demo stops with a clear reason if the failing command itself fails, the size went up to 1.5 GB (the job took about 18 seconds for 600 MB, not the minute I had guessed), and the rehearsal has a case that reproduces this exact failure.

**The second run worked** (`job_1791450997865_0039`, 1.5 GB): the first attempt was failed at 16:00:25, the task ran again as attempt 1, the job completed and the final file has 1,500,000,000 bytes. The wrapper logged 59 lines for the job, from five JVMs (the client, the NodeManager, the ApplicationMaster and the two task containers):

| Time into the job | JVM | What the wrapper logged |
|---|---|---|
| 0 to 1 s | the client | uploads of the job's files and their records into the staging folder |
| 1.2 s | the NodeManager | opens of the four job files, verified (as in run 9) |
| 9.2 s | the task, attempt 0 | creates `part-m-00000` in its own folder; **no record** |
| 14.3 s and 14.4 s | the ApplicationMaster, then attempt 0's own JVM | **both delete attempt 0's whole folder** |
| 18.0 s | the task, attempt 1 | creates `part-m-00000` in its own folder |
| 31.2 s | attempt 1 | creates the record `.part-m-00000.attested` (at close) |
| 31.3 s | attempt 1 | **renames the data file and its record to the final folder** (task commit) |
| 31.3 to 31.4 s | the ApplicationMaster | creates `COMMIT_STARTED` and `COMMIT_SUCCESS` (job commit), then the history files |
| 32.6 s | the ApplicationMaster | deletes the staging folder |

The tool's summary: attempt 0 has 1 create and 2 deletes, attempt 1 has 2 creates and 2 renames, `m0: attempts [0, 1]; committed by [1]; folder deleted for [0]`.

### 21.5 What this means for step 4.7 (a reading, not a decision)

- **An aborted attempt is visible in the wrapper's log**: creates inside its folder without a record and without a rename, then the deletion of the folder. Nothing of it reaches the final folder.
- **The wrapper can build task records by itself**: at the rename it sees the attempt id (in the source path), the final path and the file's record, which moves with it. A task record has to be written by the task's own JVM at that moment, because the job commit is made by another JVM (the ApplicationMaster) and the wrapper's logs are per JVM.
- **A job manifest has an observable end**: `COMMIT_SUCCESS` with the job id in its path, created by the ApplicationMaster. The manifest is the union of the committed tasks' records.
- **Files are identified by Merkle root and length**, with the path at commit time and the later renames taken from the wrapper's own rename lines.
- **Speculative execution off is about evidence more than about correctness**: only one attempt per task commits, so a duplicate's files never reach the final folder. Nutch's own code and any job can turn speculation on again, so the records must also show uncommitted attempts, which is possible from the same logs.
- **For teammate S's evidence files**: everything inside an attempt's folder is renamed to the final place with the committed attempt or deleted with a failed one, so evidence files written in the attempt's own work folder with the attempt id in the name share the fate of the data file and its record, and a failed attempt leaves no stray file. This is the naming that was proposed to her.

### 21.6 Limits and what is open

- Only a **failed** attempt was observed. A speculative duplicate or a killed straggler was not, so how it looks in the logs is unshown (limitations row 65).
- The test used TeraGen, not a Nutch job, and one task; a job with several tasks, reducers and Nutch's own output formats was not tried.
- The wrapper's records are per file; there is no task record or job manifest yet (limitations row 66), and paths are not stable identities (row 67).
- The first run's cause was read from its saved log; the container logs of the second run were collected within minutes (they expire after three hours).
- Question 13 and the speculative-execution question for the mentor, and the naming agreement with teammate S, were drafted and are not answered.

### 21.7 Evidence and commits

The bundle `evidence-m47-recon.tar.gz` (`a2e6f0aef21df43f...`, 226 files and its `SHA256SUMS`) holds the recon's output and the two small checks that had been seen only on screen, both test runs (client logs, verdicts, times), the merged wrapper logs of the second run, its container logs, the timeline and the scripts that ran. Three scripts are new in `ops/attested/`:

| File | Fingerprint |
|---|---|
| `attempts_recon.py` (read-only recon of how attempts appear in the wrapper's logs) | `5a546dc0e5f92f70` |
| `attempt-failure-demo.sh` | `5c848fb828ab7e3f` |
| `attempt_timeline.py` | `f7c75b31b8769091` |

### 21.8 Lessons from this step

- A search that a claim rests on is never cut with `head`: a statement about which Nutch jobs switch off the success marker was wrong because the output was cut, and was corrected after the full search.
- A pattern must match what it is meant to: `_SUCCESS` matched the end of `COMMIT_SUCCESS`.
- A guard must test the thing it guards: the first failure test checked that the client program lived, not that the job ran.
- A size chosen from a guess is a guess: say so, or measure first.
- Count every file you add: the bundle had one more file than I predicted.
- The mistakes are in [guide-pitfalls-and-lessons.md](guide-pitfalls-and-lessons.md) (mistake log 79 to 83).
