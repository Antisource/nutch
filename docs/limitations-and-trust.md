# Limitations and trust analysis: Hadoop and CCBot (Nutch) in Intel TDX Confidential VMs on Google Cloud

**Scope.** This document updates the original 14-row "limitations and challenges" table. It covers running a multi-node Apache Hadoop cluster with Common Crawl's Nutch-based crawler (CCBot, branch `cc`) inside Intel TDX Confidential VMs (CVMs) on Google Cloud (GCP). Every original row was checked against primary sources and against first-party evidence from two functional runs (R1 to R7). Rows are grouped by theme and keep their original numbers. New rows start at 15. Sources were checked on 3 October 2026. Cloud documentation changes often, so "last updated" dates are given where they matter. This is a feasibility and trust assessment, not a security certification.

## Feasibility verdict

Running Hadoop and the Common Crawl Nutch crawler inside GCP Intel TDX CVMs **works functionally**. In its current form it **does not support the most important trust claim**: that a specific, unmodified crawler produced a specific WARC output from genuine web content.

- **What works (shown in our runs).**
  - A 2-node Hadoop 3.4.3 cluster ran Nutch `cc` on two `c3-standard-4` TDX CVMs with no failed tasks.
  - TDX quotes bound to a manifest hash were verified off-cloud in two ways: with the root certificate built into the tool, and with Intel collateral and revocation lists downloaded.
  - A one-byte manifest change and a one-bit quote change were both detected.
- **What does not work yet.**
  - The quotes do not measure the JVM, Hadoop or the crawler (RTMR3 was zero).
  - The manifest in REPORTDATA was written by guest software, so it is self-asserted.
  - Inter-node traffic was unencrypted.
  - Nothing proves that fetched bytes came from the named server.
  - The clock is not attested.
  - No reference values for RTMR0 to RTMR2 were available.
- **What is unknown.**
  - Overhead at scale: no non-TDX baseline was run, and no published Hadoop or Spark benchmark on TDX was found.
  - What happens to measurements across host-maintenance terminations and updates.
  - Why RTMR0 differs between two nodes of the same machine type.

**What would make it feasible (for the claim "this code produced this output"):**
1. Measure the JDK, Hadoop, `.job` file and configuration into RTMR3.
2. Pin MRTD to Google-signed launch endorsements, and derive RTMR0 to RTMR2 from a reproducible image by replaying the event log.
3. Enable Hadoop RPC and data-transfer encryption with authentication, with keys released only to attested nodes.
4. Sign outputs with a key bound to the quote.
5. Scope the content claim to "the crawler received these bytes over TLS from host X", not "X really serves these bytes".

If any of these cannot be done on GCP, that claim becomes "not feasible with TDX alone" (inference).

## Update, 6 October 2026 (after Milestones 0 and 1)

This update leaves the 3 October analysis in place and records what the next two milestones changed. Details: [milestone-0-clean-baseline.md](milestone-0-clean-baseline.md), [milestone-1-code-measurement.md](milestone-1-code-measurement.md), [decisions.md](decisions.md).

- **Now shown.**
  - RTMR3 carries a measured stack on both nodes (master 10 events, worker 5): JDK, JDK settings, CA fingerprint list, Hadoop code and config, and on the master the job, deploy folder, driver and seeds.
  - Four RTMR3 quotes were verified off-cloud with the strict flags, and the log replay reproduces the register on two machines.
  - The firmware's boot log replays to RTMR0, RTMR1 and RTMR2 exactly, on the old and new kernels.
  - A crawl ran on the measured stack and its output matched the earlier run; every measured digest was unchanged afterwards.
  - The WARC now records real server addresses (run 3 onward).
- **Still not shown.**
  - Nothing locks the stack between measuring and running, and the root filesystem is not covered by a boot measurement we saw.
  - No known-good reference (reproducible build) and no MRTD check against Google's endorsement.
  - Inter-node traffic is still plaintext (Milestone 2 is next), and TLS checking is off pending a decision.
  - The clock and the evidence copies are as before.

| Row | What changed | Where |
|---|---|---|
| 1, 23 | The quote now covers the measured JDK, Hadoop, job, config, driver and seeds (master), and JDK and Hadoop (worker). The manifest is still self-asserted, but the measurement is hardware-signed | milestone-1 §6, §9 |
| 15 | The firmware log replays to RTMR0 to RTMR2 on both nodes. No published reference values; MRTD not yet checked | milestone-1 §4 |
| 6 | Registers change with GRUB configuration and state and with first-boot partition growth, not only with kernel updates | milestone-1 §5, new row 32 |
| 18 | `WARC-IP-Address` is now recorded. Origin authenticity is still not proved. A teammate's receipt code addresses part of it (relayed), see new row 34 | milestone-0 §3, ADR-002 |
| 16 | Unchanged. The two old `entry...` report folders vanished after the first reboot (kept in memory) | milestone-1 §7 |


## Update, 6 October 2026 (after Milestone 2)

Details: [milestone-2-wireguard-mesh.md](milestone-2-wireguard-mesh.md), [decisions.md](decisions.md) (ADR-013 to ADR-016).

- **Now shown.**
  - Node-to-node Hadoop traffic (HDFS, YARN, shuffle) travels through a WireGuard tunnel: a job and a 27-application crawl ran over it, and about 3.9 GB crossed it.
  - A host firewall refuses Hadoop ports on the ordinary network: seven ports were dropped in both directions, a job submission to the ordinary address was refused, and the drop counters rose from 0 to 48 across two test runs (0 during normal work).
  - okhttp was seen in 22 of the worker's task logs for run 5.
- **Still not shown.**
  - No test from a real third machine, no IPv6 rules, and no packet capture.
  - The worker's daemons still listen on all addresses and depend on a firewall that is not saved across reboot.
  - Peers are authenticated by static keys, not by attestation quotes, and the private keys sit on the boot disk.
  - Hadoop's own wire encryption and Kerberos are not enabled; the mesh and firewall configuration are not in the measured set.

| Row | What changed | Where |
|---|---|---|
| 3, 17 | Inter-node traffic is now encrypted by the tunnel and the ordinary interface is closed to Hadoop ports. The mitigation is a different mechanism from the one listed (Hadoop's `rpc.protection`); no mutual attestation yet. See new rows 35 and 36 | milestone-2 §5 to §7 |
| 18 | Unchanged. Run 5's addresses vary for an external site (`www.zyte.com` was served from a pool of addresses) | milestone-2 §7 |


## Update, 6 October 2026 (after Milestone 3)

Details: [milestone-3-hdfs-wrapper.md](milestone-3-hdfs-wrapper.md), [decisions.md](decisions.md) (ADR-017 to ADR-019).

- **Now shown.**
  - A pass-through wrapper behind `hdfs://` carries every HDFS request of a full 27-application crawl (300 start-ups in 111 programs on both nodes), for both Hadoop storage APIs.
  - The crawl completed and matches run 5 on everything the crawler did on its own side (same pages, same counters); the one different page is explained by a site redeployment.
  - A storage audit found no change that remains in storage and was made outside the wrapper: 187 paths added, none removed or changed, all explained.
- **Still not shown.**
  - Nothing is hashed, signed or verified yet; the wrapper forwards and logs.
  - The wrapper fails open, and the audit is the proof for this crawl only.
  - The NodeManager reads the job file through plain HDFS.
  - Reads by unwrapped programs, same-size changes and transient files are outside the audit.
  - The log and the listings are plain files on the provider's machines.
  - The measured chain predates the changed driver files and job.

| Row | What changed | Where |
|---|---|---|
| 26 | Unchanged: outputs are still not signed. The wrapper is where hashing and signing will happen (handoff Stage B), and a real run through it now exists | milestone-3 §6, §10 |
| 23 | Unchanged: the job file and the new classes are not covered by a measurement yet; re-measurement (which needs a reboot) is deferred until the job next changes (ADR-020) | milestone-3 §12 |
| 39 to 44 | New rows (table C below) | this section |

## Update, 7 October 2026 (after Milestone 4, steps 4.1 to 4.3)

Details: [milestone-4-storage-integrity.md](milestone-4-storage-integrity.md), [decisions.md](decisions.md) (ADR-021 to ADR-024).

- **Now shown.**
  - Every file written through the wrapper in runs 7 and 8 is hashed when it is closed (SHA-256 per 16,384-byte chunk, Merkle root). In both runs 54 of 54 files left under the crawl folder have a matching record, and an independent program that re-reads the real files agrees on all 54.
  - Since run 8 a record is kept next to each file and every read through the wrapper is checked against it: 156 of 157 opens were verified, with 0 failures. The one unverified read is the seed file put there by the command-line client.
  - A one-byte change made with the plain HDFS client to a real crawl data file makes the next job that reads it fail, with a `VERIFY-FAIL` line in the worker's audit log; with the original bytes put back the job succeeds again.
  - The storage audit stayed clean (322 paths added in run 8, all explained).
  - Hadoop's own file-system contract tests (255 per mode) behave identically through the wrapper and through plain HDFS on the real cluster, and the same suite reports 10 differences with the wrapper as it was before step 4.4 (milestone-4 section 18).
- **Still not shown.**
  - Records are not signed: a file and its record rewritten together pass.
  - Length, existence and listings still come from storage.
  - There are no task records or job manifests; the job file is not checked at task start; the NodeManager still reads it through plain HDFS.
  - `copyToLocalFile`, opening by path handle and unwrapped programs are not verified; a file created through the builder API would not be hashed (none occurred).
  - Runs 6 to 8 are not covered by the measurement; one new crawl on measured code is needed after the re-measurement.
  - One file and one kind of change were tampered with on the cluster.

| Row | What changed | Where |
|---|---|---|
| 44 | Partly addressed: hashing at close and verified reads exist; signing, metadata from records and manifests do not | milestone-4 §6, §10, §13 |
| 41 | Partly addressed for reads through the wrapper: each OPEN line of the audit now says how the read was verified. Reads by unwrapped programs and same-size changes outside the wrapper are still outside | milestone-4 §10 |
| 23 | Unchanged: runs 6 to 8 are not covered by the measurement (ADR-020) | milestone-4 §13 |
| 26 | Unchanged: records and outputs are not signed | milestone-4 §13 |
| 47 | Addressed in step 4.4: the builder forms of create and append now go through the wrapper | milestone-4 §18.9 |
| 45 to 52 | New rows (table C below) | this section |
| 53 to 55 | New rows (table C below), from step 4.4 | milestone-4 §18.10 |

## Update, 7 October 2026 (the mentor's answers)

The mentor's answers are recorded in ADR-026 to ADR-029 of [decisions.md](decisions.md). What they change in this analysis:

- **Row 39 (the wrapper fails open):** the fix is agreed. The mentor said to move the wrapper onto Hadoop's own classpath and set both lookups as final in the site configuration, so the NodeManager uses it too (ADR-027, step 4.6). It is not done yet.
- **Rows 41 and 46 (reads are not audited):** the mentor said to turn on the NameNode's own audit log (baby step 4.5.2).
- **Row 52 (the cost was measured once):** the mentor said that every wrapped crawl gets an unwrapped control in the same hour, with wall time and bytes fetched recorded for each (ADR-028); performance is the result that matters most. The results table is step 6.3.
- **Rows 18 and 34 (the content is not authenticated; certificate checking off):** the mentor put per-fetch TLS evidence in scope, as teammate S's patch (step 5.3; [milestone-plan.md](milestone-plan.md) section 6). Certificate checking stays off for now (ADR-002, provisional).
- **The language rule (ADR-029):** the re-measurement stays deferred, and nothing that ran outside the measured set is described as measured.

## Update, 8 October 2026 (after Milestone 4, step 4.5)

- **Answers about files now come from the records** (baby step 4.5.1): a length that differs from the record, a recorded file that is gone and a file without a record are found, whichever way the wrapper is asked; the 116 real-HDFS checks tamper through the plain client and the contract tests (238 / 16 / 1) show no false alarm ([milestone-4-storage-integrity.md](milestone-4-storage-integrity.md) section 19).
- **The NameNode's audit log is on** (baby step 4.5.2), and its comparison with the wrapper's log found exactly the 5 plain operations of a probe (7 NameNode events) and explained the 18 wrapper operations. Row 41 is addressed; row 46 is partly addressed.
- **New rows 56 to 58:** a change that keeps the length and unsigned records, the limits of the comparison, and the unmeasured cost.

## Evidence legend (first-party, "our runs")

| Code | What it shows | Repo documents |
|---|---|---|
| R1 | 2 TDX CVMs (`c3-standard-4`, 16 GB, Ubuntu 22.04.5, kernels 6.8.0-1067-gcp and 6.8.0-1069-gcp, `onHostMaintenance=TERMINATE`, us-central1-a). Hadoop 3.4.3, OpenJDK 11, replication 1. 10 fetch attempts; identical outputs in two runs; about 10 to 11 minutes each; no failed tasks; no baseline. | run-1-pilot.md, run-2-scripted.md, run-comparison.md, cluster-configuration.md |
| R2 | configfs-tsm quotes with REPORTDATA = SHA-512(manifest). All 4 verified with go-tdx-guest `check` on a laptop with no Google credentials. Basic run: embedded Intel root (warning printed). Strict run (`-get_collateral=true -check_crl=true`): passed. Tamper tests: exit code 2. `gceprovenance` not run. | quote-verification.md §1, §5 |
| R3 | MRTD identical on all quotes. RTMR0–2 stable per node, different between nodes. RTMR3 zero. No reboot between runs. No reference values available. | quote-verification.md §3, §4 |
| R4 | `default-allow-internal` (all ports). No wire encryption, Kerberos or HDFS encryption. Daemons started by hand. | cluster-configuration.md §2, §4 |
| R5 | WARC metadata written by the crawler, unsigned. `WARC-IP-Address` 0.0.0.0. An off-seed link was followed. robots.txt not stored (both 404). | run-1-pilot.md §5, run-comparison.md §5 |
| R6 | Two unrelated root-owned report entries (27 September) under `/sys/kernel/config/tsm/report`. | run-1-pilot.md §5.3, guide-pitfalls-and-lessons.md mistake 15 |
| R7 | Clock is host-provided. Worker disk about 9.6 GB (about 5.4 GB for HDFS). Helper libraries from moving snapshots; public-suffix list unversioned (hashes recorded). No live migration. Evidence copied in plaintext; logs on ordinary disks. | cluster-configuration.md §1, §3, run-comparison.md §5 |
| R8 | Run 3 (okhttp client, `store.ip.address`): real `WARC-IP-Address` in 8 page records and 2 diagnostics records; same 8 URLs as run 2; no errors. Run 3 is not byte-comparable with runs 1 and 2 | milestone-0-clean-baseline.md |
| R9 | Kernel 6.17.0-1022-gcp on both nodes; RTMR3 extended (master 10 events, worker 5); quotes verified with the strict flags; replay matches on the laptop; boot-log replay reproduces RTMR0 to RTMR2 on 6.8 and 6.17 boots | milestone-1-code-measurement.md §4, §9 |
| R10 | Boot values change with first-boot partition growth (4 GiB to 50 GiB, confirmed in the cloud-init log), GRUB configuration and saved state. Master vs worker: 13 of 105 events differ by position | milestone-1-code-measurement.md §5 |
| R11 | Run 4 on the measured master matched run 3 (same pages, same URL and address pairs); all ten digests unchanged after the crawl (twice). The worker's NodeManager exited after the master was down about 23 minutes | milestone-1-code-measurement.md §10, §11 |
| R12 | The WireGuard mesh is up (ping 3 of 3 both ways, handshakes, counters). Hadoop runs over it after a hosts-file change and a host firewall; a Pi job finished in 19.3 s. A node-name problem (the NodeManager registered under a name that resolves to the blocked address) was found and fixed | milestone-2-wireguard-mesh.md §5, §6 |
| R13 | Run 5 over the mesh: same 8 URLs as run 3, no errors found, 28 YARN applications, 3,915.2 MB sent by the master through the tunnel, Hadoop-port drop rule at 0 afterwards, 22 worker task logs list okhttp | milestone-2-wireguard-mesh.md §7 |
| R14 | Refusal test: all 7 Hadoop ports tried over the ordinary network were dropped and open over the mesh; a job submission to the ordinary address was refused (exit 255); drop counters 0 to 24, then 24 to 48 | milestone-2-wireguard-mesh.md §7 |
| R15 | The wrapper passes 43 of 43 checks over a fake HDFS and 7 of 7 in a MapReduce job (author's environment, Hadoop 3.4.1), and on the master (Hadoop 3.4.3, Java 11) 43 of 43, 7 of 7 and, against the real HDFS, 42 of 42; from the job file 7 of 7 and 42 of 42 | milestone-3-hdfs-wrapper.md §7 |
| R16 | Run 6 through the wrapper: 3 iterations, no failures found, 27 applications, 300 wrapper start-ups in 111 JVMs, `AUDIT-CLEAN` (187 added, 0 removed, 0 changed, all explained) | milestone-3-hdfs-wrapper.md §9, §10 |
| R17 | Run 6 vs run 5: same 8 pages, 7 of 8 identical in content; the different page's deployment identifier changed between the runs and the live site serves the new one; the crawl database has 2 more URLs, matching 2 new links; runs 3 to 5 were identical to each other | milestone-3-hdfs-wrapper.md §11, run-comparison.md §9.2 |

**Change markers:** Kept, Updated, Corrected, Merged, Removed. The severity of new rows is marked "(author judgement)".

## Updated limitations tables

### A. Guest TCB and guest trust

| # | Challenge | Severity | Mitigation (low to high effort) | Change | Evidence from our runs | Sources |
|---|---|---|---|---|---|---|
| 1 | Large guest TCB: kernel + JVM + Hadoop + crawler trusted | High | Low: remove unused packages and services. Medium: minimal hardened image, least privilege. High: measure userspace into RTMR3 (row 23) | Corrected: GCP measured boot stops at kernel+cmdline [1] | RTMR3 zero. our runs [quote-verification.md] | [Google: RTMR contents](https://docs.cloud.google.com/confidential-computing/confidential-vm/docs/measurement-register-contents#:~:text=The%20kernel%2C%20and%20command%20line%20passed%20to%20the%20kernel); [arXiv 2501.11558v1](https://arxiv.org/html/2501.11558v1#:~:text=TDX%20increases%20the%20trust%20boundaries%20to%20guest%20OS) |
| 2 | Compromised guest root | High | Harden the guest, isolate tenants, protect credentials; put the smallest high-value step in a separate enclave | Updated: now sourced [2] | One root context per VM. our runs [cluster-configuration.md] | [kernel.org TDX](https://docs.kernel.org/arch/x86/tdx.html#:~:text=protect%20confidential%20guest%20VMs%20from%20the%20host%20and%20physical%20attacks); [Heckler](https://arxiv.org/html/2404.03387#:~:text=we%20bypass%20the%20authentication%20in%20OpenSSH%20and%20sudo) |
| 16 | A quote does not identify which program requested it | High (author judgement) | Low: root-only configfs, one entry per requester. Medium: bind the requester's hash into REPORTDATA and RTMR3. High: a single attestation agent | Kept (verified) [3] | Unrelated report entries found. our runs [run-1-pilot.md §5.3] | [configfs-tsm ABI](https://www.kernel.org/doc/Documentation/ABI/testing/configfs-tsm#:~:text=it%20can%20prevent%20conflicts%20by%20creating%20a%20report%20instance%20per%20requesting%20context) |
| 23 | The quote does not cover JVM, Hadoop or crawler code; the manifest is self-asserted | High (author judgement) | Medium: extend RTMR3 with hashes of JDK, Hadoop, `.job`, configs. High: IMA, read-only root | New [4] | RTMR3 zero; manifest built in the guest. our runs [quote-verification.md] | [Google: RTMR3](https://docs.cloud.google.com/confidential-computing/confidential-vm/docs/measurement-register-contents#:~:text=Additional%20event%20logs%20measurement%20passed%20from%20the%20userspace) |
| 20 | Supply chain: moving snapshots; unversioned public-suffix list | Medium (author judgement) | Low: pin commits and hashes (done). Medium: vendor all inputs. High: reproducible builds | Kept | `.job` byte-identical across runs. our runs [run-comparison.md §5] | Inference from our runs |
| 27 | Software is measured after boot and before use; nothing prevents a change in between | High (author judgement) | Low: re-hash after the run (done). Medium: measure at launch from a boot service. High: read-only verified root, no login | New | `check-unchanged.sh` printed ALL-UNCHANGED twice after run 4: a point-in-time check. our runs [milestone-1-code-measurement.md §10] | Inference from our runs |
| 28 | The root filesystem and its tools are not covered by any boot measurement we saw | High (author judgement) | High: read-only root with an integrity hash on the kernel command line, or measure the root's hash at boot | New (inference) | The kernel command line seen began `root=PARTUUID=...`; its end was not read, so an integrity parameter cannot be ruled out. our runs [milestone-1-code-measurement.md §8] | Inference from our runs |
| 29 | The measured stack is lost at every reboot; the 6.17 kernel is a one-time boot and the nodes return to 6.8 | Medium | Low: rerun the scripts after each boot. Medium: a boot-time service. High: a measured image | New | RTMR3 resets at boot; saved GRUB entries still name 6.8 kernels. our runs [milestone-1-code-measurement.md §7] | Inference from our runs |
| 30 | The JDK start-up cache differs per node; JDK settings and the CA store live outside the JDK folder | Low–medium (author judgement) | Measure settings and the CA list separately (done). Build one image so all nodes share one cache | New | One of 345 JDK files differs; 26 symlinks point into `/etc`. our runs [milestone-1-code-measurement.md §6] | Inference from our runs |
| 31 | The cluster runs Hadoop 3.4.3, but the design's hook points were read from Hadoop 3.4.1 source | Low (to verify) | Re-read the hook points in 3.4.3 before building the file wrapper | New | Handoff line 153 vs `hadoop version`. our runs | Handoff |

### B. Attestation, measurements and verifiers

| # | Challenge | Severity | Mitigation (low to high effort) | Change | Evidence from our runs | Sources |
|---|---|---|---|---|---|---|
| 15 | No RTMR0–2 reference values; MRTD not checked against Google's endorsement | High (author judgement) | Low: fetch the launch endorsement for the observed MRTD. Medium: replay the CCEL log. High: own reproducible image with published RTMRs | Corrected: MRTD references exist; none published for RTMRs [5] | MRTD identical; RTMRs differ between nodes. our runs [quote-verification.md §3] | [Google: launch endorsement](https://docs.cloud.google.com/confidential-computing/confidential-vm/docs/verify-firmware#:~:text=A%20launch%20endorsement%20contains%20precomputed%20and%20signed%20measurements) |
| 6 | Measurements change on legitimate upgrades | High operational risk | Low: store the event log with every quote. Medium: A/B allowlists, signed release metadata. High: staged policy rollovers | Updated: which registers change and why [6] | Kernels differ (1067 vs 1069) and RTMRs differ (the link is inference). our runs [cluster-configuration.md] | [Google: new machine per launch](https://docs.cloud.google.com/confidential-computing/confidential-vm/docs/measurement-register-contents#:~:text=Every%20Compute%20Engine%20VM%20instance%20launch%20is%20treated%20as%20a%20new%20machine); [kernel.org: TEE_TCB_SVN_2](https://docs.kernel.org/arch/x86/tdx.html#:~:text=The%20main%20exception%20is%20the%20TEE_TCB_SVN_2%20field) |
| 5 | Attestation infrastructure outage | Medium–high | Low: cache collateral with expiry. Medium: redundant verifiers, bounded credential lifetime. Always: do not fail open | Updated: dependencies named [7] | Basic check offline; strict check needed Intel. our runs [quote-verification.md §5] | [Google: best-effort bucket](https://docs.cloud.google.com/confidential-computing/confidential-vm/docs/verify-firmware#:~:text=This%20Cloud%20Storage%20bucket%20is%20only%20hosted%20in%20one%20region) |
| 22 | The verification tool carries its own trust anchor | Medium (author judgement) | Low: always use strict mode. Medium: pin the root hash; build the tool from a pinned commit | Updated: earlier claims corrected [8] | Embedded-root warning; strict run passed. our runs [quote-verification.md §5] | [Google: embedded Intel root](https://docs.cloud.google.com/confidential-computing/confidential-vm/docs/tdx-provenance#:~:text=Verify%20the%20authenticity%20of%20the%20Intel%20TDX%20quote%20by%20using%20the%20embedded%20Intel%20root%20certificate) |
| 21 | Dependence on the provider's firmware, host registry and attestation service | Medium (author judgement) | Low: verify with Intel collateral (done). Medium: add `gceprovenance`. High: a second independent verifier | Updated [9] | `gceprovenance` not run. our runs [quote-verification.md] | [Google: gceprovenance scope](https://docs.cloud.google.com/confidential-computing/confidential-vm/docs/tdx-provenance#:~:text=The%20gceprovenance%20tool%20performs%20a%20basic%20quote%20authenticity%20check,use%20the%20check%20CLI%20tool) |
| 14 | Lock-in to one vendor TEE | Medium | Keep the policy interface abstract (evidence in, claims out); test a second verifier | Updated: multi-TEE verifiers are partial [10] | Only TDX tested. our runs | [Intel Trust Authority: SEV-SNP preview](https://docs.trustauthority.intel.com/main/articles/articles/ita/whats-new.html#:~:text=AMD%20SEV%2DSNP%20attestation%20remains%20a%20preview%20feature) |
| 32 | Boot measurements depend on first-boot partition growth, bootloader configuration and saved state | Medium (author judgement) | Low: replay the log and judge events, not totals. Medium: build the image with its final disk layout | New | The partition-table event changed from a 4 GiB to a 50 GiB layout after the first boot; RTMR2 changed with GRUB; RTMR1 was equal on the second 6.8 boot and the 6.17 boot. our runs [milestone-1-code-measurement.md §5] | Inference from our runs; cloud-init log |

### C. Cluster, network and performance

| # | Challenge | Severity | Mitigation (low to high effort) | Change | Evidence from our runs | Sources |
|---|---|---|---|---|---|---|
| 3 | Shared I/O memory controlled by the hypervisor | High | Low: no secrets in shared buffers; validate input. Medium: TLS everywhere and Hadoop wire encryption (HDFS encryption covers data at rest only) | Updated: sourced; mitigation corrected [11] | RPC, shuffle and HTTP in plaintext. our runs [cluster-configuration.md §4] | [kernel.org: shared mappings](https://docs.kernel.org/arch/x86/tdx.html#:~:text=Shared%20mapping%20content%20is%20entirely%20controlled%20by%20the%20hypervisor) (snippet only) |
| 17 | No encryption or mutual attestation between nodes | High (author judgement) | Low: firewall limited to Hadoop ports. Medium: `hadoop.rpc.protection=privacy`, `dfs.encrypt.data.transfer=true`, HTTPS, Kerberos. High: keys only for attested nodes | Kept [12] | `default-allow-internal`; no Kerberos. our runs [cluster-configuration.md §2, §4] | [Hadoop SecureMode](https://hadoop.apache.org/docs/stable/hadoop-project-dist/hadoop-common/SecureMode.html#:~:text=Setting%20hadoop.rpc.protection%20to%20privacy) (snippet only) |
| 4 | HDFS and shuffle I/O overhead | Medium–high | Low: guest kernel with TDX halt fixes; size SWIOTLB. Medium: TDX vs non-TDX benchmark, CPU per GB. High: tune batching and buffers | Updated: Google documents the overhead [13] | Functional only; no baseline. our runs [run-comparison.md] | [Google: bandwidth and latency](https://docs.cloud.google.com/confidential-computing/confidential-vm/docs/supported-configurations?tab=intel-tdx#:~:text=Confidential%20VM%20instances%20might%20experience%20lower%20network%20bandwidth%20and%20higher%20latency); [halt fixes](https://docs.cloud.google.com/confidential-computing/confidential-vm/docs/supported-configurations?tab=intel-tdx#:~:text=Guest%20images%20without%20the%20TDX%20halt%20fixes) |
| 13 | No public benchmark of full Hadoop on TDX | Medium evidence risk | Run a representative PoC with a non-TDX baseline before committing to capacity or cost | Updated: still none found [14] | Two functional runs. our runs | None found; see [14] |
| 33 | Hadoop daemons started by hand do not recover from outages | Low–medium (availability) | Low: check `jps` on the worker after any master outage. Medium: supervised services | New | The worker's NodeManager retried the ResourceManager until 17:29:08 and shut down; the master's ResourceManager had been down about 23 minutes. our runs [milestone-1-code-measurement.md §11] | NodeManager log |
| 35 | The worker's daemons and the NameNode web page listen on all addresses, and a host firewall that is not saved across reboot is the only thing closing them | Medium–high (author judgement) | Low: re-run the script after every reboot. Medium: per-daemon bind settings. High: persistent rules in the image | New | `ss` listings after the firewall still show `0.0.0.0`; the drop rule stayed at 0 in normal work. our runs [milestone-2-wireguard-mesh.md §6, §8] | Inference from our runs |
| 36 | Mesh peers are authenticated by static keys, not by attestation; the private keys are on the boot disk | High (author judgement) | Medium: generate keys in the guest at boot and bind the public key into REPORTDATA or RTMR3. High: admit a peer only after verifying its quote | New | Keys are root-only (mode 600) and not bound to any quote. our runs [milestone-2-wireguard-mesh.md §5, §8] | Inference from our runs |
| 37 | The job file reaches the worker through HDFS staging for every application | Medium (author judgement) | Check the job file's digest at load on the worker; put the staging folder under the signed file layer | New | 28 applications; about 3.9 GB sent by the master in run 5; the 134 MB job file is uploaded each time. our runs [milestone-2-wireguard-mesh.md §7] | Inference from our runs |
| 38 | A node can register under a name that resolves to a closed network after an unrelated change; the firewall then blocks Hadoop's own traffic | Low–medium (operational) | Check `yarn node -list` and run a small job after any network change | New | Observed on 6 October and fixed by mapping the names. our runs [milestone-2-wireguard-mesh.md §6] | Inference from our runs |
| 39 | The wrapper fails open: a program that does not get the two settings silently uses plain HDFS | High (author judgement) | Low: run the audit after every crawl (done). Medium: put the settings in the job's own configuration instead of the driver's options. High: refuse plain access to crawl data | New; the fix is agreed: ADR-027, step 4.6 (the mentor, 7 October) | 300 of 300 start-ups in 111 programs used the wrapper and the audit found no outside change. our runs [milestone-3-hdfs-wrapper.md §9, §10] | Inference from our runs |
| 40 | The NodeManager, the daemons and the crawl script's two `hadoop fs` commands do not use the wrapper; the NodeManager reads the job file through plain HDFS | Medium | Make the NodeManager use the wrapper and check the job file's digest at load (handoff Stage B, item 6) | New | The settings reach only the crawl's own programs; the NodeManager's read was not tested separately. our runs [milestone-3-hdfs-wrapper.md §12] | Inference from our runs |
| 41 | The audit does not cover reads, a change that keeps size and modification time, or files created and deleted between the two listings | Medium | Add an independent source (the NameNode's own audit log); record sizes in the wrapper's log | Addressed, 8 October 2026: the NameNode's audit log is on and compared with the wrapper's log (milestone-4 section 19.7); that log is itself a plain file on the provider's machine (row 42) | Tool tested with planted faults; run 6 clean. our runs [milestone-3-hdfs-wrapper.md §10] | Our tests |
| 42 | The wrapper's log and the before and after listings are plain files on the provider's machines | High (author judgement) | In the final design the records are signed inside the TD and the ledger is witnessed (handoff Stage C) | New | Logs in `/tmp/attested-audit` on each node. our runs [milestone-3-hdfs-wrapper.md §12] | By design |
| 43 | The measured job cannot be rebuilt from a clean checkout: an untracked file, `conf/effective_tld_names.dat`, enters it | Medium | Track the file or generate it deterministically; build the image from a clean checkout | New | Job comparison: 1029 against 1032 entries before the file was copied. our runs [milestone-3-hdfs-wrapper.md §8] | Our runs |
| 44 | Storage integrity is only partly protected: files are hashed at close and every read is checked against a record (Milestone 4, steps 4.2 and 4.3), but records are not signed, metadata still comes from storage and there are no task records or manifests | Medium (author judgement) | Handoff Stage B, items 4 to 6 (steps 4.4 to 4.7 remain), then signing (Stage C) | Partly addressed, 7 October 2026 | Runs 7 and 8 and the tamper test. our runs [milestone-4-storage-integrity.md §9 to §11, §13] | Handoff section 6 |
| 45 | Records are not signed: a file and its record rewritten together pass the check | High (author judgement) | Sign each record inside the TD with a quote-bound key and anchor the roots in a witnessed log (handoff Stage C) | New | Stated as a test (a known limit); not tried on the cluster. our runs [milestone-4-storage-integrity.md §13] | Inference from our runs |
| 46 | Some read paths are not verified: `copyToLocalFile` (marked `verify=bypassed`), opening by path handle, and every program that does not use the wrapper | Medium | Route `copyToLocalFile` through the verifying open; refuse plain access to crawl data; audit reads from the NameNode's own log | Partly addressed, 8 October 2026: reads by programs that do not use the wrapper are found by the comparison with the NameNode's log (milestone-4 section 19.7); `copyToLocalFile` and opening by path handle are still not verified | `copyToLocalFile` was not used in run 8 (no bypassed read). our runs [milestone-4-storage-integrity.md §10, §13] | Our runs |
| 47 | Files created through the builder API (`createFile`) were not hashed, and a file appended to through the builder kept a stale record | Medium | Done in step 4.4: the builders call the wrapper's own create and append | Addressed, 7 October 2026 | None in runs 7 and 8: every kept file has a record and a companion file; Hadoop's contract tests found the defect (10 differences with run 8's job) and none remain. our runs [milestone-4-storage-integrity.md §10, §18.7] | Our runs |
| 48 | A file without a record is read with a warning; a file whose writer was killed before closing it has none | Medium | Set `attested.verify.missing=fail` once every writer goes through the wrapper | New | Run 8: 1 of 157 opens (the seed file, on the allow list). our runs [milestone-4-storage-integrity.md §10] | Our runs |
| 49 | Metadata (length, existence, listings) still comes from storage: an operator can still hide or add files that no read touches | High (author judgement) | Step 4.5: answer metadata from records; step 4.7: job manifests | Known | The length is compared with the record at open, so a shortened or lengthened file that is read fails. our runs [milestone-4-storage-integrity.md §13] | Handoff section 6, piece 3 |
| 50 | Companion files are visible to plain HDFS tools and to consumers that list directories without skipping hidden files | Low | Document it; consumers skip names that start with a dot, as Hadoop's input formats do | New | The command-line wildcard fetch copied them (18 hidden files with 18 data files). our runs [milestone-4-storage-integrity.md §10] | Our runs |
| 51 | The hasher keeps every chunk's hash while a file is written (32 bytes per chunk) | Low at this scale | A larger chunk size for large files; a streaming record format | New | Calculated, not measured: the 134.8 MB job file is about 8,227 chunks, 263 KB of hashes. our runs [milestone-4-storage-integrity.md §12] | Inference from our runs |
| 52 | The cost of verification was measured once: 10 min 57 s against 10 min 43 s; CPU use was not measured | Low | Repeat with and without verification; measure CPU per GB (handoff item 12) | New; every crawl is now paired with an unwrapped control in the same hour (the mentor, 7 October; ADR-028), results in step 6.3 | Runs 6 to 8. our runs [milestone-4-storage-integrity.md §12] | Our runs |
| 53 | The contract tests ran on one small cluster, once per mode: 16 of 255 tests fail on plain HDFS here (block-size minimum, no etags, no stream statistics) and say nothing about the wrapper | Low | Repeat on another cluster, or lower the NameNode's minimum block size for a test run | New | Runs of 7 October. our runs [milestone-4-storage-integrity.md §18.5, §18.6] | Our runs |
| 54 | The contract suite does not cover the wrapper's own additions (records, verification, hiding of companion files) or `copyToLocalFile`; those rest on our own tests | Low to medium | Add tests for the additions to the suite; route `copyToLocalFile` through the verifying open | New | our runs [milestone-4-storage-integrity.md §18.10] | Inference from our runs |
| 55 | Rename over an existing file, and of a folder into an existing folder, were not exercised on the cluster: the three contract tests for them need a block size below the NameNode's minimum | Low | Run those three with a lowered minimum, or add them to our own tests | New | our runs [milestone-4-storage-integrity.md §18.6] | Our runs |
| 56 | The metadata checks do not see a change that keeps the length, and the records are not signed | Medium | Reading the file catches a changed byte (done in step 4.3); signed records are step 4.7 and Milestone 5 | New | The 116 real-HDFS checks include a same-size change found only at read. our runs [milestone-4-storage-integrity.md §19.2, §19.9] | Our tests |
| 57 | The comparison with the NameNode's log needs the clocks to agree within its window, counts a file of more than ten blocks as several reads, and uses a log that is a plain file on the provider's machine | Medium | Check the clocks on both machines; the signed and witnessed logs of Stage C | New | The probe's 7 findings and 18 matches were on one machine. our runs [milestone-4-storage-integrity.md §19.7, §19.9] | Our runs |
| 58 | The cost of the metadata checks and of the NameNode's audit log was not measured | Low to medium | Measure them in the paired runs (ADR-028; step 6.3) | New | Each file question reads a record header (remembered for 10 s); a missing path costs one more check. our runs [milestone-4-storage-integrity.md §19.9] | Inference from our runs |

### D. Host, availability and platform

| # | Challenge | Severity | Mitigation (low to high effort) | Change | Evidence from our runs | Sources |
|---|---|---|---|---|---|---|
| 8 | Denial of service by the host | Fundamental | Low: watch maintenance-event metadata; checkpoint. Medium: HA across zones and administrative domains | Updated: sourced [15] | TERMINATE policy; replication 1. our runs [cluster-configuration.md] | [arXiv 2602.11434](https://arxiv.org/html/2602.11434#:~:text=Availability%20is%20not%20included%20in%20the%20security%20objectives); [Google: no live migration](https://docs.cloud.google.com/confidential-computing/confidential-vm/docs/troubleshoot-live-migration#:~:text=All%20other%20Confidential%20VM%20types%20don%27t%20support%20live%20migration) |
| 19 | The clock is provided by the host | Medium–high (author judgement) | Low: record several external time sources. Medium: external signed timestamps (not researched) | Kept; no source found either way (unverified) | WARC dates come from the VM clock. our runs [cluster-configuration.md §1] | None found (unverified) |
| 24 | GCP TDX restrictions: no kdump, reservations or sole-tenant nodes; Balanced PD only; CPUID limits; up to 192 vCPU | Medium (author judgement) | Plan without reservations; test on the exact machine type | New [16] | Small worker disk. our runs [cluster-configuration.md §3] | [Google: 192 vCPUs](https://docs.cloud.google.com/confidential-computing/confidential-vm/docs/supported-configurations?tab=intel-tdx#:~:text=Intel%20TDX%20supports%20up%20to%20192%20vCPUs) |

### E. Data at rest, logs and evidence handling

| # | Challenge | Severity | Mitigation (low to high effort) | Change | Evidence from our runs | Sources |
|---|---|---|---|---|---|---|
| 9 | Logs leak plaintext | High | Low: no record dumps; redaction. Medium: encrypt sensitive logs in the guest. Guest console logs can also leave the TD (Google's SEV-SNP list recommends console logs instead of kdump; its TDX list only says kdump is unsupported) | Kept; no TEE-specific primary guidance found (unverified) [17] | Logs on ordinary disks. our runs | [Google: kdump unsupported on TDX](https://docs.cloud.google.com/confidential-computing/confidential-vm/docs/supported-configurations?tab=intel-tdx#:~:text=those%20CPUID%20values.-,VM%20instances%20don%27t%20support%20kdump) |
| 10 | Crash and core dumps leak memory | High | Disable JVM heap dumps and user core dumps, or encrypt them; kernel kdump is not available on GCP TDX | Corrected: the remaining risk is user-space dumps (inference) [17] | Not tested | Same link as row 9 |
| 11 | Backups separate data from the TEE | High | Medium: encrypt before persistence; keys in a separate KMS. High: attestation-gated key release; attested restore tests | Kept; Hadoop encryption zones and GCP disk options not re-verified (unverified) | No HDFS encryption. our runs | Not verified in this pass |
| 26 | Evidence and outputs leave the TD in plaintext and unsigned | High (author judgement) | Low: sign the evidence bundle in the TD with a quote-bound key. Medium: encrypt to the recipient before export | New | Copied in plaintext to Cloud Shell and a laptop. our runs | Inference from our runs |

### F. Authenticity of crawled content

| # | Challenge | Severity | Mitigation (low to high effort) | Change | Evidence from our runs | Sources |
|---|---|---|---|---|---|---|
| 18 | A TEE does not authenticate crawled web content | Fundamental for content claims (author judgement) | Low: record the real IP, TLS certificate chain and robots.txt (including 404s); domain filters. Medium: hash payloads into the attested manifest. High: TLS-oracle proofs for selected pages | Kept [18]; the TLS-evidence part is in scope as teammate S's patch (the mentor, 7 October; step 5.3) | IP 0.0.0.0; off-seed link; no robots.txt records. our runs [run-1-pilot.md §5] | [WARC 1.1](https://iipc.github.io/warc-specifications/specifications/warc-format/warc-1.1-annotated/#:~:text=A%20WARC%2DIP%2DAddress%20field%20should%20be%20used%20to%20record%20the%20network%20IP%20address%20from%20which%20the%20response%20material%20was%20received) (snippet only); [TLSNotary FAQ](https://tlsnotary.org/docs/faq/#:~:text=TLS%20does%20not%20have%20a%20mechanism%20to%20enable%20the%20server%20to) (snippet only) |
| 34 | With CCBot's certificate checking off, pages that fail validation can still be archived | Medium–high (author judgement) | Decide whether records without a source receipt are dropped, labelled or rejected; or turn CCBot's checking on | New (the teammate's receipt behaviour is relayed, not tested by us); per-fetch TLS evidence is in scope as her patch (the mentor, 7 October; step 5.3) | Runs 3 and 4 used the default (off). our runs [decisions.md ADR-002] | Teammate's description |

### G. TEE vulnerabilities, side channels and physical attacks

| # | Challenge | Severity | Mitigation (low to high effort) | Change | Evidence from our runs | Sources |
|---|---|---|---|---|---|---|
| 7 | Side channels | Threat-dependent | Constant-time crypto; no secret-dependent access patterns; isolate sensitive tenants; follow advisories | Updated: attacks sourced; lost footnote 19 partly restored [19] | Not tested | [TDXRay](https://tdxray.cpusec.org/#:~:text=Intel%27s%20own%20threat%20model%20explicitly%20excludes%20microarchitectural%20side%20channels) |
| 12 | TEE vulnerabilities and firmware lifecycle | High | Low: check TCB status in every verification. Medium: minimum TDX module version and SVN in policy. High: re-attest after TCB recovery | Updated: CVE and fix versions sourced [20] | Strict check passed. All four quotes carry minor SVN 0x0F, which Intel's release notes map to TDX module 1.5.34 [20]. our runs [quote-verification.md §6] | [arXiv 2602.11434: CVE](https://arxiv.org/html/2602.11434#:~:text=Migratable%20TD%20can%20become%20debuggable%20during%20migration) |
| 25 | Physical memory-bus attacks can forge quotes that pass verification | Threat-dependent (author judgement) | Rely on provider physical security; add provenance binding (row 21); limit what one quote unlocks | New [21] | Not testable | [TEE.fail](https://tee.fail/#:~:text=at%20the%20highest%20trust%20level%20of%20UpToDate); [Intel bulletin: physical attacks out of scope](https://www.intel.com/content/www/us/en/security-center/announcement/intel-security-announcement-2025-10-28-001.html#:~:text=does%20not%20change%20Intel%E2%80%99s%20previous%20out%20of%20scope%20statement) (page text seen in search; fragment untested) |

All original rows 1 to 14 are present: 1, 2 (A); 5, 6, 14 (B); 3, 4, 13 (C); 8 (D); 9, 10, 11 (E); 7, 12 (G). None were removed or merged.

### Notes

[1] Google maps MRTD to the TDVF firmware, RTMR[0] to "TDVF configuration (TD Hand-Off Block, ACPI, Secure boot configuration)", RTMR[1] to "TD loader (GRUB/shim)", RTMR[2] to "The kernel, and command line passed to the kernel", and RTMR[3] to user-defined data (page opened and re-checked on 3 October 2026; last updated 2026-08-26). Another Google page (Confidential VM token claims, snippet only) describes `rtmr1` as the guest OS bootloader and kernel and `rtmr2` as the initramfs and kernel command line, and Intel's TDVF design guide (snippet only) describes RTMR[1] as the OS loader and RTMR[2] as the OS components such as kernel and initrd. The exact split between RTMR1 and RTMR2 therefore differs between sources and may depend on the image. Hardening shrinks the TCB but does not make it attested. The original row's implication that measured boot covers the JVM and Hadoop was too strong.

[2] The kernel documentation says TDX protects "confidential guest VMs from the host and physical attacks" (page opened; docs version 7.3.0-rc5). The guest OS and its root user are therefore inside the trust boundary. Bruno Casella's study "A performance analysis of VM-based Trusted Execution Environments for Confidential Federated Learning" (arXiv 2501.11558, 20 January 2025; federated learning, not Hadoop) says "TDX increases the trust boundaries to guest OS, all the applications, and VM admins". It also finds that VM-based TEEs "introduce a limited overhead (at most 1.5x)". Heckler showed that a malicious hypervisor could reach guest root: "on AMD SEV-SNP and Intel TDX, we bypass the authentication in OpenSSH and sudo" (arXiv 2404.03387, author's version of the USENIX Security 2024 paper). Whether the GCP 6.8 guest kernels carry the Heckler fixes was not checked.

[3] The configfs-tsm ABI says `generation` "increments each time @inblob or any option is written", and that userspace "can prevent conflicts by creating a report instance per requesting context" (page opened; plain-text file, so fragment support varies by browser). This gives conflict detection, not caller identity. Any root process can get a quote over any REPORTDATA (matches R6).

[4] Google: "Users can extend the RTMR[3] register with user space measurements" ([Confidential VM attestation](https://docs.cloud.google.com/confidential-computing/confidential-vm/docs/attestation#:~:text=Users%20can%20extend%20the%20RTMR%5B3%5D%20register%20with%20user%20space%20measurements); snippet only). With RTMR3 at zero, the only link from the quote to the crawler is a hash that any root process could have computed. This is the largest gap between what was demonstrated and what is claimed (inference).

[5] Google-signed launch endorsements are looked up by the MRTD at "offset b8h (for TDX Module 1.5)". They are stored in a bucket "only hosted in one region, us-west1", described as "a best-effort backup established for transparency purposes" (page opened). The TDX endorsement depends on "The amount of RAM in GiB provided to the VM", which is consistent with identical MRTDs on two 16 GB nodes (inference). No Google page publishing expected RTMR values was found. Google's community blog "Beyond Confidential" (18 November 2025, page opened 3 October 2026) lists reference values for some claims, for example `td_attributes` 0x10000000 (debug disabled, migration not allowed), but shows `mr_td` and `rtmrs[4]` only as `#HASH`, describing the RTMRs as values "that can be used to validate the measured boot event log". They have to be derived by replaying the CCEL log at `/sys/firmware/acpi/tables/data/CCEL` (attestation-overview; snippet only). The earlier claim that "no MRTD reference exists" was too strong.

[6] RTMR1 and RTMR2 cover GRUB/shim and the kernel plus command line, so kernel updates change them. The different kernels on master and worker plausibly explain the different RTMR2 values (inference). The RTMR0 difference is unexplained. Google: "Every Compute Engine VM instance launch is treated as a new machine, booted with the latest virtual firmware version" (vTPM section, page opened). MRTD may therefore change after a TERMINATE and restart (inference for TDX). After a host TDX module runtime update, "TEE_TCB_SVN_2 ... changes" while "TEE_TCB_SVN reflects the TCB at TD launch time" (kernel.org, page opened). Google's release notes (14 July 2025, snippet only) add that remote attestation is not supported on SLES 15 SP7 and Ubuntu 25.04 guest images, so an operating-system upgrade can also break attestation. Our VMs run Ubuntu 22.04.

[7] The dependencies are:
- Intel collateral and CRLs. Intel: "The Verifier compares evidence in the quote with the verification collateral it collects from the provisioning certification services" ([Intel TCB Recovery](https://www.intel.com/content/www/us/en/developer/articles/technical/software-security-guidance/best-practices/trusted-computing-base-recovery.html#:~:text=The%20Verifier%20compares%20evidence%20in%20the%20quote%20with%20the%20verification%20collateral); snippet only).
- Google's host-registry JSON in Cloud Storage (tdx-provenance, page opened).
- The best-effort endorsement bucket [5].

The basic check needs none of these, but it skips revocation. "Do not fail open" therefore means: deny access when collateral cannot be fetched, rather than falling back to the basic check (author judgement).

[8] Google's provenance page verifies quotes "by using the embedded Intel root certificate" (page opened; last updated 2026-09-30). Two earlier claims are corrected and must not reappear. First, verification did not rely on an "offline" root only: the basic run used the built-in root, and the strict run downloaded Intel collateral and CRLs, and both passed. Second, `check` was not compared with `gceprovenance`, because `gceprovenance` was not run.

[9] Google says `gceprovenance` "performs a basic quote authenticity check by verifying the quote's signature and the embedded certificate chain". For "complete TCB evaluation, certificate revocation list (CRL) checks, or RTMR verification" it points to `check` (page opened). What `gceprovenance` adds is host provenance (the PPID from the PCK certificate matched against Google's host registry) and instance binding (the SHA-384 of project number, zone and instance ID matched against `MR_OWNER`). The two tools complement each other.

[10] Intel Trust Authority's change log (dated 2026-09-28) says "AMD SEV-SNP attestation remains a preview feature, available only on the Intel Trust Authority Pilot environment" (page opened). An older concept page (02/06/2025) lists only SGX and TDX, so the two pages are not in sync. Google's Confidential Space overview lists "Google Cloud Attestation: Supports AMD SEV and Intel TDX VM instances" and "Intel Trust Authority: Supports Intel TDX VM instances" (page opened). IETF RATS, Trustee and KBS were not researched.

[11] The kernel documentation says "Shared mapping content is entirely controlled by the hypervisor" and "TDX uses SWIOTLB for most DMA allocations" (snippet only, because the opened copy was cut off before that section). Intel's guest-hardening specification says data in shared memory "must be protected where possible using application-level security mechanisms, such as encryption and authentication" (snippet only). HDFS encryption at rest does not protect shuffle or RPC traffic in flight, so the mitigation now names wire encryption.

[12] Hadoop SecureMode: "Setting hadoop.rpc.protection to privacy in core-site.xml activates data encryption"; set "dfs.encrypt.data.transfer to true" for DataNode transfer (snippet only; the snippet labelled `stable` as 3.3.5 and `current` as 3.5.0). The 3.4.0 page cited in the previous draft was not opened, and the cluster ran 3.4.3. Privileged-port DataNode authentication assumes "the attacker won't be able to get root privileges on DataNode hosts" (r3.3.4, snippet only). In a TEE setting the host operator is the attacker, so SASL data-transfer protection is the better fit (inference).

[13] Google's Intel TDX limitations (page opened; tabbed page, so fragments may not scroll if the tab is hidden):
- "Confidential VM instances might experience lower network bandwidth and higher latency compared to non-Confidential VM instances."
- "Guest images without the TDX halt fixes might experience extended halt durations, resulting in performance degradation."
- CPUID "might return limited or no CPU architecture details", which may affect JVM tuning (inference).

Whether the Ubuntu 6.8.0-106x-gcp kernels carry the halt fixes was not checked.

[14] One search for Hadoop or Spark benchmarks on TDX found none. It returned only general CVM studies:
- Misono et al., "Confidential VMs Explained: An Empirical Analysis of AMD SEV-SNP and Intel TDX" (SIGMETRICS 2025, TUM PDF), reports "up to 431% increase in execution time (NPB benchmark "ua" on a TD)", and links part of it to HLT overhead. It also reports up "to 60% performance drop for heavy network processing benchmarks (iperf TCP)", the closest available proxy for Hadoop shuffle traffic (snippet only).
- Kuvaiskii et al. (Gramine-TDX, CCS '24, ACM DL abstract) report "1-25% average overhead for CPU- and memory-intensive applications". They add that "Performance on network- and FS-intensive applications can drop to 6% of the native application's" (a library OS, not a stock guest).

These results do not transfer to Hadoop. One search does not prove that no benchmark exists.

[15] The Google/Intel review (arXiv 2602.11434 v1, Feb 2026) says: "Availability is not included in the security objectives because a host VMM can simply deny the Intel TDX Module and TDs the platform resources required for operation". This arXiv HTML appears to be converted from the PDF; no LaTeXML ids were found, so text fragments are used. Google's live-migration page (page opened, 2026-09-24) says non-migratable CVMs "must set their onHostMaintenance policy to TERMINATE". It lists a notice period of "7 days" for Intel TDX on `c3-standard-*`, `c3-standard-*-lssd` and `c4-standard-*` ([table](https://docs.cloud.google.com/confidential-computing/confidential-vm/docs/troubleshoot-live-migration#:~:text=host%20maintenance%20event%20notification%20period)). That page suggests sole-tenant nodes, but the supported-configurations page says TDX "VM instances can't be provisioned on sole-tenant node groups". The two Google pages conflict, and the TDX-specific restriction is the more specific statement.

[16] Google's TDX limitations (page opened) include:
- "Only Balanced Persistent Disk volumes that use the NVMe interface are supported".
- "Confidential VM instances with Intel TDX don't support reservations".
- "VM instances don't support kdump." (Intel TDX list). The advice "Instead, use the guest console logs" appears in the AMD SEV-SNP list in the page text checked on 3 October 2026, not in the TDX list. The fragment uses a prefix because the same kdump line also appears under SEV-SNP.

The page lists `c3-standard-*` (Sapphire Rapids) and `c4-standard-*` (Granite Rapids) for TDX, both in us-central1-a. On GA status, the release notes say "Support for Intel TDX on c3-standard-* machine types is now released to General Availability" ([release notes](https://docs.cloud.google.com/confidential-computing/confidential-vm/docs/release-notes#:~:text=Support%20for%20Intel%20TDX%20on%20c3%2Dstandard%2D%2A%20machine%20types%20is%20now%20released%20to%20General%20Availability); snippet only), and they list `c3-standard-*-lssd` as Preview. The GA status of TDX on `c4` was not verified.

[17] No primary Google, Intel or Microsoft guidance on logging or core dumps inside CVMs was found. Guest console logs go to the serial console, which the host can read, so treat the console as a plaintext channel (inference). JVM heap dumps and `hs_err` files are not affected by the lack of kdump (inference; not tested).

[18] The WARC 1.1 IP field is only a hint, and our runs did not even fill it. TLSNotary: "TLS does not have a mechanism to enable the server to "sign" the data" (snippet only). A 2023 project update said proofs were practical only for "data volumes in the low kB range" (snippet only; may be out of date). DECO (arXiv 1909.00938) makes the same point about TLS (PDF snippet only). Signed HTTP Exchanges and verifiable web archiving were not researched. Common Crawl (pages opened):
- "CCBot is a Nutch-based web crawler that makes use of the Apache Hadoop project" ([FAQ](https://commoncrawl.org/faq#:~:text=is%20a%20Nutch%2Dbased%20web%20crawler%20that%20makes%20use%20of%20the%20Apache%20Hadoop%20project)).
- It is "checking first the robots.txt" ([FAQ](https://commoncrawl.org/faq#:~:text=checking%20first%20the%20robots.txt)).
- It identifies as `CCBot/2.0 (https://commoncrawl.org/faq/)`.
- "we are aware of crawlers falsely identifying themselves as CCBot" ([CCBot](https://commoncrawl.org/ccbot#:~:text=we%20are%20aware%20of%20crawlers%20falsely%20identifying%20themselves%20as%20CCBot)).
- "CCBot is now run on dedicated IP address ranges with reverse DNS" ([CCBot](https://commoncrawl.org/ccbot#:~:text=CCBot%20is%20now%20run%20on%20dedicated%20IP%20address%20ranges%20with%20reverse%20DNS)).

A crawl from GCP VMs uses none of these IP ranges, so sites may serve it different content (inference). FAQ answers may be collapsed, which can break fragments.

[19] TDXRay is by Hornetz, Yavarzadeh et al. (CISPA/Google; IEEE S&P 2026). It runs "entirely in software on the host machine". It affected Sapphire, Emerald and Granite Rapids; the benchmark results were reported on "Intel Xeon 6736P (Granite Rapids) · TDX Module v2.0". Its FAQ says "Intel's own threat model explicitly excludes microarchitectural side channels". The authors also say they "notified Intel and major vendors ... including Apple, Anthropic, Google, Microsoft, Meta, and OpenAI — in November 2025".

There is a conflict over the Intel advisory number. The TDXRay FAQ calls it INTEL-SA-01271. Intel's Security Bulletins index lists the TDXRay notice as "TDXRay | 2026-04-02-001 | April 2, 2026", while Intel's own INTEL-SA-01271 page (page text seen on 3 October 2026) is the "Intel® Gaudi® Software Installer Advisory" (CVE-2024-45067, May 2025), unrelated to TDX. The bulletin index page lists TDXRay as 2026-04-02-001; the bulletin page itself was not opened. Cite the bulletin 2026-04-02-001, not the FAQ's number.

GCP `c3-standard` uses Sapphire Rapids. The 2026 Google/Intel review also left "attacks that leak memory access patterns of TDs" out of scope ([arXiv 2602.11434](https://arxiv.org/html/2602.11434#:~:text=attacks%20that%20leak%20memory%20access%20patterns%20of%20TDs%20were%20also%20outside%20the%20scope)). For the lost footnote 19, AMD's TDXRay bulletin "recommends software developers employ existing best practices, including constant-time algorithms, and avoiding secret-dependent data accesses where appropriate" ([AMD-SB-3044](https://www.amd.com/en/resources/product-security/bulletin/amd-sb-3044.html#:~:text=AMD%20recommends%20software%20developers%20employ%20existing%20best%20practices); severity "N/A - Informational"). The same bulletin says "AMD believes that all side-channel techniques demonstrated in the paper fall within the category of already known, documented, and out-of-scope behaviors" of the SEV-SNP threat model. That is the closest match found; the original source remains unknown. WeSee targets SEV-SNP, not TDX (search title only).

[20] The 2026 report found "one vulnerability that enables a VMM to fully compromise a TD": CVE-2025-30513, score 7.9. All findings were "remediated in versions 1.5.24/1.5.25 & 2.0.14 of the Intel TDX Module onwards (versions depend on the specific Intel platform)" ([fix versions](https://arxiv.org/html/2602.11434#:~:text=remediated%20in%20versions%201.5.24,2.0.14%20of%20the%20Intel%20TDX%20Module%20onwards)). Fixes shipped in "IPU 2026.1 or other product sustaining releases between September and December 2025", followed by TCB Recovery after the "February 10, 2026 public disclosure". Intel's advisory INTEL-SA-01397 (2026.1 IPU, TDX module, severity HIGH, 02/10/2026) lists "4th Gen Intel® Xeon® Scalable processor · 1.5.20 and earlier" as affected (page opened 3 October 2026; CVE-2025-30513 is rated 7.9 under CVSS 3.1 and 8.4 under CVSS 4.0). Google's report says all findings are remediated from 1.5.24/1.5.25, and Intel's text says CVE-2025-32007 affects versions before 1.5.24, so the status of 1.5.21 to 1.5.23 is not stated clearly in either source (check Intel's TDX module release notes). The report text above was verified verbatim in the arXiv PDF on 3 October 2026; the arXiv HTML view was not opened, so the text fragments may not resolve. That is Sapphire Rapids, which `c3-standard` uses. The advisory also covers transient-execution leakage (CVE-2025-27572). The CVE affects migratable TDs, and GCP TDX VMs do not live-migrate, so direct exposure is probably low (inference). The lesson is that the TDX module is patchable software. The 2023 TDX 1.0 review "covered 81 potential attack vectors, and resulted in 10 confirmed security issues and five defense-in-depth changes over a period of nine months" ([Google Cloud blog, 24 April 2023](https://cloud.google.com/blog/products/identity-security/rsa-google-intel-confidential-computing-more-secure#:~:text=The%20review%20covered%2081%20potential%20attack%20vectors)). Our quotes' `tee_tcb_svn` (read on 3 October 2026) begins `0f 01 0a` in all four quotes: minor SVN 0x0F, major SVN 0x01, microcode SVN 0x0A. Intel's TDX module release notes (page text seen in search results) list minor SVN 0x0D for 1.5.24, 0x0E for 1.5.28 and 0x0F for 1.5.34 (build date 2026-03-30, described as the latest publicly available 1.5 release at the time), so the TDs were launched on a module at or above the 1.5.34 level (inference from the SVN table; `TEE_TCB_SVN` reflects the TCB at TD launch). That is above the 1.5.24 level at which Google's report says its findings are remediated.

[21] TEE.fail (IEEE S&P 2026) built a DDR5 interposer "using only off the shelf electronic equipment" and extracted "in some cases secret attestation keys from fully updated machines in trusted status". Its forged TDX quote verifies "at the highest trust level of UpToDate" (page opened). The attack needs physical access. A valid UpToDate quote is therefore necessary but not sufficient, and provider provenance and physical security become part of the trust argument (inference). Intel's bulletin INTEL-2025-10-28-001 "TEE.fail" (page text seen 3 October 2026) says the research "does not change Intel's previous out of scope statement for these types of physical attacks" and names 4th and 5th Gen Xeon Scalable and Xeon 6 platforms with DDR5. Google lists `c3-standard` as Intel Sapphire Rapids, which is 4th Gen (inference). A later paper, DDRop (snippet only, not opened), claims end-to-end attacks on an up-to-date TDX platform, including forcing a TD into debug mode and spoofing attestation reports.

## Severe trust issues (ranked)

1. **Application code is not attested (rows 23, 16).** The quote proves that some TD signed some REPORTDATA. It does not prove which program computed it.
2. **Content authenticity is out of reach of any TEE (row 18).** A perfect TD still cannot prove that fetched bytes are what the origin really serves, and the current WARCs lack even the IP and robots.txt records.
3. **Inter-node traffic is plaintext and unauthenticated (rows 17, 3).** The host can read and alter shuffle, RPC and block traffic.
4. **No RTMR0–2 reference values, and MRTD not yet checked against Google's endorsement (rows 15, 6).** A verifier cannot tell a good boot chain from a bad one.
5. **TEE vulnerabilities and physical attacks (rows 12, 25, 7).** Forged UpToDate quotes are possible with physical access, and side channels are excluded from Intel's threat model.
6. **Host-controlled time (row 19).** Dates are claims made by the host, not attested facts.
7. **Evidence and logs leave the TD unprotected (rows 26, 9).** Once exported in plaintext, the TEE guarantees are gone.

**Update, 6 October 2026.** Issue 1 is partly addressed: the quotes now cover the measured stack (rows 1, 23), but nothing locks it between measuring and running (rows 27, 28). Issue 4 is partly addressed: the firmware log replays to RTMR0 to RTMR2, but there are still no reference values and MRTD has not been checked (row 15). Issues 2, 3, 5, 6 and 7 are unchanged. Inter-node traffic (issue 3) is the next milestone.


**Update, 6 October 2026 (Milestone 2).** Issue 3 is partly addressed: traffic between the nodes goes through an encrypted tunnel and the ordinary interface is closed to Hadoop ports (rows 3, 17), but peers are not admitted by attestation (row 36) and the closing depends on a firewall that is not persistent (row 35). The other issues are unchanged.

## Better TEE options for CCBot

| Option | Trust anchor | What is attested | TCB size | Multi-node Hadoop/JVM fit | Networking for a crawler | Maturity (as verified) | Main caveat |
|---|---|---|---|---|---|---|---|
| Intel TDX CVM on GCP (current) | Intel plus Google firmware endorsements | MRTD, RTMR0–2; RTMR3 optional | Large (whole guest) | Good: ran unmodified (R1) | Full, via shared buffers | `c3-standard-*` GA (snippet only); `c4` listed | Userspace not measured by default; no kdump, reservations or live migration |
| AMD SEV-SNP CVM on GCP | AMD VCEK chain plus Google endorsements | Launch MEASUREMENT; vTPM for later stages | Large | Good, by analogy (inference) | Full | N2D Milan only; zones include us-central1-a ([page opened](https://docs.cloud.google.com/confidential-computing/confidential-vm/docs/supported-configurations?tab=amd-sev-snp#:~:text=AMD%20SEV%2DSNP%20is%20supported%20in%20the%20following%20zones)) | 1-hour maintenance notice; post-launch boot measurements software-attested |
| Google Confidential Space | AMD SEV or Intel TDX plus Google image and attestation | Container image and launch policy | Medium | Weak for clusters; suits one container (inference) | Normal VM (inference) | Operator "has no access to the data" ([page opened](https://docs.cloud.google.com/confidential-computing/confidential-space/docs/confidential-space-overview#:~:text=The%20workload%20operator%20has%20no%20access%20to%20the%20data)); "must use AMD SEV, Intel TDX" | Trust in Google's image and verifier; good for a sealing or signing step |
| AWS Nitro Enclaves | AWS Nitro hypervisor and NSM | Enclave image measurements | Small enclave; AWS fully trusted | Poor | None: "no external network connectivity, and no persistent storage" ([AWS](https://docs.aws.amazon.com/enclaves/latest/user/nitro-enclave-concepts.html#:~:text=An%20enclave%20has%20no%20external%20network%20connectivity%2C%20and%20no%20persistent%20storage); snippet only) | Mature | The untrusted parent carries all traffic; no CPU-vendor root |
| Intel SGX with Gramine or Occlum | Intel SGX DCAP | MRENCLAVE and MRSIGNER | Smallest | Poor to medium (heavy JVM porting) | Host-mediated | GCP SGX not verified; absent from GCP's Confidential VM list (inference) | Side channels; porting; prior SGX MapReduce work not re-verified |
| Azure CVMs (SEV-SNP, Intel TDX) | AMD or Intel plus Microsoft attestation | Hardware report plus vTPM (paravisor detail unverified) | Large | Good, by analogy (inference) | Full | TDX "generally available in West US, West US 3 and West Europe" ([Microsoft](https://techcommunity.microsoft.com/blog/azureconfidentialcomputingblog/announcing-general-availability-of-azure-intel%C2%AE-tdx-confidential-vms/4495693#:~:text=are%20now%20generally%20available%20in%20West%20US); snippet only); SEV-SNP DCasv5 GA (snippet only) | Limited TDX regions; Azure Attestation not verified |
| Constellation (Edgeless) | CVM plus Constellation images | Node images, cluster attestation | Large | Designed for clusters | Encrypted pod network | "no longer actively maintained"; archived 22 Jan 2026 ([GitHub](https://github.com/edgelesssys/constellation#:~:text=Constellation%20is%20no%20longer%20actively%20maintained%20by%20Edgeless%20Systems); snippet only) | Do not adopt |
| Contrast (successor) | SEV-SNP or TDX via Kata micro-VMs | Per-pod policy | Medium | Possible as Kubernetes pods (inference) | Pod network plus mesh | "supports bare-metal setups based on AMD SEV-SNP and Intel TDX" ([docs](https://docs.edgeless.systems/contrast#:~:text=Contrast%20supports%20bare%2Dmetal%20setups%20based%20on%20AMD%20SEV%2DSNP%20and%20Intel%20TDX%20hardware); snippet only); GKE only "future support" ([blog, Oct 2025](https://www.edgeless.systems/blog/from-constellation-to-contrast#:~:text=with%20future%20support%20for%20EKS%20and%20GKE); snippet only) | Not usable on GCP CVMs as verified |
| Confidential Containers / Kata with Trustee | CVM plus Trustee KBS | KBS-checked evidence | Medium | Possible (inference) | Pod network | Not researched (unverified) | Unverified |
| Intel Trust Authority (verifier, not a TEE) | Intel-operated service | TDX and SGX; SEV-SNP preview [10] | n/a | Works with any TDX CVM | n/a | TDX supported for Confidential Space [10] | Moves trust to Intel; still an online dependency |

**Recommendation.** Keep VM-level TDX for the Hadoop and crawler workload. GCP or Azure TDX can be chosen later. Spend effort on the attestation gaps rather than on switching TEE. Process-level TEEs fit a networked multi-node JVM crawler poorly. Constellation is unmaintained, and Contrast does not yet run on GCP CVMs (inference). The best near-term design is: TDX CVMs with userspace measured into RTMR3; attested, encrypted Hadoop channels; and a small attested signing step (possibly in Confidential Space) that signs the hashes of the WARCs and manifest with a key released only after an independent verifier approves (Intel Trust Authority, or a self-run go-tdx-guest with Intel collateral) (inference). Add TLS-oracle proofs only for the pages where provenance matters.

**What would change this recommendation.**
- A published Hadoop-on-TDX benchmark showing prohibitive I/O overhead.
- Contrast supporting GKE.
- The crawl data becoming confidential. For public web data, integrity matters more than confidentiality, which lowers the weight of row 7 (author judgement).

## Next experiments

1. Extend RTMR3 with hashes of the JDK, Hadoop, `.job`, configs and seeds before starting the daemons; verify by replaying the event log. **Done 5 to 6 October 2026** (Milestone 1): master 10 events, worker 5; quotes verified off-cloud and replayed. On the worker it was done before the daemons started; on the master the daemons were already running; both were before the crawl. See [milestone-1-code-measurement.md](milestone-1-code-measurement.md).
2. Check the observed MRTD against Google's launch endorsement; replay CCEL on both nodes to explain the RTMR0 difference. **Partly done:** CCEL replayed on both nodes on 6.8 and 6.17 boots (RTMR0 to RTMR2 reproduced). The MRTD check is not done, and one RTMR0 event (`Boot0002`) is not decoded.
3. Run `gceprovenance` and strict `check` on the same quotes; record TCB status and TDX module version.
4. Enable `hadoop.rpc.protection=privacy`, `dfs.encrypt.data.transfer=true`, HTTPS and Kerberos or SASL; restrict the firewall to Hadoop ports. **Partly done 6 October 2026** by a different mechanism: a WireGuard mesh plus a host firewall (milestone-2-wireguard-mesh.md). Hadoop's own encryption and authentication are not enabled.
5. Repeat the crawl on non-TDX `c3-standard-4` with the same image; compare wall time, CPU per GB and throughput.
6. Fix the WARC gaps: real IP, stored robots.txt responses, a domain filter, payload hashes in the attested manifest. **Partly done:** the real IP is recorded since run 3; the rest is open.
7. Simulate host maintenance and compare MRTD and RTMRs after restart.
8. Sign the evidence bundle inside the TD before export.
9. Done on 3 October 2026 (see [quote-verification.md](quote-verification.md) section 6): `td_attributes` is all zeros and `tee_tcb_svn` shows minor SVN 0x0F in all four quotes. Still open: why `td_attributes` differs from Google's example value 0x10000000, and recording the TCB status string the verifier reports.
10. Pass-through file layer in front of HDFS (handoff Gate A, item 2). **Done 6 October 2026** (Milestone 3): the wrapper behind `hdfs://` (both lookups, the real client built directly), a full crawl through it (run 6), and a clean storage audit. Then **partly done 7 October 2026** (Milestone 4, steps 4.2 and 4.3): chunk hashing at close and verified reads (runs 7 and 8) and a tamper test. Contract tests (step 4.4) **done 7 October 2026**. Step 4.5 (metadata from records, with the NameNode's audit log) **done 8 October 2026**. Next, in numeric order ([milestone-plan.md](milestone-plan.md)): step 4.6 (the wrapper on Hadoop's classpath, changed by the mentor), step 4.7 (task records and manifests), then the re-measurement (step 4.8).

## Verification status

| Source | Status | Used for |
|---|---|---|
| Google: tdx-provenance (2026-09-30), verify-firmware, measurement-register-contents (2026-08-26), troubleshoot-live-migration (2026-09-24) | page opened | rows 1, 5, 6, 8, 15, 21, 22, 23 |
| Google: supported-configurations | page opened (tabbed; fragment stability uncertain) | rows 4, 9, 10, 24 |
| Google: attestation-overview, attestation, release notes | snippet only | rows 15, 23, 24 |
| Google: Confidential Space overview and security pages; 2023 TDX review blog | page opened | options table, rows 12, 14 |
| arXiv 2602.11434 v1, 2404.03387, 2501.11558v1 (HTML; no LaTeXML ids found, text fragments used) | page opened | rows 1, 2, 7, 8, 12 |
| kernel.org TDX (7.3.0-rc5) and configfs-tsm ABI | page opened (SWIOTLB sentence snippet only) | rows 2, 3, 6, 16 |
| Intel guest hardening spec; Intel TCB Recovery; AMD-SB-3044 | snippet only | rows 3, 5, 7 |
| Intel INTEL-SA-01397 | page opened (3 October 2026) | rows 12, note 20 |
| Intel INTEL-SA-01271 (Gaudi installer advisory, see note 19); Intel bulletin 2025-10-28-001 (TEE.fail) | page text seen in search results | rows 7, 25 |
| Intel bulletin 2026-04-02-001 (TDXRay) | listed on Intel's bulletin index; bulletin page not opened | row 7 |
| arXiv 2602.11434: text checked in the PDF (3 October 2026); HTML view not opened | PDF opened | rows 7, 8, 12 |
| Google community blog "Beyond Confidential" (18 November 2025) | page opened | rows 6, 12, 15 |
| Intel TDX module release notes (1.5.13 to 1.5.34 and their SVNs); Intel TDX module 1.5 ABI specification | page text seen in search results (3 October 2026) | row 12, note 20 |
| Intel Trust Authority pages; TDXRay site; TEE.fail site; Common Crawl CCBot and FAQ | page opened | rows 7, 14, 18, 25 |
| Hadoop SecureMode; WARC 1.1; TLSNotary; DECO; TUM and Gramine-TDX PDFs | snippet only | rows 3, 13, 17, 18 |
| AWS Nitro concepts page; Constellation GitHub and documentation (archived 22 January 2026) | page text seen in search results (3 October 2026) | options table |
| Edgeless Contrast; Microsoft Azure posts | snippet only | options table |
| Hadoop transparent encryption; GCP disk encryption; trusted guest time | unverified | rows 11, 19 |
| gce-tcb-verifier issue 73; Gramine performance page; Nitro "nitro-enclave.html"; Hadoop r3.4.0 page | not opened; not cited | — |
| kernel.org ABI `sysfs-devices-virtual-misc-tdx_guest`; Ubuntu archive package lists (noble-updates, jammy-updates) and the 6.17.0-1022-gcp packages | page and package lists opened (5 October 2026) | rows 1, 23, 29; milestone-1 §7 |
| A teammate's description of their source-receipt code | relayed in conversation; not tested by us | row 34, ADR-002 |
| Items marked "(inference)" or "(author judgement)" | inference | throughout |

## Open questions and not researched

- Why RTMR0 (and possibly RTMR1) differs between the nodes. Updated 6 October: the RTMR1 and RTMR2 differences are explained (partition growth, kernel, GRUB); one RTMR0 event, `Boot0002`, is not decoded.
- Whether the GCP 6.8 kernels include the TDX halt fixes and the Heckler mitigations.
- Why `td_attributes` is all zeros while Google's example value is 0x10000000; and the TCB status string the verifier reported (not recorded).
- Trusted time for TDX guests; time-stamping options for WARC dates.
- Hadoop encryption zones and KMS; GCP CVM disk-encryption options.
- Hadoop, Spark or MapReduce benchmarks on TDX or SEV-SNP (only one search was run).
- SGX MapReduce systems (VC3, M2R, Opaque, Occlum/BigDL PPML, Gramine); whether GCP offers SGX.
- Microsoft Azure Attestation, and the paravisor's place in the TCB.
- Confidential Containers with Trustee, IETF RATS, Signed HTTP Exchanges.
- The original source of footnote 19.
