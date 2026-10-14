# Decision log

Short records of decisions that shape the work, in the style of architecture decision records (ADRs). Each entry says what was decided, why, what it costs, and its status.
Decisions taken before 5 October 2026 (runs 1 and 2) are in [guide-pitfalls-and-lessons.md](guide-pitfalls-and-lessons.md), section 4. Entries here are added as decisions are made; a decision is never edited away, only superseded by a later entry.
Times are UTC.

| ADR | Decision | Status |
|---|---|---|
| 001 | Plain TDX VMs with our own image | Accepted (mentor) |
| 002 | TLS certificate checking stays off for now | Provisional |
| 003 | Kernel route: Ubuntu 24.04's 6.17 kernel on the existing VMs | Accepted; fallback recorded |
| 004 | One RTMR3 event per component, with our own event log | Accepted |
| 005 | Measure the CA store as a sorted fingerprint list | Accepted |
| 006 | Measure JDK settings and the CA store as separate components | Accepted |
| 007 | Run 3 on fresh folders and a rebuilt job | Accepted |
| 008 | Scripts in the repository, evidence outside it | Accepted |
| 009 | JDK start-up cache (`classes.jsa`): handling deferred | Open |
| 010 | Measure at run time now; lock the image down later | Accepted |
| 011 | Use the existing VMs, protected by snapshots; no extra test VM | Accepted |
| 012 | Documentation as we go; README and first-principles guide last | Accepted |
| 013 | WireGuard mesh: addressing and tooling | Accepted |
| 014 | Host firewall and hosts-file names instead of per-daemon binding | Accepted |
| 015 | Map the nodes' internal names to the mesh | Accepted |
| 016 | Refusal test without a third VM | Accepted |
| 017 | Replace the implementation behind `hdfs://` with the wrapper (Option B) | Accepted (mentor) |
| 018 | The storage audit is the proof that the wrapper was used | Accepted |
| 019 | Build and test in scratch folders; commit exactly what ran | Accepted |
| 020 | Defer the re-measurement until the job next changes | Accepted (mentor confirmation asked); carried out on 14 October (ADR-040) |
| 021 | Keep each file's record next to the file | Accepted (mentor confirmation asked) |
| 022 | Records come from the wrapper when a file is closed, not from the commit hook | Accepted (question 13 is moot since ADR-034 dropped the task records) |
| 023 | A file without a record is allowed but logged, for now | Accepted (provisional) |
| 024 | Naming, the commit gate, and checking assumptions against real samples | Accepted |
| 025 | Rehearse code with the real libraries; documents and programs in separate commits | Accepted |
| 026 | The mentor's answers of 7 October 2026 | Accepted (mentor) |
| 027 | The wrapper on Hadoop's own classpath, both lookups final | Accepted (mentor) |
| 028 | Every wrapped crawl has an unwrapped control in the same hour; wall time and bytes fetched are recorded | Accepted (mentor) |
| 029 | Nothing that is not measured is described as measured | Accepted (mentor) |
| 030 | Answers about files are checked against the records; findings fail closed by default | Accepted |
| 031 | The audit, admin and demo tools ask for the plain client explicitly | Accepted |
| 032 | Before a crawl, rotate the logs and restart the wrapped daemon; collect the container logs right after | Accepted |
| 033 | The NameNode comparison gets two explicit rules, visible and switchable | Accepted |
| 034 | Storage integrity rests on one mechanism, sign on write and verify on read; step 4.7 and the task records are dropped | Accepted (Pingshan, 10 October) |
| 035 | Folder identity files bind a file to its folder | Accepted (Pingshan, 10 October) |
| 036 | The WARC is the point where teammate S's layer and ours connect | Proposed by teammate S |
| 037 | The mentor's answers of October 2026 (policy, certificates, single-record verification, performance, TLS capture, threat model) | Accepted as direction; the plan is not yet updated |
| 038 | Reading a file's content and asking about its status are two different questions, with two settings for a file without a record | Accepted |
| 039 | The wrapper's own settings count only when the site configuration set them | Accepted |
| 040 | The re-measure covers the patched job, the policy folder and the repository's ops folder, and needs a one-time boot into 6.17 | Accepted |
| 041 | A timing pair: the wrapped run first, then a plain control with the same job, seeds and settings, then the wrapped settings restored and proved | Accepted |
| 042 | Kits are committed as folders exactly as they ran, without other people's code and without evidence | Accepted; publishing the teammate's files needs her consent |

---

## ADR-001: Plain TDX VMs with our own image

- **Date:** 5 October 2026. **Status:** accepted by the mentor.
- **Context:** the handoff offered plain TDX VMs with our own image, or Google Confidential Space (less image work, but Google's attestation service joins the trust chain; multi-node Hadoop inside it is unproven).
- **Decision:** keep plain TDX VMs.
- **Why:** full control of the kernel, the network and the image; raw quotes can be verified off-cloud by us, as already done.
- **Consequences:** we build and measure our own image; kernel and boot configuration are ours to maintain.

## ADR-002: TLS certificate checking stays off for now

- **Date:** 5 October 2026; updated 6 October. **Status:** provisional; to be settled at the next mentor meeting.
- **Context:** stock CCBot sets `http.tls.certificates.check` to false. With it off, whoever controls the network can impersonate a site, and the measured crawler will archive the fake page. The mentor's instinct was to leave it off and rely on a teammate's code.
- **What the teammate reports (relayed, not tested by us):** their source-receipt code runs in the live fetch path, validates certificates itself and fails closed (they tested wrong host, self-signed, expired and untrusted-root cases with CCBot's checking off), and refuses to issue a receipt for such pages. CCBot may still fetch and archive them without a receipt. They will ask whether their layer is sufficient or whether CCBot's own checking should also be on.
- **Decision:** leave it off in our runs (runs 3 and 4 used the default).
- **Consequences:** archived pages can lack receipts, so a verifier must decide whether to drop, label or reject such records. The teammate's code becomes part of what must be measured once its layout is known. If checking is turned on, the job file changes and the stack is measured again.

## ADR-003: Kernel route: Ubuntu 24.04's 6.17 kernel on the existing VMs

- **Date:** 5 October 2026. **Status:** accepted; fallback recorded.
- **Context:** extending RTMR3 needs kernel 6.16 or later. Ubuntu 22.04 offers Google kernels only up to 6.8; 24.04 offers 6.17 and 7.0. The mentor asked us to confirm the upgrade was needed and, if not too much trouble, to go ahead; later she left the choice to us. We preferred not to create a new VM.
- **Options:** (A) install 24.04's 6.17 kernel packages on the 22.04 VMs; (B) upgrade the whole OS in place; (C) create new 24.04 VMs.
- **Decision:** A. Safeguards: a snapshot of each boot disk first, a GRUB backup, the running kernel pinned as the default, a one-time boot request, checksums for both packages. Fallback: C if A fails.
- **Why:** smallest change, nothing else on the VMs is touched, and the measurement mechanism lives in the kernel, not in the userland on top. The package dependencies were satisfiable on 22.04, the new kernel's drivers needed for an initramfs-less boot are built in, and Secure Boot is off.
- **Consequences:** an unsupported combination, tested only on these two machines. The nodes return to 6.8 on the next reboot unless the default is changed. A clean, reproducible 24.04 image remains a later milestone.

## ADR-004: One RTMR3 event per component, with our own event log

- **Date:** 5 October 2026. **Status:** accepted.
- **Context:** RTMR3 only holds a hash chain, so a verifier needs a log to interpret it.
- **Decision:** extend once per component (JDK, JDK settings, CA list, Hadoop code, Hadoop config, deploy folder, driver, seeds), in a fixed order, recording `name, digest, before, after` in a tab-separated log; request the quote with the log as input so REPORTDATA is the log's SHA-512.
- **Why:** a verifier can see which component is wrong, and the log is bound into the quote.
- **Consequences:** the log must travel with the quote; the chain is lost at reboot and must be rebuilt; the first test marker stays in the master's chain.

## ADR-005: Measure the CA store as a sorted fingerprint list

- **Date:** 5 October 2026. **Status:** accepted.
- **Context:** the two nodes' CA store files differ in bytes but hold the same 121 certificates, with the same package versions.
- **Decision:** measure the sorted list of certificate fingerprints, not the raw file.
- **Why:** pinning the raw file would reject a valid node.
- **Consequences:** if the CA package changes, the list changes and is measured again.

## ADR-006: Measure JDK settings and the CA store as separate components

- **Date:** 5 October 2026. **Status:** accepted.
- **Context:** 26 files inside the JDK folder are symlinks into `/etc`; a folder fingerprint records the link, not the target.
- **Decision:** measure `/etc/java-11-openjdk` and the CA list as their own components.
- **Consequences:** the quote now identifies the Java settings and trust store as well as the binaries.

## ADR-007: Run 3 on fresh folders and a rebuilt job

- **Date:** 5 October 2026. **Status:** accepted.
- **Context:** the configuration is packed into the job file, so the two config fixes needed a rebuild.
- **Decision:** a separate run 3 with its own HDFS and evidence folders; runs 1 and 2 untouched.
- **Consequences:** run 3 is not byte-comparable with runs 1 and 2 (different job hash).

## ADR-008: Scripts in the repository, evidence outside it

- **Date:** 6 October 2026. **Status:** accepted.
- **Context:** the repository is public. Evidence is large, machine-specific (hostnames, IPs, disk identifiers) and derived.
- **Decision:** commit scripts under `attest/measure/` and `ops/`, with the filenames unchanged so each evidence bundle's script fingerprints match the committed files, and a `.gitattributes` forcing LF line endings there. Keep bundles outside the repo and list them, with fingerprints, in the milestone reports.
- **Consequences:** a fresh clone reproduces the tested scripts byte for byte; evidence must be stored and backed up separately.

## ADR-009: JDK start-up cache (`classes.jsa`)

- **Date:** 5 October 2026. **Status:** open.
- **Context:** this one file differs between the nodes (generated per machine). Excluding it from the fingerprint would leave a file the JVM may load unmeasured; including it makes the two nodes' JDK digests differ.
- **Options:** (a) build one image and share one copy; (b) disable the cache and exclude the file; (c) keep per-node digests.
- **Decision:** deferred to the image build. Until then, per-node digests (c) are recorded as measured.

## ADR-010: Measure at run time now; lock the image down later

- **Date:** 5 October 2026. **Status:** accepted.
- **Context:** the handoff wants a read-only verified root disk, no login, and the stack extended into RTMR3 before any job runs.
- **Decision:** for Milestone 1, measure after boot and before the crawl, by script, and re-hash after the crawl. The read-only root, no-login image and a boot-time service belong to a later milestone.
- **Consequences:** the measurement shows what was there when measured; it does not prevent a change between measuring and running.

## ADR-011: Use the existing VMs, protected by snapshots

- **Date:** 5 October 2026. **Status:** accepted.
- **Context:** the kernel test could have used a temporary third VM.
- **Decision:** no extra VM. Snapshot each boot disk before any change (`tdx-lab-pre-kernel-1005`, `tdx-lab-worker-pre-kernel-1005`). Delete the snapshots when the kernel work is stable.
- **Consequences:** a small storage cost; a failed boot is recovered by resetting to the pinned kernel or restoring a snapshot.

## ADR-012: Documentation as we go; README and first-principles guide last

- **Date:** 6 October 2026. **Status:** accepted.
- **Decision:** write a milestone report when each milestone closes; update the living documents (limitations table, cluster configuration, quote verification, pitfalls, comparison) as facts change; keep this log. Leave `README.md` and `guide-first-principles.md` until the end of the technical work, because they summarise everything.
- **Consequences:** the README's file list lags until the end.

## ADR-013: WireGuard mesh: addressing and tooling

- **Date:** 6 October 2026. **Status:** accepted.
- **Context:** node-to-node traffic crossed the cloud network in plaintext.
- **Decision:** a two-node WireGuard mesh: master `10.10.0.1/24`, worker `10.10.0.2/24`, UDP 51820, one static peer each, keepalive 25 s. Tools from Ubuntu's signed archive (`wireguard-tools`, no recommended extras). Keys generated on each node; only public keys leave it; the interface starts at boot.
- **Why:** the kernel already includes WireGuard; it is small and simple; Google's internal-traffic rule already lets the UDP through.
- **Consequences:** one extra package on the VMs (outside the measured folders); static keys on the boot disk (root only); peer admission by attestation is a later milestone (the mesh's keys are not tied to quotes).

## ADR-014: Host firewall and hosts-file names instead of per-daemon binding

- **Date:** 6 October 2026. **Status:** accepted.
- **Context:** the master's RPC daemons bind through the name `hadoop-master`, but the NameNode web page and all of the worker's daemons listen on all addresses. Binding each daemon needs configuration differences between nodes.
- **Options:** (a) per-daemon bind settings in Hadoop's configuration files; (b) point the names at the mesh in `/etc/hosts` and close the ordinary interface with a host firewall.
- **Decision:** (b). The firewall accepts loopback, established connections, `wg0`, UDP 51820, SSH, ping and the metadata server, counts and drops the Hadoop ports on other interfaces, and drops everything else. A self-undo timer protects the first application.
- **Why:** Hadoop's configuration files stay identical on both nodes, so the measured configuration does not change; no restart-order subtleties; the counted rule gives evidence.
- **Consequences:** the wildcard listeners remain and depend on the firewall; the rules are not saved across reboot (the script is safe to re-run); the firewall and hosts file are not in the measured set. Per-daemon bind settings remain an optional second layer.

## ADR-015: Map the nodes' internal names to the mesh

- **Date:** 6 October 2026. **Status:** accepted.
- **Context:** after the hosts change the worker's NodeManager registered under Google's internal DNS name, which resolves to the ordinary address that the firewall blocks.
- **Decision:** add the two nodes' internal names (long and short) to `/etc/hosts` on both nodes, pointing at the mesh addresses; restart Hadoop; verify with a real job.
- **Consequences:** any name Hadoop might use for a node must resolve to its mesh address; check `yarn node -list` and run a small job after any network change.

## ADR-016: Refusal test without a third VM

- **Date:** 6 October 2026. **Status:** accepted.
- **Context:** the handoff asks for a job submitted from a third machine outside the mesh to be refused. We preferred not to create another VM (ADR-011).
- **Decision:** test over the ordinary network path between the two existing nodes, in both directions, with port probes and one real job submission aimed at the ordinary address, and read the firewall's counted drop rule before and after.
- **Consequences:** it shows that traffic arriving over the ordinary network is refused; it does not test a separate machine, IPv6, or a firewall that is absent after a reboot.

## ADR-017: Replace the implementation behind hdfs:// with the wrapper (Option B)

- **Date:** 6 October 2026. **Status:** accepted by the mentor; supersedes the author's earlier recommendation of Option A.
- **Context:** the handoff words the wrapper as a class registered under a custom scheme such as `attested://`. Three ways were weighed: A (a new scheme, with path translation), B (replace the implementation behind `hdfs://`), and a hybrid (A with a hidden storage root and an inventory).
- **Decision:** B, with three conditions from the mentor. (1) Swap both lookups, `fs.hdfs.impl` and `fs.AbstractFileSystem.hdfs.impl`; the second needs its own small adapter class, following the pattern Hadoop uses for its built-in file systems (`DelegateToFileSystem`, as S3A does). (2) Inside the wrapper, construct the real HDFS client class directly, never through a lookup by scheme, which would find the wrapper again and loop. (3) Keep the audit: list all of storage before and after a crawl and compare with the wrapper's log (ADR-018).
- **Why:** no path translation (Option A needs a translation layer; Hadoop's `ChRootedFileSystem`, the closest example, overrides 60 methods, and a scheme swap is a known rough edge of `FilterFileSystem`, whose own comment says other things break); every `hdfs://` request in a configured program is covered, including the six places where Nutch asks for the default file system.
- **Consequences:** the wrapper fails open, because a program without the two settings silently uses plain HDFS. Paths no longer show whether the wrapper was used, so the audit is the proof. The NodeManager, the daemons and the crawl script's two `hadoop fs` commands are not covered. The Option A prototype was never committed.

## ADR-018: The storage audit is the proof that the wrapper was used

- **Date:** 6 October 2026. **Status:** accepted.
- **Context:** with ADR-017 the paths look the same whether or not the wrapper handled a request.
- **Decision:** every JVM that loads the wrapper writes a local log line for each request that changes storage, and for opens, before forwarding it; the wrapper refuses to start if it cannot write the log. After a crawl, `audit_compare.py` checks that every difference between a listing of all of HDFS taken before and one taken after is explained by a log line (a path created, renamed, deleted, appended or changed), that moved files keep their size, and that every required host wrote a start-up line. No allow-list is used unless a stated reason exists.
- **Why:** it is the only check that does not depend on the wrapper's own claims; it was tested with planted faults.
- **Consequences:** it shows that no change that remains in storage came from outside the wrapper; it does not show reads, same-size edits, or files created and deleted between the two listings. The logs and listings are plain files on the provider's machines; the final design replaces them with signed records.

## ADR-019: Build and test in scratch folders; commit exactly what ran

- **Date:** 6 October 2026. **Status:** accepted.
- **Context:** the measured tree and the job of run 5 must stay reproducible, and code should enter the repository only after it has run on the cluster.
- **Decision:** unpack new files into a scratch folder on the master and test there; build the job in a scratch clone and compare it with the measured job entry by entry; commit only files whose fingerprints equal those recorded when they ran, and check them from a fresh clone.
- **Consequences:** the job of run 6 is not the measured job, so the measurement chain does not cover run 6; it is redone, after a reboot, when the job next changes (ADR-020). A clean clone builds a different job from the measured one because of an untracked file, `conf/effective_tld_names.dat`, which was copied into the clone.

## ADR-020: Defer the re-measurement until the job next changes

- **Date:** 6 October 2026. **Status:** accepted by the author and the maintainer; the mentor is asked to confirm. **Carried out on 14 October 2026 (ADR-040).**
- **Context:** the measured set is the main tree, and it is unchanged (all ten components `SAME` after run 6). Run 6 ran from a scratch build outside it. `measure-all.sh` refuses to measure twice in one boot, so covering the new job needs a reboot of both nodes. A reboot also removes the firewall rules, stops the daemons that were started by hand, returns each node to the pinned 6.8 kernel (which has no measurement interface) and needs a one-time boot into 6.17.
- **Decision:** do not reboot now. Re-measure, from a clean boot, when the job next changes; the next milestone changes it. Until then, record that run 6 is not covered by the chain and keep running `check-unchanged.sh` to show the measured tree is intact.
- **Why:** a measurement now would cover a state that is about to be replaced, at the price of a reboot's risks; the Gate A measurement item already passed in Milestone 1.
- **Consequences:** run 6 is not in the chain, and the documents say so. The next measurement points `NUTCH_DIR` at the build folder that holds the hashing layer.

## ADR-021: Keep each file's record next to the file

- **Date:** 7 October 2026. **Status:** accepted by the author and the maintainer; the mentor is asked to confirm.
- **Context:** verifying a read needs the file's record at read time, on any machine, and the record must survive the renames Hadoop performs while committing output. There is no ledger and no signing yet (Stage C).
- **Decision:** a hidden companion file `.NAME.attested` in the same folder, written when the file is closed (format `ATTEST01`: length, chunk size, the hash of every chunk and the Merkle root). The wrapper moves it when the file is renamed (a renamed folder carries it along), deletes it with the file, drops it when the file is appended to, truncated or concatenated, and hides it from its own listings.
- **Why:** it is the pattern of Hadoop's own `.NAME.crc` files; it follows renames without a central index; any machine can read it. Alternatives were a central record store (it needs a rename-aware index, and the Stage C ledger will hold the hashes anyway) and records only in local logs (other machines cannot read them).
- **Consequences:** plain HDFS tools list the companion files. Until records are signed, rewriting a file and its record together is accepted (a test states this). If the mentor prefers another store, the read and write code of `AttestedSidecar` is what changes; the format is versioned so that signing adds fields.

## ADR-022: Records come from the wrapper when a file is closed, not from the commit hook

- **Date:** 7 October 2026. **Status:** accepted by the author; to be put to the mentor as question 13 (not asked yet).
- **Context:** the handoff has the task's output committer sign the record. Step 4.1 found that Nutch's fetch, parse and WARC outputs are written directly to their final path, and that the parse output creates its own committer, so the committer hook set by configuration does not see every file.
- **Decision:** the wrapper makes a record for every file when it is closed, tagged with host, process, job id and the task attempt id read from the task's configuration. The committer stays an optional extra for manifests.
- **Why:** the wrapper is the one place that sees every file, whatever output format wrote it.
- **Consequences:** a file whose writer is killed before closing it has no record; the completeness of a job's outputs (step 4.7) has to come from the per-attempt records and Hadoop's counters. If the mentor wants the committer as the main source, a custom committer is needed for the parse output (medium effort), and the wrapper's records can stay as a second line of defence.
- **Update (10 October 2026):** question 13 is moot. ADR-034 drops the task records and the job manifests, so the wrapper is no longer asked to be the source of anything beyond the signed per-file record.

## ADR-023: A file without a record is allowed but logged, for now

- **Date:** 7 October 2026. **Status:** accepted (provisional).
- **Context:** some data is put into HDFS by the command-line client (the seed file), which does not use the wrapper; the crawl has to run, and the first goal is to find which paths lack a record.
- **Decision:** the setting `attested.verify.missing` defaults to `warn`: the open is logged as `verify=missing` and the file is read unverified. The verification summary lists such reads, and each use of its allow list needs a stated reason (run 8: the seed folder). The default becomes `fail` when every writer goes through the wrapper.
- **Why:** it keeps runs going while the gaps are found, and every gap is visible.
- **Consequences:** until the default is `fail`, a file that has no record, or whose companion file was removed with plain tools, is read unverified; the summary shows it.

## ADR-024: Naming, the commit gate, and checking assumptions against real samples

- **Date:** 7 October 2026. **Status:** accepted.
- **Context:** the working labels B0 to B5 confused the author; a tamper demo and several expected values were wrong because they were written from assumptions about other tools' output and tested with stand-ins built from the same assumptions; code and documents must match what actually ran.
- **Decision:** (1) names are Milestone N and Step N.k with a descriptive title, runs are numbered, and the handoff's item numbers stay as references. (2) A commit gate: committed programs and scripts are checked identical, by fingerprint, to the files that ran, on the cluster, on the laptop and in a fresh clone from GitHub; on any difference the commit and push are aborted. The documents are checked against the procedure followed and against the evidence (`docs_facts_check.py`). (3) Before a check depends on another tool's real output, a read-only sample of that output is read; proofs rely on what our own code writes (audit lines, records).
- **Why:** unverified assumptions cost hours of repeated steps on 7 October.
- **Consequences:** a little slower per step and much fewer repeats; each milestone has a facts file that ties the documents' numbers to the evidence.

## ADR-025: Rehearse code with the real libraries; documents and programs in separate commits

- **Date:** 7 October 2026. **Status:** accepted.
- **Context:** the first version of the contract tests was only type-checked against stand-ins written from the author's own assumptions, and failed at compilation on the cluster. The author asked for documents and programs to be kept apart in the history.
- **Decision:** (1) code that depends on real libraries is rehearsed in the development environment with those libraries (or the nearest available versions) before it is sent to the cluster, and the message says what could not be rehearsed. (2) Documents and programs are committed separately, each with its own gate: programs first, each checked identical to the files that ran; then documents, checked against the evidence by the facts checker. A tool's data file (for example a facts list) is committed as a program. The one earlier exception is commit `d4c5489`, which also carried the facts checker.
- **Why:** the rehearsal found three defects in the wrapper and one in the runner before the cluster run, and a clear separation makes the history easier to read and review.
- **Consequences:** some libraries are not reachable from the development environment, so a rehearsal can use a different version (AssertJ 3.14.0 instead of 3.12.2) or leave one class out (`VectoredRead`); each such gap is stated in the report.

## ADR-026: The mentor's answers of 7 October 2026

- **Date:** 7 October 2026. **Status:** accepted by the mentor.
- **Context:** the questions of 6 October (1 to 5 for Gate A, 6 to 12 for Stage B) were answered. The mentor's reply, as relayed by Rishab (the "(teammate S)" is his note):

  > This seems fine. We might have to fix things afterwards
  >
  > Gate A accepted. (1) Yes; from Stage B on, run the unwrapped control in the same hour. (2) Yes as scoped; turn on the NameNode audit log in Stage B. (3) Defer, as long as nothing unmeasured is ever described as measured. (4) Apply the handoff corrections now, in one commit with a corrections list at the top. (5) Nothing new until the 16 October list; plan for mid-November to 20 November, 5 pages plus 2.
  > For Stage B, use your defaults except 6: a task hashing its own job file can be skipped by a swapped job file, so it isn't a security check. Move the wrapper onto Hadoop's own classpath and set both lookups in the site config as final, so the NodeManager uses it too. 11 is Subhi's (teammate S) patch: please coordinate with her on building the job with it. Per Amir, performance is the result that matters most, so start recording wall time and bytes fetched for every wrapped and unwrapped pair.

- **Decision:** the mentor said:
  1. Gate A is accepted. (1) The evidence for "outputs match" is enough; from Stage B on, run the unwrapped control in the same hour (ADR-028).
  2. (2) The audit's scope is accepted; turn on the NameNode audit log in Stage B (step 4.5, baby step 4.5.2).
  3. (3) The re-measurement is deferred, as long as nothing unmeasured is ever described as measured (ADR-029).
  4. (4) The handoff corrections are applied now, in one commit with a corrections list at the top ([handoff-attested-hadoop-cluster.md](handoff-attested-hadoop-cluster.md)).
  5. (5) Nothing new until the 16 October list; the workshop paper is planned for mid-November to 20 November, 5 pages plus 2.
  6. For Stage B our defaults stand (HDFS; a test key behind an interface; hash everything with a path filter; a witness interface with a local stand-in; contract tests first), except question 6, which becomes ADR-027, and question 11, per-fetch TLS evidence, which is teammate S's patch: the job is to be built with it in coordination with her (Milestone 5, step 5.3).
  7. Per Amir, performance is the result that matters most: wall time and bytes fetched are recorded for every wrapped and unwrapped pair (ADR-028).
- **Why:** these are the mentor's decisions.
- **Consequences:** the plan of six milestones is unchanged ([milestone-plan.md](milestone-plan.md)); the changes land inside existing steps as baby steps (4.5.2, 4.6.1 to 4.6.3, 5.3.3). Question 13 (records from the wrapper or from the commit hook, ADR-022) has not been asked yet and keeps its default.

## ADR-027: The wrapper on Hadoop's own classpath, both lookups final

- **Date:** 7 October 2026. **Status:** accepted by the mentor; changes the content of step 4.6.
- **Context:** step 4.6 was planned as a check of the job file's digest inside the task. The mentor said a task hashing its own job file can be skipped by a swapped job file, so it is not a security check. Until now the wrapper was switched on per job by `-D` options, so the NodeManager (which reads the job file through plain HDFS) and any program without the options bypassed it (ADR-017, ADR-018).
- **Decision:** the mentor said to move the wrapper onto Hadoop's own classpath and set both lookups in the site configuration as final, so the NodeManager uses it too. (1) The wrapper's classes are put onto Hadoop's classpath on both nodes, built from the same sources as the classes in the job file. (2) `fs.hdfs.impl` and `fs.AbstractFileSystem.hdfs.impl` are set as final in the site configuration on both nodes, so a job cannot override them. (3) The NodeManager's read of the job file then goes through the wrapper and is checked against the record made when the client uploaded it. The step keeps its name; these are its baby steps 4.6.1, 4.6.2 and 4.6.3.
- **Why:** it removes the fail-open weakness of ADR-017 for everything that reads the site configuration, and it closes the job-loader gap that the handoff left open.
- **Consequences:** the Hadoop installation and configuration change, so the measured set changes and the re-measurement (ADR-020, ADR-029) must cover them. A failure of the wrapper now affects every client, including the daemons and the command-line tools (whose files get records too), so the change needs a staged rollout, a rollback and a switch between the wrapped and the plain configuration, which the control runs of ADR-028 also need. The settings of the wrapper stay non-final.
- **Outcome (9 October 2026):** done in step 4.6 (commits `fcffad09d`, `bef3a6452`, `9ef0f405d`, `28c811ff4`). The NodeManager's own process opened the four files of each of run 9's 27 jobs through the wrapper (108 opens, all verified) and refused a swapped file it fetched; a first switch failed and rolled back by itself because Hadoop's admin tool refuses the wrapper (ADR-031). A final setting stops a job's settings file but not a command-line `-D` or code in a JVM, so it is not a lockdown (limitations row 59). Report: [milestone-4-storage-integrity.md](milestone-4-storage-integrity.md) section 20.

## ADR-028: Every wrapped crawl has an unwrapped control in the same hour; wall time and bytes fetched are recorded

- **Date:** 7 October 2026. **Status:** accepted by the mentor.
- **Context:** run 6 had no contemporaneous unwrapped run. The mentor said that from Stage B on the unwrapped control is run in the same hour, and, per Amir, that performance is the result that matters most.
- **Decision:** from now on every wrapped crawl is paired with an unwrapped control run in the same hour (the order alternates). For every run the pair table records the wall time, the bytes fetched, and the HDFS bytes read and written. The unwrapped run uses the plain configuration and the measured job. This is a rule for every crawl, not a step; the first pair is the crawl that follows the re-measurement (step 4.8), and the results table belongs to Milestone 6, step 6.3.
- **Why:** pages change between runs (a live site redeploys), so bytes fetched must be recorded to compare times fairly.
- **Consequences:** the cluster needs a switch between the wrapped and the plain configuration (baby step 4.6.2); each pair costs about two crawls.

## ADR-029: Nothing that is not measured is described as measured

- **Date:** 7 October 2026. **Status:** accepted by the mentor.
- **Context:** the re-measurement is deferred (ADR-020); runs 6 and later used jobs outside the measured set. The mentor accepted the deferral as long as nothing unmeasured is ever described as measured.
- **Decision:** every document, table and sentence of the paper that mentions a run says whether it is covered by the measurement; anything that ran outside the measured set is called "unmeasured" or "not covered by the measurement", never "measured". Here "measured" means covered by the attestation measurement of Milestone 1; timing a run is a different thing, and the documents avoid the word for it.
- **Why:** the claim of the project is about the exact build that ran.
- **Consequences:** the facts checks include the phrase for the runs concerned; the re-measurement, when it happens, is described by what it covers.

## ADR-030: Answers about files are checked against the records; findings fail closed by default

- **Date:** 8 October 2026. **Status:** accepted.
- **Context:** the handoff wants all metadata from records, never from storage. Until step 4.5 the wrapper compared a file's length with its record only when the file was opened; its listings only hid the records. A file that was shortened, removed or slipped in behind the wrapper's back was noticed only if something read it.
- **Decision:** (1) `getFileStatus` and the listings are checked against the records: a length that differs from the record, and a record whose file is gone, follow the setting `attested.metadata.mismatch`, default `fail`; a file without a record follows the existing `attested.verify.missing`, default `warn`. (2) The default for a mismatch is to refuse, because a mismatch is the signal this step exists to give; a file without a record stays allowed because files put in by programs that do not use the wrapper, and files still being written, are normal today. (3) A listing is read in full before it is returned, so that the records in it can be seen. (4) A record's length is remembered for 10 seconds and is always read again before a refusal, so that a rewrite by another program is not a finding. (5) A finding is logged once per file per program, and a refusal each time. (6) The NameNode's audit log is switched on (the mentor, ADR-026) and compared with the wrapper's log by operation, path and time, because every client on a machine shows with the same user and address.
- **Why:** it closes the gap between "the file was checked when read" and "the answer about the file was believed"; the contract tests show no false alarm and the real-HDFS tests show the detection.
- **Consequences:** one more small read per file question and one more check per missing path, to be measured in the paired runs (ADR-028); listings of very large folders are read in full; the records are still not signed, so someone who rewrites a file and its record together is not caught (step 4.7, Milestone 5).

## ADR-031: The audit, admin and demo tools ask for the plain client explicitly

- **Date:** 9 October 2026. **Status:** accepted.
- **Context:** since step 4.6 the wrapper is the cluster's default file system (ADR-027), so a plain `hdfs dfs` goes through it. That would hide the record files from the audit's listing, make the independent re-hash read through the wrapper, and turn the tamper demo's change "behind the wrapper's back" into a wrapped write. Hadoop's admin tool (`hdfs dfsadmin`) refuses any file system that is not a `DistributedFileSystem`, the wrapper included (found when the first switch failed on 8 October; Hadoop 3.4.3, `AdminHelper.checkAndGetDFS`).
- **Decision:** every tool that must see HDFS as it is, not as the wrapper shows it, passes `-D fs.hdfs.impl=org.apache.hadoop.hdfs.DistributedFileSystem` itself: `audit.sh`, `records_verify.sh`, `tamper-demo.sh`, `nn-audit.sh`, `nn-audit-probe.sh` and `cluster-mode.sh`. A command-line option can override a final setting (tested), which is the intended use. Admin calls are not data operations, so they use the plain client. The two scripts of `ops/mesh/` were not edited because they cannot be run without a network change; they need plain mode.
- **Why:** an inspector must not depend on the guard it inspects, and a tool must not depend on the cluster's current mode.
- **Consequences:** the 5 changed scripts were run on the cluster in their final form (one branch of `nn-audit.sh` only in rehearsal); a plain client is still available to anyone who asks for it, so `final` is not a lockdown (limitations row 59; the lockdown is Milestone 5).

## ADR-032: Before a crawl, rotate the logs and restart the wrapped daemon; collect the container logs right after

- **Date:** 9 October 2026. **Status:** accepted.
- **Context:** the first rotation after the switch moved the NodeManager's open log file, and the NodeManager went on writing into the archived file, so its reads were missing from the clean folder. Run 9's container logs expired before they were collected, because log aggregation is off and YARN deletes them after its retention time (3 hours by default).
- **Decision:** on the worker, `audit.sh rotate` is followed by `cluster-mode.sh wrapped --restart-yarn` before the crawl, so the NodeManager starts a new log file; `audit.sh rotate` warns about any process that wrote a moved file and is still running; the container logs are collected right after the crawl. No cluster setting is changed for this.
- **Why:** the NodeManager's reads are exactly the evidence step 4.6 exists to produce, and the container logs are the only record of why a task failed.
- **Consequences:** one more command per crawl; the measured runs follow the same procedure.

## ADR-033: The NameNode comparison gets two explicit rules, visible and switchable

- **Date:** 9 October 2026. **Status:** accepted.
- **Context:** the first comparison of a whole crawl had 26 unexplained opens and 27 unmatched wrapper lines. The data showed two causes: one upload writes two wrapper lines (`COPYFROMLOCAL` and `CREATE`) against one NameNode create, and a job's client asks the NameNode where the input's blocks are, which HDFS audits as `open`.
- **Decision:** `nn_audit_compare.py` pairs the two lines of an upload only if the other line was itself matched to a NameNode event, and counts an `open` as a submission lookup only if the same client address created the job's `job.jar` before it and its `job.split` after it (from the NameNode's own log), never for a create, delete or rename. Both are printed as their own lines, never merged into "explained", and `--strict` turns both off. A delete with `allowed=false` is listed as "removed nothing", not as denied, because HDFS writes the result of the delete there.
- **Why:** an exemption written quietly would hide the next real difference; a rule that is printed, bounded and tested does not.
- **Consequences:** the 26 lookups of run 9 rest on timing, because the NameNode cannot tell a lookup from a read and the DataNode does not log reads here (limitations row 60); turning on the DataNode's client trace at run time for the measured runs is an open item.

## ADR-034: Storage integrity rests on one mechanism, sign on write and verify on read; step 4.7 and the task records are dropped

- **Date:** 10 October 2026. **Status:** accepted (Pingshan's decisions after step 4.6, recorded in [next-steps-storage-signing.md](next-steps-storage-signing.md)).
- **Context:** after step 4.6 the wrapper hashes every file at close and verifies every read, with unsigned records. Step 4.7 planned task records and job manifests, and question 13 (may the wrapper be the main source) was open.
- **Decision:** storage integrity rests on **sign on write, verify on read, with the VM's signing key**. There are no per-task records, job manifests, per-file history, folder tracking, "start" records or commit hook, and step 4.7 is dropped. The wrapper stays a plain file-system layer with no Hadoop logic in it. The Merkle log and the witness are deferred (the mentor's view: nice to have, not crucial). The verifier checks the final files: signature, key, quote, measurements and hash, instead of walking the chain back to the seed list.
- **Threat scope for storage.** In scope, to be prevented: tampering with stored bytes; forgery of a file that no attested VM wrote; a validly signed file placed in a different folder or under a different name (Hadoop names output files identically in every folder, so this would otherwise be trivial). Noted and out of scope: deletion (a file removed together with its record) and rollback (an older, validly signed file or folder put back), because neither can tamper with or insert data. A signed per-folder tracking file or ledger was considered and rejected: one shared file serialises every writer in the folder and can itself be rolled back, and per-writer ledgers still need a sealing step.
- **Consequences:** retries, duplicate attempts and re-runs are not visible (a provider can re-run a job and keep the run it prefers; every run is genuine); an outside verifier cannot re-check intermediate steps and trusts that measured code verified its own inputs; a bug in the wrapper's verification would not be caught downstream, so the wrapper is small and reviewed closely. The recon of step 4.7 (report section 21) stays as history. The next steps are A1 to A4, B1 to B4 and C1 to C4 (plan section 8).

## ADR-035: Folder identity files bind a file to its folder

- **Date:** 10 October 2026. **Status:** accepted (Pingshan); the details marked "ours" are to be settled while building (step B2).
- **Decision:** when a folder is created, the wrapper gives it a random ID and writes a small signed identity file inside it, covering the folder's ID, its own name and its parent's ID (the crawl's top folder binds to its full path). A file's signed record covers the folder's ID, the file's name, the content hash (our chunked Merkle root) and the length, and **not** the full path. Renaming a file signs a new record for that one file; renaming a folder re-signs only that folder's identity file, so the files inside and the folders below are untouched and no data is re-read. A read checks the record's signature, that the key belongs to an attested VM, that the record names this file and this folder's ID, the identity chain up to the top, and each chunk against the hash; anything missing or mismatched fails the read.
- **Why:** a full path in every record makes a folder rename re-sign everything below it, and Nutch renames whole folders (it swaps in the new crawl database); signing only the file name makes renames free but lets same-named files be swapped between folders. The folder identity keeps the binding and makes a folder rename one small write.
- **Details to settle:** two tasks may create the same folder at once (the first identity file written wins, created without overwrite); the identity file's name starts with `_` so that Hadoop's input listing skips it, and it is hidden from listings like the companion files; folders that exist before the wrapper is in use (the crawl's top folder, the seed folder) get an identity file from the driver. **Ours:** in run 9 the output committer moved files one by one, some into folders that already existed, so an identity file must never be moved like an ordinary file, or it would replace the destination's identity; this needs a rule and a test.
- **Consequences:** the pass conditions of B2 (a signed file or a whole folder copied elsewhere fails the read; a folder rename writes one identity file and re-signs no file record; a normal crawl with Hadoop's commit renames and Nutch's folder moves still passes).

## ADR-036: The WARC is the point where teammate S's layer and ours connect

- **Date:** 10 October 2026. **Status:** proposed by teammate S in her message of 10 October, consistent with ADR-034 and ADR-035; not yet validated end to end.
- **Context:** her patch (repository `Heron-AI-Security/training-custody`, branch `subhiksha/source-provenance`, commit `6128bc0`, applies to our `d4d520f`) embeds a source receipt and the TLS handshake evidence in WARC metadata records, and each fetch task writes attempt-scoped files `tc_receipts/receipts-<attempt>.jsonl`, `handshakes-<attempt>.jsonl` and `outcomes-<attempt>.jsonl` in its work output folder.
- **Decision:** the signed commitment to the WARC (its Merkle root, signed with the quote-bound VM key) is the link between the two verification paths, so no separate signing of her evidence is needed; her outcome files are covered the same way, because every file written through the wrapper is signed. Our verifier checks the signed commitment and the attestation binding, hers checks the embedded receipts, response hashes, certificate evidence and policy.
- **Open, with Pingshan:** how the collection policy is authenticated (packaged with the measured workload, or signed by the driver and distributed through HDFS), and whether the measured job lets the crawler reject invalid certificates itself (ADR-002). **To verify, not to assume:** that the trust anchors and the policy used by a task are covered by the measurement; that the baseline runs of the performance pairs do not inherit her key-free capture option (`-Djavax.net.debug=ssl:record:plaintext`, set per job in `mapreduce.map.java.opts`, never globally).
- **Consequences:** her patch changes existing Nutch classes (our branch alone only adds files); the combined validation list is in her message (the patched job builds and runs on our branch, both kinds of evidence are emitted, WARC contents match the signed commitments, failed attempts leave no authoritative evidence, both verifiers accept the same WARC, and the performance pairs use consistent configurations).

## ADR-037: The mentor's answers of October 2026 on policy, certificates, single-record verification, performance, TLS capture and the threat model

- **Date:** October 2026. **Source:** a message from the mentor to the team; it is not a file in the repository. **Status:** accepted as the mentor's direction; the consequences below are proposals and are not yet in the plan.
- **Collection policy:** packaged in the measured image. Where it lives in the driver script matters little, because the driver script will also be packaged in the measured image (this closes the open item about the policy in ADR-036).
- **Certificate checking:** CCBot should note an expired certificate in the source receipt and inform instead of rejecting; downstream quality filters decide whether to include that data in training.
- **CDX byte range and record verification:** verification should work on a single record. It is on the whole WARC now and has to be broken down.
- **Performance:** the control is a vanilla CCBot run on the cluster. Benchmarks must compare wrapped and unwrapped runs and more, to find where the cost comes from (the WireGuard mesh, TLS dumping, the wrapped HDFS or something else). This is the core of the experiment; the mentor asked the teammate whether she wants to own part of it.
- **TLS evidence:** parsing messages from the Java debugger is unlikely to be accepted as production code. The options he names: a different TLS library (maybe Bouncy Castle), building our own TLS stack (no), instrumenting Java internals (brittle, probably not production grade), patching the Java library (no), or generating no TLS signature at all and trusting the TEE (the last and least reliable option).
- **Threat model:** TEEs are secure unless there is physical access (the tee.fail attack needs a memory-interposition board soldered on). Our threat is insiders: a bad actor within the CC foundation or a frontier lab tampering with the crawl process. Physical access to the machines is a tall assumption. The signature authority (the TEEs) needs its own assumptions, such as physical security, which are acceptable.
- **Consequences (to apply):** step C3 widens to a piece-by-piece measurement with a vanilla control; the verifier needs a check of a single record (our records hold a hash for every 16 KiB chunk of a file, so a byte range can be checked against the chunks that cover it, but the procedure is not written); the teammate's key-free capture, which needs a JVM debug option, is in question; the certificate setting of her patch (it rejects) should become note-and-continue.

## ADR-038: Reading a file's content and asking about its status are two different questions, with two settings for a file without a record

- **Date:** 13 October 2026. **Status:** accepted (found on the cluster by the contract tests; the mentor's step A2, baby step 4.6.5, asked for the first of the two).
- **Context:** step A2 asked that reading an unrecorded file fail. The first version used the one setting `attested.verify.missing` for that and for status and listing questions; on the real HDFS the contract test `testSyncable` then failed through the wrapper, because a file that is still being written has no record yet and the status question about it was refused.
- **Decision:** `attested.verify.missing` (default `fail`) governs **opening a file** to read it. `attested.metadata.missing` (default `warn`: answer from storage and log once; `allow` and `fail` are the other values) governs **status and listing questions**. A status question exposes no content; opening an unrecorded file is what is refused.
- **Consequences:** a file still being written cannot be read through the wrapper (its record is made at close), and shows as one expected difference in the contract comparison; a listing can show an unrecorded file that cannot be opened (limitations rows 75 and 76).

## ADR-039: The wrapper's own settings count only when the site configuration set them

- **Date:** 13 October 2026. **Status:** accepted; it differs from the mentor's wording for step A3, baby step 4.6.6 ("mark them final in the site configuration, or remove them"), and meets its pass condition.
- **Decision:** a setting of the wrapper (`attested.hash.enabled`, `attested.hash.chunk.size`, `attested.sidecar.enabled`, `attested.verify.reads`, `attested.verify.missing`, `attested.metadata.check`, `attested.metadata.mismatch`, `attested.metadata.cache.seconds`, and `attested.metadata.missing`) is obeyed only when its last source, as Hadoop records it, is `core-site.xml` (or the default resources). A setting from a job file, a `-D` on the command line or code is ignored, the secure default is used, and the `INIT` line of the wrapper's audit log names the setting and its source (`ignored=`).
- **Why not only `final`:** marking a setting final in the site file stops a later settings file but not a `-D` or a call in code; the source rule stops all three, and it lets the smoke tests feed settings from code through a hook that is private to the package.
- **Scope:** the two log-folder settings (`attested.audit.dir`, `attested.records.dir`) are not covered, because four scripts pass them with `-D`. The rule defends against unmeasured settings, not against code in the JVM; a job that shadows `core-site.xml` on the class path would also replace our classes, which the measured job and the fixed driver close (limitations rows 73 and 74).


## ADR-040: The re-measure covers the patched job, the policy folder and the repository's ops folder, and needs a one-time boot into 6.17

- **Date:** 14 October 2026. **Status:** accepted. It carries out ADR-020; the mentor's note of 10 October (section 8) asks for the job to be built with the teammate's patch and re-measured; ADR-029 (nothing unmeasured is described as measured) stays.
- **Context:** the measured job was still the baseline of 5 October, while runs 6 to 11 used other jobs. The teammate's design puts the collection policy into the measured image (ADR-037). A normal reboot returns both nodes to the pinned 6.8 kernel, which cannot extend RTMR3, and the firewall rules are not saved across a reboot.
- **Decision:** (1) point `NUTCH_DIR` at the scratch build of step 4.8.1 (`~/m481/patched`), as ADR-020 planned, so that the old tree is not touched; (2) add one measured component, `tc-policy` (the folder `~/tc-policy` with `policy.json`), on both nodes, so the master has 9 events and the worker 6, and drop the two test events of Milestone 1; (3) before each re-measure ask GRUB for one more boot into 6.17 (`grub-reboot`; the pin on 6.8 stays); (4) after the boot, in this order: the firewall (saved before, applied again under a new backup name and compared with the saved one), the measurement, the quote and its replay, a recompute of every digest, and only then the daemons.
- **Why:** the order proves the measurement before anything runs; the new backup name keeps the original rules that the undo instructions refer to; the policy must have the same digest on both nodes because the receipts check it on whichever node runs a task.
- **Consequences:** the measured `driver` is the repository's whole `ops` folder at the commit (84 files); the kit scripts that start our runs are not in it, and only the fixed driver (step 5.3.2) closes that (limitations row 78). Every re-measure costs a reboot of both nodes and about an hour. The kit is `ops/kits/m482/`; the results are in [milestone-4-storage-integrity.md](milestone-4-storage-integrity.md) section 23.3.

## ADR-041: A timing pair: the wrapped run first, then a plain control with the same job, seeds and settings, then the wrapped settings restored and proved

- **Date:** 14 October 2026. **Status:** accepted. It carries out ADR-028 for the first pair.
- **Context:** the control needs the plain configuration, and switching to it changes `core-site.xml`, which is in the measured set.
- **Decision:** run the wrapped run first and check the measured set right after it; switch both nodes to plain (`cluster-mode.sh plain --restart`, master first); run the control with the same patched job, the same seeds and the same receipt settings (receipts on in both, so that only the file system differs); switch both nodes back and prove with the measured-set check that `core-site.xml` and every other component equal the measurement. The control is outside the measurement and is called so. The numbers are the wall time of the crawl command, the jobs completed, Hadoop's byte counters per file system, the bytes stored in HDFS (new files, the record files separately), the NameNode events of the window, and, from the WARC files, the pages and their payload bytes; a value that cannot be found is printed as "not found", never as 0.
- **Why:** it keeps the covered run covered, it makes the control a real control (same pages), and the proof after the restore shows that the switch left no trace.
- **Consequences:** a pair costs about 40 minutes and two switches of both nodes; the order should alternate in later pairs (ADR-028); the results table belongs to step 6.3 and one pair is not a result.

## ADR-042: Kits are committed as folders exactly as they ran, without other people's code and without evidence

- **Date:** 14 October 2026. **Status:** accepted; publishing the teammate's files needs her consent and the mentor's.
- **Context:** the scripts of step 4.8 ran from kit folders (zips) with fingerprints; the first rule of the project is that committed files are identical to the files that ran. Two kits also held the teammate's patch and her policy builder, which come from her private repository.
- **Decision:** each kit goes under `ops/kits/<kit>/` with its layout unchanged, in script-only commits, after a gate compared every file with the fingerprint of the zip (or of the evidence copy, for the three tools that ran as single files) that ran. Rehearsal transcripts and file lists are evidence and stay outside the repository with their fingerprints. The teammate's patch and policy builder are not committed: they are identified by her repository, commit `841c1d3`, the patch's blob id and SHA-256, and the fingerprints in `ops/kits/m481-policy/m481r-src.sha`; a check of the branch hashes every file and finds none of them. Known flaws stay as they ran.
- **Why:** her work is unpublished and its licence and authorship are hers to decide; a copy committed by us would also show us as its author. The experiment stays identifiable and checkable without it.
- **Consequences:** the build and policy kits cannot be re-run from the repository alone; the paper's artifact will need her consent (preferably through her own commit to our branch, step 5.3.3). A fixed version of a flawed script is a new file that must run before it is committed.
