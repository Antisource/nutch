# CCBot on Hadoop inside Intel TDX Confidential VMs: documentation

This folder documents a two-run experiment: run Common Crawl's Nutch fork ("CCBot") on a
two-node Hadoop cluster whose nodes are Intel TDX Confidential VMs on Google Cloud, crawl at most
10 URLs, collect the WARC output, and bind a manifest of each run to hardware attestation quotes.

Everything here was written from terminal output captured during the work (times are UTC,
2 and 3 October 2026). Where something was not observed, the text says so.

## Documents

| File | What it answers |
|---|---|
| [cluster-configuration.md](cluster-configuration.md) | How the VMs, network, Hadoop and the crawl were configured, and why two VMs |
| [run-1-pilot.md](run-1-pilot.md) | Run 1: hand-typed commands, full timeline, results and evidence |
| [run-2-scripted.md](run-2-scripted.md) | Run 2: the same crawl driven by the committed scripts |
| [comparison-run1-run2.md](comparison-run1-run2.md) | What was identical, what differed, and what that does and does not show |
| [guide-pitfalls-and-lessons.md](guide-pitfalls-and-lessons.md) | Mistakes made, corrections, decisions taken, and a checklist for repeating the work |

## Repository map: what was added and why

Commit ids are abbreviated. `git log --stat --oneline` shows the full history.

| Path | Commit | Why it exists |
|---|---|---|
| `conf/nutch-site.xml` | `5635894b7` `feat(config)` | Nutch overrides: bot identity (`http.agent.name`), WARC output switched on, and the labels written into each WARC's `warcinfo` record. The repository's `.gitignore` ignores `conf/*.xml`, so it was added with `git add -f` |
| `attest/quote.sh` | `3560802e3` `feat(attest)` | Requests a TDX quote whose REPORTDATA field holds the SHA-512 of a file |
| `attest/verify-binding.sh` | `52a96263f` `feat(attest)` | Checks that a quote's REPORTDATA equals the SHA-512 of a file (prints MATCH or MISMATCH). It does **not** verify the quote's signature |
| `attest/make-manifest.sh` | `f30e694cc` `feat(attest)` | Writes a text inventory of one node: versions, config hashes, inputs, outputs |
| `ops/run-crawl.sh` | `4fec69478` `feat(ops)` | The capped cluster crawl command, kept as a script so run 2 used exactly the documented options |
| `seeds/seed.txt` | `4fec69478`, later corrected by a `fix(seeds)` commit | The two practice seed URLs. Lives outside `conf/` so it is not ignored |
| `attest/README.md` | `a7e758726` (empty by mistake), then `105efc288` | Explains the attestation workflow and its limits |
| `docs/run-1-pilot.md` | `2aadecd86` `docs(run-1)`, expanded later | Run 1 record |
| `docs/*` (this set) | later `docs` commits | Reports, comparison and lessons |

The commit that both run-2 manifests record as `scripts_repo_commit` begins `441cb333c21b`. It is
presumably the `fix(seeds)` commit, but confirm with `git log`.

The base of the branch is `3270a761e` ("Fetcher: do not set number of reduce tasks
programmatically"), the tip of the fork's `cc` branch when the work started. All work is on the
branch `feat/tee-hadoop-cluster` of the fork `Antisource/nutch`.

## Evidence (kept outside this repository)

| Location in Cloud Shell | Contents |
|---|---|
| `~/evidence/` | Run 1: manifests, quotes, WARC output, crawl log, HDFS listing |
| `~/evidence-run2/` | Run 2: manifests, quotes, WARC output, crawl log |
| `~/evidence-all.tar.gz` | Bundle of both folders, with its SHA-256 saved in `evidence-all.sha256` |

Full hash values live in the manifests. These documents quote only the first 12 hex characters
of a hash, because values retyped by hand were unreliable (see the pitfalls guide).

## Deliverable status

| Mentor deliverable | Status |
|---|---|
| Minimum number of VMs | Decided by the mentor: 2 (master and worker), both verified as TDX |
| Fork the CCBot repo and make CCBot/Hadoop work in a TEE | Done: fork `Antisource/nutch`, crawl ran on both TDX VMs, twice |
| Specify the VM configuration for Hadoop | [cluster-configuration.md](cluster-configuration.md) |
| Crawl 10 URLs and see the WARC output | Done twice: 8 pages + 2 redirect records = 10 fetch attempts each time |
| Update the limitations table and answer the better-TEE question | **Not yet written.** Observations so far are in the comparison and lessons documents |
| Reference exercises: signature check, measurement comparison | **Not yet done** |

## Glossary

| Term | Meaning |
|---|---|
| TEE | Trusted Execution Environment: hardware-isolated computation whose memory the host cannot read |
| Intel TDX, Trust Domain (TD) | Intel's confidential-VM technology. A TD is the protected VM |
| Confidential VM (CVM) | A whole VM run inside a TEE; on GCP, `confidentialInstanceType: TDX` |
| Quote | A signed statement from the CPU about a TD: its measurements plus 64 bytes of caller-chosen data |
| REPORTDATA | The 64-byte field of a quote the caller fills. Here: the SHA-512 of a manifest |
| MRTD, RTMR0-3 | Fingerprints of the TD's initial contents and of boot-time events. Not yet examined here |
| Manifest | A plain-text inventory of code versions, configuration hashes, inputs and outputs for one node |
| WARC | Web ARChive file format. Records here: `warcinfo`, `request`, `response`, `metadata` |
| Segment | The folder one crawl round writes (one per round) |
| HDFS, YARN | Hadoop's shared storage, and its job scheduler |
| tmux | A terminal that keeps commands running if the connection drops |

## Conventions

- Times are UTC. The VM clock is supplied by the host and is not proven by a quote.
- A hash comparison done by eye is not evidence. Comparisons in this work were done by the shell
  (`[ "$a" = "$b" ] && echo SAME`).
- Shell prompts identify the machine: `cloudshell`, `tdx-lab` (master), `tdx-lab-worker`, or the
  laptop's PowerShell.
