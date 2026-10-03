# Pitfalls, corrections and decisions

A practical guide for anyone repeating this work. It records what went wrong, how each problem was
resolved, which instructions turned out to be wrong, and why the key decisions were taken.

## 1. Operating rules that would have prevented most problems

1. **Check where you are before every command.** Run `hostname`. Four places are in play: laptop
   (PowerShell), Cloud Shell, the master `tdx-lab`, and the worker `tdx-lab-worker`.
2. **All SSH logins start from Cloud Shell.** A VM cannot SSH to another VM with `gcloud compute ssh`
   (it fails with "insufficient authentication scopes"). Leave with `exit`, then log in again.
3. **Paste one command at a time after any `ssh` or `tmux new`.** Lines typed while a login or session
   is starting are swallowed.
4. **Run long jobs inside tmux, and log to a file.** Detach with **Ctrl+B, release, then D**.
   Re-attach with `tmux attach -t <name>`.
5. **Do not rely on `| tail -N` for visibility.** It prints nothing until the command ends. Use
   `| tee file.log | tail -N`.
6. **Never compare hashes by eye, and never retype evidence.** Let the shell compare
   (`[ "$a" = "$b" ] && echo SAME`). Retyped hashes in this work were the wrong length.
7. **Compare hashes, not file sizes.** A wrongly formatted seed file had the right size by coincidence.
8. **Clear the screen (`clear`) before a long paste**, and write results to a file you then `cat`.
9. **Add Git files by name**, never `git add .` or `git commit -a`, and read `git log --stat` before pushing.
10. **Never run `hdfs namenode -format` twice.** It erases HDFS.
11. **Do not touch folders you did not create** (for example unknown `entry…` folders under
    `/sys/kernel/config/tsm/report/`).
12. **Label every time with its source and zone.** VM clocks are UTC; tools on the laptop print local time
    (India Standard Time, UTC+5:30). Convert before writing "UTC".
13. **Keep test artefacts in a named folder**, not `/tmp`, which is cleared when a VM restarts.

## 2. Mistake log

| # | Where | What happened | Cause | Resolution | Prevention |
|---|---|---|---|---|---|
| 1 | Cloud Shell | Tool installs and `/etc/hosts` edits ran in Cloud Shell; ping to the worker showed 100% loss | Command pasted before the SSH login completed | Harmless: Cloud Shell is a separate temporary machine. Redone on the VM | Rule 1 |
| 2 | Master | `gcloud compute ssh tdx-lab-worker` run from the master failed ("insufficient authentication scopes") and created an unneeded SSH key | Logins must start from Cloud Shell | `ls ~/.ssh` later showed only `authorized_keys` | Rule 2 |
| 3 | Worker | `dmesg` and `ls` lines pasted with the `ssh` command produced no output | Lines typed during login | Re-ran separately | Rule 3 |
| 4 | Screenshots | Overlapping text in many screenshots; some results unreadable | Long multi-line pastes | Re-ran checks one at a time | Rule 8 |
| 5 | Git | `git add conf/nutch-site.xml` was refused | `.gitignore` has `conf/*.xml` and `conf/*.txt` (except `nutch-default.xml`) | `git add -f` for this one file | New files go in `attest/`, `ops/`, `seeds/`, `docs/` |
| 6 | Git (PowerShell) | Multi-line commit with `\` continuation failed: `'\' is outside repository` | PowerShell does not use `\` for continuation | One-line commits | Note which shell you are in |
| 7 | Git | `attest/README.md` committed with 0 insertions and pushed (`a7e758726`) | File staged before content was saved | Follow-up commit `105efc288` instead of rewriting pushed history | Rule 9 |
| 8 | Git | `git add docs/run-1-pilot.md` found no files | File was not yet at that path | Located and moved it, then committed (`2aadecd86`) | `git status --short` before `add` |
| 9 | VS Code | `.gitignore` showed `M` but `git diff .gitignore` was empty | Line-ending or metadata noise | `git restore .gitignore` | Rule 9 |
| 10 | Seed file | The committed seed file was 56 bytes with a different hash from run 1's 57-byte file; the Windows copy was also 57 bytes but with another hash (CRLF) | A heredoc on the VM wrote LF plus a final newline; the Windows editor wrote CRLF and no final newline. Git stores LF (`core.autocrlf input`) | Wrote the exact bytes (`"…/`n…/`n"`), checked `CR=1 LF=1 last=47` on the old file and size 57 with hash prefix `14a80f8c8eaa` on the new one, committed `fix(seeds)` | Rule 7 |
| 11 | tmux | Ctrl+P was pressed instead of the detach shortcut; the browser tab switched and the terminal was closed | Wrong shortcut | The session survived and was re-attached | Rule 4 |
| 12 | tmux/build | Laptop crash during a build; blank screen on re-attach; no `BUILD SUCCESSFUL` seen | `tail -30` hides output; no log file | Used `pgrep`, the job file timestamp and `git diff` to establish state | Rules 4 and 5 |
| 13 | tmux/build | The second build session (`build2`) never started; no log file existed | Lines pasted immediately after `tmux new` were lost | Did not rebuild: build inputs were unchanged and the job hash matched run 1 | Rule 3 |
| 14 | Evidence | A summary built from retyped commands used wrong paths (`seed/`, `crawl-run2/seed.txt`) and contained hash strings of 62 and 65 characters | Manual retyping | Discarded; replaced with shell comparisons (`JOB-IDENTICAL`, `SEEDS-IDENTICAL`, `SAME-PAGES`) | Rule 6 |
| 15 | configfs | Two unknown `entry…` folders under the master's report directory | Dated 27 September, root-owned, provider `tdx_guest`: they predate this work, probably from an earlier exercise (inference) | Left alone; `quote.sh` uses its own `req-…` folder name and removes it | Rule 11 |
| 16 | Crawl | The crawl left the seed domains and fetched `www.zyte.com` | No domain restriction in the configuration | Recorded as a finding | Add a URL filter and hash it into the manifest |
| 17 | WARC | `WARC-IP-Address` is `0.0.0.0` in the record read | Not investigated | Recorded | Investigate the fetcher's WARC writer |
| 18 | Documentation | The laptop check was recorded as "about 17:07 UTC"; the tool had printed the laptop's local time (India, UTC+5:30), so the correct time is about 11:37 UTC | A local timestamp was read as UTC | Corrected, and every time in every document was audited against its source | Rule 12 |
| 19 | go-tdx-guest | `check -get_collateral -check_crl` stopped with `flag -get_collateral=-check_crl invalid` | The flags take explicit values; the tool read the second flag as the first one's value | `-get_collateral=true -check_crl=true` | Read the tool's own error; do not copy flag syntax from an example blindly |
| 20 | Cloud Shell | `xxd: command not found` | Cloud Shell does not have `xxd` (the VMs do) | Used `od -An -v -tx1 -j <offset> -N <length>`, checked against a known REPORTDATA match | Check a tool exists before building a procedure on it |
| 21 | Evidence | A file size (3355 bytes) retyped from a screenshot did not match the screen (3395) | Retyping | The screenshot value was used | Rule 6 |

## 3. Corrections to earlier working instructions

Some guidance given during the work turned out wrong or too strong. Corrected here so nobody repeats it.

| Earlier statement | Correct position |
|---|---|
| Export WARC with `bin/nutch warc` after the crawl | The fork writes WARC during the fetch when `fetcher.store.warc=true`; no export step |
| The Hadoop download is about 1 GB | It was 491 MB (514,917,037 bytes) |
| Cap: 5 URLs per round, 2 rounds | Replaced by 4 per round and 3 rounds, because round 1 can only fetch the seeds: 2 + 4 + 4 = 10 |
| A rebuilt job file will have a different hash (embedded timestamps) | Not tested: no rebuild actually ran, and the existing job hash matched |
| The worker would also show the two `entry…` folders | Only the master has them; the worker's listing was empty |
| "Probably Ant finished quickly" (explaining the blank screen) | The build never ran (no log file); see mistake 13 |
| Wording that a `MATCH` showed a genuine TDX statement | A `MATCH` shows only that the quote's 64 bytes equal the manifest's hash. Genuineness needs the signature check, still pending |
| The README for the scripts said changing any output file breaks the match | Changing the manifest breaks the match with the quote; changing a listed output file makes its hash differ from the recorded value |
| The laptop signature check was recorded as 17:07 UTC | It was the laptop's local time (IST); the correct time is about 11:37 UTC |
| `check -get_collateral -check_crl` (flags without values) | The flags need explicit values: `-get_collateral=true -check_crl=true` |
| Measurements can be extracted in Cloud Shell with `xxd` | Cloud Shell lacks `xxd`; `od` works and was validated against a known REPORTDATA match |
| The first `make-manifest.sh` always reproduced run 1's manifest | It does not: run 1's manifests were assembled by hand with a different layout |

## 4. Decision log

| Decision | Reason |
|---|---|
| Two VMs, master and worker | Mentor's choice, for authenticity and later scaling. Costs: more trust links (every node must be a TEE; two quotes) |
| Work only in the fork `Antisource/nutch`, branch `feat/tee-hadoop-cluster` | One repository for all changes; the upstream remote was removed |
| Hadoop 3.4.3 | The version pinned in the fork's `ivy/ivy.xml` |
| Start Hadoop daemons by hand | No SSH keys between the nodes; fewer trust links |
| `dfs.replication=1` | A single DataNode |
| Local `commit` then `pull` on the VMs | Keeps GitHub credentials off the VMs |
| `git add -f conf/nutch-site.xml` rather than editing `.gitignore` | Keeps `.gitignore` identical to the fork's; the file is a deliberate deliverable |
| Scripts in `attest/` and `ops/`, seeds in `seeds/` | Outside `conf/`, so Git does not ignore them |
| Conventional Commits 1.0.0 messages | Required by the mentor's convention: `feat`, `fix`, `docs`, with scope |
| Separate HDFS and evidence folders for run 2 | Run 1's data stays untouched for comparison |
| Hash a manifest instead of one file | One quote then covers code versions, configuration, inputs and outputs |
| SHA-512 into REPORTDATA | The digest is exactly 64 bytes, the size of the field |
| Quote REPORTDATA read at byte 568 | 48-byte header + 520 bytes into the quote body, per the TDX v4 layout (verify against Intel's specification) |
| Delete the `req-…` request folder after each quote | Leave configfs clean; never delete others' folders |
| No rebuild for run 2 | Build inputs unchanged and the job hash identical, giving a stronger comparison |
| Practice sites as seeds | Built for crawling tests; their `robots.txt` returned 404 (no published restrictions) |
| `-DskipTests` on the helper libraries | Saved time. Not what the upstream README says |
| Tamper tests on the master's run 2 manifest and quote only | The tests check mechanisms (a hash binding, a signature) that behave the same on any node. The worker was not repeated |
| Tampered copies kept in named folders, original files untouched | Evidence for the record; `/tmp` is cleared on restart |
| Tampered quote kept outside the repository | Evidence, not code |

## 5. Checklist for repeating the work

1. Create the master and worker as TDX Confidential VMs; check `dmesg | grep -i tdx` and `ls /sys/kernel/config/tsm/` on both.
2. Install `openjdk-11-jdk ant maven git libcld2-0 libcld2-dev` on both; add host aliases; ping both ways.
3. Download Hadoop 3.4.3, compare the SHA-512, unpack, set environment variables, write the four config files.
4. Format HDFS once, start the four daemons, run the Pi test, confirm 1 live DataNode and 1 running node.
5. Build `crawler-commons` and `language-detection-cld2`; record their commits; download the suffix list and record its hash.
6. Build the fork with `ant runtime`; record the job hash.
7. Put the seed file in a new HDFS folder; check the seed hash (57 bytes, prefix `14a80f8c8eaa`).
8. Run `ops/run-crawl.sh <seed-dir> <crawl-dir>` inside tmux, logging to a file.
9. Copy the WARC folders out of HDFS; hash them; count record types; list URLs; check `hostname:` lines.
10. Build a manifest per node, make a quote per node, check `MATCH`, hash the evidence files.
11. Copy evidence to Cloud Shell (VMs can be stopped); re-hash; compare by shell.
12. Verify the quote signatures on a machine with no Google credentials (`check -inform bin`, then with `-get_collateral=true -check_crl=true`); extract MRTD and RTMRs and count the distinct values per register.
13. Run the tamper tests on a copy of a manifest and on a copy of a quote; keep the logs and the tampered copies.

## 6. Security hygiene

- Keep GitHub tokens, passwords and API keys off the VMs. Commit from the laptop and `git pull` on the VMs.
- Do not open Hadoop ports to the internet; add no firewall rules.
- Do not put personal data or secrets in `nutch-site.xml`: its values are written into WARC files and committed.
- Remove stray SSH keys created on a VM by a mistaken command.
- Treat unknown folders under `/sys/kernel/config/tsm/report/` as someone else's.

## 7. Open items

| Item | State |
|---|---|
| Verify quote signatures off the cloud | **Done** for all four quotes (basic and strict check); see [quote-verification.md](quote-verification.md) |
| Compare MRTD and RTMR values between the nodes and runs | **Done.** MRTD identical; RTMR0 to RTMR2 differ between nodes. Not judged against a reference value |
| Record the one-byte tamper test | **Done** on run 2's master manifest and quote. Not repeated on the worker |
| Restrict the crawl to the seed domains | Open: the crawl fetched an external site in both runs |
| Investigate `WARC-IP-Address: 0.0.0.0` | Open: the server address is not captured in the record read |
| Compare MRTD with a published reference, replay the boot event log, validate offsets against Intel's specification | Open |
| Write the limitations and challenges table; assess a better TEE for CCBot | Open: mentor deliverable, not yet written |
| Capture run 2 file sizes | Open |
| Larger worker disk | Open: about 5.4 GB usable by HDFS limits scale |
