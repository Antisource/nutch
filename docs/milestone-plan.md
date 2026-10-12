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
| 4 | Storage integrity (the first plan called it "sign on write, verify on read") | Storage cannot be changed unnoticed: files are fingerprinted when written and checked when read; the signing comes with steps B1 to B3 (section 8) | Stage B, items 4 to 6 | In progress: steps 4.1 to 4.6 done, 4.7 dropped on 10 October, the steps A1 to B2 of section 8 and 4.8 open | [milestone-4](milestone-4-storage-integrity.md) |
| 5 | Identity, ledger, lockdown | Each machine has a key that only an attested machine can use, the machine cannot be fiddled with, and (deferred on 10 October) an outside witness checks an append-only log | Stage C, items 7 to 9 | Not started | none yet |
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
| 4.6 | Check the job file and configuration digests at the start of each task | Done (9 October). Changed by the mentor on 7 October (ADR-027). Baby steps: 4.6.1 the wrapper's classes on Hadoop's classpath (done); 4.6.2 both lookups set as final, with a switch back to the plain configuration (done); 4.6.3 the NodeManager's read of the job file checked against its record, and a swapped file refused (done) |
| 4.7 | Task records and job manifests; speculative execution off | **Dropped** (10 October, ADR-034): no task records, job manifests or per-file history. The recon ([milestone-4](milestone-4-storage-integrity.md) section 21) stays as history |
| 4.8 | Milestone report; re-measure after a reboot (ADR-020) | Open, after the steps A and B of section 8 |

Milestone 5 and Milestone 6 (the items of the first plan; their reports will list the details):

| Step | Name | Status |
|---|---|---|
| 5.1 | Per-VM signing key bound to the quote (a test key behind a key-provider interface first) | Not started. Now steps B1 (the test key) and B3 (the real key) of section 8 |
| 5.2 | Mesh admission only after verifying a peer's quote | Not started. Step B4 reuses it as the source of the accepted keys |
| 5.3 | Locked image (no SSH or shell), fixed driver with typed parameters, TLS checking on. Baby steps: 5.3.1 the locked image; 5.3.2 the fixed driver; 5.3.3 TLS checking on, with per-fetch TLS evidence (teammate S's patch) | Not started |
| 5.4 | Merkle log with signed checkpoints and an off-cloud witness (a witness interface and a local stand-in first) | Deferred (10 October, ADR-034) |
| 5.5 | "Start" records logged before work begins | Dropped (10 October, ADR-034) |
| 6.1 | The standalone verifier of the final files (signature, key, quote, measurements, hash), then a second independent one that must agree (the second one is not changed by the decisions of 10 October) | Not started |
| 6.2 | The tamper harness with a clean control | Not started |
| 6.3 | Performance with and without the custody layer, and TDX against non-TDX | Not started |
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

## 5. What each milestone needs before it can start

| Milestone | Needs | Why |
|---|---|---|
| 5 | 1, 2, 4 | The key is bound to a quote (Milestone 1), machines are admitted through the mesh (Milestone 2), and the log holds the records of Milestone 4 |
| 6 | 4, 5 | The verifier checks the records, the log and the TLS evidence; the performance pairs need the wrapper (Milestone 3) and the final job |

## 6. Teammate S's work and ours

Teammate S writes the per-fetch TLS evidence: when the crawler fetches a page, her code records who the server really was (certificate chain, TLS version, cipher, server address). Ours is the layer that protects what is written and ties it to tasks and jobs. In the claim "this record was fetched over TLS from host X, by this exact build, inside a genuine VM, as part of job J, and nothing changed afterwards", hers is the "over TLS from host X" part and ours is the rest.

She can start now: the code she needs is on the branch `feat/tee-hadoop-cluster` and nothing on our side blocks her. Where the two workstreams depend on each other:

| Step | Depends on her work? | What exactly |
|---|---|---|
| 4.5, 4.6 | No | |
| 4.7 | Dropped | Step 4.7 is dropped (ADR-034). Her attempt-scoped outputs are covered by the per-file signed records like every other file (her message of 10 October, ADR-036) |
| 4.8 (re-measure) | Yes | The measured job must contain her code and files |
| 5.1 | Small agreement | The signing key stays out of the fetcher JVM; her evidence is bound by the signed commitment to the WARC and to her output files (ADR-036) |
| 5.2, 5.4, 5.5 | No | Her evidence is more records |
| 5.3 | Yes | TLS checking on and her evidence belong together; her extra files must be in the locked image and her settings must fit the fixed driver |
| 6.1 | Yes | The verifier checks her evidence for each record, so it needs her format, versioned |
| 6.2 | Yes | Attacks on the evidence: forged evidence, an impersonated site, evidence removed |
| 6.3, 6.4 | Yes | The final numbers include the cost of capturing the evidence |

The HTTP client is okhttp (`protocol-okhttp`), as the handoff requires; a change to plain `http` would need the mentor's agreement.

## 7. Timeline

- The workshop paper is planned for mid-November to 20 November, 5 pages plus 2 (the mentor, 7 October). Nothing new for the paper is started before the 16 October list.
- The plan has no dates of its own; the handoff attaches none on purpose. After 10 October the order is A1 to A4, B1 and B2, then B3 and B4 with the other steps of Milestone 5, then C1 to C4 (section 8); step 4.7 is dropped. Any dates are proposals until the mentor confirms them.
- The handoff's rule applies: security work is not cut to meet a date. What is not done in time is written down as a limitation, and the paper claims only what exists:

| When it is done | What can honestly be claimed |
|---|---|
| Milestone 4 | Files in storage cannot be changed unnoticed (the records are not yet signed) |
| Milestone 5 | The records are signed inside attested machines and logged under a witness |
| Milestone 6 | An outsider can check a crawl, each tested attack is caught or recorded as a miss, and the cost and the scale are reported |

## 8. Rules that apply to every milestone

- A commit contains only files identical to the ones that ran on the cluster; documents and programs are committed separately (ADR-024, ADR-025).
- Code that depends on real libraries is rehearsed with them before it is sent (ADR-025).
- Nothing that ran outside the measured set is called measured (ADR-029).
- Every wrapped crawl has an unwrapped control in the same hour, and wall time and bytes fetched are recorded (ADR-028).
- A check is only trusted after it has caught a known fault ([guide-pitfalls-and-lessons.md](guide-pitfalls-and-lessons.md), rule 20).

## 8. The steps after 10 October (A1 to C4)

Pingshan's decisions of 10 October (ADR-034 to ADR-036) drop step 4.7 and replace the rest of the storage plan with the steps below. The labels are the ones of [next-steps-storage-signing.md](next-steps-storage-signing.md), which has the full pass conditions; teammate S's message uses them too. The working order is A, then B1 and B2, then B3 and B4, then C.

| Step | What | Pass condition in one line | Lands in |
|---|---|---|---|
| A1 | `append`, `concat` and `truncate` throw an error | a full crawl completes, and a direct call fails | Milestone 4 |
| A2 | A file with no record fails the read; the driver signs the seed file | reading an unrecorded file fails, the crawl still runs | Milestone 4 |
| A3 | The wrapper's own switches cannot be changed by a job (final in the site configuration, or removed) | a job submitted with `-D attested.verify.reads=false` still has its reads verified | Milestone 4 |
| A4 | Opening by path handle and the raw inner file system are refused | a direct call to each fails | Milestone 4 |
| B1 | Records are signed (a test key, clearly labelled, never used in evidence) | a file rewritten with its record, without the key, fails the read | Milestone 4 |
| B2 | Folder identity files, and records bound to (folder ID, file name) | a signed file or a whole folder copied elsewhere fails the read; a folder rename re-signs no file record; a normal crawl still passes | Milestone 4 |
| B3 | The real key: per VM at boot, held by a small signing service, bound to the quote through REPORTDATA | a record's key resolves to a quote that verifies off-cloud, whose RTMR3 replay matches | Milestone 5 (step 5.1) |
| B4 | Readers accept only keys of attested VMs (the mesh admission step is the source of the list) | a record signed by a key from outside the cluster fails the read | Milestone 5 (step 5.2) |
| C1 | Tamper demonstrations: flip a byte; replace a file and its record; move a signed file or swap same-named files between folders; copy a folder elsewhere; add an unsigned file; sign with a non-attested key | all refused | Milestone 6 (step 6.2) |
| C2 | The two documented limits shown honestly: delete a file with its record; put back an older signed copy | both go undetected, and are recorded as such | Milestone 6 (step 6.2) |
| C3 | Wall time and bytes fetched for every wrapped and unwrapped pair in the same hour; then TDX against non-TDX VMs of the same shape | (the number readers look for) | Milestone 6 (step 6.3) |
| C4 | Review of what is readable or changeable outside the TEE: which keys exist, where they live, what crosses the VM boundary unprotected | (the most common way such systems fail) | Milestone 6 |

Step 5.3 (locked image, fixed driver, TLS checking on with teammate S's patch) is unchanged. Our own fail-open findings are in the limitations (row 72).
