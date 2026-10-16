# Cluster configuration

This is the "specify the configuration of VMs for Hadoop" deliverable. Values come from command
output captured during the work. Times are UTC (the VMs run in UTC). Items marked *assumption* or *not captured* were not observed.

## 1. Nodes

| Item | Master `tdx-lab` | Worker `tdx-lab-worker` |
|---|---|---|
| Project and zone | `training-custody`, `us-central1-a` | same |
| Machine type | `c3-standard-4` (4 vCPU, 16 GB) | `c3-standard-4` |
| Confidential computing | `confidentialInstanceType: TDX` | same |
| Maintenance policy | `onHostMaintenance: TERMINATE`, `automaticRestart: true`, not preemptible | same |
| OS | Ubuntu 22.04.5 LTS | Ubuntu 22.04.5 LTS |
| Kernel | `6.8.0-1067-gcp` | `6.8.0-1069-gcp` |
| Boot disk | about 48 GB (`df` showed 49G, 44G free after installs) | about 9.6 GB (`df` showed 9.6G; 6.6G free after the Java install) |
| Last boot (`uptime -s`, UTC, read on 3 October) | 2026-09-22 18:49:27 | 2026-10-02 10:24:12 |
| Internal IP | `10.128.0.2` (alias `hadoop-master`) | `10.128.0.5` (alias `hadoop-worker`) |
| Hadoop roles | NameNode, ResourceManager, job submission | DataNode, NodeManager |
| Java | OpenJDK 11.0.32.1 | OpenJDK 11.0.32.1 |
| Hadoop | 3.4.3 | 3.4.3 |
| CLD2 library | `libcld2-0` (version `0.0.0-git20150806-9` as recorded on the worker) | same package installed |

Provisioning notes:

- The master existed before this work (created by the mentor). The worker was created with the
  same TDX flags. Only the tail of the creation command is visible in the screenshots, so the
  command below is as intended, not as captured:

```bash
gcloud compute instances create tdx-lab-worker \
  --machine-type=c3-standard-4 --zone=us-central1-a \
  --confidential-compute-type=TDX --maintenance-policy=TERMINATE \
  --image-family=ubuntu-2204-lts --image-project=ubuntu-os-cloud
```

- The worker's small disk looks like the default image size. The master's larger disk is presumably
  a creation-time choice by the mentor (*assumption*).
- TDX VMs cannot live-migrate, so Google stops them for host maintenance. Keep nothing important
  only on a boot disk. Evidence was copied to Cloud Shell for this reason.

## 2. Network

| Item | Observed |
|---|---|
| Network | `default` |
| Rules | `default-allow-icmp` (icmp), `default-allow-internal` (tcp 0-65535, udp 0-65535, icmp), `default-allow-rdp` (tcp 3389), `default-allow-ssh` (tcp 22) |
| Source ranges | *Not captured* |
| Node-to-node reachability | Ping both ways, 3 of 3 replies, 0% loss, round trip about 0.1 to 0.8 ms |

Hadoop ports were reachable only because `default-allow-internal` opens all ports between
instances. No Google firewall rule was added, and no Hadoop port was opened to the internet. (Host firewalls and a WireGuard mesh were added on 6 October 2026; see section 10.)
Hadoop traffic between the nodes crosses a network the cloud host controls (see the limitations in
[run-comparison.md](run-comparison.md)).

Host aliases were added to `/etc/hosts` on both nodes:

```
10.128.0.2 hadoop-master
10.128.0.5 hadoop-worker
```

## 3. Software provenance

| Component | Source and checks |
|---|---|
| Hadoop 3.4.3 | Version chosen from the `hadoop-*` dependencies in the fork's `ivy/ivy.xml` (all `rev="3.4.3"`). Tarball (491 MB) downloaded from Apache, SHA-512 compared with Apache's `.sha512` file: `MATCH` on both nodes |
| Nutch fork | `Antisource/nutch`, branch `cc`, identical to the upstream `cc` branch at fork time (0 commits ahead, 0 behind). Built with `ant runtime` (6 min 30 s, `BUILD SUCCESSFUL`) |
| `crawler-commons` | Built from its latest snapshot (`1.7-SNAPSHOT`) with `mvn install -DskipTests`; commit recorded as `13118882ddfe…` |
| `language-detection-cld2` | Built the same way; commit recorded as `38efccdc1ec1…` |
| Public suffix list | Downloaded into `conf/effective_tld_names.dat`; **not committed**; hash recorded in the manifests (`73c95828f5f6…`) |
| Packaged crawler | `runtime/deploy/apache-nutch-1.22.job`, hash `88161b64126a…`, built 2026-10-02 12:50:04 |

`-DskipTests` was a choice made to save time, not something the upstream README says.
The two helper libraries are built from moving snapshots, which is why their commit ids are
recorded: a later build may differ.

## 4. Hadoop configuration

The same four files, byte-identical (matching SHA-256) on both nodes. Each node reads its own copy.

| File | Property | Value |
|---|---|---|
| `core-site.xml` | `fs.defaultFS` | `hdfs://hadoop-master:9000` |
| | `hadoop.tmp.dir` | `~/hadoop-data/tmp` |
| `hdfs-site.xml` | `dfs.replication` | `1` (one storage worker) |
| | `dfs.namenode.name.dir` | `file://~/hadoop-data/namenode` |
| | `dfs.datanode.data.dir` | `file://~/hadoop-data/datanode` |
| `yarn-site.xml` | `yarn.resourcemanager.hostname` | `hadoop-master` |
| | `yarn.nodemanager.aux-services` | `mapreduce_shuffle` |
| | `yarn.nodemanager.resource.memory-mb` | `12288` |
| | `yarn.nodemanager.resource.cpu-vcores` | `4` |
| | `yarn.scheduler.maximum-allocation-mb` | `12288` |
| | `yarn.nodemanager.vmem-check-enabled` | `false` |
| `mapred-site.xml` | `mapreduce.framework.name` | `yarn` |
| | `yarn.app.mapreduce.am.env`, `mapreduce.map.env`, `mapreduce.reduce.env` | `HADOOP_MAPRED_HOME=~/hadoop` |

The paths in the table use `~` for brevity. The files contain the full home path. The memory
figures are starting values for a 16 GB node chosen by the author, not tuned values.

`hadoop-env.sh` additionally sets `JAVA_HOME=/usr/lib/jvm/java-11-openjdk-amd64`.

## 5. Daemon lifecycle

Daemons were started by hand, so no SSH trust between the nodes was needed.

```bash
# master, once ever (this erases HDFS if repeated)
hdfs namenode -format
# master
hdfs --daemon start namenode
yarn --daemon start resourcemanager
# worker
hdfs --daemon start datanode
yarn --daemon start nodemanager
```

Health after start-up (2 October 2026, about 11:35 UTC):

| Check | Observed |
|---|---|
| `jps` on master | `NameNode`, `ResourceManager` |
| `jps` on worker | `DataNode`, `NodeManager` |
| `hdfs dfsadmin -report` | Live datanodes (1): `10.128.0.5:9866` (`hadoop-worker`), configured capacity 9.51 GB, non-DFS used 4.10 GB, DFS remaining 5.40 GB, no missing or corrupt blocks |
| `yarn node -list` | 1 node, `hadoop-worker:44353`, `RUNNING` |
| Test job (`hadoop-mapreduce-examples pi 2 10`) | Finished in 20.889 s, 2 maps and 1 reduce, `Estimated value of Pi is 3.8` (too few samples for accuracy; it proves the cluster works) |

Daemons survived a dropped SSH session and a day of idle time (both were still running on 3 October).

**After a reboot or an outage (observed 5 October).** Daemons do not restart by themselves. The order that worked: on the master, `hdfs --daemon start namenode` then `yarn --daemon start resourcemanager`; on the worker, `hdfs --daemon start datanode` then `yarn --daemon start nodemanager`. Never repeat `hdfs namenode -format`. After the NameNode starts, HDFS stays in safe mode for up to a minute or two until the DataNode reports; do not force it off. If the master's ResourceManager is down for roughly 20 minutes or more, the worker's NodeManager gives up and exits (its log shows retries, then `SHUTDOWN_MSG`), so check `jps` on the worker and start it again.

## 6. Why two VMs

- The mentor chose two VMs for authenticity and to ease later scaling.
- Reasoning, not tested here: a single VM could run Nutch in local mode, since Nutch's `crawl`
  script switches to local mode when no `.job` file is present. A genuinely distributed Hadoop
  needs at least a master and a worker, which is two.
- Consequence for trust: every node of a cluster must itself be a TEE. One ordinary VM in the
  cluster would break the chain. Each node produces its own quote, so a verifier checks two.

## 7. Crawl job settings (identical in both runs)

| Option | Value | Effect |
|---|---|---|
| `-s <dir>` | HDFS folder with the seed file | Two seeds: `https://books.toscrape.com/`, `https://quotes.toscrape.com/` |
| `--num-fetchers` | `1` | One fetch task (one worker node) |
| `--num-tasks` | `1` | One reduce task |
| `--size-fetchlist` | `4` | At most 4 URLs selected per round |
| `--num-threads` | `2` | Two download threads, to be polite to the sites |
| `--time-limit-fetch` | `10` | Minutes allowed for fetching, a safety stop |
| `-D mapreduce.map.memory.mb` and reduce | `2048` | Container memory |
| `-D ...java.opts` | `-Xmx1536m` | Task heap |
| rounds | `3` | |

Cap arithmetic: round 1 can fetch only the 2 seeds, rounds 2 and 3 at most 4 each, so at most
2 + 4 + 4 = **10 fetch attempts**. Both runs reached exactly 10 (8 pages + 2 redirect records), so
the cap held but was also fully used.

Settings in `conf/nutch-site.xml` (committed): `http.agent.name`, `http.agent.url`,
`fetcher.store.warc=true`, and the `warc.export.*` labels (`operator`, `publisher`, `software`,
`description`, `isPartOf`). Defaults left unchanged and relevant to the output:
`warc.export.crawldiagnostics=true` and `warc.export.robotstxt=true` (separate WARC files for
unsuccessful fetches and robots.txt), `fetcher.store.robotstxt=false`, `fetcher.store.404s=false`,
`warc.detect.language=false`.

## 8. Known gaps

- The creation command, the firewall source ranges, and the master's disk-size decision were not captured.
- The memory settings were not tuned; no task failed, so no tuning data exists.
- Disk headroom on the worker is small (about 5.4 GB for HDFS). Larger crawls need a larger disk.

## 9. Changes since the first two runs (5 and 6 October 2026)

| Item | Master `tdx-lab` | Worker `tdx-lab-worker` |
|---|---|---|
| Kernel now running | `6.17.0-1022-gcp` since 2026-10-05 17:15:31 (one-time boot) | `6.17.0-1022-gcp` since 2026-10-05 18:47:47 (one-time boot) |
| Kernel after the next reboot | `6.8.0-1067-gcp` (pinned) | `6.8.0-1069-gcp` (pinned) |
| Added packages | `linux-image-6.17.0-1022-gcp`, `linux-modules-6.17.0-1022-gcp` (from Ubuntu 24.04's archive, checksums verified) | same |
| GRUB | `/etc/default/grub.d/zz-saved-default.cfg` (`GRUB_DEFAULT=saved`); saved entry names the old kernel; backup in `/root/grub-backup-1005` | same file; backup in `/root/grub-backup-20261005184601` |
| Boot disk snapshot | `tdx-lab-pre-kernel-1005` (50 GB disk, about 6.0 GB stored) | `tdx-lab-worker-pre-kernel-1005` (10 GB disk, about 2.35 GB stored) |
| Secure Boot | off | off |
| Boot method | UEFI, no initramfs (`GRUB_FORCE_PARTUUID`); kernel needs the disk and ext4 drivers built in | same |
| Measurement files | `/sys/devices/virtual/misc/tdx_guest/measurements/` (`mrtd`, `rtmr0` to `rtmr3`, ...) exists on 6.17 only | same |
| Boot event log | `/sys/firmware/acpi/tables/data/CCEL` (root-only, 262,144 bytes) | same |
| Scripts | measurement and replay scripts in the home folder; committed under `attest/measure/` | `worker-kernel-prep.sh`, `worker-post-boot.sh` and helpers in the home folder; committed under `attest/measure/` and `ops/` |
| Measured stack | 10 events in `~/rtmr3-events.tsv`; per-folder manifests in `~/measured` | 5 events; manifests in `~/measured` |

Notes:

- The `/sys/kernel/config/tsm/report` folder is in memory. After the master's first reboot it was empty: the two old `entry...` folders from 27 September were gone.
- The Hadoop tree (`~/hadoop`) is owned by the lab user. Its only changing folder is `logs/`; HDFS data lives in `~/hadoop-data`.
- A reboot zeroes RTMR3. After any reboot, the measurement scripts must be run again (milestone-1-code-measurement.md §7).
- The master's HDFS now also holds `crawl-run3`, `crawl-run4`, `seeds-run3` and `seeds-run4`.

## 10. Network after Milestone 2 (6 October 2026)

| Item | Master `tdx-lab` | Worker `tdx-lab-worker` |
|---|---|---|
| Ordinary address | `10.128.0.2` | `10.128.0.5` |
| Mesh interface `wg0` | `10.10.0.1/24`, UDP 51820 | `10.10.0.2/24`, UDP 51820 |
| Mesh files | `/etc/wireguard/` (private key mode 600, root; `wg0.conf` mode 600) | same |
| Package added | `wireguard-tools` (Ubuntu archive, no recommended extras) | same |
| `/etc/hosts` (Hadoop lines) | `10.10.0.1 hadoop-master`, `10.10.0.2 hadoop-worker`, and the two nodes' internal names mapped to `10.10.0.1` and `10.10.0.2` | same four lines |
| `/etc/hosts` backups | `/etc/hosts.before-mesh`, `/etc/hosts.before-names` | same |
| Host firewall (inbound) | accept loopback, established, `wg0`, UDP 51820, SSH, ping, metadata server; counted drop of the Hadoop ports; policy drop. Backup of the old rules `/root/iptables-before-mesh` | same |
| Hadoop sockets | ResourceManager and NameNode RPC on `10.10.0.1`; NameNode web page on all addresses | all daemons on all addresses |

Notes:

- Hadoop's configuration files are unchanged (the names in them resolve to the mesh). They are still identical on both nodes.
- The firewall rules are **not saved across a reboot**; `wg0` is enabled at boot. After a reboot, re-run the scripts in `ops/mesh/` (they are safe to re-run: the hosts step detects existing lines), then start the daemons in the order of section 5.
- Hadoop's node names matter: the worker must register under `hadoop-worker`. After any network change, check `yarn node -list` and run a small job.
- Undo (by hand): copy `/etc/hosts.before-names` and `/etc/hosts.before-mesh` back, `sudo iptables-restore < /root/iptables-before-mesh`, `sudo wg-quick down wg0`.
- Scripts: `ops/mesh/`; report: [milestone-2-wireguard-mesh.md](milestone-2-wireguard-mesh.md).

## 11. Storage wrapper after Milestone 3 (6 October 2026)

| Item | Value |
|---|---|
| Settings that put the wrapper in place (job configuration, passed as `-D` options by `ops/run-crawl-attested.sh`) | `fs.hdfs.impl=org.apache.nutch.attested.AttestedHdfsFileSystem`, `fs.AbstractFileSystem.hdfs.impl=org.apache.nutch.attested.AttestedHdfs`, `attested.audit.dir=/tmp/attested-audit` |
| Where the classes live | inside the Nutch job file (`org/apache/nutch/attested/`); no change to Hadoop's own folders or configuration |
| Hadoop's configuration files | unchanged; still identical on both nodes |
| Audit logs | `/tmp/attested-audit/<host>-<pid>-<start>.tsv` on each node, one per JVM; old logs are moved aside by `audit.sh rotate` to `/tmp/attested-audit-old/<time>/` |
| Not covered by the wrapper | Until step 4.6 (section 16): the NameNode, DataNode, ResourceManager and NodeManager daemons (the NodeManager reads the job file through plain HDFS), and the crawl script's two `hadoop fs` commands |
| Build location for run 6 | a scratch clone, `~/m3-build` (not measured); the measured tree `~/ccbot-work/nutch-cc` and its job (`bbd30ad90d357ca1`) were left untouched. Run 6's job is `ddc415a5d87c9e6b` |
| Known difference of the measured tree | until 9 October 2026 one untracked file, `conf/effective_tld_names.dat`, which is packed into the job and was copied into the scratch clone; it is tracked since commit `30cd062da` (section 17) |

How a wrapped crawl was run until step 4.6 (every step is a script in `ops/attested/`, `ops/run-crawl-attested.sh`; the procedure since then is in section 16):

1. On each node: `audit.sh rotate`. On the master: put the seeds into HDFS, then `audit.sh snapshot <file>` (the "before" listing).
2. On the master, in tmux, from the build clone: `ops/run-crawl-attested.sh <seeds> <crawl-folder>`.
3. When it finishes: `audit.sh snapshot <file>` (the "after" listing); on the worker, check the task logs before any daemon restart.
4. In Cloud Shell: copy both listings and both nodes' log folders, then `audit_compare.py before after logs --require-hosts tdx-lab,tdx-lab-worker`. The result is `AUDIT-CLEAN` or a list of unexplained changes.

Undo: run the original `ops/run-crawl.sh` (no wrapper); remove `/tmp/attested-audit` and `/tmp/attested-audit-old` on each node.
Report: [milestone-3-hdfs-wrapper.md](milestone-3-hdfs-wrapper.md).

## 12. Storage records after Milestone 4 (7 October 2026)

| Item | Value |
|---|---|
| Settings (defaults are in the code, so `ops/run-crawl-attested.sh` is unchanged) | `attested.hash.enabled` (true), `attested.hash.chunk.size` (16384), `attested.sidecar.enabled` (true), `attested.verify.reads` (true), `attested.verify.missing` (warn), `attested.metadata.check` (true), `attested.metadata.mismatch` (fail), `attested.metadata.cache.seconds` (10), `attested.records.dir` (`/tmp/attested-records`) |
| Record logs | `/tmp/attested-records/<host>-<pid>-<start>.tsv` on each node, one per JVM; old logs are moved aside by `ATTESTED_AUDIT_DIR=/tmp/attested-records audit.sh rotate` to `/tmp/attested-records-old/<time>/` |
| Companion files | hidden files `.NAME.attested` beside every file written through the wrapper; plain HDFS tools list them, the wrapper's listings hide them; Hadoop's input formats skip names that start with a dot |
| Audit log | each OPEN line ends with `verify=ok`, `verify=missing`, `verify=skipped`, `verify=off` or `verify=bypassed`; a refused read writes `VERIFY-FAIL`; a metadata finding writes `META-FAIL`, `META-MISSING` or `META-ORPHAN` (step 4.5); the start-up line shows the settings |
| Build and test folders (not measured) | `~/m3-build` (the build clone, kept under its Milestone 3 name), `~/m4-b1` and `~/m4-b2` (unpacked test zips); jobs `8fdd7cdadd6a7e11` (run 7) and `a092d5fab91d4b73` (run 8), saved as `job-run7.job` and `job-run8.job` in `~/evidence-m3` |
| Not covered | as in section 11, and `copyToLocalFile` and opening by path handle are not verified |

How a verified crawl is run: section 15 of [milestone-4-storage-integrity.md](milestone-4-storage-integrity.md).

Undo: pass `-D attested.verify.reads=false -D attested.sidecar.enabled=false -D attested.hash.enabled=false`, or run the original `ops/run-crawl.sh`; remove `/tmp/attested-records` and `/tmp/attested-records-old` on each node. Companion files already in HDFS can stay (Hadoop's input formats ignore them) or be removed with `hdfs dfs -rm`.

## 13. Contract tests (7 October 2026, step 4.4)

| Item | Value |
|---|---|
| What it does | Hadoop's file-system contract tests run twice against the real HDFS, through the plain client and through the wrapper, and are compared (`ops/attested/contract-tests.sh`, `contract_compare.py`) |
| Test folder in HDFS | `/user/rishabsdp17/contract-tests-m44`; created and deleted by the tests; the script refuses to start if it exists, and both script and contract class refuse any folder that is not dedicated |
| Settings (environment) | `ATTESTED_CONTRACT_URI` (default `hdfs://hadoop-master:9000`), `ATTESTED_CONTRACT_DIR`, `ATTESTED_JOB` (the job file that supplies the wrapper), `EXPECT_JOB` (job fingerprint prefix), `EXPECT_FILES` (list of file fingerprints), `HADOOP_HOME` |
| Libraries | `hadoop-common-3.4.3-tests.jar`, `junit-4.13.2.jar` and `hamcrest-core-1.3.jar` from `~/hadoop/share/hadoop`; `assertj-core-3.12.2.jar` downloaded by the script into `~/contract-libs` (sha1 checked) |
| Build and output folders | `~/contract-build` (compiled classes); results in `~/evidence-m3/contract-m44` and the sensitivity run in `~/evidence-m3/contract-m44-sensitivity-run8-job`; the unpacked test zip is `~/m44b` (scratch, not measured) |
| Wrapper logs of the tests | in the output folder (`audit-wrapped`, `records-wrapped`), not in `/tmp/attested-audit` |
| Jobs | `dea47c6d41729bef` (the fixed wrapper, saved as `job-m44.job`) and run 8's `a092d5fab91d4b73` for the sensitivity run |

Run: `EXPECT_JOB=<job fingerprint> EXPECT_FILES=<list> ATTESTED_JOB=<job file> ops/attested/contract-tests.sh <new output folder>` on the master. Undo: nothing persists in HDFS (the tests delete their folder); `~/contract-libs`, `~/contract-build` and the output folders can be removed.

## 14. Planned changes (not applied)

Both changes of step 4.6 (ADR-027, ADR-028) were **applied on 8 and 9 October 2026** and are described in section 16; no decided change is waiting to be applied now. The table is kept as the record of what was planned.

| Change | Decision | Step | What it will do |
|---|---|---|---|
| The wrapper's classes onto Hadoop's own classpath on both nodes, and `fs.hdfs.impl` and `fs.AbstractFileSystem.hdfs.impl` set as final in the site configuration | ADR-027 | 4.6 (baby steps 4.6.1 and 4.6.2) | Every Hadoop process that reads the site configuration, the NodeManager included, uses the wrapper; a job can no longer switch it off |
| A switch between the wrapped and the plain configuration | ADR-028 | 4.6 (baby step 4.6.2) | The unwrapped control run of each pair |

Each of them changes the Hadoop installation or configuration, so the measured set changes and the re-measurement (ADR-020, ADR-029) must cover it. Each needs a backup of the files it changes and a rollback before it is applied.

## 15. NameNode audit log (applied 8 October 2026, step 4.5, baby step 4.5.2)

| Item | Value |
|---|---|
| What changed | `hadoop-env.sh` on the master gained four lines (a blank line, the marker `# >>> attested step 4.5.2: NameNode audit log (remove this block to undo)`, `export HDFS_AUDIT_LOGGER=INFO,RFAAUDIT`, and the marker `# <<< attested step 4.5.2`); the NameNode was restarted (about 06:31 UTC, new pid 531076). The worker is unchanged |
| Where the log is | `~/hadoop/logs/hdfs-audit.log`; the appender `RFAAUDIT` was already defined in `log4j.properties` (up to 20 files of 256 MB) |
| How it was done | `ops/attested/nn-audit.sh check`, then `on` (it backs up, restarts, verifies and rolls back by itself if the verification fails) |
| Backups | `~/nn-audit-backup`: `hadoop-env.sh.20261008T063033Z` and `name-20261008T063033Z-0` (the NameNode's metadata folder, 9384 KB); keep them until the step is closed |
| Undo | `ops/attested/nn-audit.sh off` on the master (restores that `hadoop-env.sh` and restarts the NameNode) |
| Effect | HDFS was unavailable for under a minute; every later run, wrapped or not, has the log; runs 6 to 8 had none. The measured set changes (`hadoop-env.sh`), so the re-measurement (ADR-020, ADR-029) covers it |
| How it is used | `ops/attested/nn_audit_compare.py` compares it with the wrapper's logs; `ops/attested/nn-audit-probe.sh` makes a known workload to test that |

## 16. The wrapper as the cluster's file system (applied 8 and 9 October 2026, step 4.6)

| Item | Value |
|---|---|
| What changed on both nodes | `attested-hdfs.jar` (34,217 bytes, `f0d96a83759a55fe...`, the 13 wrapper classes of the job file `apache-nutch-1.22.job`) in `~/hadoop/share/hadoop/common/lib/`; `~/hadoop/etc/hadoop/core-site.xml` is the WRAPPED version (`1c335707555b2427`): the file as it was (`d7e7dffd27def2a0`) plus `fs.hdfs.impl=org.apache.nutch.attested.AttestedHdfsFileSystem` and `fs.AbstractFileSystem.hdfs.impl=org.apache.nutch.attested.AttestedHdfs`, both marked `final` |
| When | the jar on 8 October before 08:22 UTC (no setting, no restart); the WRAPPED file on the master at 08:58 and on the worker at 09:01 UTC after a first attempt that rolled back (section 20.3 of the report), with all daemons restarted in order (the master's NameNode and ResourceManager, the worker's DataNode and NodeManager); the switch to plain and back on 8 October around 09:12 to 09:17 UTC; wrapped on both nodes since then |
| Current state | **wrapped on both nodes** (`cluster-mode.sh status` says which version is in place and which daemons run) |
| Backups | `~/cluster-mode` on each node: `core-site.xml.plain`, `core-site.xml.wrapped`, and `before-<time>.core-site.xml` for every change (the master's first attempt is `before-20261008T083926Z`) |
| Tools | `ops/attested/wrapper-jar.sh` (`build`, `install`, `verify`, `selftest`, `remove`); `ops/attested/cluster-mode.sh` (`status`, `prepare`, `wrapped` and `plain`, each with `--restart` or `--restart-yarn`; it refuses while a YARN application runs and rolls back by itself when its checks fail) |
| Undo | `cluster-mode.sh plain --restart` on the master and then on the worker; optionally `wrapper-jar.sh remove` on both |
| What still needs the plain client | Hadoop's admin tool (`hdfs dfsadmin`) and the two scripts of `ops/mesh/`; the audit and demo tools ask for it themselves (ADR-031) |
| Effect | every Hadoop process that reads the site settings serves `hdfs://` through the wrapper unless a command-line `-D` says otherwise; the NodeManager's reads of job files are verified against records; the measured set changed (`core-site.xml`, the jar, and `hadoop-env.sh` on the master), so the re-measurement of step 4.8 covers them, and the firewall rules must be saved before the reboot |

How a wrapped crawl is run since step 4.6 (this replaces the numbered steps of section 11; every step is a script in `ops/attested/`):

1. **Worker:** `audit.sh rotate`, then `cluster-mode.sh wrapped --restart-yarn`, so that the NodeManager starts a new log file (ADR-032). **Master:** `audit.sh rotate`; `wrapper-jar.sh verify <job file>` must say `CLASSES-SAME`; put the seeds into HDFS with an ordinary `hdfs dfs -put` (the wrapper makes their record); `audit.sh snapshot <before>`.
2. **Crawl:** in tmux, from the build clone, `ops/run-crawl.sh <seeds> <crawl-folder>`. It needs no wrapper options: the cluster's settings do it.
3. **Right after the crawl:** `audit.sh snapshot <after>`; on the worker, pack the container logs from `~/hadoop/logs/userlogs`, which YARN deletes after 3 hours; pack both nodes' `/tmp/attested-audit` and `/tmp/attested-records`.
4. **Cloud Shell:** `audit_compare.py before after logs --require-hosts tdx-lab,tdx-lab-worker`; `records_expected.py after records logs --cover '^/user/<user>/(crawl|seeds)-<run>(/|$)' --require-sidecars --out expected.tsv`; `verify_summary.py logs` with no exemption. Then on the master `records_verify.sh expected.tsv`.
5. **NameNode:** cut its audit log from the rotation to the end of the crawl and run `nn_audit_compare.py --nn <window> --wrapper logs`; read the `known` lines, and run it once with `--strict` and once with one wrapper log removed (the negative control).
6. **Tamper test:** rotate again, then `tamper-demo.sh <crawl-folder> <outdir>` from the build clone, then `tamper_verify.py` on both nodes' logs.

The control run of ADR-028: `cluster-mode.sh plain --restart-yarn` on both nodes, run the unwrapped crawl, then `cluster-mode.sh wrapped --restart-yarn` on both nodes.

To count what the NodeManager read through the wrapper, on the worker: `cat /tmp/attested-audit/*-<NodeManager pid>-*.tsv | awk -F'\t' '$4=="OPEN"{n=split($5,a,"/"); print a[n]}' | sort | uniq -c`. In run 9 it gave 27 each of `job.jar`, `job.xml`, `job.split` and `job.splitmetainfo`.

## 17. Building the job from a clean checkout (9 October 2026)

| Item | Value |
|---|---|
| What was missing from the repository | `conf/effective_tld_names.dat`, Mozilla's Public Suffix List (snapshot `2026-09-30_20-56-07_UTC`, upstream commit `714ac1bf5f2d038161c7419478cc3207431d706d`, MPL 2.0, 334,832 bytes, 16,501 lines, SHA-256 `73c95828f5f62a3f...`). Nutch uses a file of that name in `conf/` as an optional override of the older list bundled in one of its libraries; the build does not fetch it. It was one identical file in the measured tree, the scratch clone and inside both jobs |
| The fix | the file is tracked at `conf/effective_tld_names.dat` (commit `30cd062da`, one new file, mode 100644); `.gitignore` hides only `conf/*.txt` and `conf/*.xml` |
| How to build the job | `git clone --branch feat/tee-hadoop-cluster https://github.com/Antisource/nutch.git`, then `ant runtime` (Ant 1.10.12, OpenJDK 11.0.32.1); the job is `runtime/deploy/apache-nutch-1.22.job` (1,043 entries). The first build took 6 min 30 s with a cold dependency cache, the test build 33 s with a warm one |
| How to compare two jobs | `ops/attested/job_compare.py OLD NEW` (CRC-32 of every entry, nested jars by content) and `ops/attested/job_sha_compare.py OLD NEW` (SHA-256 of every entry and of every file inside the nested jars) |
| Where the test build is | `~/clean-build` and its log `~/clean-build-ant.log` on the master (a scratch folder, not part of the cluster); the evidence is in the bundle `evidence-m46-cleanbuild.tar.gz` ([milestone-4-storage-integrity.md](milestone-4-storage-integrity.md) section 20.11) |

## 18. The new wrapper on both nodes (13 October 2026, baby steps 4.6.4 to 4.6.7)

| Item | Value |
|---|---|
| What changed on both nodes | `attested-hdfs.jar` in `~/hadoop/share/hadoop/common/lib/`: 14 classes (one more than before, `AttestedSettings`), 36,292 bytes, `027f29942fe2a69d...`, identical to the wrapper classes of the job file `afdd82c598f52264...` (`wrapper-jar.sh verify` says `CLASSES-SAME`). `core-site.xml` is unchanged (the WRAPPED version of section 16) |
| How | built on the master from the job file (`wrapper-jar.sh build`), installed there with `ATTESTED_FORCE=1`, copied to the worker and installed there, then `cluster-mode.sh wrapped --restart` on the master and on the worker (each said `CLUSTER-MODE-OK`) |
| The job | built on 13 October in `~/a14-work` (a copy of `~/clean-build` with the change applied, `ant runtime`, `BUILD SUCCESSFUL`); the evidence is in the bundle `evidence-m4-hardening-build.tar.gz` |
| Settings that changed | `attested.verify.missing` now defaults to `fail` (opening a file with no record is refused); the new `attested.metadata.missing` defaults to `warn` (status and listing questions are answered and logged once); every setting of the wrapper counts only when `core-site.xml` set it, and the `INIT` line of the audit log names a setting that was ignored (`ignored=`); the wrapper's two log-folder settings are not covered |
| Refused now | `append`, `concat`, `truncate`, opening by path handle, making a path handle, `getRawFileSystem`, `startLocalOutput` and `completeLocalOutput`; `getChildFileSystems` answers none |
| What the cluster holds from run 10 | `seeds-run10` and `crawl-run10` in HDFS (the demos removed their own folders); the logs and listings are in `~/run10` on the master; the NameNode's audit log is on |
| Procedure | unchanged (section 16): rotate the logs, restart the worker's NodeManager, put the seeds in through the wrapper, take the "before" listing, run `ops/run-crawl.sh`, then the checks. A script that is not executable in the repository is run with `bash` |
| Evidence | `evidence-m4-hardening-run10.tar.gz`, `evidence-m4-hardening-demos10.tar.gz` and `evidence-m4-hardening-build.tar.gz`; the report is [milestone-4-storage-integrity.md](milestone-4-storage-integrity.md) section 22 |


## 19. The re-measure and the first timing pair (14 October 2026, step 4.8)

| Item | Value |
|---|---|
| What changed | both nodes were rebooted into the 6.17 kernel (one-time boot, the pin on 6.8 unchanged), the firewall was applied again, the stack was measured again with the patched job and the new component `tc-policy`, and the daemons were started afterwards; the plain and the wrapped `core-site.xml` were switched and restored for the first timing pair |
| The measured set | master: `jdk`, `java-settings`, `java-ca-fingerprints`, `hadoop-code`, `hadoop-conf`, `tc-policy`, `nutch-deploy`, `driver`, `seeds` (9 events, final RTMR3 `0e137cc3e973`); worker: the first six (6 events, `0f1db95fcb1a`); `NUTCH_DIR` is `~/m481/patched` on the master |
| Files and backups | `~/tc-policy` (`policy.json` and its `.sha256`) on both nodes; `~/m482/` holds the state saved before the reboot, the old chain and the post-boot outputs; the firewall before the re-applied rules is `/root/iptables-after-reboot-m482` (the original backup `/root/iptables-before-mesh` was not overwritten); `~/cluster-mode/before-<time>.core-site.xml` records every switch |
| Current state | **wrapped on both nodes**, `core-site.xml` fingerprint `1c335707555b2427`, the same as before the pair; the plain version is `d7e7dffd27def2a0` |
| After a reboot | the nodes return to 6.8 and the stack is not measured; a new re-measure needs another one-time boot (the kit `ops/kits/m482`) |
| Kits and report | `ops/kits/m482`, `ops/kits/m483`; the report is [milestone-4-storage-integrity.md](milestone-4-storage-integrity.md) section 23, the decisions are ADR-040 to ADR-042 |


## 20. The shared cluster client (15 October 2026, ADR-043)

| Item | Value |
|---|---|
| What it is | a read-only, root-owned copy of the measured Hadoop client, its configuration and the measured job folder in `/opt/tc-shared` on the master, proved equal to the measurement of 14 October (`hadoop-code` `9f5b29d6258642f2…`, `hadoop-conf` `6593ba442a9d9a00…`, `nutch-deploy` `9976e227f2c4378b…`); 1,225 MB of Hadoop and 129 MB of job |
| The tools in `/opt/tc-shared/bin` | `tc-env.sh` (the environment), `tc-check.sh` (a one-command test), `tc-seed.sh` (a seed file with its record), `tc-busy.sh` (the reservation marker), `tc-user-add.sh` (the admin tool for a user's HDFS folder); the rules are in `/opt/tc-shared/README.txt` |
| Accounts with a normal user id on the master | `ubuntu`, `dev` (origin not known), the teammate's account, and the author's; the teammate's HDFS folder is `/user/<her name>` |
| The wrapper's log folders | `/tmp/attested-audit` and `/tmp/attested-records` are mode 1777, owned by the cluster user, and recreated at every boot by `/etc/tmpfiles.d/zz-tc-shared.conf` |
| The marker | `/opt/tc-shared/state/BUSY` (a line with the user, the time and the reason); an agreement, not a lock |
| Undo | `sudo rm -rf /opt/tc-shared` and `sudo rm /etc/tmpfiles.d/zz-tc-shared.conf` |
| Kit | `ops/kits/tcshared` |

## 21. The signed wrapper window (15 October 2026, step 5.1.1, ADR-045)

| Item | Value |
|---|---|
| What a window is | a reserved, temporary change of the measured stack: the new jar and three signature settings are in place on a node until `close` restores the saved jar and `core-site.xml` and the measured-set check passes |
| State on a node | `~/m511/window` while open (saved jar and settings, the mode folder, the logs), moved to `~/m511/window-closed-<role>-<time>` by `close` |
| The test key | `~/tc-test-key/test-key.txt` on both nodes, mode 600, key id `TEST-37c2a6aaa70d55b2`; a TEST key, never evidence; delete it after the combined run |
| The new jar and job | the wrapper jar `f20364cf2ba34639…` (20 classes) and the job `9a6dcb5f0c6fbe27…` (134,851,125 bytes) in `~/m511b` on the master |
| Current state | **measured stack on both nodes** (jar `027f29942fe2a69d…`, `core-site.xml` `1c335707555b2427…`); the window of 15 October (08:19 to 08:33) is closed |
| Kits | `ops/kits/m511-test`, `ops/kits/m511-build`, `ops/kits/m511-window`; the report is [milestone-5-signed-records.md](milestone-5-signed-records.md) section 3 |


## 22. The folder binding window (15 October 2026, step 5.1.2, ADR-046)

| Item | Value |
|---|---|
| What it is | the second window of the method of section 21: the 5.1.2 wrapper on both nodes with signing and folder binding on and required, for the demonstration of the folder binding |
| Times | the cluster reserved and the master opened at 15:38:12, the worker opened at 15:41:51, the demonstration at 15:46:12, the master closed at 15:52:15, the worker closed at 15:56:23 |
| The settings applied | the measured `core-site.xml` plus five final settings: `attested.signature.enabled`, `attested.signature.required`, `attested.signature.allow.test.keys`, `attested.folder.binding.enabled`, `attested.folder.binding.required` (the signed file's fingerprint starts `671287c4f1b619bb`) |
| The new jar and job | the wrapper jar `ca96be26b8748125…` (26 classes) on both nodes (the worker's copy is `~/m512-new-jar.jar`) and the job `6f98295641a4f559…` (134,868,431 bytes) in `~/m512b` on the master |
| State on a node | `~/m512w/window` while open, moved to `~/m512w/window-closed-<role>-<time>` by `close`; the demonstration's folders in `~/m512w/demo` |
| The test key | unchanged from section 21: `~/tc-test-key/test-key.txt` on both nodes, mode 600, key id `TEST-37c2a6aaa70d55b2`; a TEST key, never evidence; delete it after the combined run |
| Current state | **measured stack on both nodes** (jar `027f29942fe2a69d…`, `core-site.xml` `1c335707555b2427…`); the window is closed |
| Kits | `ops/kits/m512-test`, `ops/kits/m512-build`, `ops/kits/m512-window`; the report is [milestone-5-signed-records.md](milestone-5-signed-records.md) section 4 |


## 23. The combined crawl window (15 October 2026, `run14`)

| Item | Value |
|---|---|
| What it is | the third window of the method of section 21, with the 5.1.2 wrapper and the same five settings as section 22, for the combined crawl `run14` |
| Times | the cluster reserved at 18:29:57, the master opened at 18:30:22, the worker at 18:33:07, the crawl from 18:37:50 for 770 s, the master closed at 18:58:04, the worker at 19:01:55 |
| The crawl's data | `/user/rishabsdp17/seeds-run14` and `/user/rishabsdp17/crawl-run14` in HDFS (about 1.3 MB, 55 folders and 60 files, with `ATTEST03` records and identity files); readable only in a window |
| Files on the master | `~/run14` (the run's folder with its fingerprints and its offline verification results), `~/run14-console.txt`, the kit in `~/m512ckit` |
| Files on the worker | `~/run14-worker.tar.gz` (the wrapper logs of the window, without task logs), the kits in `~/m512ckit` and `~/m512cfixkit` |
| Current state | **measured stack on both nodes**; the window is closed; the test key `TEST-37c2a6aaa70d55b2` is still on both nodes (delete it at the end of Milestone 5) |
| Kit | `ops/kits/m512c`; the report is [milestone-5-signed-records.md](milestone-5-signed-records.md) section 5 |


## 24. The real-key window (16 October 2026, step 5.1.3, `run15`)

| Item | Value |
|---|---|
| What it is | the fourth window of the method of section 21, with the 5.1.3 wrapper jar, the signing service on each node and ten settings: the five of section 22 (test keys not allowed) plus `attested.keys.provider` (service), `attested.keys.service.address` (127.0.0.1:7461), `attested.keys.service.token.file`, `attested.keys.list.dir` and `attested.keys.list.allow.unquoted` (false) |
| Times | the cluster reserved at 11:17:03, the master opened at 11:17:42 (its service started at 11:18:43), the worker at 11:27:50 (11:28:50), the bundles exchanged at 11:36:43, the crawl from 11:46:59 for 736 s, the master closed at 12:11:27, the worker at 12:14:20 |
| The keys | master `TDX-428f3734fdb03238`, worker `TDX-5fdb825500807c66`; made at the start of each service, kept in memory only, gone when the services stopped at the close; the bundles (public) are in `~/tc-keys/list` on both nodes and in the evidence |
| The new jar and job | the wrapper jar `36324a608d9d1a2c…` (32 classes) on both nodes (the worker's copy is `~/m513-new-jar.jar`) and the job `3a55e21d17c07d78…` (134,891,448 bytes) in `~/m513b` on the master |
| The crawl's data | `/user/rishabsdp17/seeds-run15` and `/user/rishabsdp17/crawl-run15` in HDFS (about 1.3 MB, 55 folders and 60 files); readable with the wrapper of 5.1.3 and the key list that holds the two bundles |
| Files | state in `~/m513w/window` while open, then `~/m513w/window-closed-<role>-<time>` (it holds `keyservice-dir` with the bundle, the quote and the audit log of the service; its token is deleted); on the master `~/run15`, the kit in `~/m513wkit`, the scratch tree `~/m513/tree` and `~/m513b`; on the worker `~/run15-worker.tar.gz` (made by hand) |
| Current state | **measured stack on both nodes**; the window is closed; no signing service runs; the test key `TEST-37c2a6aa…` is still in `~/tc-test-key` on both nodes (unused; delete it at the end of Milestone 5) |
| Kits | `ops/kits/m513-test`, `ops/kits/m513-build`, `ops/kits/m513-window`; the report is [milestone-5-signed-records.md](milestone-5-signed-records.md) section 6 |
