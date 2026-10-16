# Milestone 5: signed records

Status: **steps 5.1.1 and 5.1.2 are done on 15 October 2026**: every record can be signed with a labelled test key, a file rewritten together with its record, without the key, fails the read (section 3), and every file is bound to its folder and its name, so that a signed file moved or copied elsewhere fails the read too (section 4); both are shown on the real HDFS. The combined crawl, with signing and folder binding on and required, ran on the real cluster the same day and its whole output verifies offline with the public key only (section 5). **Step 5.1.3, the real key, is done on 16 October 2026**: each VM makes its own signing key in the memory of a small signing service, the hardware quote vouches for exactly that key, and a crawl with the real keys verifies offline against a key list (section 6). Steps 5.2 and 5.3 are open ([milestone-plan.md](milestone-plan.md)). It is extended as the later steps close. All times are UTC.

## 1. What this milestone does, in plain words

Until now every file in HDFS has a tamper sticker, its record. The sticker proves little, because anyone who can write the file can also rewrite its record. Milestone 5 replaces the sticker with a **signature**: a stamp that only a holder of the key can make. Step 5.1 gives each machine a signing key and ties every file to its folder, and step 5.2 makes readers accept only the keys of machines whose hardware quote has been checked. The mentor's note of 10 October (section 3) is the design: sign on write, verify on read.

## 2. The steps

| Step | What | State |
|---|---|---|
| 5.1.1 | records are signed with a test key, clearly labelled and never used in evidence | **Done on 15 October 2026** (section 3) |
| 5.1.2 | folder identity files bind each file to its folder (ADR-035) | **Done on 15 October 2026** (section 4) |
| 5.1.2b | the combined crawl with signing and folder binding on and required (`run14`) | **Done on 15 October 2026** (section 5) |
| 5.1.3 | the real key: generated per VM at boot, held by a small signing service, bound to the quote through REPORTDATA | **Done on 16 October 2026** (section 6) |
| 5.2.1 | readers accept only keys of attested machines | Open |
| 5.3 | locked image, fixed driver, TLS checking on | Open |

## 3. Step 5.1.1: signing the records with a test key

### 3.1 What it does

With signing switched on, the wrapper signs the record of every file it writes, and before it returns any byte of a file it checks the signature of that file's record. A record whose signature does not verify is **always** refused. With signatures required, a record in the old format is refused too, so a file that someone rewrote together with a matching record, without the key, fails the read. Everything is switched off by default: nothing changes until the site configuration says so.

### 3.2 The decisions, and where they come from

The note of 10 October answers the design but not these four choices. I took the recommended defaults on 15 October, the mentor not having answered them (ADR-044).

| Question | Answer | Source |
|---|---|---|
| What a record covers | the folder's ID, the file's name, the content hash and the length (not the full path); in 5.1.1 the signature covers the key id, chunk size, length and root, and 5.1.2 adds the folder ID and name | the mentor's note, section 3 |
| A test key is allowed | clearly labelled, never used in evidence | the mentor's note, B1 |
| Signature scheme | **ECDSA with P-256 and SHA-256**, built into the Java 11 on the cluster | default (ADR-044) |
| Old unsigned records | readable as legacy while `attested.signature.required` is off | default (ADR-044) |
| How the test key is labelled | its id always starts with `TEST-`, and a setting refuses test keys in the real-key mode | default (ADR-044) |
| The identity file's name | `_attested-folder` (the note requires only a `_` prefix); used from 5.1.2 | default (ADR-044) |

### 3.3 The record and what the signature covers

A record in the new format `ATTEST02` is the old `ATTEST01` record (8 bytes of header, chunk size, length, the Merkle root, the number of chunks and the 32-byte hash of every chunk) followed by a signature block: one byte for the key id's length, the key id, two bytes for the signature's length, and the signature (ECDSA P-256 with SHA-256, in DER, at most 200 bytes). The signed statement is a fixed tag, the key id, the chunk size, the length and the root; the root commits to every chunk hash, so the hashes need no second signature. Every field of the statement has a fixed length or a length in front of it, so two different records can never give the same bytes. The old format is still written when signing is off, byte for byte, and both formats are read. A test key's id is `TEST-` followed by the first 16 hex characters of the SHA-256 of its public key (21 characters); the key file holds the id, the public key and, for a key that can sign, the private key, with mode 600.

### 3.4 The settings and the rules

| Setting (core-site.xml only; job settings are ignored, ADR-039) | Default | Meaning |
|---|---|---|
| `attested.signature.enabled` | false | sign every record that is written |
| `attested.signature.required` | false | refuse a file whose record is not signed |
| `attested.signature.allow.test.keys` | true | accept records signed with a test key (the real key turns this off) |
| `attested.signature.test.key.file` | `~/tc-test-key/test-key.txt` of the user the JVM runs as | the test key file |

The rules: a signature that does not verify is refused whatever the settings say; a record signed by a key that is not trusted here is refused; a record signed with a test key is refused when test keys are not allowed; an unsigned record is refused only when signatures are required. Signing on without a key file, signing without records, and signing with a test key when test keys are not allowed all refuse to start. The audit log shows the result: `verify=ok sig=ok-test` on a read, `sidecar signed=<key id>` on a write, and `sign=`, `sigrequired=`, `testkeys=` and `key=` in the INIT line; our audit tools read the result with `verify=(\w+)`, so the new field cannot break them.

### 3.5 How it was built and tested

1. **In the sandbox**, against the real Hadoop 3.4.3 jars (a pack taken from the master) and at Java 11 level: the repository's own smoke test passes 141 of 141 with its own code and **167 of 167** with the change (26 new checks), the signing core passes **48 of 48** (40 runs without a failure), and deliberate breaks of the code are caught (four in the core, three in the integration).
2. **Kit 1** (`m511-test`, on the master, 15 October 07:42:09): the branch tip with the teammate's patch and ours in a scratch clone, tested with the repository's own `build-and-test.sh` and the core tests: fake mode 167 of 167, hash mode 18 of 18, **the real-HDFS mode 140 of 140 with the new code**, signing core 48 of 48 (`M511-TEST-OK`). The cluster was not touched.
3. **Kit 2** (`m511-build`, 07:56:00): the job built with ant in 36 s and compared with the job of 4.8.1: 6 classes changed, 6 are new, none unexpected (`JOB-DIFF-ONLY-THE-PATCH`); the wrapper jar `f20364cf2ba34639…` has 20 classes (14 installed now), and against the installed jar only our classes differ.
4. **Kit 3** (`m511-window`, the real cluster): the window described in section 3.7.

The rehearsals of the kits run the real scripts with the real wrapper code, over a local folder that plays HDFS where a cluster is needed. The first rehearsal found a flaky test of mine (the key id of a "wrong key" test was altered by replacing a letter that a random id sometimes does not contain); it was made deterministic before anything ran on the cluster (mistake log 102).

### 3.6 The demonstration on the real HDFS

On 15 October at 08:28:26 the demonstration wrote a file through the wrapper and then played the attacker with the plain client, which the wrapper cannot stop. Every read through the wrapper failed, with the right reason:

| Attack (behind the wrapper's back) | The wrapper's answer |
|---|---|
| 1. only the file changed | chunk 0 (hash does not match the record) |
| 2. the file and an unsigned record | the record is not signed and signatures are required |
| 3. the file and a record with the old signature copied | the signature of the record does not verify |
| 4. a record signed with the attacker's key under the real key id | the signature of the record does not verify |
| 5. a record signed with the attacker's key under its own key id | the record is signed by a key that is not trusted here |
| 6. the record deleted, the file kept | the file has no record |
| 7. a new file with no record at all | the file has no record |

The audit log held exactly 7 new `VERIFY-FAIL` lines. The honest file and its record read before the attacks and again after they were undone. An offline check of a local copy with the public key only (`M511Tools verify`: signature, chunk hashes and length) accepted the honest copy and found the forgery of attack 4.

### 3.7 The window, and what the measurement covers

Putting the signed wrapper on the cluster changes what Hadoop runs, so it was done in a **window**: the cluster reserved with `tc-busy.sh` (08:19:47), then on each node the installed jar and `core-site.xml` saved, the test key made on the master and copied to the worker, the new jar installed atomically, the measured settings plus three signature settings applied with `cluster-mode.sh` (from a state folder of its own), and the daemons restarted (master open 08:19:47, worker open 08:26:04). After the demonstration each node was restored (master close 08:29:48, worker close 08:33:32): the installed jar `027f29942fe2a69d…` and `core-site.xml` `1c335707555b2427…` are byte for byte the saved ones, the signature settings are no longer in effect, and the measured-set check printed `ALL-UNCHANGED` (9 components on the master, 6 on the worker). The window lasted 14 minutes.

**Nothing from the window is covered by the measurement** (ADR-029): the nodes were not the measured stack while it was open. The measured stack was restored and proved, so the shared client in `/opt/tc-shared` and the measurement stay consistent (ADR-045).

### 3.8 Limits and what stays open

- Signing is off by default, and an unsigned record is accepted as legacy unless signatures are required: a downgrade is accepted until the setting is on (the demonstration ran with it on).
- A status question (a file's length) reads only the record's header and does not check the signature; reading the content does.
- The signature of format `ATTEST02` does not cover the file's name or folder: a signed file and its record copied into another folder or under another name still verify with that format. Step 5.1.2 (section 4) closes this with a new record version, `ATTEST03`.
- The key is a test key, in a file readable by the cluster user on both nodes; it stays there until the combined run and must be deleted afterwards.
- No crawl ran with signing on. Step 5.1.2 changes the record format again, so one combined crawl after 5.1.2 tests signing and folder identity under a real workload; the MapReduce test of the wrapper with signing on runs in a scratch build at every stage.
- Files written by the signed wrapper have records that the measured (old) wrapper cannot read; the data of a window is test data.

### 3.9 Evidence and commits

| Item | Value |
|---|---|
| Code commit | `240df4dca` (9 files: 6 new, 3 modified), exactly the files that were built, tested and run |
| Kit commit | `efc4a730f` (17 files: the three kits under `ops/kits/m511-test`, `m511-build` and `m511-window`) |
| The patch that was tested | `2406f0d0838a6ec5…` (9 files, against branch tip `0b2a7f28e`) |
| Kit zips that ran | `m511t` `95999705…`, `m511b` `4450659a…`, `m511w` `8ad79a9d…` |
| Evidence bundle (outside the repository, `MATCH` on the laptop) | `evidence-m511.tar.gz` (`391d383e…`, 39 files): the test bundle `a746144e…`, the build bundle `7bbb0020…`, the demonstration bundle `ed9efcb4…`, the consoles of both nodes and the window folders |
| The files that ran are the files committed | the nine source files in the tree on the master that was built and run equal the source package `1c9cedc1…` (`SOURCE-IDENTICAL`) |

### 3.10 Lessons

- A test of something random must not depend on the random value's content, and such tests are run many times (mistake log 102).
- A passing fault test must be checked for passing for the right reason, and every fault variable is reset between scenarios (mistake log 103).
- When I say that I am preparing a file, I deliver it in the same reply or say that it follows (mistake log 104).


## 4. Step 5.1.2: binding every file to its folder

### 4.1 What it does

A signed record proves who signed it, not where the file lives: with `ATTEST02` a file and its record could be copied into another folder, or under another name, and still verify. Step 5.1.2 closes this. Every folder gets a small signed identity file, every record names the folder and the file it belongs to, and a read checks the whole chain up to the top folder. A file in the wrong folder, under the wrong name, or in a folder that was copied, renamed or tampered with behind the wrapper's back fails the read. Everything is off by default, like step 5.1.1.

### 4.2 The design

| Part | What it is |
|---|---|
| The identity file | a signed file `_attested-folder` in every folder that the wrapper makes or adopts: a random 16-byte folder ID, the folder's own name, and either its parent's ID (a child) or its full path (a top folder, the root of a wrapper-managed tree); signed with ECDSA P-256 under the same key as the records |
| The record `ATTEST03` | the `ATTEST02` record plus the 16-byte ID of the folder the file is in and the file's name, both covered by the signature |
| What a read checks | the record's signature, that it names this file and the ID of this folder, and every identity up to the top: each verifies, names the folder it sits in and points at the identity of its parent, and the top identity is for the folder's own full path |
| A file rename | signs one new record for the new folder and name from the old record, with no data read, after the old record's signature and binding were checked (a forged record is never signed again) |
| A folder rename | signs only the folder's own identity file again (the same folder ID, the new name and parent); the files and folders inside are untouched |
| The reserved name | `_attested-folder` cannot be created, renamed or deleted through the wrapper, and listings made through the wrapper do not show it |
| Which folders get an identity | folders made through the wrapper, and folders that the wrapper writes into (it adopts them); a folder is a top folder only when no ancestor has an identity, otherwise the unidentified folders in between are adopted as children, so the shape never depends on timing |
| Two writers at once | the first identity file written wins, and the other writer reads it |
| The cache | identity files are cached per process for the metadata cache time (10 s by default) |

| Setting (core-site.xml only; job settings are ignored, ADR-039) | Default | Meaning |
|---|---|---|
| `attested.folder.binding.enabled` | false | write records bound to folders and give folders identities; needs signing, records and hashing |
| `attested.folder.binding.required` | false | refuse a file whose record is not bound to its folder (an older format); a bound record is always checked whatever this says |

### 4.3 How it was built and tested

1. **In the sandbox**, against the real Hadoop 3.4.3 jars at Java 11 level: the smoke test passes **214 of 214** (167 of step 5.1.1 plus 47 for folder binding), the signing core **73 of 73** (25 new checks), and the demonstration tools 22 of 22. The tests include every attack of the mentor's list that moves or copies signed files, played with the plain client, and thirteen deliberate faults of the binding are caught (the folder ID, the file name, the top path, the folder's own name and the parent link are never compared; a rename that signs without checking the old record; a folder rename that does not sign again; the reserved name; binding never required; an identity signature that is not checked; and three for the race and the adoption below).
2. **Three scratch runs on the master** (the kit `m512-test`, which touches nothing on the cluster): run 1 (13:30:40) **failed** in the real-HDFS mode, which found a difference between the real HDFS and my local fake (section 4.4); run 2 (14:00:54) passed (`M512-TEST-OK`: the fake mode 214 of 214, the hash test 18 of 18, **the real-HDFS mode 212 of 212**, the signing core 73 of 73); run 3 (14:12:20) added a mode `mr-bound` that runs Hadoop's real output committer with signing and folder binding on and required, and passed **16 of 16**.
3. **The build** (`m512-build`, 14:24:43): the job `6f98295641a4f559…` (134,868,431 bytes, built in 33 s) differs from the job of step 5.1.1 in exactly 9 changed and 6 new classes with none unexpected, and the wrapper jar `ca96be26b8748125…` has 26 classes (20 in step 5.1.1) and differs from the 5.1.1 jar only in our classes.
4. **The window** (`m512-window`, the real cluster): sections 4.5 and 4.6.

### 4.4 What the real HDFS showed

The first scratch run failed in the race test (four writers making the same new folder at once), and looking into it found two things.

- **The error of the loser.** A writer that loses the race to create an identity file gets, on the real HDFS, "already being created by another client" and not "file exists", so it failed. The wrapper now looks at what is there after any failure to create and uses the winner's identity. My local fake always gave "file exists", which is why the sandbox never showed it; it now behaves like the real HDFS for a loser, with all racers trying at the same moment.
- **A design flaw, found while making that fake exact.** A late writer that found its parent folder without an identity (because another writer was still signing it) guessed that its own folder was a top folder. A top identity binds a folder to its full path, so a top folder nested in an identified tree breaks when an ancestor is renamed, which is what Hadoop's output committer does. Waiting longer would not fix a guess, so the rule is now deterministic (section 4.2).

### 4.5 The demonstration on the real HDFS

On 15 October at 15:46:12 the demonstration made a tree `seg1`, `seg2` with a file in each through the wrapper, and verified a local copy of the whole tree offline with the public key only (3 folders, 2 files). The honest operations worked: a file renamed into another folder got a record signed again for the new folder and name, and a folder rename signed only the folder's own identity file again (the same folder ID, the new name) with the record inside byte for byte unchanged. Then the attacker, with the plain client, behind the wrapper's back:

| Attack | The wrapper's answer |
|---|---|
| 1. two same-named files swapped between the two folders | both reads fail: the record belongs to another folder than the one this file is in |
| 2. a file and its record copied under another name in the same folder | the read fails: the record is for a file named 'part-r-00000', not 'copy-of-a' |
| 3. a file and its record moved into another folder | the read fails: the record belongs to another folder |
| 4. a whole folder copied elsewhere | the read fails: its identity names another folder name |
| 4b. a folder copied under another parent with the same name | the read fails: its identity points to the old parent |
| 5. another folder's identity planted in seg1 | the read fails: the identity names another folder |
| 6. the identity file deleted | the read fails: the folder has no identity |
| 7. seg1's identity signed with the attacker's key under the real key id | the read fails: the signature of the folder identity does not verify |
| 8. a folder renamed behind the wrapper's back | the read fails (its identity names the old name), and the wrapper refuses to sign that folder again when asked to rename it |
| 9. an unsigned file added to a folder | the read fails: the file has no record |
| 10. a forged record (right folder, right name, the attacker's signature) | the wrapper refuses to rename the file (it would sign the forged record again), and the read fails: the signature of the record does not verify |

That is 12 refused reads and 2 refused renames, with exactly 14 new `VERIFY-FAIL` lines in the audit log. After each attack the honest state was put back, the honest reads were logged as `verify=ok sig=ok-test bind=ok`, and the tree verified offline again at the end. The demonstration's folder was removed.

### 4.6 The window

The same method as in step 5.1.1 (ADR-045): the cluster reserved with `tc-busy.sh` (15:38:12), on each node the installed jar and `core-site.xml` saved, the new jar installed atomically and the measured settings plus five applied (signing on and required, test keys allowed, folder binding on and required) with `cluster-mode.sh`, the daemons restarted (master open 15:38:12, worker open 15:41:51; the test key of step 5.1.1 was already on both nodes). After the demonstration each node was restored (master close 15:52:15, worker close 15:56:23): the installed jar `027f29942fe2a69d…` and `core-site.xml` `1c335707555b2427…` are byte for byte the saved ones, the signature and binding settings are no longer in effect, and the measured-set check printed `ALL-UNCHANGED` (9 components on the master, 6 on the worker). **Nothing from the window is covered by the measurement** (ADR-029).

### 4.7 Limits and what stays open

- Folder binding is off by default, and a record in an older format is accepted as legacy unless `attested.folder.binding.required` is on; files of step 5.1.1 (`ATTEST02`) are unbound.
- A change made behind the wrapper's back is seen within the identity cache time (10 s by default), not at once.
- A top folder is bound to its full path: renaming a folder above a top folder through the wrapper does not sign it again.
- The identity files cannot be created atomically with the folder: a writer that crashes while writing one can leave an empty file, which fails closed.
- No crawl ran with signing and folder binding on: the combined crawl follows in a second window, and `nn_audit_compare.py` must treat `_attested-folder` like a record file before that.
- Files written by the new wrapper have records that the measured wrapper cannot read; the data of a window is test data.

### 4.8 Evidence and commits

| Item | Value |
|---|---|
| The patch that was tested | `f1904142168e8193…` (9 files, against branch head `9f4409d44`) |
| The code commit | `feat(attested): bind every file to its folder with signed folder identities and ATTEST03 records (step 5.1.2)` (9 files: 2 new, 7 modified), exactly the files that were built, tested and run |
| The kits commit | `feat(ops): add the test, build and window kits of the folder binding (step 5.1.2)` (17 files: `ops/kits/m512-test`, `m512-build`, `m512-window`) |
| Evidence bundles (outside the repository) | the three scratch runs (`88b8901b…` failed, `0f1ecf02…`, `9dbaf244…`), the build `08149b8b…`, the demonstration `5e0ff5ff…`, with the consoles of both nodes and the window folders |
| The files that ran are the files committed | the nine source files in the tree on the master equal the source package (`SOURCE-IDENTICAL`) |

### 4.9 Lessons

- When code handles an error that depends on the real system, the fake must produce the real system's errors, and a planted fault must show that the test catches the missing handling (mistake log 105 and 107).
- A structural fact (top or child) is decided by a rule that does not depend on timing; waiting longer does not fix a guess (mistake log 106).
- A planted fault that survives means a missing test: two survived in the first set of binding tests and became two tests (mistake log 108).


## 5. The combined crawl (`run14`, 15 October 2026)

### 5.1 What it is

One real crawl with the job of step 5.1.2, with signing and folder binding **on and required** on both nodes, in a reserved window, to see what happens when a real Nutch job writes through the wrapper in this mode: every file it writes, including everything that Hadoop's output committer moves between folders, must end with a signed record bound to its folder. It is the crawl command of the earlier runs with receipts on (run 12's settings), started by `m512c-run.sh` after it had checked that the window was open, the cluster reserved, the test key present, the job exactly `6f98295641a4f559…` and the policy file the verified one. Right after the crawl the script made a copy of the whole output with the plain client and verified it **offline with the public key only**.

### 5.2 What ran

| Item | Value |
|---|---|
| The window | the cluster reserved at 18:29:57, the master opened at 18:30:22, the worker at 18:33:07, the master closed at 18:58:04, the worker at 19:01:55 (about 32 minutes, `ALL-UNCHANGED` 9 and 6 after the closes) |
| The crawl | started 18:37:50, finished with exit code 0 after 770 s |
| The listings | 3,409 paths before the crawl and 3,802 after (393 added); the NameNode's audit window has 10,011 events |
| The offline verification | the seeds folder: 1 folder, 1 file, clean; the crawl output: **55 folders and 60 files, all clean**; the plain copy held 175 files (60 data files, 60 record files and 55 identity files, 1,260 KB) |

### 5.3 What the analysis found

The analysis (`m512c-analyze.sh`, in Cloud Shell, read-only) ran the standard checks with the committed tools of commit `5bedce243` and two of them replaced by the updated versions of this step (section 5.4):

| Check | Result |
|---|---|
| The audit comparison | `AUDIT-CLEAN`: 393 added, all explained by the wrapper's log |
| The expected records | `RECORDS-COMPLETE`: 61 files judged, 61 with a matching record |
| The verification summary | `VERIFY-CLEAN`: 265 opens |
| The NameNode comparison | `NN-AUDIT-COMPARE-CLEAN`, with 27 folders made with their identity file explained; the negative control (the biggest wrapper log removed) reports 108 findings, so the comparison can fail |
| Every verified read | **265 reads with `sig=ok-test` and `bind=ok`**, none with `sig=none` or `bind=none`, and no `VERIFY-FAIL` line in any audit log |
| The identity files | 57 identity files in the after listing (55 in the crawl output, the rest in other folders that the wrapper made during the run) |

**One finding:** "no task logs from the worker". It is a gap in my kit, not in the wrapper. The earlier runs' worker packs held the YARN task logs (`userlogs`) next to the wrapper logs, and version 1 of the worker script packed only the wrapper logs. They could not be added afterwards: the NodeManager deletes the old container logs when it restarts, which the window's close does; version 2 of the script, with a `repack` that adds the task logs of the applications started during the window, found none. The task logs are not part of any check of this step, so run 14 was not repeated for them; its analysis ends with this one finding, explained (limitations row 106). Version 2's `pack` takes the task logs during the window and refuses to pack without them.

### 5.4 The tools

Folder binding changes what the NameNode shows, so two analysis tools were updated and tested before the run: `nn_audit_compare.py` skips the NameNode's opens of `_attested-folder` files (like those of record files) and explains a NameNode `mkdirs` only when the wrapper's log shows the creation of the identity file in that very folder (the wrapper makes the missing folders of a file's path itself and does not log that `mkdirs`); `records_expected.py` treats an identity file as a companion of the data, not as data. Their tests pass 46 of 46 and 7 of 7, with negative controls, and planted faults are caught. The run showed the first rule at work: 27 folders explained, nothing else excused. Limitations row 99 is resolved.

### 5.5 What it does not show

- One run: no timing claim is made. Run 14 (770 s) is not a controlled pair with run 12 (709 s, a wrapped crawl) or run 13 (672 s, a plain control): different jobs and settings, and timing pairs follow the method of ADR-041 in Milestone 6.
- The signing key is a test key, and nothing from the window is covered by the measurement (ADR-029).
- The data of the run (`/user/rishabsdp17/crawl-run14` and `seeds-run14`, about 1.3 MB) stays in HDFS with `ATTEST03` records that the measured wrapper cannot read; it is readable only in a window (limitations row 107).
- The teammate's verifier has still not been run on an export of this run.

### 5.6 Evidence and commits

| Item | Value |
|---|---|
| The tools commit | `fix(ops): treat the folder identity files like record files in the analysis tools (step 5.1.2)` (4 files under `ops/attested/`, with their tests) |
| The kit commit | `feat(ops): add the combined crawl kit (run, worker and analysis scripts with their rehearsals)` (`ops/kits/m512c`, both versions of the worker script) |
| Evidence (outside the repository) | the run's folder with its fingerprints and verification results, the consoles of both nodes and of the windows, the worker pack (`0e8ed9ee…`), the repack attempt and both analyses; the two consoles of the self-test of the kit on the master |
| The files that ran | on the cluster: `m512c-run.sh` (master), `m512c-worker-v1.sh` and `audit.sh` (worker), `m512c-analyze.sh`, `nn_audit_compare.py` and `records_expected.py` (Cloud Shell, which printed the fingerprints of the two tools), `M512Tools.java` (compiled and used by the run), and the `repack` of `m512c-worker.sh` (its `pack` has not run on the cluster); they are byte for byte the files of the kits that were delivered (`ad55e910…` and `c33c9bd0…`). The three rehearsal scripts, `M512ToolsTest.java`, `M512TreeGen.java` and the two test files were run on the master afterwards, in a self-test of the final kit (`b5dc7eb3…`) on 15 October at 19:59: all six results pass (22 of 22, 46 of 46, 7 of 7 and the three rehearsals). The first self-test, at 19:47, had failed in the rehearsal of the run script, which read the master's real configuration through `HADOOP_HOME`; the rehearsal was made hermetic (mistake log 111) |

### 5.7 Lessons

- A claim about what a restart keeps must be checked before it is relied on for evidence (mistake log 109).
- A rehearsal fixture is made from what the script produces, not from the shape of an older run (mistake log 110).
- A rehearsal must be hermetic against the environment of the machine it runs on, and its first run on the real machine is a test of the test (mistake log 111).


## 6. Step 5.1.3: the real signing key (`run15`, 16 October 2026)

### 6.1 What it does

Until now the signing key was a **test key**: a file on both nodes, which anybody who could read the file could copy and use. Step 5.1.3 replaces it, for real runs, by a key that no file ever holds. On each VM a small **signing service** makes the machine's key when it starts and keeps it in memory only; it signs on request over a loopback socket and dies with its process. The hardware then vouches for the key: the service asks for a TDX quote whose `REPORTDATA` field is the SHA-512 of a short **key statement** (the key id, the public key, the host, the time and a random nonce), exactly the rule that `attest/quote.sh` and `attest/verify-binding.sh` already use. The result is a **key bundle** (the statement and the quote). A reader trusts a key only if its bundle is in its **key list** and passes the checks (ADR-047 to ADR-049).

### 6.2 The design

| Part | What it is |
|---|---|
| The signing service (`KeyService`, in the wrapper jar) | a process of its own on each VM: the key (ECDSA P-256) is made at start and never written; a loopback socket with a token; it signs only the three statement formats of the wrapper and only for its own key id, so it is not a general signing oracle; every request is logged (time, result, a short digest, never the statement or the signature) |
| The key bundle (`KeyBundle`, `*.attestkey`) | the statement and the quote; the key id is `TDX-` and 16 hex digits of the SHA-256 of the public key; a TDX key is never made without its quote; a service key without a quote (`SVC-`) exists for tests only |
| The key list (`KeyList`, `BundleCheck`) | a folder of bundles; a bundle is trusted only if the key id is the hash of the public key and the quote's `REPORTDATA` is the SHA-512 of the statement; a key without a quote is refused unless the list says otherwise; an extra check class (`attested.keys.list.check.class`) is the hook where step 5.2.1 verifies the quote's signature chain and the measurements |
| The wrapper's side (`ServiceKeys`, `AttestedKeyFactory`) | one new setting; signing goes to the service, public keys come from the list; reading needs only the list, writing needs the service and fails closed with a message that names the service |
| The key tool | `bundle-info` and `bundle-verify` |

| Setting (core-site.xml only, ADR-039) | Default | Meaning |
|---|---|---|
| `attested.keys.provider` | `test` | `test` is the test key of step 5.1.1; `service` is the real key |
| `attested.keys.service.address` | none | `HOST:PORT` of the local signing service (needed to sign) |
| `attested.keys.service.token.file` | `~/tc-keyservice/token` | the token of the service |
| `attested.keys.list.dir` | `~/tc-keys/list` | the key list |
| `attested.keys.list.allow.unquoted` | false | accept `SVC-` keys (tests only) |
| `attested.keys.list.cache.seconds` | 10 | how long the list is kept before it is read again |

### 6.3 How it was built and tested

1. **In the sandbox:** 68 core checks (bundle, service, key list, the signed formats, a restart, eight threads at once), 21 new wrapper-level checks in the smoke test (real service and list; attacks with a test key, with another machine's real key that is not in the list, and with one flipped bit; the service stopped; a restart; a key without a quote), the signing core still 73 of 73, and 18 planted faults, all caught (the first run found three blind spots in my own tests, which were fixed).
2. **On the master, in a scratch clone** (the kit `m513-test`, 08:46:09): the fake-mode smoke test **235 of 235**, Hadoop's real committer with signing and binding **16 of 16**, the hash test **18 of 18**, **the real HDFS 233 of 233** (the 212 of step 5.1.2 plus the 21 new checks), the signing core **73 of 73**, the key core **68 of 68**.
3. **The build** (`m513-build`, 08:47:30): the job `3a55e21d17c07d78…` (134,891,448 bytes, built in 34 s) differs from the job of step 5.1.2 in 4 changed and 6 new classes, none unexpected; the wrapper jar `36324a608d9d1a2c…` has 32 classes (26 before) and starts a throw-away signing service that makes a key bundle that verifies.
4. **The self-test of the window kit on the master** (11:03 to 11:05, read-only): six parts, all passing (the offline verifier and bundle extraction 11 of 11, the key exchange, the analysis, the run script, the window script and the worker script, with their planted faults).

### 6.4 The window

The cluster was reserved at 11:17:03. The master was opened at 11:17:42 and its signing service started at 11:18:43 with the key `TDX-428f3734fdb03238`; the worker was opened at 11:27:50 and its service started at 11:28:50 with the key `TDX-5fdb825500807c66`. On each VM the hardware quote is **8,000 bytes**, its `REPORTDATA` equals the SHA-512 of the key statement (our check, and `attest/verify-binding.sh` says `MATCH`), and the service answered on `127.0.0.1:7461` with its token. At 11:36:43 the two bundles were exchanged in Cloud Shell and checked there again (`M513-SYNC-OK`; a first attempt had stopped safely because Cloud Shell had no `xxd`). On the laptop, go-tdx-guest's `check` verified the Intel signature chain of **both quotes**. The master was closed at 12:11:27 and the worker at 12:14:20: each signing service was stopped (its key disappeared with it), its port closed, the measured jar and settings restored byte for byte, `ALL-UNCHANGED` 9 and 6. **Nothing from the window is covered by the measurement** (ADR-029).

### 6.5 The crawl `run15`

| Item | Value |
|---|---|
| The crawl | started 11:46:59, exit code 0 after 736 s, with signing and folder binding on and required, the keys from the signing services, test keys not allowed |
| The listings | 3,806 paths before and 4,036 after (230 added); the NameNode's audit window has 8,551 events |
| The offline verification against the key list | the seeds folder (1 file) clean; the crawl output (**55 folders and 60 files**) clean; the plain copy held 175 files (1,264 KB) |
| The keys in the output | the tree was signed by exactly **2 keys**, the master's and the worker's, both in the key list |
| The negative control | with only the master's bundle in the list, the worker's files are refused (**13 findings, not trusted here**) |
| The services | the master's signed **180** statements and the worker's **436**, neither refused any, both with a hardware quote |
| The analysis | `M513C-ANALYSIS-CLEAN`: `AUDIT-CLEAN` (230 added), `RECORDS-COMPLETE` (61 of 61), `VERIFY-CLEAN` (211 opens), `NN-AUDIT-COMPARE-CLEAN` (27 folders made with their identity), every one of the **211 verified reads with `sig=ok` and `bind=ok`**, none with a test key, no `VERIFY-FAIL`, and the worker's task logs present (671 files) |

### 6.6 What it does not show

- The signing service runs under the same user as the fetcher in this first window: the key is in no file, but a compromised fetcher could read the service's memory and could ask for signatures while the service runs (limitations row 109).
- The key list is a folder that the node trusts; the wrapper does not itself verify the quote's signature chain or the measurements (rows 110 and 111): the chain of both quotes was verified on the laptop. Step 5.2.1 builds this into the list through the hook.
- One crawl only: no timing claim (row 116).
- The data of the run (`/user/rishabsdp17/crawl-run15` and `seeds-run15`, about 1.3 MB) stays in HDFS (row 115).
- The worker script's `pack` stopped by mistake and the pack of this run was made by hand (row 114).

### 6.7 Evidence and commits

| Item | Value |
|---|---|
| The patch that was tested | `2534afa5b62423fc…` (10 files, against branch head `ee6571e6f`) |
| The code commit | `feat(attested): the real signing key: a signing service, key bundles bound to the hardware quote, and a key list (step 5.1.3)` (10 files: 7 new, 3 modified), exactly the files that were built, tested and run |
| The kits commit | `feat(ops): add the test, build and window kits of the real key (step 5.1.3)` (`ops/kits/m513-test`, `m513-build`, `m513-window`) |
| Evidence bundles (outside the repository) | the test and build on the master (`evidence-m513`, `dc5a1d93…`), the self-test of the window kit (`evidence-m513w-selftest`, `a667b5a9…`), and the window, the run, the exchange, the analysis and the laptop's quote check (`evidence-run15`, `9cd82ec0…`, 292 files) |
| The files that ran | the ten source files in the tree on the master equal the source package (`SOURCE-IDENTICAL`); the scripts that ran on the cluster are the files of the kit zips that were delivered (`m513tb` `5f45dcc4…`, `m513w` `c483f023…`); the rehearsals ran in the self-test on the master; the worker script's `pack` ran on the cluster for the first time and stopped by mistake |

### 6.8 Lessons

- A rehearsal fixture must be as large as the real thing: a check of a big archive that failed because of a broken pipe never showed on a small one (mistake log 114).
- A tool needed by a step must be checked on every machine that runs the step, not only on the nodes (mistake log 113).
- A helper used by a test must be compiled by the script that compiles the test (mistake log 112), and a script must look at the folder of the step that it belongs to (mistake log 115).
