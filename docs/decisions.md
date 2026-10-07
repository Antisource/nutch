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
| 020 | Defer the re-measurement until the job next changes | Accepted (mentor confirmation asked) |

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

- **Date:** 6 October 2026. **Status:** accepted by the author and the maintainer; the mentor is asked to confirm.
- **Context:** the measured set is the main tree, and it is unchanged (all ten components `SAME` after run 6). Run 6 ran from a scratch build outside it. `measure-all.sh` refuses to measure twice in one boot, so covering the new job needs a reboot of both nodes. A reboot also removes the firewall rules, stops the daemons that were started by hand, returns each node to the pinned 6.8 kernel (which has no measurement interface) and needs a one-time boot into 6.17.
- **Decision:** do not reboot now. Re-measure, from a clean boot, when the job next changes; the next milestone changes it. Until then, record that run 6 is not covered by the chain and keep running `check-unchanged.sh` to show the measured tree is intact.
- **Why:** a measurement now would cover a state that is about to be replaced, at the price of a reboot's risks; the Gate A measurement item already passed in Milestone 1.
- **Consequences:** run 6 is not in the chain, and the documents say so. The next measurement points `NUTCH_DIR` at the build folder that holds the hashing layer.
