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

14. **Read a real sample before writing a check that depends on another tool's output.** Run one read-only command, look at what it prints, then write the check. (The first tamper demo looked for an error text that the client never prints, and assumed `hdfs dfs -ls` prints absolute paths.)
15. **Do not test a check only against stand-ins you wrote from the same assumption.** Such a test cannot find the assumption. Prefer evidence that our own code writes (audit lines, records), and run the check on real logs.
16. **Move files in one pack, with a printed fingerprint, and verify it on arrival.** Look at the unpacked folder (`pwd`, `ls`) before running anything from it. Several browser downloads in a row lost files; a small web server in Cloud Shell (`python3 -m http.server 8080`, opened through Web Preview) worked.
17. **Commit gate and documents.** Before any commit, check that the files are identical (by fingerprint) to the files that ran, in the cluster folders, on the laptop and in a fresh clone; abort on any difference. Write the documents after the code ran, from a fresh copy of the branch, and check their numbers against the evidence (`docs_facts_check.py`).
18. **Rehearse code with the real libraries before sending it.** If the real libraries cannot be had, say in the message exactly what could not be rehearsed. Code checked only against stand-ins written from one's own assumptions fails where the assumptions are wrong (the contract tests, 7 October).
19. **Documents and programs go in separate commits**, programs first and each gated; a tool's data file counts as a program.
20. **Test a check against a known fault before trusting its pass.** The contract comparison was run once with the old job, which has known defects, and had to report them.
21. **Do not rename or add steps.** Steps keep the names already committed; anything new from the mentor goes inside an existing step as a baby step (4.5.2, 4.6.1 to 4.6.3, 5.3.3).
22. **Do not draft messages to teammates or mentors unless asked.**
23. **A stand-in must model the real tool's constraints.** A stand-in written from the same assumption as the script cannot find that assumption's error: the admin tool refused the wrapper and the stand-in did not.
24. **After moving a file, find out where the running writer writes.** A rotation does not stop a process that holds the file open; before saying something was not logged, look in the archive too.
25. **Tools that inspect the cluster ask for the plain client themselves.** They must not depend on the cluster's current mode or on the guard they inspect.
26. **Collect task logs right after a run.** They expire (after 3 hours here, with log aggregation off).
27. **Say what a number or a label means, from the source.** `allowed=false` on a delete is not "denied"; "about 40 jobs" had no source; a count that includes its own list is not "files listed".

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
| 22 | Master | A first check of `conf/nutch-site.xml` printed `protocol-http`; every later check of the same file printed `protocol-okhttp` | Not established (the reflog showed one pull that morning) | The shell confirmed the working file equal to the commit before the build | Compare by shell (`git diff --quiet`, a byte comparison) before building |
| 23 | Evidence | Commit ids and hashes in text copied from terminals differed from the originals by single characters (for example `594b992e3` and `594b9928c`) | Retyping and display glitches | Compared by the shell instead | Rule 6: never compare by eye |
| 24 | Master | `unzip` was not installed; three `grep -c` counts printed 0, which looks like an answer | The count of empty input is 0 | Used Python's `zipfile`; no package was installed on a VM we plan to measure | Check that a tool exists first (as mistake 20) |
| 25 | Cloud Shell | `gcloud compute scp` with sources on two machines failed: "All sources must refer to the same remote" | One remote per command | Two commands | Copy from one machine at a time |
| 26 | Cloud Shell | A command containing `<paste-id-here>` ran literally and gave `syntax error near unexpected token` | A placeholder was not replaced | Re-ran with a real id | Say which parts are placeholders; avoid angle brackets in commands |
| 27 | Cloud Shell | The first `ccel_replay.py` stopped with `KeyError: 65535` | The log's unused tail is `0xFF` fill, and the script assumed zeros | The script now recognises the end marker and stops with a parse error on anything else | Test a parser on the real data's edges, and make it say where it fails |
| 28 | Cloud Shell | The first event comparison reported 39 differing events | It compared by position, so one inserted event shifts every later one | Read the list by content | State the limits of a positional diff; prefer a sequence-aware one |
| 29 | Evidence | A long script pasted into Cloud Shell looked truncated, and one script (`gpt_diff.py`) was never created | Copying from a terminal drops or garbles lines | A fingerprint check after each paste; the script was later proved identical from the evidence bundle | Always check a pasted file's fingerprint |
| 30 | Package install | A malformed checksum line was silently skipped by `sha256sum -c` | Without `--strict`, improperly formatted lines are ignored | `sha256sum --strict -c` in the prep script (found in testing) | Use `--strict` |
| 31 | Master | One reboot command led to two reboots: the journal shows a manual `sudo reboot` 21 seconds after an SSH login | The reboot line was run again after reconnecting | Harmless; no evidence belongs to the extra boot | Keep reboot commands in their own block; check `last -x` after a surprise |
| 32 | Worker | After the master's ResourceManager was down about 23 minutes, the worker's NodeManager had exited | Hadoop's NodeManager gives up reconnecting; the daemons are not supervised | Started it by hand | Run `jps` on the worker after any master outage |
| 33 | Laptop and git | Scripts copied through Windows risk CRLF line endings, which break shell scripts on Linux | Windows git and editors | `.gitattributes` with `eol=lf` for `attest/` and `ops/`; a fresh clone matched the tested fingerprints | Verify committed files from a clean clone |
| 34 | Cloud Shell | `rm -rf /tmp/chk` while standing in `/tmp/chk` gave `Unable to read current working directory` (twice during the work: also with the `m1-inv` folder) | The folder being deleted was the current directory | `cd ~` first, then re-ran | Never delete the folder you are in |
| 35 | Nodes | After the hosts file pointed the Hadoop names at the mesh, the worker's NodeManager registered under Google's internal name, which resolves to the ordinary address the new firewall drops | The node named itself by reverse lookup; the old `/etc/hosts` alias had hidden this | Found by reading `yarn node -list`; mapped the internal names to the mesh; verified with a real job | After any network change, check the node names and run a small job |
| 36 | Scripts | `hdfs` and `yarn` would not be found by a command run over `gcloud compute ssh --command` | A non-interactive SSH command does not read `~/.bashrc`, where the paths are set | The scripts set `HADOOP_HOME`, `JAVA_HOME` and `PATH` themselves (found in testing) | Set the environment explicitly in remote scripts |
| 37 | PowerShell | `Get-ChildItem -Filter` given two patterns failed with `Cannot convert System.Object[]` | `-Filter` takes one string | The listing failed; the copy and verification that followed worked | Use one `-Filter` per command, or pass an array of wildcard paths |
| 38 | Evidence | Re-running the refusal test changed the drop counters (24 to 48) | Counters are cumulative | Both runs recorded | Note the counter baseline when repeating a test |
| 39 | Cloud Shell | `scp` failed with "No such file" twice: the zip had not been uploaded to Cloud Shell yet (once I had also forgotten to attach it) | A step in the chain (download from chat, upload to Cloud Shell, copy to the node) was skipped | Uploaded the file and re-ran | `ls` the file before copying it on; check the fingerprint after each hop |
| 40 | Design | The Option A wrapper was built and tested (63 checks) before the mentor had answered; the mentor chose Option B and the Option A code was dropped | Building ahead of an open design decision | The Option A code was never committed; Option B was built in its place | While a design question is with the mentor, do read-only analysis and build only what all options share |
| 41 | Tests | The first fake HDFS crashed (`myUri` was null) because the parent class's constructor calls an overridable method before the fake's fields exist, and its statuses assumed `file:` paths | Java constructor order; the fake was too strict | Fake fixed | A fake must tolerate being called during construction |
| 42 | Audit | The first audit tool counted every file under a renamed folder as explained, so a file edited after its folder was moved slipped through. Found by planting that fault | The rule was too generous | A moved file must keep its size; a file that vanishes during a move is reported | Test every checking tool with planted faults before trusting its "clean" |
| 43 | Predictions | Two guesses were wrong: that HDFS byte counters might read zero through the wrapper (they read normally), and that a live site "changes on every fetch" (it changes when it is redeployed; runs 3 to 5 were identical) | Explaining a difference before testing it | Settled by counting the counters, by the control runs, and by the page's own deployment identifier | Run a control before explaining a difference; compare live pages only with a contemporaneous control or on static pages |
| 44 | Comparison | A comparison of the crawl database statistics reported every line as different because the log timestamps were part of the compared text | Timestamps in compared output | Timestamps stripped | Strip timestamps and ids before diffing logs |
| 45 | Build | A job built from a clean clone lacked a file that the measured job has (the untracked `conf/effective_tld_names.dat`) | The measured tree is not a clean checkout | Found by comparing the two job files entry by entry; the file was copied into the clone | Compare job files entry by entry before comparing crawls |
| 46 | Master | The copy meant to keep run 6's job file was already the rebuilt job, so run 6's job bytes are lost | The command copied to a fixed name with no guard, and the build step had probably run twice (not verified) | The fingerprint (`ddc415a5d87c9e6b`), the entry count and the comparison outputs remain; later jobs are compared with the measured run 5 job; the copy is kept under a clear name | Use `cp -n` and check the fingerprint before copying; keep each run's job under its own name |
| 47 | Master | `chmod` and the build script failed with "No such file" | The zip unpacked into an extra top folder (`m4b1/`) | Changed into the inner folder; the 15 fingerprints had matched | `pwd` and `ls` after unpacking; the instructions name the folder (rule 16) |
| 48 | Laptop | Four downloads in a row: only the last file arrived; later the Cloud Shell download button produced nothing | The browser accepted one automatic download and dropped the rest (inference) | One pack with a printed fingerprint, served with `python3 -m http.server 8080` and Web Preview | Rule 16 |
| 49 | Laptop | The verify script printed "PACK MISMATCH" when the file was only missing | It treated any non-match, including an empty hash, as a mismatch | The script now says "FILE NOT FOUND" separately | A script must name the real failure |
| 50 | Predictions | Several expected values were wrong: 44 task logs instead of 22 (run 7's logs were still kept), 56 applications instead of 54, and "18 WARC files" (there are 9 WARC and 9 index files, 18 data files) | Expected values were stated before a real sample was read | Counted again, restricted to the right applications; the folder listing was read | Rule 14 |
| 51 | Tests | The first tamper demo printed `FAIL` although the wrapper had refused the changed file; its path label also showed a relative path | The script looked for the error text in the client's console, where it is never printed, and assumed `hdfs dfs -ls` prints absolute paths; its stand-in tests were written from the same assumptions | The reason was proved from the worker's audit log with `tamper_verify.py`; the demo was rerun with a fixed script; the label flaw is documented, not fixed in the committed script | Rules 14 and 15 |
| 52 | Tests | A check for carriage returns flagged two files | The shell used did not interpret `$'\r'`, so the pattern matched the text `$r` | A byte-level check found no carriage returns | Check for bytes with a program, not with a shell pattern |
| 53 | Process | A design draft was written before the code the author wanted | Documents were written ahead of the build | The draft was kept uncommitted and the build was done first | Code first; documents after, each with a gate (rule 17) |
| 54 | Documents | A local copy of the repository used as the base for these documents lacked the latest documents commit (ADR-020) | The copy had been fetched earlier and was not refreshed | A fresh clone of the branch head was used | Refresh before editing (rule 17) |
| 55 | Master | The check of the file list printed "22 of 21" and stopped the run; I had miscounted the files and gave an invented reason for the number | A miscount, then an explanation made up to fit it | All 22 files had matched; the check now compares with the list's own line count and lives inside the script | Never explain a number that was not verified (rule 14) |
| 56 | Master | The same check was bypassed once: the pasted block began with a stray `> ` and its first line failed | The prompt character was copied with the lines | The files had matched minutes earlier; the check moved into the script | Copy only the lines inside the box |
| 57 | Master | The first contract run failed at compilation: `PathHandle` and `VectoredRead` are parameterized tests and need constructor arguments | The stand-ins assumed no-argument constructors; the real sources had been downloaded but only their imports were checked | Fixed, then rehearsed with the real classes (milestone-4 §18.3) | Rule 18 |
| 58 | Package | `job_compare.py` was used in a command but was not in the package | Not checked against the package | The tool already existed on the master; the comparison was rerun with its fingerprint printed | List every file a command uses |
| 59 | Master | `unzip` is not installed, so an inventory reported 0 contract classes | The error output was hidden (`2>/dev/null`) | Redone with `jar`; the real result was 22 classes | Do not hide errors in an inventory |
| 60 | Reports | A pass count was added wrongly (239 instead of 238) | Mental arithmetic | Corrected: 255 − 16 − 1 | Show the sum, or compute it |
| 61 | Display | The output of a long run scrambled when read inside tmux | The tmux screen redraws over the text | The output was read in a normal shell | tmux for running, a normal shell for reading |
| 62 | Process | The contract comparison had never been shown to fail on the cluster | A pass means little if the check could not fail | Ran the same suite with the old job: 10 differences (milestone-4 §18.7) | Rule 20 |
| 63 | Plan | The plan drifted to 10 milestones and to steps 4.9 to 4.11, and step 4.6 was renamed, without being asked | Milestones and steps were split and added as the work became concrete, and I did not say so | Reverted to the six milestones after the pre-flight and to the committed step names; the mentor's items became baby steps | Rule 21 |
| 64 | Messages | Draft messages to a teammate were written without being asked, twice | The drafting tool was used by habit | Stopped; no drafts unless asked | Rule 22 |
| 65 | Master | A read-only check printed one live DataNode, and I had written that it should be 2 | An assumption about the cluster; by design the worker is the only DataNode and replication is 1 | The script records the number it finds and does not depend on it; the design is in cluster-configuration.md | Read the configuration document before expecting a number |
| 66 | Development | The probe script failed `bash -n`: an apostrophe inside `${VAR:?message}` | Quoting inside a parameter expansion | Found in the rehearsal and fixed before it reached the master | Run `bash -n` and a stand-in rehearsal on every script |
| 67 | Reports | A read command planned for step 4.5 assumed a file name and a layout (the run 8 listing) that I had not checked | The same kind of assumption as in step 4.4 | Caught before it was sent; replaced by reading the code and a probe that makes its own data | Read a real sample first |
| 68 | Tool | The comparison's documentation said a plain read next to a wrapped read of the same file would be taken for the wrapped one; the test showed the tool is stricter (each wrapper line explains one event) | I described the behaviour before testing it | The test and the text were corrected | Test a stated limit before writing it |
| 69 | Tests | A test expected the number of findings to stay the same after a run with the policy `fail`, which logs every refusal | The test forgot its own earlier step | The test compares with a count taken just before | Compare with a count taken at the moment |
| 70 | Cluster | The first switch to the wrapped file failed (`safe mode did not end`) and rolled back by itself | Hadoop's admin tool refuses any file system that is not a `DistributedFileSystem`; I had not checked it, and the rehearsal's stand-in did not model it | Read the source, put the plain client in the admin calls, corrected the stand-in (the old script then fails 5 checks, as on the cluster) | Model a real constraint in the stand-in; read a tool's source before relying on it |
| 71 | Development | The rollback printed `ROLLED-BACK` but did not restart a NodeManager that had failed to start | Restart and verification looked only at daemons that were still running | The script notes the node's daemons once before any change; the rehearsal checks it | Verify against the state expected before the change |
| 72 | Procedure | The NodeManager's reads of the swap demo were missing from the clean log folder | The rotation moved its open log file and it went on writing into the archive | Found in the archive; `audit.sh rotate` warns about running writers; the procedure restarts the NodeManager | Look where a running writer writes before saying something is absent |
| 73 | Commands | A command of mine printed a second NodeManager pid | `grep` matched my own `awk` command line, which contained the word | Patterns that name the class and cannot match the command itself | Match with a pattern that cannot match your own command |
| 74 | Tool | The comparison called 81 deletes "DENIED" | HDFS writes the result of a delete into `allowed`, so false means nothing was deleted | Read the source and the data (all deletes, 0 permission errors); the label was fixed with tests | Check what a field means in the source before naming it |
| 75 | Claims | I wrote that the crawl was "about 40 jobs" | No count behind it | Withdrawn; 27, confirmed by the master's uploads and the NodeManager's reads | Give a number only with its source |
| 76 | Tests | Three of my own new checks were wrong (a substring that missed a parenthesis, a pattern that matched the older leftover, a wrong expected path) | I wrote the expectation before reading the tool's actual wording and output | The checks were fixed, not the tools, after the output was read | When a new check fails, read the output before deciding which side is wrong |
| 77 | Evidence | Run 9's container logs had expired before I collected them | Log aggregation is off and YARN deletes them after 3 hours; I did not collect them | Stated as a limit; the procedure collects them right after a run | Collect task logs right after a run |
| 78 | Counting | I quoted 828 and 354 as the bundles' "files listed" | The totals included the `SHA256SUMS` file itself | Explained after the laptop check (827 and 353 listed) | Say what a count includes |

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
| Registers are stable per node, so equal values across runs say nothing about the crawl | Still true, but stable only while the node does not reboot or change its boot configuration. They changed after our GRUB changes and after the first boot's partition growth ([milestone-1-code-measurement.md](milestone-1-code-measurement.md) section 5) |
| The firmware's boot log ends in zero fill | It ends in `0xFF` fill (mistake 27) |
| The two old `entry...` folders under the report directory are leftovers to leave alone | They are in memory and were gone after the master's first reboot |
| Quotes carry no code measurement (RTMR3 zero) | True for runs 1 to 3 only. From 5 October the master and worker quotes carry measured stacks in RTMR3 |
| The ResourceManager and DataNode are bound to the mesh after the hosts change | Only the master's RPC daemons bind through their hostnames. The NameNode web page and all of the worker's daemons listen on all addresses and are closed by the host firewall |
| No firewall rule was added (run 1 and 2 wording) | True for Google's firewall. Host firewalls on both nodes were added on 6 October 2026 (cluster-configuration.md section 10) |
| The wrapper is registered under a custom scheme such as `attested://` (handoff, wrapper piece) | Replaced by the mentor-approved design: the wrapper replaces the implementation behind `hdfs://`, through two settings, `fs.hdfs.impl` and `fs.AbstractFileSystem.hdfs.impl` |
| "Nutch always reaches storage through this layer" (handoff) | Nutch's Java asks for the default file system in 6 places and from the path in 81; the six are outside the crawl loop. With the `hdfs://` replacement every request of a configured program goes through anyway |
| HDFS byte counters might read zero through the wrapper (author's guess) | They read normally: 27 read and 27 written lines in both run 5 and run 6, with nearly equal values |
| A live site's page changes on every fetch (author's guess) | It changes when the site is redeployed; its deployment identifier is in the page. Runs 3, 4 and 5 were identical; run 6 saw a new deployment |

## 4. Decision log

Decisions from 5 October 2026 onward are kept in [decisions.md](decisions.md). This table covers runs 1 and 2.

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
14. For a configuration change, rebuild: `conf/` is packed into the job file. Check the new job file's contents (a Python one-liner with `zipfile` is enough) and keep the old job hash.
15. Before touching the kernel: snapshot each boot disk, back up GRUB, pin the running kernel with a `grub.d` file and `grub-set-default`, and prove the pin with one reboot. Then install the packages (checksums verified) and request one boot with `grub-reboot`. Keep the reboot command in its own block.
16. After the boot: check the `measurements` folder, run the measurement script, request a quote with the log as input, and verify the signature off-cloud and the replay on two machines.
17. Run the crawl, then recompute every measured digest and compare. After any master outage, check the worker's daemons with `jps`.
18. Before a network change, back up `/etc/hosts` and the firewall rules. Apply a firewall with a self-undo timer that only a fresh login can cancel.
19. After a network change: check `yarn node -list` (the node name), HDFS safe mode and live DataNodes, and run the Pi example. Check the worker's task logs for okhttp right after a crawl, before any daemon restarts.
20. Prove the firewall with counted rules: probe the Hadoop ports over the ordinary address and the mesh address, in both directions, and read the drop counters before and after.
21. Unpack new code into a scratch folder on the master and test it there; commit only files whose fingerprints equal those recorded when they ran, and check them from a fresh clone.
22. Build the job in a scratch clone, never in the measured tree, and compare it with the measured job entry by entry (`job_compare.py`) before any crawl comparison.
23. Before a crawl: on the worker rotate the logs and restart the NodeManager; run `wrapper-jar.sh verify <job file>` (it must say `CLASSES-SAME`); right after the crawl pack the container logs.
24. In wrapped mode use `ops/run-crawl.sh` (no wrapper options); for the unwrapped control switch both nodes with `cluster-mode.sh plain --restart-yarn` and switch back afterwards.
25. Run the NameNode comparison over a window that starts at the rotation (so that the seed upload is in it), read its `known` lines, and run it once with `--strict` and once with one wrapper log removed.
23. A wrapped crawl: rotate the logs on both nodes, put the seeds in, list HDFS before, crawl in tmux, list HDFS after, check the worker's task logs before any restart, collect both nodes' logs, run `audit_compare.py` with `--require-hosts` for both nodes.
24. When two crawls differ, look at the earlier runs (a control) and at the page itself (a deployment identifier, new links) before explaining the difference.
25. Test any new checking tool with planted faults, and keep timestamps out of compared text.

## 6. Security hygiene

- Keep GitHub tokens, passwords and API keys off the VMs. Commit from the laptop and `git pull` on the VMs.
- Do not open Hadoop ports to the internet; add no firewall rules.
- Do not put personal data or secrets in `nutch-site.xml`: its values are written into WARC files and committed.
- Remove stray SSH keys created on a VM by a mistaken command.
- Treat unknown folders under `/sys/kernel/config/tsm/report/` as someone else's.
- The repository is public: commit scripts only, and keep quotes, boot logs, manifests and WARC files out of it.
- Do not install extra packages on a VM you plan to measure; use the tools already there (Python's `zipfile` instead of `unzip`).
- WireGuard private keys stay on the node that made them (root only, mode 600). Never print, copy or commit them; only public keys travel.
- The wrapper's logs and the HDFS listings are plain local files. They are an engineering proof for the author, not evidence against someone with root. `audit.sh rotate` moves logs aside; it deletes nothing.
- Do not build in the measured tree: a build overwrites the job that the measurements and earlier runs refer to.

## 7. Open items

| Item | State |
|---|---|
| Verify quote signatures off the cloud | **Done** for all four quotes (basic and strict check); see [quote-verification.md](quote-verification.md) |
| Compare MRTD and RTMR values between the nodes and runs | **Done.** MRTD identical; RTMR0 to RTMR2 differ between nodes. Not judged against a reference value |
| Record the one-byte tamper test | **Done** on run 2's master manifest and quote. Not repeated on the worker |
| Restrict the crawl to the seed domains | Open: the crawl fetched an external site in both runs |
| Investigate `WARC-IP-Address: 0.0.0.0` | **Done in run 3:** `store.ip.address` was not set; with it on, real addresses are recorded ([milestone-0-clean-baseline.md](milestone-0-clean-baseline.md)) |
| Compare MRTD with a published reference, replay the boot event log, validate offsets against Intel's specification | Partly done: the boot log is replayed ([milestone-1-code-measurement.md](milestone-1-code-measurement.md) section 4). The MRTD reference and the offset validation are open |
| Write the limitations and challenges table; assess a better TEE for CCBot | **Done:** see [limitations-and-trust.md](limitations-and-trust.md). Spot-check its sources before citing |
| Experiments proposed by the limitations analysis (RTMR3 extension, MRTD against Google's endorsement, `gceprovenance`, Hadoop wire encryption, non-TDX baseline, WARC fixes, maintenance restart, signed evidence bundle) | Open: listed under "Next experiments" in [limitations-and-trust.md](limitations-and-trust.md) |
| Capture run 2 file sizes | Open |
| RTMR3 extension and measurement of the stack | **Done** 5 to 6 October for both nodes ([milestone-1-code-measurement.md](milestone-1-code-measurement.md)) |
| Encrypt and authenticate node-to-node traffic | **Partly done** 6 October: WireGuard mesh and host firewall ([milestone-2-wireguard-mesh.md](milestone-2-wireguard-mesh.md)). Not done: a real third-machine test, IPv6, persistence across reboot, attested peer admission |
| Re-measure after a reboot (the jobs of runs 6 to 8 and the new scripts are outside the measured set) | Deferred (ADR-020; accepted by the mentor on 7 October as long as nothing unmeasured is described as measured, ADR-029): at the end of Milestone 4 (step 4.8), with the firewall rules saved first; one new crawl on measured code follows |
| Make the job reproducible from a clean checkout (`conf/effective_tld_names.dat` is untracked) | Open |
| Chunk hashing on write, verification on read, metadata from records (handoff Stage B) | **Partly done** 7 October (Milestone 4, steps 4.2 and 4.3): hashing at close and verified reads ([milestone-4-storage-integrity.md](milestone-4-storage-integrity.md)). Open: metadata from records (step 4.5), task records and manifests (step 4.7) |
| The NodeManager reads the job file through plain HDFS | Decided by the mentor on 7 October (ADR-027): the wrapper on Hadoop's own classpath with both lookups final; open, step 4.6 |
| An independent audit of reads, from the NameNode's own audit log | **Done** 8 October (baby step 4.5.2): the log is on and compared with the wrapper's log ([milestone-4-storage-integrity.md](milestone-4-storage-integrity.md) section 19) |
| An unwrapped control in the same hour for every wrapped crawl, with wall time and bytes fetched | A rule for every crawl from now on (the mentor, 7 October; ADR-028); results in step 6.3 |
| Per-fetch TLS evidence | In scope as teammate S's patch (the mentor, 7 October); step 5.3, see [milestone-plan.md](milestone-plan.md) |
| Hadoop's file-system contract tests against the wrapper | **Done** 7 October (Milestone 4, step 4.4): 255 tests, identical to plain HDFS; three wrapper defects found and fixed ([milestone-4-storage-integrity.md](milestone-4-storage-integrity.md) section 18) |
| Larger worker disk | Open: about 5.4 GB usable by HDFS limits scale |
| Turn on the DataNode's client trace at run time before the measured runs | Open: it would give a second look at the reads of the submitting client (limitations row 60) |
| Re-measure after a reboot with the wrapped configuration | Open: step 4.8; the measured set now includes `core-site.xml` and the library jar |
