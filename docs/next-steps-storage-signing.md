# Storage integrity: decisions and next steps

Written 2026-10-10 by Pingshan's assistant, for Rishab. It records the decisions Pingshan made after milestone 4.6 and replaces the parts of the handoff they supersede. Code references are to your branch at commit `d4d520f`, which I read but did not run. Your later fail-open fixes are not shared yet, so some items below may already be done.

## 1. The decision in one paragraph

Storage integrity rests on one mechanism only: **sign on write, verify on read, with the VM's signing key.** There are no per-task records, no job manifests, no per-file history and no folder tracking. Step 4.7 is dropped. The wrapper stays a plain file system layer with no Hadoop logic in it.

## 2. Threat scope for storage

| Attack | Status | Why |
|---|---|---|
| Tampering (changing stored bytes) | **In scope, must be prevented** | Puts attacker-chosen content into the corpus |
| Forgery (inserting a file no attested VM wrote) | **In scope, must be prevented** | Same |
| A validly signed file placed in a different folder or under a different name | **In scope, must be prevented** | It is a form of tampering with what a job reads. Hadoop names output files identically in every folder (`part-r-00000` and so on), so this would otherwise be trivial |
| Deletion (a file removed together with its record) | **Noteworthy, out of scope** | It removes data but cannot tamper with or insert data |
| Rollback (an older, validly signed file or folder put back) | **Noteworthy, out of scope** | Same reason. Only content that measured code genuinely produced can be replayed |

Deletion and rollback are to be written up together as known limits, with that reasoning. We looked at detecting deletion with a signed per-folder tracking file or ledger and decided against it. A single shared file serialises every writer in the folder and can itself be rolled back to an earlier version; per-writer ledgers avoid the contention but still need a sealing step to be complete. Neither is worth building for an attack that is out of scope. The folder identity file in section 3 is not delete tracking: it records what a folder is, not what is in it.

## 3. What the design is

1. **Folder identity.** When a folder is created, the wrapper gives it a random ID and writes a small signed identity file inside it. The identity file covers the **folder's ID, the folder's own name, and its parent folder's ID**. The top folder of the crawl binds to its full path instead of a parent.
2. **On write.** The wrapper hashes the bytes as they pass through its output stream and, when the file is closed, signs a record with the VM's key. The signed record covers the **folder's ID, the file's name, the content hash (your chunked Merkle root) and the length**. It does not contain the full path.
3. **On rename.** Renaming a file signs a new record for that one file. Renaming a folder re-signs only that folder's identity file; the files inside it and the folders below it are untouched. No data is re-read.
4. **On read.** Before any byte reaches the caller, the wrapper checks the record's signature, checks that the signing key belongs to an attested VM, checks that the record names this file and this folder's ID, checks the folder's identity against its parent up to the top, and verifies each chunk against the hash. Anything missing or mismatched fails the read. Identity files are small and can be cached per process.
5. **Trust in the key.** Each VM's key is bound to its TDX quote, and the quote covers the measured code, wrapper included.

```
 segments/2026.../crawl_fetch/
    _dir            signed: { folder id 7f3a.., name "crawl_fetch", parent id 91c2.. }
    part-r-00000    record signed: { folder id 7f3a.., name "part-r-00000", hash, length }
    part-r-00001    record signed: { folder id 7f3a.., name "part-r-00001", hash, length }
```

Why this shape: putting the full path in every record makes a folder rename re-sign every file under it, and Nutch renames whole folders (for example when it swaps in the new CrawlDb). Signing only the file name makes renames free but lets same-named files be swapped between folders. The folder identity keeps the binding and makes a folder rename one small write. It is how ordinary file systems keep renames cheap, and it does not depend on how CCBot lays out its folders.

Details to settle while building:
- Two tasks may create the same folder at the same moment. The first identity file written wins (create without overwrite); the other task reads it.
- Give the identity file a name that starts with `_` so Hadoop's input listing skips it, and hide it from listings the same way you hide the companion files.
- Folders that exist before the wrapper is in use (the crawl's top folder, the seed folder) need an identity file written by the driver at the start.

The argument for soundness is inductive: every VM runs measured code, that code only reads inputs that verify, so everything it writes derives from verified inputs. An outside verifier checks the final output files and does not re-walk the intermediate steps.

## 4. Where the current code stands

Read at `d4d520f`:

- **The interception level is right.** `HashingOutputStream` hashes every byte handed to the write calls and records on close, so byte-by-byte and line-by-line writers are covered. `VerifyingInputStream` verifies a whole chunk before returning any of it and handles seeks.
- **The wrapper is the cluster's own file system** (both lookups marked final in the site config), so the NodeManager's reads go through it.
- **Hadoop's contract tests were run** and found a real bypass (the builder forms of create and append), now fixed.

## 5. Next steps, in order

Each has a pass condition. The first block is the fail-open list; skip anything your unshared branch already does.

**A. Close the fail-open cases**

| # | Change | Pass condition |
|---|---|---|
| A1 | `append`, `concat` and `truncate` throw an error. Today append passes through unhashed and all three drop the record (`AttestedHdfsFileSystem.java` L751-L796) | A full crawl completes, showing Nutch needs none of them. A direct call fails |
| A2 | A file with no record fails the read. Today `attested.verify.missing` defaults to `warn` | Reading an unrecorded file fails. The seed file is signed by the driver at the start so the crawl still runs |
| A3 | The wrapper's own switches (`attested.hash.enabled`, `attested.verify.reads`, the missing and mismatch policies) cannot be changed by a job: mark them final in the site config, or remove them | A job submitted with `-D attested.verify.reads=false` still has its reads verified |
| A4 | Opening a file by path handle, and the accessor that returns the raw inner file system, are refused. I found no override for either in the main class | A direct call to each fails |

**B. Signing**

| # | Change | Pass condition |
|---|---|---|
| B1 | Records are signed. A test key is fine for now, clearly labelled, and never used in evidence | A file rewritten together with its record, without the key, fails the read |
| B2 | Folder identity files, and records bound to (folder ID, file name) | A signed file copied into another folder, with its record, fails the read there. So does a whole folder copied to another place or name. A folder rename writes one identity file and re-signs no file records (check the count in your operation log). A normal crawl, with Hadoop's commit renames and Nutch's folder moves, still passes |
| B3 | The real key: generated per VM at boot, held by a small signing service on the VM, bound to the quote through REPORTDATA | A record's key resolves to a quote that verifies off-cloud and whose RTMR3 replay matches the measured set |
| B4 | Readers accept only keys of attested VMs. Reusing the mesh's admission step (a peer is admitted after its quote is checked) is the obvious source of the accepted key list | A record signed by a key from outside the cluster fails the read |

**C. Evidence**

| # | What | Notes |
|---|---|---|
| C1 | Tamper demonstrations: flip a byte; replace a file and its record; move a signed file into another folder; swap two same-named files between folders; copy a whole folder elsewhere; add an unsigned file; sign with a non-attested key | All must be refused |
| C2 | Demonstrate the two documented limits honestly: delete a file with its record; put back an older signed copy at the same path | Both are expected to go undetected. Record them as such |
| C3 | Performance: wall time and bytes fetched for every wrapped and unwrapped pair, run in the same hour; then TDX against non-TDX VMs of the same shape | The mentor's view is that throughput overhead is the number readers look for |
| C4 | Review of what is readable or changeable outside the TEE: which keys exist, where they live, what crosses the VM boundary unprotected | The mentor named this as the most common way such systems fail. He also named a red-team harness in the meeting, which you noted |

## 6. What this supersedes in the handoff

| Handoff item | Now |
|---|---|
| A new `attested://` scheme | Replaced by swapping the implementation behind `hdfs://`, both lookups (done) |
| Commit hook writing a task record per attempt and a job manifest | Dropped |
| "All metadata from records" as a completeness mechanism | Keep the length check you built; no listing guarantee is claimed |
| VC3-style counts and completeness checks | Dropped with the records |
| Merkle log, witness, checkpoints | Deferred. The mentor's view is that the ledger is nice to have, not crucial |
| "Start" records before work | Dropped. They addressed rollback and re-run selection, now out of scope |
| A verifier that walks the chain back to the seed list | Replaced by a verifier that checks the final files: signature, key, quote, measurements, hash |

Unchanged: the WireGuard mesh, the measured image and RTMR3, plain TDX VMs with our own image, the fixed driver, and locking down the image.

## 7. Limits to state in the paper

- Deletion and rollback of stored data are not detected (section 2).
- Retries, duplicate attempts and re-runs are not visible. A provider can re-run a job and keep the run it prefers; every run is still genuine.
- An outside verifier cannot re-check intermediate steps. It trusts that measured code verified its own inputs.
- A bug in the wrapper's verification would not be caught by anything downstream. The wrapper is small and will be reviewed closely for this reason.
- Whether a website served truthful content is out of scope.
- TLS certificate checking is still off, pending Subhi's work (your ADR-002).

## 8. Other open items

- **Subhi's patch.** Per-fetch TLS evidence comes from Subhi's crawler patch. Build the job with it and re-measure. Coordinate this week.
- **Handoff corrections.** Apply them, together with section 6 above, in one commit with a corrections list at the top.
- **Deadline.** AAAI-27 workshop submissions are due to organisers by 20 November 2026 at the latest, and possibly mid-November. The accepted-workshop list is due by 16 October. Format is assumed to be 5 pages plus 2 until the new call says otherwise.
- **Please share the branch with the fail-open fixes**, so the review of the wrapper can start.
