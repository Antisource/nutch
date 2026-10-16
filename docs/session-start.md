# Session start: where we are and how to continue

Attach this page to the first message of a new session (with `handoff-attested-hadoop-cluster.md` and `next-steps-storage-signing.md`). **Update the "State" section at the end of every session.**

## What the project is

A verifiable chain of custody for web-crawl pretraining data: Common Crawl's own crawler (CCBot, a Nutch fork, branch `feat/tee-hadoop-cluster` of `Antisource/nutch`) runs on two Intel TDX VMs on GCP with Hadoop 3.4.3 and our storage layer, so that tampering with what the crawl stores is detected. The threat is insiders, not physical attacks on the machines (the mentor's note of October 2026).

## State (last updated 16 October 2026, after step 5.2.1, offline)

| Area | State |
|---|---|
| Milestones 0 to 3 | done (clean baseline, code measurement, WireGuard mesh, pass-through wrapper) |
| Milestone 4 | **closed on 14 October**: steps 4.1 to 4.6 done and committed (baby steps 4.6.4 to 4.6.7 on 13 October); step 4.7 dropped by the mentor's decision of 10 October (ADR-034); step 4.8 done (the job with the teammate's patch, the re-measure after a reboot, the first timing pair: report section 23) |
| Milestone 5 | **steps 5.1.1 and 5.1.2 and the combined crawl done on 15 October, step 5.1.3 on 16 October, step 5.2.1 offline on 16 October** (5.2.1: a key is trusted only if its hardware quote verifies offline in Java and its measurements are allowed by an editable reference file; both real keys of run 15 are admitted and the whole run-15 output verifies with only admitted keys; [milestone-5-signed-records.md](milestone-5-signed-records.md) section 7, ADR-050 to ADR-052; 5.1.3: each VM makes its own signing key in the memory of a signing service, a hardware quote vouches for it, and run 15 verifies offline against a key list; 211 verified reads, all with real signatures; [milestone-5-signed-records.md](milestone-5-signed-records.md) section 6, ADR-047 to ADR-049); (run 14: signing and folder binding on and required; 60 files in 55 folders verify offline with the public key only; 265 verified reads, all signed and bound; [milestone-5-signed-records.md](milestone-5-signed-records.md) section 5): 5.1.2 binds every file to its folder (signed identity files `_attested-folder` and records `ATTEST03`; ten attacks that move, copy or relabel signed files fail the read on the real HDFS; ADR-046); 5.1.1: records are signed with a labelled test key (ECDSA P-256, format `ATTEST02`), everything off by default; a file rewritten together with its record, without the key, fails the read on the real HDFS ([milestone-5-signed-records.md](milestone-5-signed-records.md); ADR-044, ADR-045); the decisions of step 5.1 were taken with the recommended defaults, the mentor not having answered them |
| Next steps (`milestone-plan.md`) | the short live window of step 5.2.1 (admission on the real VMs, a file written and read, a rogue key refused live), then the rest of step 5.2, then Milestone 6; section 8 maps the mentor's list of 10 October (A1 to C4) to the steps |
| Baby steps 4.6.4 to 4.6.7 (the mentor's A1 to A4) | **done and committed** on 13 October: the wrapper refuses append, concat, truncate and the doors to the plain file system, fails reads of files without a record, and takes its settings from the site configuration only; run 10 and two demos prove it (report section 22) |
| The teammate | her patch is built into the job and ran in runs 11 to 13 (ADR-036, ADR-037); her code is **not** in our repository (the kits refer to her files by fingerprint; publishing them needs her consent, ADR-042); her own verifier has not been run on our exports (no result recorded); she works on the cluster through the shared measured client in `/opt/tc-shared`, her own HDFS folder and the reservation marker (ADR-043); her first `tc-check.sh` is to be confirmed |
| The measured stack | re-measured on 14 October (ADR-040): 9 events on the master, 6 on the worker; run 12 is the first run covered by the measurement; the nodes run the 6.17 kernel from a one-time boot, and a reboot returns them to 6.8 (a re-measure needs another one-time boot); four windows (ADR-045) changed it and restored it byte for byte: three of 15 October for 14, 18 and 32 minutes (the second, 15:38 to 15:56, was step 5.1.2; the third, 18:30 to 19:02, was the combined crawl) and one of 16 October for 57 minutes (11:17 to 12:14, step 5.1.3, with the real keys); a test key `TEST-37c2a6aa…` is still in `~/tc-test-key` on both nodes |

Plan and decisions: `docs/milestone-plan.md`, `docs/decisions.md` (ADR-034 to ADR-042 are the latest), `docs/limitations-and-trust.md`.

## Where everything is

| What | Where |
|---|---|
| Code and documents | GitHub, branch `feat/tee-hadoop-cluster` |
| Evidence bundles, the VM-state bundle, the job files | the laptop's `tdx-evidence` folder (`extracted\`, `jobs\`); keep a second copy elsewhere |
| The baseline job and the patches that rebuild the other jobs | `jobs\` and `extracted\evidence-job-patches`, with `MANIFEST.txt` |
| The rebuild kit | `ops/rebuild/`; the runbook is `docs/cluster-rebuild.md` |

## Starting after our files on the VMs were wiped

1. In Cloud Shell: `git clone https://github.com/Antisource/nutch.git -b feat/tee-hadoop-cluster nutch && cd nutch`.
2. `bash ops/rebuild/rebuild-cluster.sh ship base hadoop mesh build wrapper suite` (the VMs are still there; about 40 minutes), and look for `SUITE-OK`. This is the "we are back where we left off" check. If the VMs themselves were deleted, run the script with no stage names.
3. Work. At the end: `bash ops/rebuild/end-of-session.sh`, download the bundle, commit what was tested, update this page.

## How we work (the rules that proved their worth)

- **Evidence first.** A claim in a document is checked against the evidence by a facts list (`docs_facts_check.py`); a document is committed only after that check passes.
- **Code and documents in separate, gated commits.** Each gate checks the head, the base files and the exact content before it commits and pushes, and a GitHub check follows.
- **Small steps with a pass condition**, rehearsed first with stand-ins, then run on the cluster; each real run is saved as a bundle and checked on the laptop.
- **A control for every test**: a test is believed only when it fails on the old behavior.
- **Plain language** for explanations (the user is learning the subject), and no secret ever goes into a bundle.
- **Never cut a search that a claim rests on**, and a guard must test the thing it guards (`guide-pitfalls-and-lessons.md` has the full list).
