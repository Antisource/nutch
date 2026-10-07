# Milestone 4: storage integrity (handoff Stage B)

Date: 7 October 2026. Times are UTC. Status: **steps 4.1 to 4.4 done; steps 4.5 to 4.8 open** (section 4).
Written when step 4.3 closed and extended when step 4.4 closed (section 18). It is extended as the later steps close.

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
| 4.5 | Answer length, existence and listings from records, never from storage | 4 | 4.3 | Open | |
| 4.6 | Check the job file and configuration digests at the start of each task | 6 | 4.2 | Open | |
| 4.7 | Task records and job manifests; speculative execution off | 5 | 4.3 | Open | Depends on the answer to question 13 |
| 4.8 | Milestone report; re-measure after a reboot (ADR-020) | | 4.4 to 4.7 | Open | Firewall rules must be saved first |

Old working labels: B0 = 4.4, B1 = 4.2, B2 = 4.3, B3 = 4.5, B4 = 4.6, B5 = 4.7.

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
- **Metadata still comes from storage** (step 4.5). The length is compared with the record at open, which catches a shortened or lengthened file, but listings and existence are storage's.
- **No task records or job manifests** (step 4.7) and no job-file digest check (step 4.6).
- **The NodeManager still reads the job file through plain HDFS.**
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

How a verified crawl is run (every step is a script): rotate the logs on both nodes; put the seeds into HDFS; take the "before" listing; run `ops/run-crawl-attested.sh`; take the "after" listing; check the worker's task logs; copy both listings and both nodes' audit and record logs to Cloud Shell; run `audit_compare.py`, `records_expected.py` (with `--require-sidecars`) and `verify_summary.py` (with `--allow-missing` for the seed folder); copy `expected.tsv` back and run `records_verify.sh` on the master. The tamper test follows (rotate the logs first), then `tamper_verify.py` on the collected logs.

## 16. Decisions taken at this milestone

ADR-021 (keep the record next to the file), ADR-022 (records from the wrapper when a file is closed), ADR-023 (a file without a record is allowed but logged for now), ADR-024 (naming, the commit gate, and verifying assumptions before writing checks), ADR-025 (rehearse code with the real libraries; documents and programs in separate commits). See [decisions.md](decisions.md).

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
