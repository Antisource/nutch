# Run 1 (pilot): 10-URL crawl on a two-node Intel TDX Hadoop cluster

Date: 2 October 2026 (UTC). Run 1 was done with **hand-typed commands**, before the scripts in
`attest/` and `ops/` existed. Those scripts re-implement the same steps. They did not produce run 1's
evidence, and their output differs in field order and wording. See
[comparison-run1-run2.md](comparison-run1-run2.md).

This file supersedes the earlier short version committed as `2aadecd86`; the old text stays in git history.

## 1. Goal

1. Run Common Crawl's Nutch fork ("CCBot") on Hadoop inside GCP Confidential VMs.
2. Crawl from 1 to 2 seed URLs with a cap of 10 URLs and inspect the WARC output.
3. Bind a manifest of the run to a TDX quote on each node, to see what attestation can and cannot show.

Environment details are in [cluster-configuration.md](cluster-configuration.md).

## 2. Timeline (UTC, 2 October 2026)

| Time | Event |
|---|---|
| 09:47 | First SSH into the master `tdx-lab` |
| 09:53 to 09:55 | Hello-world attestation exercise on the master (see section 4) |
| 10:27 | First login to the new worker `tdx-lab-worker`; ping to master 3/3 replies |
| 11:04 | Hadoop 3.4.3 downloaded and checksum-verified |
| 11:30 | `hdfs namenode -format`, then NameNode and ResourceManager started |
| 11:35 | Cluster report: 1 live DataNode, 1 running node |
| shortly after | Pi test job finished in 20.889 s |
| 12:41 | Public suffix list downloaded |
| 12:50 | `ant runtime` finished (6 min 30 s, `BUILD SUCCESSFUL`); job file stamped 12:50:04 |
| 13:12 | Seed file put into HDFS (`seeds/seed.txt`, 57 bytes) |
| 13:17 | Crawl started (first Hadoop job submitted 13:17:29) |
| 13:28 | `Finished loop with 3 iterations` (about 11 minutes) |
| 13:55 | WARC files copied from HDFS to the master's disk |
| 14:08 to 14:09 | Master manifest and quote |
| 14:18 | Worker manifest and quote |
| later | Evidence copied to Cloud Shell and re-verified |

## 3. Procedure

Each phase lists what was done and how success was checked.

1. **Access.** `gcloud auth login`, project `training-custody`, `gcloud compute ssh tdx-lab`.
   Check: `sudo dmesg | grep -i tdx` showed `tdx: Guest detected` and
   `Memory Encryption Features active: Intel TDX`; `/sys/kernel/config/tsm/report` existed.
2. **Worker VM.** Created with the same TDX flags. Check: `describe` showed
   `confidentialInstanceType: TDX`; the same `dmesg` lines appeared on the worker.
3. **Tools on both nodes.** `openjdk-11-jdk ant maven git libcld2-0 libcld2-dev`; host aliases in
   `/etc/hosts`. Check: `java -version` (11.0.32.1), `getent hosts`, pings both ways.
4. **Hadoop on both nodes.** Download, SHA-512 check (`MATCH`), unpack, environment variables, four
   configuration files, then start daemons by hand. Check: `jps`, `hdfs dfsadmin -report`,
   `yarn node -list`, Pi job.
5. **Build the crawler on the master.** Clone of the fork; `mvn install -DskipTests` for
   `crawler-commons` and `language-detection-cld2`; suffix list; `ant runtime`. Check:
   `BUILD SUCCESSFUL`; `runtime/deploy/apache-nutch-1.22.job` present.
6. **Configuration.** `conf/nutch-site.xml` written on a laptop, committed
   (`feat(config): enable WARC output and set crawler identity`), pushed, pulled on the master.
7. **Seeds.** Two practice sites made for crawling. Both `robots.txt` URLs returned HTTP 404 pages,
   meaning no published restrictions. Seed file copied to HDFS.
8. **Crawl** (inside `tmux`):

```bash
runtime/deploy/bin/crawl -s seeds --num-fetchers 1 --num-tasks 1 \
  --size-fetchlist 4 --num-threads 2 --time-limit-fetch 10 \
  -D mapreduce.map.memory.mb=2048 -D mapreduce.map.java.opts=-Xmx1536m \
  -D mapreduce.reduce.memory.mb=2048 -D mapreduce.reduce.java.opts=-Xmx1536m \
  crawl 3 2>&1 | tee ~/ccbot-work/crawl-run1.log
```

   The script echoes each Nutch command it runs, so the full option list can be confirmed from
   the log (`grep -m1 inject ~/ccbot-work/crawl-run1.log`).
9. **WARC extraction.** `hdfs dfs -get` of the `warc/`, `robotstxt/` and `crawldiagnostics/` folders of
   every segment into `~/ccbot-work/warc-out/{pages,robotstxt,diagnostics}`; SHA-256 of each file saved
   to `SHA256SUMS.txt`; `sha256sum -c` printed `OK` for all nine files.
10. **Manifests and quotes (by hand).** One manifest per node, SHA-512 of the manifest into REPORTDATA,
    quote requested through the kernel's configfs-tsm interface, binding checked (`MATCH` on both nodes).
11. **Evidence copy.** `gcloud compute scp` to Cloud Shell, `sha256sum -c` there (`OK`), Hadoop
    config hashes identical across the two manifests.

## 4. Hello-world attestation exercise (reference exercise from the mentor)

Run before the crawl, on the master, in `~/attest-lab`:

1. Wrote `output.txt` ("hello world from inside a TD at 1790934753").
2. Computed its SHA-512, converted to 64 raw bytes (`reportdata.bin`, size 64).
3. Created a request folder under `/sys/kernel/config/tsm/report/`, wrote the bytes to `inblob`,
   read `outblob` into `quote.bin` (8000 bytes at 09:55), removed the folder.
4. Compared bytes 568 to 631 of the quote with the SHA-512 of `output.txt`: identical.

The offset is not arbitrary. In the TDX quote v4 layout (as I recall it; verify against Intel's
specification) a 48-byte header precedes a 584-byte body, and REPORTDATA starts 520 bytes into the
body, so 48 + 520 = 568.

The tamper test (change one byte, re-check) and the copy of the files to Cloud Shell were reported done
by the operator; their output was not captured here.

## 5. Results

### 5.1 Crawl output

| Item | Result |
|---|---|
| Rounds and duration | 3 rounds; first job 13:17:29, loop finished 13:28:25 |
| Segments | `20261002131812`, `20261002132120`, `20261002132508` |
| `pages/` | 8 `response`, 8 `metadata`, 3 `warcinfo` records |
| `diagnostics/` | 2 `response`, 2 `metadata`, 3 `warcinfo` |
| `robotstxt/` | 3 `warcinfo` only (no robots.txt records; both sites returned 404 for it) |
| Fetch attempts | 8 + 2 = **10**, equal to the cap |
| Deduplication job | 43,585 ms |
| Errors | Every error counter in the final job summary was 0 |
| Fetching machine | Every page file reports `hostname: tdx-lab-worker` |

Pages fetched (8):

```
https://books.toscrape.com/
https://quotes.toscrape.com/
https://quotes.toscrape.com/tag/humor/page/1/
https://quotes.toscrape.com/tag/inspirational/page/1/
https://quotes.toscrape.com/tag/life/page/1/
https://quotes.toscrape.com/tag/love/page/1/
http://quotes.toscrape.com/author/Albert-Einstein/
https://www.zyte.com/
```

Unsuccessful fetches (2): `https://quotes.toscrape.com/author/Albert-Einstein` and
`https://quotes.toscrape.com/author/Marilyn-Monroe`, both HTTP 301. The Einstein redirect target
(note the `http://` scheme and trailing slash) appears among the 8 pages; the Marilyn Monroe target
does not, presumably because the cap was reached.

WARC file sizes (bytes):

| Round | `pages/*.warc.gz` | `crawldiagnostics` | `robotstxt` |
|---|---|---|---|
| 1 | 8,999 | 529 | 526 |
| 2 | 9,612 | 1,455 | 527 |
| 3 | 81,954 | 1,455 | 528 |

Each `warc/` folder also holds a small `.cdx.gz` file (an index of record positions, as far as I
know). The 81,954-byte file is much larger than the others, which fits the external page
(`zyte.com`) being fetched, though per-file contents were not itemised.

### 5.2 Anatomy of one WARC (first records of the first page file)

| Record | Content seen | Why it matters |
|---|---|---|
| `warcinfo` (13:18:37Z) | `operator`, `publisher`, `description`, `isPartOf` as set in `nutch-site.xml`; `hostname: tdx-lab-worker`; `software` naming this fork and branch; `robots: checked via crawler-commons 1.7-SNAPSHOT`; `format: WARC File Format 1.1` | Self-description. Every value is text the crawler wrote about itself |
| `response` (13:18:50Z) for `https://books.toscrape.com/` | `WARC-Target-URI`, `WARC-Date`, `WARC-Payload-Digest: sha1:...`, `WARC-IP-Address: 0.0.0.0`, then the server's `HTTP/1.1 200 OK` headers and the HTML | The core provenance facts. The digest is SHA-1 computed by the crawler, not signed. The IP address field holds `0.0.0.0` in the record read, so the server address was not captured there |

The page's own HTTP `Date` header (13:18:50 GMT) agreed with the WARC date.

### 5.3 Evidence and attestation

| Node | Manifest (UTC) | Quote | Binding check |
|---|---|---|---|
| Master | 14:08:41 | 8000 bytes, 14:09 | `MATCH` |
| Worker | 14:18:18 | 8000 bytes, 14:18 | `MATCH` |

The master manifest recorded: node, role, kernel `6.8.0-1067-gcp`, fork commit `5635894b757c…`,
`fork_uncommitted_files: 1` (the downloaded suffix list), helper-library commits, Hadoop and Java
versions, SHA-256 of `nutch-site.xml`, `seeds/seed.txt`, the suffix list, the `.job` file and the four
Hadoop config files, and the nine WARC hashes. The worker manifest recorded node, role, kernel
`6.8.0-1069-gcp`, versions, and the four Hadoop config hashes (identical to the master's).

Copies in Cloud Shell were re-hashed: `OK` for all files. Two unexpected folders,
`entry3751458786` and `entry613572852`, were already present under the master's configfs-tsm
report directory (owned by root, dated 27 September, provider `tdx_guest`). They predate this work
and were left alone.

## 6. Findings

1. **The cluster works across two TDX VMs.** The fetch ran on the worker (its hostname is in every file).
2. **The cap held, and was fully used:** exactly 10 fetch attempts.
3. **Nothing restricts the crawl to the seed sites.** It followed a link out to `zyte.com`.
4. **The WARC's provenance claims are self-reported.** Labels, hostname, digests and dates are written by the crawler.
5. **A matching binding shows consistency only.** It shows the quote's 64 bytes equal the manifest's hash. It does not
   show the quote is genuine until its signature is checked, nor that the manifest is true.
6. **The two nodes boot different kernels** (`-1067` and `-1069`) despite the same VM type and image family.
7. **The worker's disk is small** (about 5.4 GB usable by HDFS).

## 7. Not done in run 1

- Signature verification of the quotes (go-tdx-guest `check`).
- Extraction and comparison of MRTD and RTMR values between the two nodes.
- Any check that the pages came from the real websites (a TEE does not authenticate the network).

Mistakes and workarounds from this run are in [guide-pitfalls-and-lessons.md](guide-pitfalls-and-lessons.md).
