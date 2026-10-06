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
