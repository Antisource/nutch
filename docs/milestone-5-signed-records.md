# Milestone 5: signed records

Status: **step 5.1.1 is done on 15 October 2026**: every record can be signed with a labelled test key, and the mentor's pass condition for the step ("a file rewritten together with its record, without the key, fails the read") is shown on the real HDFS. Steps 5.1.2, 5.1.3, 5.2 and 5.3 are open ([milestone-plan.md](milestone-plan.md)). Written when step 5.1.1 closed; it is extended as the later steps close. All times are UTC.

## 1. What this milestone does, in plain words

Until now every file in HDFS has a tamper sticker, its record. The sticker proves little, because anyone who can write the file can also rewrite its record. Milestone 5 replaces the sticker with a **signature**: a stamp that only a holder of the key can make. Step 5.1 gives each machine a signing key and ties every file to its folder, and step 5.2 makes readers accept only the keys of machines whose hardware quote has been checked. The mentor's note of 10 October (section 3) is the design: sign on write, verify on read.

## 2. The steps

| Step | What | State |
|---|---|---|
| 5.1.1 | records are signed with a test key, clearly labelled and never used in evidence | **Done on 15 October 2026** (section 3) |
| 5.1.2 | folder identity files bind each file to its folder (ADR-035) | Open |
| 5.1.3 | the real key: generated per VM at boot, held by a small signing service, bound to the quote through REPORTDATA | Open |
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
- The signature does not cover the file's name or folder yet: a signed file and its record copied into another folder or under another name would still verify. Step 5.1.2 closes this with a new record version.
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
