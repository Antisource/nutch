# Session start: where we are and how to continue

Attach this page to the first message of a new session (with `handoff-attested-hadoop-cluster.md` and `next-steps-storage-signing.md`). **Update the "State" section at the end of every session.**

## What the project is

A verifiable chain of custody for web-crawl pretraining data: Common Crawl's own crawler (CCBot, a Nutch fork, branch `feat/tee-hadoop-cluster` of `Antisource/nutch`) runs on two Intel TDX VMs on GCP with Hadoop 3.4.3 and our storage layer, so that tampering with what the crawl stores is detected. The threat is insiders, not physical attacks on the machines (the mentor's note of October 2026).

## State (last updated 13 October 2026, after the fail-open step)

| Area | State |
|---|---|
| Milestones 0 to 3 | done (clean baseline, code measurement, WireGuard mesh, pass-through wrapper) |
| Milestone 4, steps 4.1 to 4.6 | done and committed; step 4.7 dropped by the mentor's decision of 10 October (ADR-034) |
| Next steps (`milestone-plan.md` section 8) | B1 to B4 (signing), then C1 to C4 (evidence); A1 to A4 are done |
| Baby steps 4.6.4 to 4.6.7 (the mentor's A1 to A4) | **done and committed** on 13 October: the wrapper refuses append, concat, truncate and the doors to the plain file system, fails reads of files without a record, and takes its settings from the site configuration only; run 10 and two demos prove it (report section 22) |
| The teammate | her patch is ready for integration (ADR-036); the mentor's answers of October 2026 are in ADR-037 (policy in the measured image, expired certificates noted not rejected, single-record verification, the TLS capture in question) |

Plan and decisions: `docs/milestone-plan.md`, `docs/decisions.md` (ADR-034 to ADR-039 are the latest), `docs/limitations-and-trust.md`.

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
