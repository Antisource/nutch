# Run 1 (pilot): 10-URL crawl on a 2-node Intel TDX Hadoop cluster

Date: 2026-10-02 (UTC). This run was done with hand-typed commands, **before** the
scripts in `attest/` and `ops/` existed. Those scripts are re-implementations of the
same steps. They did not produce this run's evidence, and their manifests differ in
field order and wording.

Evidence files (manifests, quotes, WARC output, logs) are kept outside this repo,
in a Cloud Shell `evidence/` folder. Exact versions and hashes are in `manifest-master.txt`
and `manifest-worker.txt` there.

## Environment
- Master `tdx-lab` and worker `tdx-lab-worker`: GCP c3-standard-4 (4 vCPU, 16 GB),
  Intel TDX Confidential VMs, Ubuntu 22.04, zone us-central1-a.
- Kernels differ: master 6.8.0-1067-gcp, worker 6.8.0-1069-gcp.
- Hadoop 3.4.3 (the version pinned in `ivy/ivy.xml`), OpenJDK 11, HDFS replication 1.
- Master: NameNode + ResourceManager. Worker: DataNode + NodeManager. Daemons were
  started by hand (`hdfs --daemon start ...`, `yarn --daemon start ...`) after a single
  `hdfs namenode -format`.
- Code: this fork at commit `5635894b7` (`feat(config): ...`), built with `ant runtime`.
- `crawler-commons` and `language-detection-cld2` built from their latest snapshots with
  `mvn install -DskipTests`; commit ids are in the manifest.
- Public suffix list downloaded into `conf/effective_tld_names.dat` (not committed).

## Crawl command (run on the master inside tmux)
```bash
runtime/deploy/bin/crawl -s seeds --num-fetchers 1 --num-tasks 1 \
  --size-fetchlist 4 --num-threads 2 --time-limit-fetch 10 \
  -D mapreduce.map.memory.mb=2048 -D mapreduce.map.java.opts=-Xmx1536m \
  -D mapreduce.reduce.memory.mb=2048 -D mapreduce.reduce.java.opts=-Xmx1536m \
  crawl 3 2>&1 | tee ~/ccbot-work/crawl-run1.log
```
Seeds (in HDFS `seeds/seed.txt`): `https://books.toscrape.com/`, `https://quotes.toscrape.com/`.
Cap: at most 4 URLs per round and 3 rounds, with only the 2 seeds known in round 1,
so at most 2 + 4 + 4 = 10 fetch attempts.

## Results
- 3 rounds, about 11 minutes (13:17 to 13:28 UTC).
- `pages/`: 8 response records. `diagnostics/`: 2 response records (301 redirects for
  `quotes.toscrape.com/author/...`). `robotstxt/`: warcinfo records only.
- 8 + 2 = 10 fetch attempts, equal to the cap.
- All page files report `hostname: tdx-lab-worker`.
- The crawl left the seed domains and fetched `https://www.zyte.com/`.
- `WARC-IP-Address` is `0.0.0.0` in the records read.

## Evidence steps (also done by hand)
1. Copy WARC files out of HDFS with `hdfs dfs -get`; `sha256sum` each into `SHA256SUMS.txt`.
2. Write a manifest per node (code, config and output hashes).
3. Hash each manifest with SHA-512 into REPORTDATA and request a quote through
   `/sys/kernel/config/tsm/report/`.
4. Check that bytes 568..631 of the quote equal the manifest's SHA-512 (MATCH on both nodes).
5. Copy everything to Cloud Shell and re-check the hashes there.

## Not yet done at the time of this run
- Signature verification of the quotes with go-tdx-guest.
- Comparison of MRTD and RTMR values between the nodes.

## Notes
- Two `entry...` folders already existed under the configfs report directory before this run
  (dated days earlier). They were not created by these steps.