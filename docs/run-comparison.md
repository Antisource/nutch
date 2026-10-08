# Comparison of the runs

Run 1 ([run-1-pilot.md](run-1-pilot.md)) used hand-typed commands on 2 October 2026. Run 2
([run-2-scripted.md](run-2-scripted.md)) used the committed scripts on 3 October 2026. Same cluster,
same crawler, same seeds, same cap.

Runs 3 and 4 (5 October 2026) are compared with run 2 in section 9, run 5 (6 October, over the WireGuard mesh) in section 9.1 and run 6 (6 October, through the hdfs:// wrapper) in section 9.2. This file was renamed from comparison-run1-run2.md on 6 October 2026.

## Contents

- [1. Side by side](#1-side-by-side)
  - [Inputs](#inputs)
  - [Process](#process)
  - [Outputs](#outputs)
- [2. What this shows](#2-what-this-shows)
- [3. What differs, and why that is expected](#3-what-differs-and-why-that-is-expected)
- [4. What the evidence shows, and what it does not](#4-what-the-evidence-shows-and-what-it-does-not)
- [5. Observations that affect the trust discussion](#5-observations-that-affect-the-trust-discussion)
- [6. Limits of this comparison](#6-limits-of-this-comparison)
- [7. How the comparison was done](#7-how-the-comparison-was-done)
- [8. Next steps for the evidence](#8-next-steps-for-the-evidence)
- [9. Runs 3 and 4 (added 6 October 2026)](#9-runs-3-and-4-added-6-october-2026)
  - [9.1 Run 5 over the mesh (added 6 October 2026)](#91-run-5-over-the-mesh-added-6-october-2026)
  - [9.2 Run 6 through the hdfs:// wrapper (added 6 October 2026)](#92-run-6-through-the-hdfs-wrapper-added-6-october-2026)
  - [9.3 Run 7 with hashing (added 7 October 2026)](#93-run-7-with-hashing-added-7-october-2026)
  - [9.4 Run 8 with verified reads (added 7 October 2026)](#94-run-8-with-verified-reads-added-7-october-2026)

## 1. Side by side

### Inputs

| Input | Run 1 | Run 2 | How compared |
|---|---|---|---|
| Packaged crawler (`apache-nutch-1.22.job`) | built 2026-10-02 12:50:04 | same file, not rebuilt | `JOB-IDENTICAL` |
| `conf/nutch-site.xml` | committed `5635894b7` | same | `SAME` |
| Seed file | 57 bytes, hash `14a80f8c8eaa…` | same bytes | `SEEDS-IDENTICAL`, `SAME` |
| Public suffix list | downloaded, uncommitted | same file | `SAME` |
| Four Hadoop config files | identical on both nodes | identical on both nodes, same as run 1 | `SAME` (x4), `CONFIGS-IDENTICAL` |
| Helper library commits | `13118882ddfe…`, `38efccdc1ec1…` | same, recorded again | manifest |
| Crawl options | as in [cluster-configuration.md](cluster-configuration.md) | same, via `ops/run-crawl.sh` | script echo in the log |

### Process

| Aspect | Run 1 | Run 2 |
|---|---|---|
| How commands were issued | Typed by hand | Committed scripts at commit `441cb333c21b…` |
| Manifest | Built by hand, free layout | `make-manifest.sh`, fixed layout |
| Quote | `report0` folder, hand-made `reportdata` file | `quote.sh`: unique `req-…` folder, removed on exit |
| Binding check | Inline shell comparison | `verify-binding.sh` |
| Extra manifest fields | none | `libcld2` version, `scripts_repo_commit`, hashes of the four scripts |
| Duration of crawl | about 11 minutes | about 10 minutes |
| Deduplication job | 43,585 ms | 42,808 ms |

### Outputs

| Output | Run 1 | Run 2 |
|---|---|---|
| Segments | 3 (`20261002…`) | 3 (`20261003…`) |
| `pages/` records | 8 response, 8 metadata, 3 warcinfo | 8 / 8 / 3 |
| `diagnostics/` records | 2 / 2 / 3 | 2 / 2 / 3 |
| `robotstxt/` | 3 warcinfo only | 3 warcinfo only |
| Fetch attempts | 10 | 10 |
| Pages fetched | 8 URLs | the same 8 URLs (`SAME-PAGES`) |
| Redirects | two 301s (Einstein, Marilyn Monroe) | the same two |
| Fetching machine | `tdx-lab-worker` | `tdx-lab-worker` |
| WARC file names and hashes | `NUTCH-CRAWL-20261002…`, hash values differ | `NUTCH-CRAWL-20261003…`, hash values differ |
| Quotes | two, 8000 bytes, `MATCH` | two, 8000 bytes, `MATCH` |

## 2. What this shows

1. **The procedure is repeatable.** The same inputs gave the same page set, the same redirect behaviour and the same
   counts, one day apart.
2. **The scripts reproduce the hand-typed result.** Run 2's structure matches run 1's.
3. **The cap is reached exactly.** Both runs used all 10 attempts, so a longer run would have continued; the
   cap is a ceiling that was fully used.
4. **The crawler binary is the same artefact.** The job file was not rebuilt, so run 2 used the identical bytes.

## 3. What differs, and why that is expected

- **WARC files are not byte-identical.** Each file carries fetch timestamps, record ids and the fetch time, so hashes
  differ even when the pages are the same. Compare structure (record types, counts, URLs), not file hashes.
- **Segment ids and WARC file names embed the date and time.**
- **Manifests differ** in layout, in the date, and in the fields run 2 added.

## 4. What the evidence shows, and what it does not

| Claim | Supported? |
|---|---|
| The 64 bytes inside each quote equal the SHA-512 of its manifest | **Yes**, checked by the shell for all four quotes |
| Changing a manifest breaks that match | **Yes, tested.** One changed byte in run 2's master manifest gave `MISMATCH` (exit code 2) against the original quote. See [quote-verification.md](quote-verification.md). Not repeated on the worker |
| Each quote is a genuine Intel-signed statement from a TDX Trust Domain | **Yes, for all four quotes.** go-tdx-guest `check` verified each one, also with certificate data and revocation checks. A one-bit change to a quote makes its signature fail |
| The manifest lines are true | **No.** They are text written by a script on the VM. A quote vouches for a hash, not for the author's honesty |
| The boot measurements (MRTD, RTMRs) are the expected ones | **Examined, not judged.** MRTD is identical on all four quotes; RTMR0 to RTMR2 differ between the nodes. Without a reference value for the cloud's virtual firmware they cannot be judged |
| The pages came from the real websites | **No.** A TEE protects computation, not the network path. The WARC digests and headers are written by the crawler |
| The recorded time is correct | **No.** The clock is supplied by the host |
| The crawl stayed within the seed sites | **No, and it did not.** It fetched `www.zyte.com` in both runs |

## 5. Observations that affect the trust discussion

These feed the limitations and challenges table (still to be written):

1. Both nodes run different kernels (`6.8.0-1067-gcp` and `6.8.0-1069-gcp`) from the same image family. RTMR0, RTMR1 and RTMR2
   differ between the nodes while MRTD is identical, so a verifier cannot assume a single expected measurement for a
   cluster. The kernel difference may explain part of it, but naming the differing boot events needs the boot event log,
   which was not examined. Neither VM rebooted between the runs, so equal values across runs are expected.
2. Hadoop traffic between nodes crosses a network the host controls, and `default-allow-internal` opens every port
   between instances.
3. The helper libraries are built from moving snapshots, so their commit ids must be recorded or builds drift.
4. A downloaded file (the suffix list) sits outside version control; only its hash in the manifest accounts for it.
5. The WARC records show `WARC-IP-Address: 0.0.0.0` in the record read, so the server address is not captured there.
6. Unexpected `entry…` folders existed in the master's configfs-tsm report directory. Other software on the node can
   also request quotes, so a quote shows that a TD produced a statement, not which program asked for it.
7. TDX VMs cannot live-migrate, so unannounced stops are possible. Evidence must not live only on a VM disk.

## 6. Limits of this comparison

- Two runs, a day apart, against two practice sites that are static and built for crawling. The same stability
  may not hold on real sites.
- Run 2 file sizes were not captured, so sizes are compared only for run 1.
- Both runs used one operator, one cluster, and one fetch machine.

## 7. How the comparison was done

Comparisons were made by the shell, never by eye:

```bash
# inputs between runs, matched by file name
for f in nutch-site.xml seed.txt effective_tld_names.dat apache-nutch-1.22.job \
         core-site.xml hdfs-site.xml yarn-site.xml mapred-site.xml; do
  a=$(grep -E "[ /]$f\$" ~/evidence/master/manifest-master.txt | cut -d' ' -f1)
  b=$(grep -E "[ /]$f\$" ~/evidence-run2/master/attest-run2/manifest-master.txt | cut -d' ' -f1)
  [ -n "$a" ] && [ "$a" = "$b" ] && echo "SAME  $f" || echo "DIFF  $f"
done

# same pages fetched
U='/^WARC-Type:/{t=$2} /^WARC-Target-URI:/{ if(t=="response") print $2 }'
diff <(zcat warc-out/pages/*.warc.gz | tr -d '\r' | LC_ALL=C awk "$U" | sort) \
     <(zcat warc-out-run2/pages/*.warc.gz | tr -d '\r' | LC_ALL=C awk "$U" | sort) && echo SAME-PAGES

# identical Hadoop config and scripts across the two nodes of run 2
diff <(grep 'hadoop/etc' master/attest-run2/manifest-master.txt) \
     <(grep 'hadoop/etc' worker/attest-run2/manifest-worker.txt) && echo CONFIGS-IDENTICAL
```

## 8. Next steps for the evidence

1. Done: all four quotes verified with go-tdx-guest's `check` on a machine with no Google credentials.
2. Done: MRTD and RTMR values extracted and compared (see [quote-verification.md](quote-verification.md)).
3. Add a URL filter to keep the crawl inside the seed domains, and put the filter file's hash into the manifest.
4. Done: the limitations table and better-TEE assessment are in [limitations-and-trust.md](limitations-and-trust.md); its "Next experiments" list holds the remaining ideas.

## 9. Runs 3 and 4 (added 6 October 2026)

Run 3 is the clean baseline of [milestone-0-clean-baseline.md](milestone-0-clean-baseline.md); run 4 is the crawl on the measured stack of [milestone-1-code-measurement.md](milestone-1-code-measurement.md).

| Item | Run 2 | Run 3 | Run 4 |
|---|---|---|---|
| Date and duration | 3 Oct, about 10 minutes | 5 Oct, 09:52 to 10:03 | 5 Oct, 17:56 to 18:07 |
| HTTP client plugin (master's crawl log, 19 jobs) | `protocol-http` in 19, okhttp in 0 | okhttp in 19, `protocol-http` in 0 | same configuration and job as run 3; the log was not re-counted |
| `store.ip.address` | not set | true | true |
| Job file | SHA-256 `88161b64126a` | rebuilt, SHA-256 `bbd30ad90d35` | the run 3 file (no rebuild; its SHA-384 `f993fd407ab5` is in the master's measured log) |
| `WARC-IP-Address` | `0.0.0.0` | real: 8 page records and 2 diagnostics records | real: the same eight URL and address pairs as run 3 |
| Pages fetched | 8 | the same 8 URLs (`SAME-PAGES`) | the same 8 URLs (`SAME-PAGES`) |
| Kernel during the run | master 6.8.0-1067, worker 6.8.0-1069 | same | master 6.17.0-1022, worker 6.8.0-1069 |
| Measured stack | none | none | master: 10 events in RTMR3 before the crawl; all ten digests unchanged afterwards |
| WARC files | 9 | 18 (9 `.warc.gz` and 9 `.cdx.gz`) | 18 |
| Evidence | `evidence-run2` | `evidence-run3.tar.gz` | `evidence-run4.tar.gz` |

What this shows: the two configuration fixes changed the client and filled in the server addresses without changing which pages were fetched, and a measured stack on a newer kernel produced the same page list and addresses.

What it does not show:
- The comparison is by URL and address, not by page content or WARC bytes.
- `JOB-IDENTICAL` cannot be repeated between run 3 and earlier runs, because the configuration is inside the job file.
- The same two practice sites plus one external site, one operator, one cluster: the same limits as section 6.
- That okhttp ran inside the worker's tasks (see milestone 0, section 4).

### 9.1 Run 5 over the mesh (added 6 October 2026)

Run 5 repeats run 3's crawl after the WireGuard mesh and host firewall were added ([milestone-2-wireguard-mesh.md](milestone-2-wireguard-mesh.md)).

| Item | Run 3 | Run 5 |
|---|---|---|
| Date and duration | 5 Oct, 09:52 to 10:03 | 6 Oct, about 08:17 to 08:27 |
| Node-to-node traffic | ordinary network | through the WireGuard tunnel (master sent 3,915.2 MB during the crawl) |
| Job file | the run 3 build | the same file (no rebuild) |
| Pages fetched | 8 | the same 8 URLs (`SAME-PAGES`) |
| `WARC-IP-Address` | `toscrape` pages `35.211.122.109`; `www.zyte.com` `216.150.1.193` | `toscrape` pages the same; `www.zyte.com` `216.150.16.1` |
| WARC files | 18 | 18 |
| Plugin lines in the master's log | okhttp 19, old 0 | okhttp 19, old 0 |
| Worker task logs | gone by the time they were checked | not deleted: 22 list okhttp, 0 list the old plugin |
| Evidence | `evidence-run3.tar.gz` | `evidence-run5.tar.gz` |

What it shows: moving the nodes' traffic onto the mesh and closing the ordinary interface did not change which pages were fetched. What it does not show: the same limits as sections 6 and 9; and the changed address of one external site is a property of that site (it is served from a pool of addresses).

### 9.2 Run 6 through the hdfs:// wrapper (added 6 October 2026)

Run 6 repeats the crawl of run 5 with every HDFS request of the Nutch jobs going through the wrapper ([milestone-3-hdfs-wrapper.md](milestone-3-hdfs-wrapper.md)).

| Item | Run 5 | Run 6 |
|---|---|---|
| Date and duration | 6 Oct, about 08:17 to 08:27 | 6 Oct, first segment 13:42, finished 13:52:41 |
| HDFS access of the crawl's programs | the plain HDFS client | through `AttestedHdfsFileSystem` and `AttestedHdfs` (both lookups) |
| Driver | `ops/run-crawl.sh` | `ops/run-crawl-attested.sh` (the same plus three `-D` settings) |
| Job file | `bbd30ad90d357ca1`, 1029 entries | `ddc415a5d87c9e6b`, 1033 entries; the four extra entries are the wrapper's classes, nothing else differs (nested jars compared by content) |
| Pages fetched | 8 | the same 8 URLs (`SAME-PAGES`) |
| WARC files | 18 | 18 |
| `WARC-IP-Address` | `toscrape` pages `35.211.122.109`; `www.zyte.com` `216.150.16.1` | the same pairs |
| Page content (payload fingerprints) | | 7 of 8 identical; `www.zyte.com` differs |
| Crawl database (total, unfetched, fetched, redirects) | 257, 247, 8, 2 | 259, 249, 8, 2 |
| Plugin lines in the master's log | okhttp 19, old 0 | okhttp 19, old 0 |
| Worker task logs | 22 list okhttp, 0 the old plugin | 22 and 0 |
| HDFS byte counters in job reports | 27 read and 27 written lines; largest read 32,527 | 27 and 27; largest read 32,533 |
| YARN applications | 27 (numbers 0002 to 0028) | 27 (0029 to 0055) |
| Storage audit | | `AUDIT-CLEAN`: 187 added, 0 removed, 0 changed, all explained by the wrapper's log |
| Evidence | `evidence-run5.tar.gz` | `evidence-run6.tar.gz`, `evidence-run6-audit.tar.gz` |

**The one different page.** `www.zyte.com` has a different content fingerprint, and the crawl database has two more discovered URLs.

- Runs 3, 4 and 5 (no wrapper) have identical fingerprints for that page (`sha1:SOKCP57…`) and identical crawl databases; run 6 is the first to differ.
- The page shows why. Its deployment identifier changed from `dpl_Aw3cvvrezTgDVzNUPQtGSiZL7Jng` (fetched 08:24:52) to `dpl_6K3MMTWXqBLaBfG2FGJjgYif2oA4` (fetched 13:50:01), with new stylesheet file names. The live site at 14:37 serves the newer identifier.
- The new page has two more links that are not build assets (`/mcp/`, `/skills-and-plugins/`), which matches the two extra URLs in count; they were not traced individually.

What it shows: routing the crawl's storage requests through the wrapper did not change what the crawler fetched or how it counted it; the one difference comes from the website. What it does not show: a contemporaneous unwrapped run was not done, so the explanation rests on the control runs and the page's own evidence; and the same limits as sections 6 and 9 apply.

### 9.3 Run 7 with hashing (added 7 October 2026)

Run 7 repeats the crawl of run 6 with every file written through the wrapper also hashed when it is closed (observe only; nothing is verified). Report: [milestone-4-storage-integrity.md](milestone-4-storage-integrity.md), section 9.

| Item | Run 6 | Run 7 |
|---|---|---|
| Date and duration | 6 Oct, 13:41:59 to 13:52:41 (10 min 42 s) | 7 Oct, 07:25:08 to 07:35:51 (10 min 43 s) |
| What the wrapper does | forwards and logs | forwards, logs, and hashes every file at close (SHA-256 per 16,384-byte chunk, Merkle root) |
| Job file | `ddc415a5d87c9e6b`, 1033 entries | `8fdd7cdadd6a7e11`, 1036 entries; against the measured run 5 job: 7 more entries (the wrapper's folder and six classes), nothing else differs |
| Pages fetched | 8 | the same 8 URLs (`SAME-PAGES`) |
| Page content (payload fingerprints) | | 7 of 8 identical; `www.zyte.com` differs |
| Crawl database (total, unfetched, fetched, redirects) | 259, 249, 8, 2 | 259, 249, 8, 2 |
| Plugin lines in the master's log | okhttp 19, old 0 | okhttp 19, old 0 |
| Worker task logs | 22 list okhttp, 0 the old plugin | 22 and 0 |
| Storage audit | `AUDIT-CLEAN` (963 to 1150 paths) | `AUDIT-CLEAN` (1182 to 1369 paths) |
| Records | none | 54 of 54 files left under the crawl folder have a matching record; an independent re-hash agrees on all 54 |
| Evidence | `evidence-run6.tar.gz`, `evidence-run6-audit.tar.gz` | `evidence-run7.tar.gz`, `evidence-run7-audit.tar.gz` |

**The one different page.** `www.zyte.com` again has a new content fingerprint (run 6 `sha1:N6BMXVA...`, run 7 `sha1:Z4NYZYD...`). Its deployment identifier changed from `dpl_6K3MMTWXqBLaBfG2FGJjgYif2oA4` (fetched 6 Oct 13:50:01) to `dpl_J25tWhywpx6QetrVxFP7wgdX7PPC` (fetched 7 Oct 07:33:11), and the live site at 07:55 served the newer one. The page's links, apart from build assets, are the same. What it shows: hashing every written file did not change what the crawler fetched or how it counted it; the difference comes from the website. Not repeated for this run: the `WARC-IP-Address` check and the HDFS byte counters.

### 9.4 Run 8 with verified reads (added 7 October 2026)

Run 8 repeats the crawl with a record kept next to each file and every read checked against it. Report: [milestone-4-storage-integrity.md](milestone-4-storage-integrity.md), section 10.

| Item | Run 7 | Run 8 |
|---|---|---|
| Date and duration | 7 Oct, 07:25:08 to 07:35:51 (10 min 43 s) | 7 Oct, 09:16:02 to 09:26:59 (10 min 57 s) |
| What the wrapper does | forwards, logs, hashes at close | the same, keeps a companion record next to each file, and verifies every read against it |
| Job file | `8fdd7cdadd6a7e11`, 1036 entries | `a092d5fab91d4b73`, 1041 entries; five new classes and three changed classes, nothing else differs |
| Pages fetched | 8 | the same 8 URLs (`SAME-PAGES`) |
| Data files fetched for the evidence | 18 | 18, each with a hidden companion file |
| Page content (payload fingerprints) | | 7 of 8 identical; `www.zyte.com` differs |
| Crawl database (total, unfetched, fetched, redirects) | 259, 249, 8, 2 | 259, 249, 8, 2 |
| Plugin lines in the master's log | okhttp 19, old 0 | okhttp 19, old 0 |
| Worker task logs (the 27 applications of the run) | 22 and 0 | 22 list okhttp, 0 the old plugin, 0 a verification failure |
| Storage audit | `AUDIT-CLEAN` (1182 to 1369 paths) | `AUDIT-CLEAN`: 1377 to 1699 paths, 322 added, all explained |
| Records and companion files | 54 of 54 files have a record | 54 of 54 have a record and a companion file; the independent re-hash agrees on all 54 |
| How reads were verified | not applicable | 157 opens: 156 verified, 1 without a record (the seed file), 0 verification failures |
| Evidence | `evidence-run7.tar.gz`, `evidence-run7-audit.tar.gz` | `evidence-run8.tar.gz`, `evidence-run8-audit.tar.gz` |

**The one different page.** `www.zyte.com` differs once more (run 7 `sha1:Z4NYZYD...`, run 8 `sha1:XX7YZPKK...`). Its deployment identifier changed from `dpl_J25tWhywpx6QetrVxFP7wgdX7PPC` (fetched 7 Oct 07:33:11) to `dpl_2HdZ2H4ohADyL4QEFsb3pBbNMGvT` (fetched 09:24:12), and the live site at 12:06 served the newer one. What it shows: keeping records and verifying reads did not change what the crawler fetched or how it counted it. Not repeated for this run: the `WARC-IP-Address` check and the HDFS byte counters.

### 9.5 A condition from the mentor (7 October 2026)

Runs 6 to 8 were not paired with an unwrapped control in the same hour: run 6 was compared with run 5, which had been made hours earlier, and runs 7 and 8 were compared with run 6 and with each other. The mentor accepted this evidence and said that from Stage B on the unwrapped control is run in the same hour, with wall time and bytes fetched recorded for each pair (ADR-028). The three durations above (10 min 42 s, 10 min 43 s and 10 min 57 s) are therefore first timings, not a performance result. Since 8 October 2026 the NameNode's audit log is also on (cluster-configuration.md section 15), which runs 6 to 8 did not have, so later runs differ from them in that respect too.
