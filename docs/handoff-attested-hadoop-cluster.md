# Handoff: attested CCBot on a multi-node Hadoop cluster in Intel TDX

**Corrected on 7 October 2026.** The text below the corrections is the handoff of 4 October 2026, unchanged; where a statement is outdated or was wrong, a marker in **bold** names the correction. The original handoff has the SHA-256 `5123668b5bd0c563d54c33cfb6b6e7698c08adff13c9559cf7577da6791b2d33`. The corrections come from our milestone reports (the lists "Differences from the handoff") and from the mentor's answers of 7 October 2026 (ADR-026 in [decisions.md](decisions.md)).

## Corrections (7 October 2026)

| ID | Where in the handoff | What it said | What is true now | Source |
|---|---|---|---|---|
| C1 | Section 2, the baseline runs | Rishab's runs are the reference for later runs | Run 3 is not byte-comparable with runs 1 and 2 (the configuration is inside the job file). | milestone-1 section 12.1 |
| C2 | Section 8, "Measured image" (line 187) | A quote must identify the JDK, Hadoop, the Nutch job jar and the config | Line 187, "identify the JDK": the JDK folder alone does not do it; JDK settings and the CA store live in `/etc`. | milestone-1 section 12.2; ADR-005, ADR-006 |
| C3 | Section 8, "Reproducible image build" (line 197; our report cites line 187) | An image digest on an allowlist means little unless someone else can rebuild it | Line 187, an image digest on an allowlist: raw register values depend on disk identifiers, partition growth on the first boot and GRUB state. A verifier needs event-level policy. | milestone-1 section 12.3 |
| C4 | Section 8, "Measured image" (line 187) | Extending RTMR3 needs kernel 6.16 or later; a 6.17 GCP kernel reportedly exists | The kernel requirement (6.16 or later) is confirmed. A 6.17 Google kernel exists for Ubuntu 24.04 and works, installed on Ubuntu 22.04, on these VMs. It exists for 22.04 only up to 6.8. | milestone-1 section 12.4; ADR-003 |
| C5 | Section 8, "Substrate choice" and "TLS certificate checking ON" (lines 189 and 190) | Both PENDING Pingshan's confirmation | Lines 189 and 190 (substrate, TLS) now have mentor answers (ADR-001, ADR-002). | milestone-1 section 12.5; ADR-001, ADR-002 |
| C6 | Section 7, condition 3 (line 181) | Workers load the job jar and config from a staging directory; digests go in every task record | Line 181: the worker holds no job file; the jar digest needs the task-record mechanism. Superseded by decision D6 (7 October 2026). | milestone-1 section 12.6; ADR-027 |
| C7 | Section 2, operations | (not in the handoff) | YARN kept no container logs on this cluster, and the worker's local task logs were removed. | milestone-1 section 12.7 |
| C8 | Section 6 (line 153), and section 2 | Hadoop source references at release 3.4.1 | The handoff's Hadoop source references are from release 3.4.1 (line 153); the cluster runs 3.4.3. | milestone-1 section 12.8 |
| C9 | Section 11 (lines 239 and 244) | Open questions: the 6.17 kernel and the RTMR0 to RTMR2 differences | Line 239 (does the 6.17 kernel expose RTMR extension and the boot log): yes, for Ubuntu 6.17.0-1022-gcp on these VMs, both nodes. Line 244 (why RTMR0 to RTMR2 differ between nodes): kernel, GRUB configuration and state, disk identifiers and partition growth; one RTMR0 event is not decoded. | milestone-1 section 12.9 |
| C10 | Section 7, design (line 172) | Every Hadoop daemon binds only to the mesh interface | The handoff says the daemons are bound to the mesh. In practice the master's RPC daemons bind through their hostnames, while the NameNode web page and the worker's daemons bind to all addresses and are closed by the host firewall. | milestone-2 section 9.1 |
| C11 | Section 9, step 1 (line 204) | Pass: a job submitted from a third machine outside the mesh is refused | A job from "a third machine" was tested with a stand-in (ordinary network path), because no third VM was created. | milestone-2 section 9.2; ADR-016 |
| C12 | Section 7 | (not in the handoff) | Node names matter: a node can register under a name that resolves to the closed network, after an unrelated hosts-file change. | milestone-2 section 9.3; ADR-015 |
| C13 | Section 7, condition 3 (line 181) | Workers load the job jar and config from a staging directory | The job file travels to the worker through HDFS staging for every application (about 134.8 MB, 27 times in run 5), which supports the handoff's design of checking the job file at load on the worker. | milestone-2 section 9.4 |
| C14 | Section 6, piece 1 (line 155), and section 9, step 2 (line 205) | A wrapper registered under a custom scheme such as attested:// | The wrapper replaces the implementation behind `hdfs://` instead of registering `attested://` (mentor-approved). | milestone-3 section 13.1; ADR-017 |
| C15 | Section 6, piece 1 (line 155) | Hadoop resolves a scheme to a class from the configuration | Both lookups must be swapped: `fs.hdfs.impl` and `fs.AbstractFileSystem.hdfs.impl`. | milestone-3 section 13.2 |
| C16 | Section 6, piece 1 (line 155) | Nutch always reaches storage through this layer | "Nutch always reaches storage through this layer" is not literally true (81 path-style calls and 6 default-style); with the `hdfs://` replacement every request of a configured JVM goes through anyway. | milestone-3 section 13.3 |
| C17 | Section 7, condition 3 (line 181), and section 11 (line 240) | Job code and config verified at load; whether Hadoop's loader goes through the wrapper is inferred, not tested | The job file is uploaded through the wrapper by the client (27 uploads), but the NodeManager reads it through plain HDFS, so the handoff's "job code verified at load" (item 3 of the control plane) is still open. Resolved by decision D6 (7 October 2026). | milestone-3 section 13.4; ADR-027 |
| C18 | Section 6 (line 153), and section 2 | Hadoop source references at release 3.4.1 | Hadoop is 3.4.3, not 3.4.1. | milestone-3 section 13.5 |
| C19 | Section 6, piece 2 (line 156) | A commit hook signs one record when a task commits | Records are made by the wrapper when each file is closed, tagged with the task attempt id, and not by the commit hook: Nutch's fetch, parse and WARC outputs are written directly to their final path, and its parse output creates its own committer, so the hook set by configuration does not see them all. The committer stays an optional extra for manifests (question 13). | milestone-4 section 14.1; ADR-022 |
| C20 | Section 6, pieces 1 and 4 (lines 155 and 158) | Sign on write, with a signed record and a ledger | The record is kept in a companion file next to the data file, not yet in a signed record and a ledger. | milestone-4 section 14.2; ADR-021 |
| C21 | Section 6, piece 3 (line 157) | All metadata from records, never from storage | Metadata from records is not yet done. | milestone-4 section 14.3; step 4.5 |
| S1 | Section 0 (line 9) | Nothing in this document has been compiled or run, except Rishab's baseline runs | Milestones 0 to 4 have been built and run on the cluster: runs 3 to 8, the mesh, the wrapper, hashing, verified reads and the contract tests (docs/milestone-0 to milestone-4). | milestone-0 to milestone-4 |
| S2 | Section 2 (line 45) | The crawler code is not measured: RTMR3 was all zeros | The crawler stack was measured in Milestone 1 (master 10 events, worker 5; quotes verified off-cloud; the event log replayed). Runs 6 and later used a job outside the measured set and are not covered by the measurement (ADR-020, ADR-029). | milestone-1; limitations rows 23 and 27; ADR-020 |
| S3 | Section 2 (line 49) | The run did not use CCBot's HTTP client | Runs 3 and later use protocol-okhttp with the IP address stored. | milestone-0 |
| S4 | Section 8, "Use CCBot's real HTTP client" (line 191) | To do | Done in runs 3 to 8 (protocol-okhttp, IP and header storage on). | milestone-0 |
| S5 | Section 9, the work plan | (statuses) | Gate A (steps 1 to 3) is done and accepted by the mentor; Stage B is partly done; see the status notes at each step and docs/milestone-plan.md. | ADR-026; milestone-plan |
| S6 | Section 11, open questions | (open) | The questions on the AAAI-27 workshop, the 6.17 kernel, the job loader, per-fetch TLS evidence and the RTMR differences have answers or decisions; see C9, C17 and decisions D5 to D7. The witness and the object-store questions are open (defaults apply). | ADR-026 |

## Decisions since the handoff (the mentor, 7 October 2026)

- **D1.** Gate A is accepted. The evidence for "outputs match" is enough; from Stage B on, run the unwrapped control in the same hour (ADR-028).
- **D2.** The audit's scope is accepted as scoped; turn on the NameNode audit log in Stage B (step 4.5, baby step 4.5.2).
- **D3.** The re-measurement is deferred, as long as nothing unmeasured is ever described as measured (ADR-029).
- **D4.** The handoff corrections are applied now, in one commit with a corrections list at the top (this document).
- **D5.** AAAI-27: nothing new until the 16 October list; plan for mid-November to 20 November, 5 pages plus 2.
- **D6.** Stage B uses our defaults except for question 6: a task hashing its own job file can be skipped by a swapped job file, so it is not a security check. The wrapper moves onto Hadoop's own classpath and both lookups are set as final in the site configuration, so the NodeManager uses it too (ADR-027; step 4.6).
- **D7.** Per-fetch TLS evidence (question 11) is teammate S's patch; coordinate with her on building the job with it (step 5.3, baby step 5.3.3).
- **D8.** Per Amir, performance is the result that matters most: record wall time and bytes fetched for every wrapped and unwrapped pair (ADR-028; results in step 6.3).

See ADR-026 to ADR-029 in [decisions.md](decisions.md) for the mentor's words, and [milestone-plan.md](milestone-plan.md) for the plan as it stands.

---


Written 2026-10-04 by Pingshan's assistant for Rishab and the LLM working with him. Rishab takes this over and sees it through to a working system and a paper.

## 0. How to use this document (instructions to the LLM)

You are picking up a design that has been researched but not built. Treat it as a strong starting point, not as fact.

- **Nothing in this document has been compiled or run**, except Rishab's own baseline runs (section 2). The Hadoop hook points, the mesh and the measured image are conclusions from reading source and docs. **[Correction S1]**
- **Verify before you build on a claim.** Each cited claim carries a status:
  - `[V]` read directly by Pingshan's assistant.
  - `[A]` read by a research agent and re-opened by a second checking agent. Not re-read by us.
  - `[R]` relayed from an abstract, a search snippet or memory. Treat as a lead.
  - `[I]` our own design reasoning.
- **Do it right, not fast.** Do not cut the security work to hit a date. If something cannot be done properly, say so and write it down as a limitation.
- **When you find this document is wrong, fix the document** and note the correction, the way Rishab's `docs/` already does.
- **Report outcomes plainly.** If a test fails, say it failed and include the output.
- Decisions marked **PENDING** are Pingshan's to confirm. Ask before building on them.

## 1. Goal, claim and threat model

**Goal.** A verifiable chain of custody for web-crawl pretraining data. A data consumer should be able to check, for every record in a crawl, that it was fetched and written by known, measured crawler code, and that nothing was changed or inserted afterwards.

**Why every record.** Data poisoning works at tiny rates, so sampling is useless. Each record needs its own proof, and consumers must be able to check all of them `[I]`.

**The claim we want to support.** "This WARC record was produced by this exact build of Common Crawl's crawler, running in a genuine Intel TDX VM, from bytes it received over TLS from host X, as part of crawl job J. The set of records for job J is complete."

**Adversary.** The data provider. They operate the cluster, the storage and the network, and have root on the hosts. They cannot break TDX.

**Out of scope, stated as assumptions.** Whether a website serves truthful content. TEE side channels and physical attacks. Availability: a malicious provider can always refuse to produce a verifiable crawl.

**Priority of threats.** Tampering and forgery come first, because they put attacker-chosen content into the corpus. Deletion and rollback come second (section 5).


## 2. Where we are: Rishab's baseline

Rishab ran stock Common Crawl Nutch (branch `cc`, commit `3270a761`, no Java changes) on a 2-node Hadoop 3.4.3 cluster in two GCP TDX VMs, bound a manifest to a TDX quote on each node, and verified all four quotes off-cloud. Docs: <https://github.com/Antisource/nutch/tree/4ecc81c99e0c404b5e19a9a72edd657666ad60d1/docs>. **[Corrections C1, C7]**

What it established:
- Hadoop and CCBot run on GCP TDX VMs with no failed tasks.
- TDX quotes can be requested through configfs-tsm and verified off-cloud with Intel collateral.
- A quote detects any later edit to the manifest it covers.

What it does not establish (Rishab's own limitations doc says most of this):
- **The crawler code is not measured.** RTMR3 was all zeros, so the quote covers firmware and kernel only. **[Correction S2]**
- **The manifest is self-asserted.** A script on the VM wrote it, about 40 minutes after the crawl ended, on the master. The worker did the fetching.
- **Nothing ties each output to the task that produced it.**
- **Inter-node traffic was plaintext and unauthenticated.**
- **The run did not use CCBot's HTTP client.** `conf/nutch-site.xml` does not set `plugin.includes`, so Nutch used the default `protocol-http` ([nutch-default.xml L1737-L1738](https://github.com/commoncrawl/nutch/blob/3270a761ee1052bed99f1b60b21d89fd5c2b1d33/conf/nutch-default.xml#L1737-L1738)) `[V]`, and `store.ip.address` is false by default ([L2940-L2941](https://github.com/commoncrawl/nutch/blob/3270a761ee1052bed99f1b60b21d89fd5c2b1d33/conf/nutch-default.xml#L2940-L2941)) `[V]`. That is why `WARC-IP-Address` was `0.0.0.0`. Common Crawl's example config uses `protocol-okhttp`. **[Correction S3]**

## 3. Why this direction (decision log)

| Decision | Why |
|---|---|
| Build on Common Crawl's crawler | It is the most widely used public web-crawl corpus for LLM pretraining, so a result on CCBot is a result on the real thing. The published WARCs name `commoncrawl/nutch` as their software `[A]` |
| Keep CCBot's code unmodified and attest it | The point is to show custody for the crawler people actually use. Config changes are allowed where security requires them (section 8) |
| VM-level TEE (Intel TDX), not SGX | SGX would mean porting a JVM, Hadoop and Nutch into enclaves. VC3 and Civet show how hard that is. A TDX VM runs the stack as is |
| **Multi-node cluster, not single-machine mode** | We chose Common Crawl to test feasibility at internet scale. Hadoop's single-machine mode defeats that purpose. In local mode the generator even forces a single fetch list ([Generator.java L969-L974](https://github.com/commoncrawl/nutch/blob/3270a761ee1052bed99f1b60b21d89fd5c2b1d33/src/java/org/apache/nutch/crawl/Generator.java#L969-L974)) `[A]` |
| Every master and worker VM is a TEE VM | All CCBot logic runs as map and reduce tasks on workers, and the masters schedule them. Trusting only the fetch step leaves the WARC writer and URL selection outside the proof |
| Storage is untrusted | Protecting storage with a TEE buys secrecy, which public web pages do not need. Integrity can be had by signing (section 6) |
| No Nimble, no CCF | Section 5 |
| Per-VM signing keys bound to the TDX quote | Third parties can verify, and a compromised VM can only forge its own outputs |

Background on the crawler's structure (jobs, tasks, the driver loop, CrawlDb) is in Pingshan's note "Hadoop and CCBot Architecture". The short version: a shell script runs separate MapReduce jobs in a loop (inject once, then generate, fetch, update per cycle) ([bin/crawl L301-L411](https://github.com/commoncrawl/nutch/blob/3270a761ee1052bed99f1b60b21d89fd5c2b1d33/src/bin/crawl#L301-L411)) `[V]`. Jobs talk to each other only through files on HDFS or object storage.

## 4. The core difficulty: from one trusted VM to a trusted cluster

A single TDX VM gives a clean story: everything inside the VM is the trusted computing base (TCB), a quote says what booted, and a key bound to that quote signs the outputs.

A cluster breaks that story, because much of what a distributed job does happens **outside every VM's TCB**:

```
   TDX VM (trusted)            TDX VM (trusted)            TDX VM (trusted)
  +----------------+          +----------------+          +----------------+
  | master         |          | worker: map    |          | worker: reduce |
  +-------+--------+          +---+--------+---+          +---+--------+---+
          |   control messages    |        |   shuffle        |        |
          +<--------------------->+        +<---------------->+        |
          :      NETWORK (operator controls it)                        :
          :                                                            :
          +----------------> DISK / OBJECT STORAGE <-------------------+
                       (operator controls it)
```

Two channels leave the TCB:

1. **Cross-node communication.** Job submission, scheduling, task status, and the shuffle (map output copied to reducers) all cross a network the operator controls.
2. **Disk I/O.** Every job reads its input from storage and writes its output to storage. The next job, possibly on another VM, reads it back. In between, the operator holds the bytes.

So a set of individually trustworthy VMs does not add up to a trustworthy computation by itself. Both channels have to be secured. This is the central engineering problem of the project, and it is the gap in Rishab's baseline.

Hadoop does not help by default `[A]`:
- The RPC server's default authentication is "simple", meaning it trusts the username the caller claims ([Server.java L3472-L3490](https://github.com/apache/hadoop/blob/4d7825309348956336b8f06a08322b78422849b1/hadoop-common-project/hadoop-common/src/main/java/org/apache/hadoop/ipc/Server.java#L3472-L3490)). Anyone who reaches the ResourceManager can submit a job, and that job runs inside an attested VM next to the signing key. That is a forgery hole.
- Map output checksums are CRC32 ([IFileOutputStream.java L53](https://github.com/apache/hadoop/blob/4d7825309348956336b8f06a08322b78422849b1/hadoop-mapreduce-project/hadoop-mapreduce-client/hadoop-mapreduce-client-core/src/main/java/org/apache/hadoop/mapred/IFileOutputStream.java#L53)), which an attacker can recompute.
- Hadoop's shuffle authentication covers the request URL and a reply hash, not the payload ([Fetcher.java L394-L395](https://github.com/apache/hadoop/blob/4d7825309348956336b8f06a08322b78422849b1/hadoop-mapreduce-project/hadoop-mapreduce-client/hadoop-mapreduce-client-core/src/main/java/org/apache/hadoop/mapreduce/task/reduce/Fetcher.java#L394-L395)).
- Hadoop's intermediate-data encryption is AES in CTR mode, which hides data but does not detect changes ([CipherSuite.java L31](https://github.com/apache/hadoop/blob/4d7825309348956336b8f06a08322b78422849b1/hadoop-common-project/hadoop-common/src/main/java/org/apache/hadoop/crypto/CipherSuite.java#L31)).

## 5. Disk I/O: what the literature offers, and why we need less of it

### Existing methods

| System | What it does | TEE | Status for us |
|---|---|---|---|
| **Nimble** (OSDI 2023) | A small ledger service. TEE "endorsers" sign the ledger's latest state; a majority of signatures is a receipt. Gives freshness on every read, so storage cannot serve an old version | SEV-SNP and SGX ([p.11](https://www.usenix.org/system/files/osdi23-angel.pdf#page=11)) `[A]` | Not adopted. Attestation in the repo is a placeholder ([coordinator.proto L72](https://github.com/microsoft/Nimble/blob/59e55d1ca6d9a76c75fc4a7ded206f73b07f93b7/proto/coordinator.proto#L72)) `[A]`, there is no Java client, it needs three or more extra TEE VMs, and losing a majority of endorsers is permanent ([p.9](https://www.usenix.org/system/files/osdi23-angel.pdf#page=9)) `[A]` |
| **Nimble-HDFS** | HDFS modified to keep its file index fresh through Nimble: "equipping the Hadoop distributed file system (HDFS) with rollback protection" ([p.3](https://www.usenix.org/system/files/osdi23-angel.pdf#page=3)). It took three person-months and 1,689 lines of Java ([p.14](https://www.usenix.org/system/files/osdi23-angel.pdf#page=14)) `[A]` | same | Not adopted. It is a separate 2023 fork of Hadoop 3.3.3 ([README L12-L14](https://github.com/mitthu/hadoop-nimble/blob/6351ed3573725078802f4a6ba693be63590c6605/README.md?plain=1#L12-L14)) `[A]`, and it protects NameNode metadata, a layer our design does not need |
| **Rollbaccine** (2025) | A Linux disk layer that authenticates and replicates block writes, so rollbacks are detected and repaired. Evaluated under HDFS ([p.1](https://arxiv.org/pdf/2505.04014#page=1)) `[A]` | SEV-SNP | Optional. Would protect local disks (spill files). Does not cover object storage |
| **ShieldFS** (2026) | ZFS with an authenticated log and Merkle tree, roots kept in a replicated TEE registry. Detects rollback ([p.1](https://arxiv.org/pdf/2608.19924#page=1)) `[A]` | SEV-SNP | Single node only. Useful as a model for tamper testing (section 10) |
| **CCF** | A replicated ledger in TEEs with Merkle receipts | SEV-SNP only ([platforms index L12](https://github.com/microsoft/CCF/blob/8575ce8fcea5919b6c74b7a282b8ca641cf37aab/doc/operations/platforms/index.rst?plain=1#L12)) `[A]` | Not usable: no TDX support |
| **dm-integrity** (as used by Parma, Azure confidential containers) | Per-block authentication tags on a disk | SEV-SNP | The authors state the tags are vulnerable to replay ([p.12](https://arxiv.org/pdf/2302.03976v3#page=12)) `[A]` |
| **SGX-MR** (2020) | MapReduce in one enclave with all blocks on untrusted disk; each block carries a block ID, file ID and MAC ([p.6](https://arxiv.org/pdf/2009.03518#page=6)) `[A]` | SGX | The closest published analogue to verify-on-read. Does not cover dropped blocks or replay |
| **VC3** (S&P 2015) | Hadoop MapReduce with SGX. Keeps "Hadoop, the operating system and the hypervisor out of the TCB" ([p.1](https://www.microsoft.com/en-us/research/wp-content/uploads/2016/02/vc3-oakland2015.pdf#page=1)). Each record is bound to (mapper, reducer, counter), tasks emit closing counts ([p.7](https://www.microsoft.com/en-us/research/wp-content/uploads/2016/02/vc3-oakland2015.pdf#page=7)), and a verifier checks every input split was processed once ([p.8](https://www.microsoft.com/en-us/research/wp-content/uploads/2016/02/vc3-oakland2015.pdf#page=8)) `[A]` | SGX (emulated) | The reference design for completeness. We copy its record binding and counts |

Related, for context:
- No one has published Hadoop MapReduce on TDX, SEV-SNP or Nitro with attested, integrity-checked outputs. A sweep of VC3's 606 citing works, keyword searches, GitHub and about 20 vendors found none `[A]`. The nearest are Spark systems that protect secrecy, not integrity: Scylla (SoCC 2025, [formal guarantees only against an honest-but-curious adversary](https://swystems.usi.ch/files/Scylla.pdf#page=5)) and LAPUTA (NDSS 2025, [no remote attestation in the prototype](https://www.ndss-symposium.org/wp-content/uploads/2025-2496-paper.pdf#page=8)) `[A]`.
- Azure Confidential Clean Rooms is the closest commercial analogue: attested Spark workers plus a [tamper-resistant audit trail](https://learn.microsoft.com/en-us/azure/confidential-computing/confidential-clean-rooms#:~:text=It%20also%20helps%20generate%20tamper%2Dresistant%20audit%20trails%20containing%20salient%20clean%2Droom%20events.) `[A]`. SEV-SNP and Spark only.
- Town Crier (CCS 2016) is the pattern for per-item signing: attest once to bind a key, then sign every fetched item ([p.8](https://eprint.iacr.org/2016/168.pdf#page=8)) `[A]`.

### Why most of that literature is about rollback

Tampering and forgery are considered solved: sign or MAC every block, and any change or insertion fails verification. Rollback is the attack that is left over, because old data carries a valid signature and passes every check. Stopping it needs trusted state that survives restarts, which TEE VMs do not provide. That is a research problem, so that is where the papers are `[I]`.

### Why rollback matters less for us

A rollback attacker can only replay things genuine code really produced. It cannot make the crawler sign content it never fetched.

- **The worst rollback can do is remove or replace recent data with older genuine data.** In effect that is deletion, or serving a stale but authentic capture. Deletion does not poison the corpus.
- **Our outputs are written once and never modified.** There is no "latest version" question for a WARC file. The only mutable state is the CrawlDb, and each job can be told which version to read by digest.
- **So we do not need a per-read freshness service like Nimble.** We need two cheap things: every signed record names its job and inputs (so an old record cannot pass as part of a new job), and the log's head is co-signed by a witness outside the provider (so history cannot be rewritten or forked).

One nuance to keep honest in the paper `[I]`: a provider who can re-run a job several times can choose which genuine run to publish. That is selection among authentic results, not forgery. The fix is cheap (a "start" record logged before work begins, section 8), and it should be listed as a property we address rather than left implicit.

**Our threat priority for storage:** tampering and forgery must be prevented outright. Deletion must be detected. Rollback is handled by context binding and witnessed checkpoints, not by a storage-layer mechanism.

## 6. The disk I/O solution: sign on write, verify on read

Treat storage as an untrusted pipe. Every byte that leaves a TEE VM is hashed and bound to a signed record before it leaves. Every byte that enters is checked against a signed record before it is used.

```
 task in TDX VM                                    task in another TDX VM
 +--------------------------+                      +--------------------------+
 | write file               |                      | look up expected digest  |
 |  hash chunks -> root     |                      |  in a verified record    |
 | task ends:               |    untrusted         | read file                |
 |  sign record {job, task, |--> storage --------->|  hash chunks, compare    |
 |   attempt, input roots,  |    (bytes +          |  mismatch -> task fails  |
 |   output roots, counts}  |     records)         |                          |
 +------------+-------------+                      +--------------------------+
              | record hash
              v
   append-only Merkle log, head co-signed by an off-cloud witness
```

The pieces (all `[A]` from source reading at Hadoop `rel/release-3.4.1`, sha `4d78253`, unless marked): **[Corrections C8, C18]**

1. **A wrapping file system.** A class extending Hadoop's `FilterFileSystem`, registered under a custom scheme such as `attested://` (Hadoop resolves scheme to class from config, [FileSystem.java L3567](https://github.com/apache/hadoop/blob/4d7825309348956336b8f06a08322b78422849b1/hadoop-common-project/hadoop-common/src/main/java/org/apache/hadoop/fs/FileSystem.java#L3567)). On close it computes SHA-256 per chunk and a Merkle root. On open it verifies each chunk against a root taken from a verified record. Nutch always reaches storage through this layer, so pointing the crawl paths at `attested://` covers every job with no Nutch patches. Hadoop's own `ChecksumFileSystem` has the same shape and is a good template. **[Corrections C14, C15, C16, C20]**
2. **A commit hook.** A custom output committer, installed by config through the per-scheme committer factory ([PathOutputCommitterFactory.java L72-L79](https://github.com/apache/hadoop/blob/4d7825309348956336b8f06a08322b78422849b1/hadoop-mapreduce-project/hadoop-mapreduce-client/hadoop-mapreduce-client-core/src/main/java/org/apache/hadoop/mapreduce/lib/output/PathOutputCommitterFactory.java#L72-L79)). When a task commits, it signs one record: job ID, task ID, attempt, the roots of the inputs it read, the roots of the outputs it wrote, record counts, and the digests of the job jar and config it ran. When the job commits, the job coordinator signs a manifest listing exactly which task attempts count. **[Correction C19]**
3. **All metadata from records, never from storage.** File existence, length and directory listings must come from verified records. If the wrapper asks storage "how long is this file?" the operator can truncate silently `[I]`. **[Correction C21; step 4.5 was done on 8 October 2026]**
4. **A ledger.** Record hashes go into an append-only Merkle log stored as plain files (the C2SP tlog-tiles layout). Its head is a signed checkpoint that an off-cloud witness co-signs only if it extends what the witness saw before ([tlog-witness L49-L51](https://github.com/C2SP/C2SP/blob/625d8db08a0f196540e40f0a2256332275492f78/tlog-witness.md?plain=1#L49-L51)). Because records are signed by attested keys, the log cannot forge. It can only drop records, which fails verification, or fork, which the witness stops. **[Correction C20]**
5. **A verifier.** A small tool with no Hadoop dependency. It checks the co-signed checkpoint, each record's inclusion and signature, each signing key's quote and measurements, the chain of inputs back to the seed list, the counts, and the hash of every file. A second implementation in another language should agree with it on every test.

Completeness follows VC3: task records carry counts, the job manifest fixes the task set, and the verifier checks that every job's inputs equal the previous job's outputs. Speculative execution is turned off, and only attempts named in the job manifest count. Nutch itself notes that a failed reduce can leave a duplicate WARC under a new name ([FetcherOutputFormat.java L117-L123](https://github.com/commoncrawl/nutch/blob/3270a761ee1052bed99f1b60b21d89fd5c2b1d33/src/java/org/apache/nutch/fetcher/FetcherOutputFormat.java#L117-L123)) `[A]`, which is why consumers must never trust a directory listing.

Known weak spot: completeness inside one job (between map and reduce) rests on Hadoop's own counters read inside the TEE, not on a cryptographic count over the shuffle `[I]`. State this in the paper.

## 7. Cross-node communication: an attested WireGuard mesh

The wrapper never sees traffic between nodes. That traffic carries job submission, scheduling, task status and the shuffle, and section 4 shows Hadoop does not protect it by default.

**Design.** Put all inter-node traffic on a WireGuard mesh that only attested VMs can join `[I]`:
- Each VM creates a WireGuard key at boot and binds it into its TDX quote together with its signing key.
- A VM adds a peer only after verifying that peer's quote and that its measurements match the expected image.
- Every Hadoop daemon binds only to the mesh interface. Nothing listens on the public or VPC interface. **[Corrections C10, C12]**

This closes job submission, protects the shuffle, and encrypts everything, with Hadoop unmodified.

**Why not Kerberos.** `hadoop.rpc.protection` only acts on SASL connections ([core-default.xml L712-L721](https://github.com/apache/hadoop/blob/4d7825309348956336b8f06a08322b78422849b1/hadoop-common-project/hadoop-common/src/main/resources/core-default.xml#L712-L721)) `[A]`, which in practice means running a Kerberos key server inside a TEE and releasing credentials only to attested nodes. That is more machinery for the same result. TLS on the shuffle alone is not enough, because it leaves job submission open.

**The mesh is necessary but not sufficient.** Three more conditions close the control plane:
1. **Nothing else in the image.** No SSH, no shell, no other service. Any process inside an attested VM can reach the ResourceManager and the signing key.
2. **A fixed driver.** The crawl loop is baked into the image and accepts a small typed set of parameters. Operator strings must never reach Hadoop's option parser, which accepts `-D` and `-conf` and could load operator config or code `[A]`.
3. **Job code and config verified at load.** Workers load the job jar and job config from a staging directory on storage. Put that directory on `attested://`, and record jar and config digests in every task record. Whether Hadoop's loader goes through the wrapper was inferred, not tested; **tested on 9 October 2026: the NodeManager's own process opened every job's `job.jar`, `job.xml`, `job.split` and `job.splitmetainfo` through the wrapper (run 9: 27 jobs, 108 verified opens) and refused a swapped file it fetched (step 4.6)**. **[Corrections C6, C13, C17 and decision D6: the wrapper goes onto Hadoop's own classpath with both lookups final, so the NodeManager uses it; step 4.6]**

## 8. Other requirements the design depends on

| Requirement | Why | Status |
|---|---|---|
| **Measured image on every VM** | A quote must identify the JDK, Hadoop, the Nutch job jar and the config. On GCP, MRTD covers Google's firmware and RTMR0 to RTMR2 cover the boot chain; RTMR3 is for our own measurements. The image needs a read-only verified root disk, no login, and the crawler stack extended into RTMR3 before any job runs | Extending RTMR3 needs kernel 6.16 or later; Rishab's VMs run 6.8. A 6.17 GCP kernel reportedly exists `[R]`. Test first **[Corrections C2, C4]** |
| **Firmware reference value** | The verifier needs to know the MRTD is Google's real firmware. Google publishes signed launch endorsements; no cloud lets you bring your own firmware (SNPGuard, [p.5](https://arxiv.org/pdf/2406.01186#page=5)) `[V]` | Rishab has not yet checked MRTD against the endorsement |
| **Substrate choice** | Plain TDX VMs with our own image (recommended: full network control, raw quotes verified off-cloud as Rishab already does) versus Google Confidential Space (less image work, but Google's attestation service joins the trusted base, and multi-node Hadoop inside it is unproven) | **PENDING** Pingshan's confirmation **[Correction C5: accepted, ADR-001]** |
| **TLS certificate checking ON** | Stock CCBot config sets `http.tls.certificates.check` to false ([nutch-default.xml L291-L292](https://github.com/commoncrawl/nutch/blob/3270a761ee1052bed99f1b60b21d89fd5c2b1d33/conf/nutch-default.xml#L291-L292)) `[V]`. The operator controls the network, so with checking off they can impersonate any site and the measured crawler signs the fake page. This is a deliberate departure from CCBot's default; measure how many fetches it costs | **PENDING** Pingshan's confirmation **[Correction C5: checking stays off for now, ADR-002 (provisional)]** |
| **Use CCBot's real HTTP client** | Set `plugin.includes` to use `protocol-okhttp` and turn on IP and header storage, as Common Crawl's example config does | To do **[Correction S4: done]** |
| **Record TLS evidence per fetch** | Certificate chain, TLS version, cipher, server IP. Java exposes the chain and stapled OCSP responses; it does not expose SCTs sent in the TLS extension `[V]`. This needs a small addition in the okhttp plugin, which is a Nutch patch | Decide whether it is in scope for the first paper **[Decision D7: in scope, teammate S's patch; coordinate on building the job with it]** |
| **"Start" record before work** | Each job logs a start record and waits to see it under a co-signed checkpoint before reading input. This gives freshness (a replayed old log head cannot contain the new start record) and stops publishing the favourite of several re-runs `[A]` | To do |
| **Time** | The VM clock comes from the host. Treat WARC dates as untrusted metadata and bound real time with the witness's co-signature timestamps `[A]` | To do |
| **Quotes from Java** | `intel/trustauthority-client-for-java` wraps configfs-tsm in pure Java ([README L4](https://github.com/intel/trustauthority-client-for-java/blob/7636e85c2d7ba589fc6441e2ec9d8278c15f5dab/configfs-tsm/README.md?plain=1#L4)) `[A]`. The kernel accepts up to 64 bytes of caller data ([configfs-tsm ABI L6](https://github.com/torvalds/linux/blob/fd179f8a05be3ccae366b9b96e176b51fbe54aab/Documentation/ABI/testing/configfs-tsm-report#L6)) `[A]` | Rishab's `quote.sh` already does this in shell |
| **Key isolation** | A small parent process holds the signing key; the Hadoop task JVMs that parse hostile web content should not `[A]` | To do |
| **Reproducible image build** | An image digest on an allowlist means little unless someone other than the provider can rebuild it from source | To do; if not achieved, say so **[Correction C3]** |

## 9. Work plan, in dependency order

Each step has a pass condition. Do not start a step until the ones it depends on pass. No dates are attached on purpose.

**Gate A: can the three risky pieces work at all? Run on the existing 2-node TDX cluster.**
1. **Mesh.** WireGuard between the two VMs, Hadoop daemons bound to it. Pass: a stock crawl completes over the mesh, and a job submitted from a third machine outside the mesh is refused. **[Status 7 October 2026: done in Milestone 2; a stock crawl completed over the mesh (run 5); the third-machine test used a stand-in (C11)]**
2. **Wrapper, no crypto.** A pass-through `FilterFileSystem` under `attested://` in front of the real storage. Pass: a stock multi-cycle crawl completes and its outputs match a run without the wrapper. This surfaces rename, commit and caching problems early. **[Status 7 October 2026: done in Milestone 3 as a replacement of the implementation behind hdfs:// (C14); the crawl's outputs match run 5 (run 6); Gate A accepted by the mentor]**
3. **Measurement.** Boot a kernel that supports RTMR extension and extend RTMR3 with the hash of the job jar. Pass: the value appears in a quote verified off-cloud, and replaying the event log reproduces it. **[Status 7 October 2026: done in Milestone 1; runs 6 and later are not covered by the measurement (S2)]**

If any gate fails, stop and write up why before going further.

**Stage B: integrity of storage.**
4. Chunk hashing on write, verification on read, metadata from records. **[Status 8 October 2026: done, with unsigned records: hashing at close and verified reads with records next to the files (steps 4.2 and 4.3, runs 7 and 8), the contract tests (step 4.4), and metadata from records with the NameNode's audit log (step 4.5)]**
5. Task records and job manifests from the committer; speculative execution off. **[Status 7 October 2026: open (step 4.7); records are made by the wrapper (C19)]**
6. Staging directory on `attested://`; jar and config digests in records. **[Status 9 October 2026: done as changed by decision D6 (step 4.6): the wrapper is on Hadoop's own classpath with both lookups final; the NodeManager's reads of the job files are verified against records and a swapped file it fetches is refused; digests in task records belong to step 4.7]**

**Stage C: identity and the ledger.**
7. Per-VM signing key bound to the quote; mesh admission by quote verification. **[Status 7 October 2026: not started (steps 5.1 and 5.2)]**
8. Locked-down measured image; fixed driver with typed parameters; TLS checking on; okhttp client. **[Status 7 October 2026: not started (step 5.3); the okhttp client is in use since run 3 (S3, S4); TLS checking stays off for now (C5)]**
9. Merkle log, signed checkpoints, an off-cloud witness, start records. **[Status 7 October 2026: not started (steps 5.4 and 5.5)]**

**Stage D: verification and evidence.**
10. Verifier, plus a second implementation. **[Status 7 October 2026: not started (step 6.1)]**
11. Tamper harness (section 10). **[Status 7 October 2026: not started (step 6.2); one tamper test exists (step 4.3: a changed byte is refused)]**
12. Performance: the same crawl with and without the custody layer, and TDX against non-TDX VMs of the same shape. Expect a network cost: one study measured TDX TCP throughput down by up to 60% at full CPU ([Misono et al., p.18](https://dse.in.tum.de/wp-content/uploads/2024/11/sigmetrics25summer-CVM-Explained.pdf#page=18)) `[A]`. **[Decision D8: wall time and bytes fetched are recorded for every wrapped and unwrapped pair, with the control in the same hour; results in step 6.3; first timings only: 10 min 42 s, 10 min 43 s and 10 min 57 s for runs 6 to 8, without a control in the same hour]**
13. Scale up: more workers and more cycles, as far as budget allows. Report the scale honestly. **[Status 7 October 2026: not started (step 6.4)]**

## 10. How we show it works

A survey of 20 papers `[A]` found that almost all argue soundness with a threat model and a written argument per property. A few prove a protocol (VC3, Town Crier). Machine-checked proofs exist only for small cores such as a ledger. Scripted tamper tests are the practical substitute for red teaming: ShieldFS ran 63 scenarios and found a flaw in its own prototype.

Our evidence, in order of effort:
1. **Attack-to-check table.** One row per attack, the exact check that catches it, where the check runs, and the test that exercises it. Include an explicit "not addressed" list.
2. **Tamper harness.** A script with the operator's powers. Flip a byte in a WARC, a CrawlDb file, a record, a log tile, a checkpoint. Truncate and delete files. Add an unsigned file. Swap outputs between tasks and cycles. Replay last cycle's CrawlDb. Present a wrong image, a wrong key, a forked log. Submit a rogue job from outside the mesh. Swap the job jar in staging. Tamper with the shuffle. Report detected out of total per class, run a clean control that must pass, and publish every miss. Run the baseline from section 2 as a row to show what it misses.
3. **Two verifiers that must agree** on every scenario.
4. **Informal theorems**, one per property: authenticity (every accepted record was signed inside a measured VM), completeness (the accepted set equals what the jobs produced), freshness, and no forking.

## 11. Open questions to resolve early

- Does a governance workshop run at AAAI-27, and what are its deadline and format? (Check after 16 October 2026.) **[Decision D5]**
- Does the GCP 6.17 kernel expose RTMR extension and the boot event log? **[Correction C9: yes]**
- Does Hadoop's job loader read the staging directory through a wrapped file system? **[Corrections C13, C17 and decision D6]**
- How does a `FilterFileSystem` behave over the object-store connector, where rename is copy plus delete?
- Who hosts the witness? A witness the provider controls adds nothing.
- Is per-fetch TLS evidence (a Nutch patch) in scope for the first paper? **[Decision D7]**
- Why do RTMR0 to RTMR2 differ between Rishab's two nodes? Replay the event logs to find out. **[Correction C9: answered]**

## 12. Further reading

- The trust gap in vendor firmware: "A Confidential Computing Transparency Framework for a Comprehensive Trust Chain" ([arXiv 2409.03720](https://arxiv.org/abs/2409.03720)) `[V]`.
- Attested evaluation as a comparable workshop-scale result: "Attestable Audits" ([arXiv 2506.23706](https://arxiv.org/abs/2506.23706)) `[V]`.
- A published recipe for a small measured TDX image: Dstack ([arXiv 2509.11555, p.10](https://arxiv.org/pdf/2509.11555#page=10)) `[A]`.
- Attested ML pipelines on TDX with a Merkle log: Atlas ([arXiv 2502.19567](https://arxiv.org/pdf/2502.19567v2#page=5)) `[A]`. It attests transformations, not network fetches, so it is the nearest competitor for the cleaning stage and not for the crawl.
