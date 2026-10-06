# Milestone 0: clean baseline (run 3)

Date: 5 October 2026. Times are UTC unless a tool is named as printing laptop time (India Standard Time, UTC+5:30).
Status: **done, with one documented limitation** (step 0.6). Written when the milestone closed; later facts go in the milestone reports that follow.

## 1. Goal

Before adding measurement and cluster security, start from a known and correct baseline. Runs 1 and 2 had two defects that the mentor's
handoff and our own checks exposed:

1. The crawl used Nutch's default HTTP client (`protocol-http`), not CCBot's `protocol-okhttp`.
2. `store.ip.address` was not set, so every `WARC-IP-Address` was `0.0.0.0`.

Pass condition: a new crawl (run 3) on the same two nodes, same seeds, same cap, with the okhttp client and real server addresses
in the WARC, and the evidence saved outside the VMs.

## 2. Steps and results

| # | Step | Status | Result |
|---|---|---|---|
| 0.1 | Record both VMs' versions | Done | Master kernel `6.8.0-1067-gcp`, worker `6.8.0-1069-gcp`; Ubuntu 22.04.5; OpenJDK 11.0.32.1; Hadoop 3.4.3. All matched [cluster-configuration.md](cluster-configuration.md) |
| 0.2 | Verify the existing evidence bundles | Done | `evidence-all.tar.gz` and `evidence-all-2.tar.gz` verified with `sha256sum -c` (`OK`); the newer bundle holds 79 entries |
| 0.3 | Fix the configuration | Done | `plugin.includes` set to the stock default with one change (`protocol-http` to `protocol-okhttp`); `store.ip.address` set to `true`. Commit `594b992e3` `feat(config): use protocol-okhttp and store server IPs` |
| 0.4 | Rebuild the job file and check its contents | Done | `ant runtime`: `BUILD SUCCESSFUL`, 16 seconds. New job file stamped 09:44 on 5 October; SHA-256 changed from `88161b64126a` (runs 1 and 2) to `bbd30ad90d35`. Inside it (read with Python's `zipfile`): 14 entries for `protocol-okhttp`, the config's `plugin.includes` names okhttp once, the old `protocol-http\|` string 0 times, and `store.ip.address` is true |
| 0.5 | Run 3 on fresh HDFS and evidence folders | Done | Seeds `seeds-run3`, crawl `crawl-run3`. Segments `20261005095259`, `20261005095604`, `20261005095948`. `Finished loop with 3 iterations` at 10:03:05. Last job's error counters all 0; a scan of the whole log for `Failed map tasks`, `Job ... failed` and `Exception` printed nothing |
| 0.6 | Confirm okhttp did the fetching | **Partly done** | See section 4 |
| 0.7 | Copy the WARC output out of HDFS and save evidence off the VM | Done | 18 files (9 `.warc.gz` and 9 `.cdx.gz`) copied and verified (18 of 18 `OK`). Bundle `evidence-run3.tar.gz`: 33 entries, verified on Cloud Shell and on the laptop |

## 3. Results

| Item | Run 3 |
|---|---|
| `pages/` | 8 `response`, 8 `metadata`, 3 `warcinfo` (2, 3 and 3 response records per file) |
| `WARC-IP-Address` | Real addresses: `216.150.1.193` for `www.zyte.com` (1 record) and `35.211.122.109` for the seven `toscrape` pages; 2 more in `diagnostics/` (`35.211.122.109`). No `0.0.0.0` anywhere |
| Pages fetched | The same eight URLs as run 2 (`SAME-PAGES`, compared by the shell on `WARC-Target-URI` lines; this compares URLs, not page content) |
| Duration | About 11 minutes (first plugin line 09:52:17, finished 10:03:05) |
| Plugin lines in the master's crawl log | Run 3: 19 lines `OKHttp Protocol Plug-in (protocol-okhttp)` and 0 for `protocol-http`. Run 2: 0 and 19 |

## 4. What was not done, and why it matters

- **okhttp was not observed inside worker tasks.** The 19 log lines come from the master's driver script, one per Hadoop job: they show the plugin
  was selected from our configuration. They do not show a fetch happening. Nutch loads only plugins that match `plugin.includes`, and our setting names okhttp
  but not `protocol-http`, so okhttp must have done the fetching (reasoning, not an observation). Worker task logs could not settle it: YARN kept no container
  logs (all 27 applications of run 3 returned 0 lines from `yarn logs`), and the worker's `userlogs` folder was empty by the time we looked on 5 October. The check will
  be repeated right after the next crawl, before any worker daemon restarts.
- **TLS certificate checking was left at the default (off)**, so that run 3 differs from run 2 in exactly the two intended settings. See [decisions.md](decisions.md), ADR-002.
- **Run 3 is not byte-comparable with runs 1 and 2.** `conf/` is packed into the job file, so any configuration change changes the job hash.
  The `JOB-IDENTICAL` comparison of runs 1 and 2 cannot be repeated against run 3.
- **No manifests or quotes were made for run 3.** Milestone 1 replaces them with measurements that cover far more (see [milestone-1-code-measurement.md](milestone-1-code-measurement.md)).

## 5. Observations that stay unexplained

- On the master, a first check of `conf/nutch-site.xml` showed `protocol-http` while the committed file, the working file and the file inside the job all said
  `protocol-okhttp` in every later check. The shell then confirmed the working file equal to the commit byte for byte (`git diff --quiet`, a hash comparison),
  and `git reflog` showed one pull that morning. The cause of the first reading was not established; the state used for the build was verified.
- Several commit ids and hashes in text copied from terminals differed from the originals by single characters. Comparisons were therefore done by the shell.

## 6. Evidence (kept outside the repository)

| Bundle | Entries | Fingerprint (first 12 hex) | Contents |
|---|---|---|---|
| `evidence-run3.tar.gz` | 33 | `a8b20d8562a0` | 18 WARC and index files, `SHA256SUMS`, build and crawl logs, job fingerprints before and after, the config used, the git commit, an HDFS listing, VM facts |

Laptop copy: `tdx-evidence`, fingerprint compared by PowerShell (`MATCH`).

## 7. Decisions taken at this milestone

- Keep plain TDX VMs with our own image (mentor): [decisions.md](decisions.md), ADR-001.
- Leave TLS certificate checking off for now, provisional: ADR-002.
- Run 3 on fresh folders, not overwriting runs 1 and 2: ADR-007.
