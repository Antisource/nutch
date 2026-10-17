# Milestone plan: Milestones 0 to 6

Date: 7 October 2026. This is the plan made on 6 October 2026: a pre-flight (Milestone 0) and six milestones. It has not changed. This page records, in one place, what each milestone proves in plain words, its steps and their status, what depends on what, where teammate S's work meets ours, and where the mentor's decisions of 7 October land: as baby steps inside existing steps, not as new milestones or new steps. The reports of the milestones are linked; the decisions are in [decisions.md](decisions.md).

## 1. How to read it

- A milestone is called **Milestone N** and its steps **Step N.k**, with the names already committed. A baby step inside a step is written N.k.j (for example 4.6.1).
- The steps of Milestones 0 to 4 are those of their reports ([milestone-4-storage-integrity.md](milestone-4-storage-integrity.md) section 4 for Milestone 4). The steps of Milestones 5 and 6 are the items of the first plan.
- "Gate A" and "Stage B, C, D" are the handoff's names for groups of its 13 work-plan items ([handoff-attested-hadoop-cluster.md](handoff-attested-hadoop-cluster.md) section 9).
- Status is as of 9 October 2026. Runs 6 and later (run 9 included) are **not covered by the measurement** (ADR-020, ADR-029).

## 2. The plan in one table

| Milestone | Name | What it proves, in plain words | Handoff items | Status | Report |
|---|---|---|---|---|---|
| 0 | Pre-flight: the clean baseline (run 3) | The starting point is solid: the crawl uses CCBot's real HTTP client and records real server addresses | (pre-flight) | Done, 5 October | [milestone-0](milestone-0-clean-baseline.md) |
| 1 | Measure the code that runs | We can show which program ran: fingerprints of the code are written into the hardware quote | Gate A, item 3 | Done, 5 to 6 October | [milestone-1](milestone-1-code-measurement.md) |
| 2 | Mesh for node-to-node traffic | The machines talk to each other only over an encrypted private network | Gate A, item 1 | Done, 6 October, with limits | [milestone-2](milestone-2-wireguard-mesh.md) |
| 3 | Pass-through wrapper (no crypto yet) | Every storage request goes through our layer, which changes nothing yet | Gate A, item 2 | Done, 6 October | [milestone-3](milestone-3-hdfs-wrapper.md) |
| 4 | Storage integrity (the first plan called it "sign on write, verify on read") | Storage cannot be changed unnoticed: files are fingerprinted when written and checked when read; the signing comes with step 5.1 | Stage B, items 4 to 6 | **Done on 14 October 2026:** steps 4.1 to 4.6 done (baby steps 4.6.4 to 4.6.7 on 13 October), 4.7 dropped on 10 October, 4.8 done (baby steps 4.8.1 to 4.8.3) | [milestone-4](milestone-4-storage-integrity.md) |
| 5 | Identity, ledger, lockdown | Each machine has a key that only an attested machine can use, the machine cannot be fiddled with, and (deferred on 10 October) an outside witness checks an append-only log | Stage C, items 7 to 9 | **In progress: steps 5.1.1 and 5.1.2 done on 15 October 2026 and 5.1.3 on 16 October 2026**; 5.2 and 5.3 open | [milestone-5](milestone-5-signed-records.md) |
| 6 | Verifier and evidence | Anyone can check a crawl, our attacks on our own system are caught, and the cost is known | Stage D, items 10 to 13 | Not started | none yet |

Milestone 2 is done with limits: the third-machine test used a stand-in, the firewall rules are not saved across a reboot, and the attested admission of peers is step 5.2.

## 3. The steps of Milestones 4, 5 and 6

Milestone 4 (the committed names; the report has the dependencies and results):

| Step | Name | Status |
|---|---|---|
| 4.1 | Recon of what the crawl writes and reads | Done |
| 4.2 | Hash every written file and record its Merkle root (observe only) | Done |
| 4.3 | Keep a record next to each file and verify every read against it | Done |
| 4.4 | Run Hadoop's file-system contract tests against the wrapper | Done |
| 4.5 | Answer length, existence and listings from records, never from storage | Done. Baby steps: 4.5.1 metadata from records (done); 4.5.2 the NameNode's audit log turned on and compared with the wrapper's log (done) |
| 4.6 | Check the job file and configuration digests at the start of each task | Done (9 October; baby steps 4.6.4 to 4.6.7 on 13 October). Changed by the mentor on 7 October (ADR-027). Baby steps: 4.6.1 the wrapper's classes on Hadoop's classpath (done); 4.6.2 both lookups set as final, with a switch back to the plain configuration (done); 4.6.3 the NodeManager's read of the job file checked against its record, and a swapped file refused (done); 4.6.4 `append`, `concat` and `truncate` refused (done); 4.6.5 a file with no record cannot be opened (done); 4.6.6 the wrapper's settings count only when the site configuration set them (done); 4.6.7 the doors to the plain file system closed (done) |
| 4.7 | Task records and job manifests; speculative execution off | **Dropped** (10 October, ADR-034): no task records, job manifests or per-file history; what they were for, tying outputs to attested code, is done by the signed per-file records of step 5.1. The recon ([milestone-4](milestone-4-storage-integrity.md) section 21) stays as history |
| 4.8 | Milestone report; re-measure after a reboot (ADR-020) | **Done on 14 October 2026.** Baby steps: 4.8.1 the job built with the teammate's patch, the collection policy and the first integration crawl (run 11); 4.8.2 the reboot and the re-measure, with the patched job and the policy as measured parts (ADR-040); 4.8.3 the first timing pair, runs 12 and 13 (ADR-041). Scripts in `93745032c`, `169c3887b`, `77fd89180` and `09ebe8565`; report: [milestone-4](milestone-4-storage-integrity.md) section 23 |

Milestone 5 and Milestone 6 (the items of the first plan; their reports will list the details):

| Step | Name | Status |
|---|---|---|
| 5.1 | Per-VM signing key bound to the quote (a test key behind a key-provider interface first) | **Done on 16 October 2026.** Baby steps: 5.1.1 records are signed with a test key, clearly labelled and never used in evidence (**done on 15 October 2026**: [milestone-5](milestone-5-signed-records.md) section 3, ADR-044); 5.1.2 folder identity files bind each file to its folder (ADR-035) (**done on 15 October 2026**: [milestone-5](milestone-5-signed-records.md) section 4, ADR-046); 5.1.3 the real key: generated per VM at boot, held by a small signing service, bound to the quote through REPORTDATA (**done on 16 October 2026**: [milestone-5](milestone-5-signed-records.md) section 6, ADR-047 to ADR-049) |
| 5.2 | Mesh admission only after verifying a peer's quote | **In progress.** Baby step 5.2.1, readers accept only keys of attested machines: **done on 16 October 2026**, offline and live ([milestone-5](milestone-5-signed-records.md) section 7, ADR-050 to ADR-052, and section 8 for the live window); baby step 5.2.2, mesh admission through the doorman: **done on 17 October 2026 on the test mesh `wg1`** ([milestone-5](milestone-5-signed-records.md) section 9, ADR-053 to ADR-055); open: the doorman as the source of the key list's bundles, and its adoption for the production mesh `wg0` (the mentor's decision) |
| 5.3 | Locked image (no SSH or shell), fixed driver with typed parameters, TLS checking on. Baby steps: 5.3.1 the locked image; 5.3.2 the fixed driver; 5.3.3 TLS checking on, with per-fetch TLS evidence (teammate S's patch) | Not started |
| 5.4 | Merkle log with signed checkpoints and an off-cloud witness (a witness interface and a local stand-in first) | Deferred (10 October, ADR-034) |
| 5.5 | "Start" records logged before work begins | Dropped (10 October, ADR-034) |
| 6.1 | The standalone verifier of the final files (signature, key, quote, measurements, hash), able to check a single record from its byte range (ADR-037), then a second independent one that must agree (the second one is not changed by the decisions of 10 October) | Not started |
| 6.2 | The tamper harness with a clean control. Baby steps: 6.2.1 the tamper demonstrations (a byte flipped; a file and its record replaced; a signed file moved to another folder, or two files of the same name swapped; a whole folder copied elsewhere; an unsigned file added; a record signed with a key that is not attested); 6.2.2 the two documented limits shown honestly (a file deleted together with its record, and an older signed copy put back, both expected to go undetected); 6.2.3 a review of what is readable or changeable outside the TEE (which keys exist, where they live, what crosses the VM boundary unprotected) and a red-team harness, both named by the mentor | Not started |
| 6.3 | Performance with and without the custody layer, and TDX against non-TDX. Baby steps: 6.3.1 paired runs in the same hour, with wall time and bytes fetched for every wrapped and unwrapped pair, against a vanilla CCBot control; 6.3.2 the same measured piece by piece (the WireGuard mesh, the wrapped HDFS, the TLS capture, TDX), because the experiment is about where the cost comes from (ADR-037) | Not started |
| 6.4 | Scale up as far as budget allows, and report the scale honestly | Not started |

The handoff items map as follows: step 5.1 and 5.2 are item 7, step 5.3 is item 8, steps 5.4 and 5.5 are item 9, and steps 6.1 to 6.4 are items 10 to 13.

## 4. What the mentor decided on 7 October, and where it lands

The decisions are recorded in ADR-026 to ADR-029 of [decisions.md](decisions.md), with the mentor's words.

| The mentor said | Where it lands |
|---|---|
| Gate A is accepted | Milestones 1 to 3 stand |
| Run the unwrapped control in the same hour from Stage B on; record wall time and bytes fetched for every wrapped and unwrapped pair (performance matters most, per Amir) | A rule for every crawl from now on (ADR-028). The first pair is the crawl after the re-measurement (step 4.8); the results table is step 6.3 |
| Turn on the NameNode audit log in Stage B | Baby step 4.5.2 (done 8 October) |
| Defer the re-measurement, as long as nothing unmeasured is described as measured | Step 4.8 and ADR-029 |
| A task hashing its own job file is not a security check: move the wrapper onto Hadoop's classpath and set both lookups final | Step 4.6, baby steps 4.6.1 to 4.6.3 (ADR-027; done 9 October) |
| Per-fetch TLS evidence is teammate S's patch; coordinate on building the job with it | Baby step 5.3.3 |
| Apply the handoff corrections now, in one commit with a corrections list at the top | Done: the corrected handoff |
| Defaults for the rest: HDFS; a test key behind an interface; hash everything with a path filter; a witness interface with a local stand-in; contract tests first | Steps 5.1, 5.4 and 4.4 (done) |
| Nothing new until the 16 October list; plan for mid-November to 20 November, 5 pages plus 2 | Section 7 |

### What the mentor decided on 10 October, and where it lands

The decisions are recorded in ADR-034 to ADR-039 of [decisions.md](decisions.md); the mentor's note is [next-steps-storage-signing.md](next-steps-storage-signing.md). This table follows the note's own order and also lists what it leaves as it was.

| The mentor said | Where it lands |
|---|---|
| Storage integrity rests on one mechanism, sign on write and verify on read, with the VM's signing key | Step 5.1 (baby steps 5.1.1 to 5.1.3): the per-file signed records replace the first plan's signed task record (ADR-034) |
| No task records, job manifests, per-file history or folder tracking; step 4.7 is dropped; the wrapper stays a plain file-system layer | Step 4.7 dropped; its recon stays as history |
| In scope: tampering, forgery, and a validly signed file in another folder or under another name | Steps 5.1.1 and 5.1.2; the tamper demonstrations in 6.2.1 |
| Deletion and rollback are noted and out of scope; retries, re-runs and intermediate steps are not visible | Limitations rows 68 to 71; shown honestly in 6.2.2 |
| Folder identity files | Baby step 5.1.2 (ADR-035) |
| Close the fail-open cases (A1 to A4) | Baby steps 4.6.4 to 4.6.7 (done, 13 October) |
| The real key bound to the quote; readers accept only attested keys | Baby steps 5.1.3 and 5.2.1 |
| The Merkle log, the witness and the checkpoints are deferred; "start" records are dropped | Step 5.4 deferred; step 5.5 dropped |
| The verifier checks the final files (signature, key, quote, measurements, hash), not the chain back to the seed list | Step 6.1; the second independent verifier is not mentioned and stays |
| Evidence: tamper demonstrations, the two limits shown honestly, performance pairs, a review of what is exposed | Baby steps 6.2.1 to 6.2.3 and 6.3.1 |
| Unchanged: the WireGuard mesh, the measured image and RTMR3, plain TDX VMs with our own image, the fixed driver, locking down the image | Milestones 1 and 2; step 5.3 |
| teammate S's patch: build the job with it and re-measure | Steps 4.8 and 5.3.3 |
| Apply the handoff corrections with section 6 of the note, in one commit with a corrections list at the top | Done: the corrected handoff (C22 to C28 and D9) |
| Not mentioned, so as before: step 6.4 (scale), the same-hour pairs and TDX against non-TDX (6.3), the results of steps 4.1 to 4.6, and the decisions of 7 October (except the witness stand-in, which waits with step 5.4) | Unchanged |

## 5. What each milestone needs before it can start

| Milestone | Needs | Why |
|---|---|---|
| 5 | 1, 2, 4 | The key is bound to a quote (Milestone 1), machines are admitted through the mesh (Milestone 2), and the signed records are those of the wrapper of Milestone 4 (the log is deferred) |
| 6 | 4, 5 | The verifier checks the records, the log and the TLS evidence; the performance pairs need the wrapper (Milestone 3) and the final job |

## 6. Teammate S's work and ours

Teammate S writes the per-fetch TLS evidence: when the crawler fetches a page, her code records who the server really was (certificate chain, TLS version, cipher, server address). Ours is the layer that protects what is written and ties it to tasks and jobs. In the claim "this record was fetched over TLS from host X, by this exact build, inside a genuine VM, as part of job J, and nothing changed afterwards", hers is the "over TLS from host X" part and ours is the rest.

She can start now: the code she needs is on the branch `feat/tee-hadoop-cluster` and nothing on our side blocks her. Where the two workstreams depend on each other:

| Step | Depends on her work? | What exactly |
|---|---|---|
| 4.5, 4.6 | No | |
| 4.7 | Dropped | Step 4.7 is dropped (ADR-034). Her attempt-scoped outputs are covered by the per-file signed records like every other file (her message of 10 October, ADR-036) |
| 4.8 (re-measure) | Yes | The measured job must contain her code and files |
| 5.1 | Small agreement | The signing key stays out of the fetcher JVM; her evidence is bound by the signed commitment to the WARC and to her output files (ADR-036). Her output folders are also the real test of the folder identity files (5.1.2): a task attempt's output is moved from its attempt folder into the final folder when the task commits, and Hadoop merges into folders that already exist, so we need the layout of her output folders and a run of her integration test against the new wrapper |
| 5.2, 5.4, 5.5 | No | Her evidence is more records |
| 5.3 | Yes | TLS checking on and her evidence belong together; her extra files must be in the locked image and her settings must fit the fixed driver |
| 6.1 | Yes | The verifier checks her evidence for each record, so it needs her format, versioned |
| 6.2 | Yes | Attacks on the evidence: forged evidence, an impersonated site, evidence removed |
| 6.3, 6.4 | Yes | The final numbers include the cost of capturing the evidence |

The HTTP client is okhttp (`protocol-okhttp`), as the handoff requires; a change to plain `http` would need the mentor's agreement.

## 7. Timeline

- The workshop paper is planned for mid-November to 20 November, 5 pages plus 2 (the mentor, 7 October). Nothing new for the paper is started before the 16 October list.
- The plan has no dates of its own; the handoff attaches none on purpose. After 10 October the order is baby steps 4.6.4 to 4.6.7 (done on 13 October), then step 5.1 (the signed records, the folder identity, the real key) and step 5.2, with step 4.8 (the re-measure) done on 14 October, then Milestone 6 (section 8 maps the mentor's labels to the steps). Any dates are proposals until the mentor confirms them.
- The handoff's rule applies: security work is not cut to meet a date. What is not done in time is written down as a limitation, and the paper claims only what exists:

| When it is done | What can honestly be claimed |
|---|---|
| Milestone 4 | Files in storage cannot be changed unnoticed (the records are not yet signed) |
| Milestone 5 | The records are signed inside attested machines and logged under a witness |
| Milestone 6 | An outsider can check a crawl, each tested attack is caught or recorded as a miss, and the cost and the scale are reported |

## 8. The steps after 10 October (A1 to C4)

The mentor's decisions of 10 October (ADR-034 to ADR-039) drop step 4.7 and change what the signing covers. The labels A1 to C4 are the ones of [next-steps-storage-signing.md](next-steps-storage-signing.md), which has the full pass conditions; they are kept here only as a cross-reference. Each item is a baby step of a committed step, so that the plan has one structure: the signing is Milestone 5, as the plan always had it ("the signing comes with step 5.1"), and Milestone 4 keeps only the fail-open fixes (done) and step 4.8. The working order is A, then B1 to B3, then B4, then C.

| Step | What | Pass condition in one line | Lands in |
|---|---|---|---|
| A1 | `append`, `concat` and `truncate` throw an error | a full crawl completes, and a direct call fails | Step 4.6, baby step 4.6.4 (done) |
| A2 | A file with no record fails the read; the driver signs the seed file | reading an unrecorded file fails, the crawl still runs | Step 4.6, baby step 4.6.5 (done) |
| A3 | The wrapper's own switches cannot be changed by a job (final in the site configuration, or removed) | a job submitted with `-D attested.verify.reads=false` still has its reads verified | Step 4.6, baby step 4.6.6 (done) |
| A4 | Opening by path handle and the raw inner file system are refused | a direct call to each fails | Step 4.6, baby step 4.6.7 (done) |
| B1 | Records are signed (a test key, clearly labelled, never used in evidence) | a file rewritten with its record, without the key, fails the read | Step 5.1, baby step 5.1.1 (open) |
| B2 | Folder identity files, and records bound to (folder ID, file name) | a signed file or a whole folder copied elsewhere fails the read; a folder rename re-signs no file record; a normal crawl still passes | Step 5.1, baby step 5.1.2 (open) |
| B3 | The real key: per VM at boot, held by a small signing service, bound to the quote through REPORTDATA | a record's key resolves to a quote that verifies off-cloud, whose RTMR3 replay matches | Step 5.1, baby step 5.1.3 (**done on 16 October 2026** for the key and the binding of the quote's REPORTDATA; the quote's chain was verified on the laptop; the measurements and the RTMR3 replay for these quotes stay for step 5.2.1) |
| B4 | Readers accept only keys of attested VMs (the mesh admission step is the source of the list) | a record signed by a key from outside the cluster fails the read | Step 5.2, baby step 5.2.1 (**done on 16 October 2026**: a key is trusted only if its quote verifies and its measurements are allowed; a rogue key with a fake quote was refused live on the real VMs, and a record signed by it fails the read; the worker's own reads and a MapReduce job with the admission on are not yet exercised) |
| C1 | Tamper demonstrations: flip a byte; replace a file and its record; move a signed file or swap same-named files between folders; copy a folder elsewhere; add an unsigned file; sign with a non-attested key | all refused | Step 6.2, baby step 6.2.1 (open) |
| C2 | The two documented limits shown honestly: delete a file with its record; put back an older signed copy | both go undetected, and are recorded as such | Step 6.2, baby step 6.2.2 (open) |
| C3 | Wall time and bytes fetched for every wrapped and unwrapped pair in the same hour; then TDX against non-TDX VMs of the same shape | (the number readers look for) | Step 6.3, baby steps 6.3.1 and 6.3.2 (open) |
| C4 | Review of what is readable or changeable outside the TEE: which keys exist, where they live, what crosses the VM boundary unprotected | (the most common way such systems fail) | Step 6.2, baby step 6.2.3 (open) |

The note groups C1 to C4 as evidence, which is Milestone 6; the review in C4 also informs step 5.3 (the locked image). Step 5.3 (locked image, fixed driver, TLS checking on with the teammate's patch) is otherwise unchanged. Our own fail-open findings were in the limitations (row 72, closed on 13 October 2026).

**Status on 13 October 2026: A1 to A4 are done (baby steps 4.6.4 to 4.6.7 of step 4.6)** ([milestone-4](milestone-4-storage-integrity.md) section 22: run 10 and two demos with the new wrapper); the signing starts with step 5.1. **Status on 14 October 2026: step 4.8 is done and Milestone 4 is closed** ([milestone-4](milestone-4-storage-integrity.md) section 23).

**Status on 15 October 2026: step 5.1.1 is done** ([milestone-5](milestone-5-signed-records.md) section 3): records are signed with a labelled test key, and a file rewritten together with its record, without the key, fails the read on the real HDFS; the next step is 5.1.2 (folder identity files).

**Status later on 15 October 2026: step 5.1.2 is done** ([milestone-5](milestone-5-signed-records.md) section 4): every file is bound to its folder by signed identity files and `ATTEST03` records, and ten attacks that move, copy or relabel signed files fail the read on the real HDFS; the next steps are 5.1.3 (the real key) and the combined crawl with signing and folder binding on.

**Status at the end of 15 October 2026: the combined crawl is done** ([milestone-5](milestone-5-signed-records.md) section 5): a real crawl with signing and folder binding on and required wrote 60 files in 55 folders, all of which verify offline with the public key only, and all 265 verified reads in the audit logs had a signature and a folder binding; the next step is 5.1.3 (the real key).

**Status on 16 October 2026: step 5.1.3 is done** ([milestone-5](milestone-5-signed-records.md) section 6): each VM makes its own signing key in the memory of a signing service, a hardware quote vouches for exactly that key (verified on the VMs and, for the Intel signature chain, on the laptop), and a crawl with the real keys on two machines verifies offline against a key list, with a negative control; the next step is 5.2.1 (readers accept only keys of attested machines, through the hook of the key list).

**Status later on 16 October 2026: step 5.2.1 is done offline** ([milestone-5](milestone-5-signed-records.md) section 7): the key list admits a key only if its hardware quote verifies offline in Java (the chain to Intel's root, the signatures) and its MRTD and boot registers are allowed by an editable reference file; both real keys of run 15 are admitted, the whole run-15 output verifies with only admitted keys, and every decision flips with one edit; the live window on the real VMs is the next step.

**Status at the end of 16 October 2026: step 5.2.1 is done offline and live** ([milestone-5](milestone-5-signed-records.md) section 8): on the two real VMs, each fresh key was admitted by its live quote before the daemons restarted, a real file was written and read back with the admission on, a rogue key with a fake quote was refused with its reason, and each decision flipped with one edit on a live quote; the next step is the rest of step 5.2 (the admission step as the source of the accepted keys).

**Status on 17 October 2026: step 5.2.2 is done on the test mesh** ([milestone-5](milestone-5-signed-records.md) section 9): a node is admitted to the mesh only if a quote made just now binds its WireGuard public key and requested address to the machine, the quote is genuine, its measurements are in the reference file, and the host and address are in a policy table; on the two real nodes both were admitted, a rogue node with a fake quote was refused, and the test mesh `wg1` came up with exactly the admitted peers on their own attested keys while `wg0` and the measured stack stayed untouched; the next steps are the doorman as the source of the key list's bundles and its adoption for the production mesh, which is the mentor's decision.

## 9. Rules that apply to every milestone

- A commit contains only files identical to the ones that ran on the cluster; documents and programs are committed separately (ADR-024, ADR-025).
- Code that depends on real libraries is rehearsed with them before it is sent (ADR-025).
- Nothing that ran outside the measured set is called measured (ADR-029).
- Every wrapped crawl has an unwrapped control in the same hour, and wall time and bytes fetched are recorded (ADR-028).
- A check is only trusted after it has caught a known fault ([guide-pitfalls-and-lessons.md](guide-pitfalls-and-lessons.md), rule 20).
