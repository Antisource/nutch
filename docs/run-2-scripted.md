# Run 2 (scripted): repeat of the 10-URL crawl using the committed scripts

Date: 3 October 2026. All times are UTC, taken from the VM clocks. Run 2 repeats run 1 on the same cluster, but every crawl and
attestation step goes through scripts committed to this repository: `ops/run-crawl.sh`,
`attest/make-manifest.sh`, `attest/quote.sh`, `attest/verify-binding.sh`.

## 1. Goal

1. Test that the committed scripts work on real TDX nodes (they had never been run).
2. Test reproducibility: same code, same inputs, same cap, one day later.
3. Keep run 1's data untouched, so the two runs can be compared.

## 2. What was kept separate from run 1

| Item | Run 1 | Run 2 |
|---|---|---|
| HDFS seed folder | `seeds` | `seeds-run2` |
| HDFS crawl folder | `crawl` | `crawl-run2` |
| WARC folder on the master | `~/ccbot-work/warc-out` | `~/ccbot-work/warc-out-run2` |
| Manifests and quotes | `~/ccbot-work/` (master), `~/attest-out` (worker) | `~/ccbot-work/attest-run2` (master), `~/attest-run2` (worker) |
| Evidence in Cloud Shell | `~/evidence` | `~/evidence-run2` |
| Crawl log | `crawl-run1.log` | `crawl-run2.log` |

## 3. Preparation

1. Scripts, seed file and docs were committed on a laptop (Conventional Commits) and pushed.
   Between the two earlier pushes, an empty `attest/README.md` commit (`a7e758726`) was fixed by a follow-up
   commit (`105efc288`).
2. The master pulled the branch (fast-forward `5635894b7..2aadecd86`, 7 files, 247 insertions). Syntax
   check (`bash -n`) passed, scripts were executable, and no script contained carriage returns.
3. The worker, which has no repositories, took a shallow clone of the branch as `~/nutch-scripts`
   (it only needs the scripts, and its disk is small).
4. **Seed file correction.** The committed `seeds/seed.txt` was 56 bytes with a different hash from
   run 1's 57-byte file (Windows line endings and a missing final newline; details in the pitfalls
   guide). The exact run-1 bytes were rewritten, committed as a `fix(seeds)` commit, and pulled.
   Both manifests record `scripts_repo_commit` beginning `441cb333c21b`.

## 4. The build question

Run 2 needed the same packaged crawler as run 1, so a rebuild was attempted but never completed:

- The first attempt was in tmux session `build`; the operator's laptop crashed. The session survived,
  but no `ant` process was running and the job file was still stamped 2026-10-02 12:50:04. Whether the
  first attempt ran at all was not established, because no log was kept.
- The second attempt (`build2`) never started: the `cd` and `ant` lines pasted immediately after
  `tmux new` were lost, and no log file was created.
- Decision: no rebuild. `git diff --stat 5635894b7 HEAD` excluding `attest`, `ops`, `seeds` and `docs`
  printed nothing, so nothing that goes into the build had changed. The job file hash was later compared by the
  shell with run 1's: `JOB-IDENTICAL`.

## 5. Procedure

```bash
# master
hdfs dfs -mkdir -p seeds-run2
hdfs dfs -put ~/ccbot-work/nutch-cc/seeds/seed.txt seeds-run2/
tmux new -s crawl2                      # alone; wait for the prompt
cd ~/ccbot-work/nutch-cc && ops/run-crawl.sh seeds-run2 crawl-run2 2>&1 | tee ~/ccbot-work/crawl-run2.log
```

Then, on the master (`WARC_OUT` points the manifest at run 2's files):

```bash
mkdir -p ~/ccbot-work/attest-run2
cd ~/ccbot-work/nutch-cc
WARC_OUT=$HOME/ccbot-work/warc-out-run2 attest/make-manifest.sh master ~/ccbot-work/attest-run2/manifest-master.txt
attest/quote.sh  ~/ccbot-work/attest-run2/manifest-master.txt ~/ccbot-work/attest-run2/quote-master.bin
attest/verify-binding.sh ~/ccbot-work/attest-run2/manifest-master.txt ~/ccbot-work/attest-run2/quote-master.bin
```

And on the worker:

```bash
mkdir -p ~/attest-run2
~/nutch-scripts/attest/make-manifest.sh worker ~/attest-run2/manifest-worker.txt
~/nutch-scripts/attest/quote.sh ~/attest-run2/manifest-worker.txt ~/attest-run2/quote-worker.bin
~/nutch-scripts/attest/verify-binding.sh ~/attest-run2/manifest-worker.txt ~/attest-run2/quote-worker.bin
```

`quote.sh` also writes `<quote>.reportdata` (the 64 bytes sent to the CPU) next to the quote. The
WARC files were copied out of HDFS into `warc-out-run2/{pages,robotstxt,diagnostics}` and hashed into
`SHA256SUMS.txt` exactly as in run 1.

## 6. Results

### 6.1 Crawl

| Item | Result |
|---|---|
| Segments | `20261003070046`, `20261003070352`, `20261003070737` |
| Duration | About 10 minutes (first segment 07:00:46; `Finished loop with 3 iterations` at 07:10:53) |
| `pages/` | 8 `response`, 8 `metadata`, 3 `warcinfo` |
| `diagnostics/` | 2 `response`, 2 `metadata`, 3 `warcinfo` |
| `robotstxt/` | 3 `warcinfo` only |
| Fetch attempts | 8 + 2 = **10**, equal to the cap |
| Deduplication job | 42,808 ms |
| Errors | Every error counter in the final job summary was 0 |
| Fetching machine | `hostname: tdx-lab-worker` in all three page files |
| Failed fetches | HTTP 301 for `.../author/Albert-Einstein` and `.../author/Marilyn-Monroe` |

Pages fetched (8): the same eight URLs as run 1 (confirmed by the shell, see below), including the external
`https://www.zyte.com/`.

WARC file sizes for run 2 were not captured in this record. Add them from `ls -l warc-out-run2/*` if needed.

### 6.2 Checks done by the shell

| Check | Result |
|---|---|
| Run-2 job hash equals run 1's manifest value | `JOB-IDENTICAL` |
| Run 1 seed hash = repository seed = seed in `seeds-run2` | `SEEDS-IDENTICAL` |
| Sorted lists of fetched page URLs, run 1 vs run 2 | `SAME-PAGES` (`diff` printed nothing) |
| `sha256sum -c` of the nine run-2 WARC files after copying | `OK` for all |

### 6.3 Evidence and attestation

| Node | Manifest (UTC) | Quote | Binding |
|---|---|---|---|
| Master | 2026-10-03 07:53:25 | 8000 bytes | `MATCH` |
| Worker | 2026-10-03 07:59:31 | 8000 bytes (08:00), 64-byte `.reportdata` | `MATCH` |

Observations from the two manifests:

- Same `scripts_repo_commit` (`441cb333c21b…`) and the same four script hashes on both nodes.
- `scripts_repo_uncommitted_files` was 1 on the master (the downloaded suffix list) and 0 on the worker.
- Kernels still differ: `6.8.0-1067-gcp` (master) and `6.8.0-1069-gcp` (worker).
- The master manifest lists the nine run-2 WARC hashes; the helper-library commits and the packaged job hash match run 1.

After each quote, the configfs-tsm report directory was checked for leftovers: the worker's was empty, and the
master's held only the two older `entry...` folders from 27 September. The script removes its own `req-...` folder.

Evidence was copied to `~/evidence-run2` in Cloud Shell and re-hashed: `OK`. Shell comparisons then
printed eight `SAME` lines (inputs between runs), `CONFIGS-IDENTICAL` and `SCRIPTS-IDENTICAL` (between the two nodes).
A bundle of both runs was written as `~/evidence-all.tar.gz`.

## 7. What went wrong in run 2 (short list)

- Seed file bytes differed from run 1 until corrected (CRLF and missing final newline).
- Rebuild attempts did not run (lines lost after `tmux new`); resolved by showing the build inputs were unchanged.
- A summary built from retyped commands used wrong paths and produced hash strings of the wrong length. It was
  discarded as evidence and replaced by shell comparisons.

Details are in [guide-pitfalls-and-lessons.md](guide-pitfalls-and-lessons.md).

## 8. Not done in run 2 at the time

Signature verification of the quotes and the MRTD and RTMR comparison were done afterwards for all four quotes of both
runs: see [quote-verification.md](quote-verification.md). A one-byte tamper test was also done on run 2's master manifest
and quote. Still not done: any check that the pages came from the real sites.
