# Milestone 3: the hdfs:// wrapper and the storage audit

Date: 6 October 2026. Times are UTC. Status: **done for Gate A item 2**, with the limitations in section 12.
Written when the milestone closed.

## 1. Goal

The handoff's Gate A, item 2: a pass-through file layer in front of the real storage; pass when a stock multi-cycle crawl completes and its outputs match a run without the wrapper. This surfaces rename, commit and caching problems early.
The mentor decided the design on 6 October (section 3): replace the implementation behind `hdfs://` and keep paths as they are, swap both of Hadoop's lookups, build the real HDFS client directly, and keep the storage audit.

## 2. Background (first principles)

- Hadoop reaches storage through a "file system" object. The prefix of a path (`hdfs://…`, `file://…`) names which one to use, and Hadoop looks the class up in configuration (`fs.<scheme>.impl`).
- Hadoop has a **second, separate lookup** for its other storage API, `FileContext` (`fs.AbstractFileSystem.<scheme>.impl`, which defaults to Hadoop's own `org.apache.hadoop.fs.Hdfs`). Both must be swapped, or part of the traffic bypasses the wrapper.
- A "wrapping" file system extends Hadoop's `FilterFileSystem` and forwards every request to a real one. Here it forwards, and writes a log line for each request that changes storage. It does not hash, sign or verify anything yet.
- **A wrapper behind `hdfs://` fails open.** A program that never gets the two settings silently uses plain HDFS. Because paths no longer show whether the wrapper was used, the proof is an **audit**: list all of storage before and after a crawl, and check that every change is explained by the wrapper's own log.

## 3. How the design was decided

| Option | Idea | Outcome |
|---|---|---|
| A | A new scheme `attested://`, as the handoff words it, with path translation | Built first as a stage-one prototype and tested (63 checks in the author's environment); **dropped, never committed** |
| B | Replace the implementation behind `hdfs://` | **Chosen by the mentor** |
| Hybrid | A, plus a hidden storage root and an after-crawl inventory | Proposed by the author; superseded |

The author had recommended A (it fails loudly where a setting is missing). The mentor chose B with three conditions: (1) swap both lookups, the second through a small adapter class that follows Hadoop's own pattern for its built-in file systems; (2) build the real HDFS client class directly inside the wrapper, never by scheme lookup, which would find the wrapper again and loop; (3) keep the audit from the hybrid, so that the audit is the proof. See ADR-017 in [decisions.md](decisions.md).

## 4. Steps and status

| # | Step | Status | Result |
|---|---|---|---|
| 3.0 | Read-only recon of the cluster, Nutch and Hadoop source | Done | Section 5 |
| 3.1 | Write the wrapper, the adapter, the audit log, the tests and the audit tools | Done | Section 6 |
| 3.2 | Test on the master (Java 11, Hadoop 3.4.3, real HDFS) | Done | Section 7 |
| 3.3 | Build the job in a scratch clone and compare it with run 5's job | Done | Section 8 |
| 3.4 | Run 6 through the wrapper, with the audit | Done | Sections 9 and 10 |
| 3.5 | Compare run 6 with run 5 and run the controls | Done | Section 11 |
| 3.6 | Commit exactly what ran | Done | Commit `a033495` (section 14) |

## 5. Recon findings

- Cluster: Hadoop **3.4.3** (the handoff cites 3.4.1), JDK 11.0.32.1, Ant 1.10.12, JUnit 4.13.2 available; `fs.defaultFS` is `hdfs://hadoop-master:9000`; no `fs.*.impl` setting existed.
- Nutch's Java obtains a file system from the path's prefix in **81** places and from the default in **6** (`FileDumper`, `DmozParser`, `ParseText`, `ParseData`, `Content`, `SeedResource`, judged by file name only; none is in the crawl loop's tools).
- The crawl script passes every `-D` option to each Nutch job, already turns speculative execution off, launches jobs with `hadoop jar`, and itself runs two plain `hadoop fs` commands (a folder test and a segment listing).
- From Hadoop 3.4.3 source (read on GitHub): `FileSystem` finds its class from `fs.<scheme>.impl` first and then from the service loader; `AbstractFileSystem` finds it **only** from `fs.AbstractFileSystem.<scheme>.impl`; S3A and the local file system show the adapter pattern (`DelegateToFileSystem` with a `(URI, Configuration)` constructor); `FilterFileSystem` forwards the main data calls.

## 6. What was built

| Class or file | Purpose |
|---|---|
| `AttestedHdfsFileSystem` (extends `FilterFileSystem`) | Forwards every request to the real HDFS client, which it builds with `new DistributedFileSystem()`; refuses to start if its inner file system is another wrapper; logs every request that changes storage, and opens |
| `AttestedHdfs` (extends `DelegateToFileSystem`) | The `FileContext` side, set through `fs.AbstractFileSystem.hdfs.impl` |
| `AttestedAudit` | One log file per JVM (`host-pid-start.tsv`) in `attested.audit.dir` (default `/tmp/attested-audit`); the wrapper refuses to start if the folder cannot be written |
| `ops/run-crawl-attested.sh` | The run 1 to 5 driver with three added `-D` settings: both lookups and the audit folder |
| `ops/attested/audit.sh`, `audit_compare.py` | List all of HDFS (`snapshot`), move old logs aside (`rotate`), and compare two listings with the logs |
| `ops/attested/job_compare.py` | Compare two job files entry by entry (nested jars by content) |
| `ops/attested/AttestedFsSmoke.java`, `build-and-test.sh` | The smoke tests and the script that builds and runs them |

There is no registration file and no path translation: the wrapper is switched on by the two settings only. Log lines have seven fields: time, host, process, operation, path, second path, extra. They are written **before** a request is forwarded, so the log can list more than happened, never less.

## 7. Tests

| Where | Test | Result |
|---|---|---|
| Author's environment (Hadoop 3.4.1 jars, fake HDFS on local disk) | wrapper checks, including `FileContext` and the audit lines | 43 of 43 |
| same | a MapReduce job through the wrapper | 7 of 7 |
| same | the audit tool, on made-up crawls | clean for honest crawls (rename of a folder with files, chained renames, the MapReduce commit pattern, recursive delete, concat); caught an unlogged file, an unlogged delete, an edit after a folder move, and a file that vanished during a move |
| Master (Java 11, Hadoop 3.4.3) | same fake-HDFS checks | 43 of 43 and 7 of 7 |
| Master, **real HDFS** | create, read, rename, delete, `FileContext`, an independent real client, audit lines | 42 of 42 |
| Master, classes taken from the job file | MapReduce and real HDFS | 7 of 7 and 42 of 42 |

The tests found real gaps: the one-argument `mkdirs` was forwarded untouched (Option A prototype), and the first audit tool missed an edit made after a folder move (fixed: a moved file must keep its size). Hadoop's own file-system contract tests were not run.

## 8. The job

Built in a scratch clone (`~/m3-build`) of the branch at `cefbd4c` plus the eight files of the first package, so the measured tree and run 5's job stayed untouched (ADR-019). The corrected `audit_compare.py` and `job_compare.py` ran outside the clone, in Cloud Shell and in the home folder. The first build took 36 seconds.

- A comparison of the two job files found one extra difference: run 5's job contains `conf/effective_tld_names.dat`, an **untracked** file of the measured tree that a clean clone lacks. It was copied into the clone and the job rebuilt (17 seconds).
- Result (`job_compare.py`): run 5's job `bbd30ad90d357ca1` has 1029 entries; run 6's job `ddc415a5d87c9e6b` has 1033. The four extra entries are the wrapper's folder and three classes. Nothing is only in the old job and nothing shared differs, nested plugin jars included.

## 9. Run 6

| Item | Result |
|---|---|
| Seeds and crawl folders | `seeds-run6`, `crawl-run6` |
| Duration | first segment 13:42:23, `Finished loop with 3 iterations` at 13:52:41 (about 10 to 12 minutes) |
| Segments | `20261006134223`, `20261006134530`, `20261006134921` |
| Failures | none found by the log scan; fetcher `errors_total=0` |
| Plugin lines in the master's log | okhttp 19, old plugin 0 |
| Worker task logs | 22 list okhttp, 0 list the old plugin |
| YARN applications | 27 (numbers 0029 to 0055) |
| Wrapper start-ups | 300 lines in 111 JVMs (19 on the master, 92 on the worker); all 300 name `inner=org.apache.hadoop.hdfs.DistributedFileSystem`, the wrapper class, and a job folder as the source |

## 10. The audit

| Item | Result |
|---|---|
| Hosts that reported the wrapper | `tdx-lab` and `tdx-lab-worker`, matched by exact name |
| Logged operations | INIT 300, CREATE 364, DELETE 164, MKDIRS 110, OPEN 157, RENAME 142, SETATTR 270, COPYFROMLOCAL 27 (one job upload per application) |
| Storage before and after | 963 paths, then 1,150 |
| Changes | **187 added, 0 removed, 0 changed; all 187 explained by the log** |
| Verdict | **AUDIT-CLEAN**, with no allow-list |

Meaning: nothing that remains in storage after the crawl was changed by a program outside the wrapper. Not shown: reads by unwrapped programs (the crawl script's two `hadoop fs` commands), a change that keeps size and time, and files created and deleted between the two listings (the wrapper's log shows them, but nothing independent cross-checks them).

## 11. Comparison with run 5, and the controls

Fetched pages: the same 8 URLs (`SAME-PAGES`), 18 files, the same address for every URL, the same two permanent redirects, normal HDFS byte counters (27 lines each; largest read counter 32,527 in run 5 and 32,533 in run 6), and 7 of 8 pages with **identical content**.

The one different page is `www.zyte.com`, and the crawl database has two more discovered URLs (259 against 257; unfetched 249 against 247).

- Runs 3, 4 and 5 (no wrapper) have identical fingerprints for that page (`sha1:SOKCP57…`) and identical crawl databases (257, 247, 8, 2). Run 6 is the first to differ.
- The page itself shows why: its deployment identifier changed from `dpl_Aw3cvvrezTgDVzNUPQtGSiZL7Jng` (fetched 08:24:52) to `dpl_6K3MMTWXqBLaBfG2FGJjgYif2oA4` (fetched 13:50:01), and its stylesheet file names changed with it. The live site at 14:37 serves `dpl_6K3M…`, the same as run 6.
- The redeployed page has two new links that are not build assets (`/mcp/`, `/skills-and-plugins/`), matching the two extra URLs in count; they were not traced one by one.
- Not done: a contemporaneous unwrapped run. The wrapper only touches storage and cannot change what the fetcher downloads, and the evidence above points at the site.

Two earlier guesses were wrong and are recorded in [guide-pitfalls-and-lessons.md](guide-pitfalls-and-lessons.md): that HDFS byte counters might read zero through the wrapper, and that the live site "changes on every fetch". Detail: [run-comparison.md](run-comparison.md) section 9.2.

## 12. What was not done

- **Nothing is hashed, signed or verified yet.** The wrapper forwards and logs.
- **The wrapper fails open.** It is in place only where the settings reach; the audit is the proof for this crawl.
- **Not wrapped:** the NodeManager (it fetches the job file through plain HDFS), the daemons, and the crawl script's two `hadoop fs` commands.
- **The audit's limits:** section 10.
- **The log and the listings are plain files** on the provider's machines; they are an engineering proof, not evidence against an adversary.
- **No contemporaneous unwrapped control run**, no Hadoop contract tests, no restart or failure tests.
- **The measured chain does not cover run 6.** The measured set (the main tree) is unchanged: `check-unchanged.sh` reported all ten components `SAME` after run 6 (kept as `check-unchanged-after-m3.txt` in the evidence folder). But run 6 used a job and scripts outside that set. A second measurement needs a reboot by design, and is deferred until the job next changes (ADR-020).
- **The measured tree is not a clean checkout** (one untracked file in `conf/`); a clean build gives a different job.

## 13. Differences from the handoff (to apply to the handoff later)

1. The wrapper replaces the implementation behind `hdfs://` instead of registering `attested://` (mentor-approved).
2. Both lookups must be swapped: `fs.hdfs.impl` and `fs.AbstractFileSystem.hdfs.impl`.
3. "Nutch always reaches storage through this layer" is not literally true (81 path-style calls and 6 default-style); with the `hdfs://` replacement every request of a configured JVM goes through anyway.
4. The job file is uploaded through the wrapper by the client (27 uploads), but the NodeManager reads it through plain HDFS, so the handoff's "job code verified at load" (item 3 of the control plane) is still open.
5. Hadoop is 3.4.3, not 3.4.1.

## 14. Evidence and scripts

| Bundle | Files | Fingerprint (12 hex) | Contents |
|---|---|---|---|
| `evidence-run6.tar.gz` | 42 | `fe84c4a8b3a1` | the 18 WARC and index files, the crawl log, both HDFS listings, the job comparison, the control and deployment checks, the smoke-test logs, the page analysis with its tools, the recon outputs, the build log |
| `evidence-run6-audit.tar.gz` | 117 | `cf51c931c498` | before and after listings, the audit result, all 111 wrapper logs, the start-up check, the worker's task-log check |

Both were compared by PowerShell on the laptop against their `.sha256` files (`MATCH`) and unpacked into `tdx-evidence\extracted`.
The nine files were committed as `a033495` and checked from a fresh clone against the fingerprints recorded when each ran: three classes under `src/java/org/apache/nutch/attested/`, and under `ops/`: `run-crawl-attested.sh` and, in `attested/`, `AttestedFsSmoke.java`, `build-and-test.sh`, `audit.sh`, `audit_compare.py`, `job_compare.py`.

## 15. Decisions taken at this milestone

ADR-017 (replace the implementation behind `hdfs://`), ADR-018 (the storage audit is the proof), ADR-019 (build and test in scratch folders; commit what ran), ADR-020 (defer the re-measurement until the job next changes). See [decisions.md](decisions.md).
