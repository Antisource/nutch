# Milestone 2: WireGuard mesh and a closed ordinary network

Date: 6 October 2026. Times are UTC unless a tool is named as printing laptop time (India Standard Time, UTC+5:30).
Status: **done for this setup**, with the limitations in section 8. Written when the milestone closed.

## 1. Goal

The mentor's second feedback point: cross-node communication happens outside the VM trust boundary, so it must be secured. The handoff's mesh gate (Gate A, step 1):
WireGuard between the two VMs, Hadoop daemons bound to it; pass when a stock crawl completes over the mesh and a job submitted from a third machine outside the mesh is refused.

## 2. Background (first principles)

- Before this milestone every Hadoop connection between the nodes (HDFS, YARN, shuffle) crossed the cloud network in plaintext, and the default firewall rule allowed all ports between instances ([cluster-configuration.md](cluster-configuration.md) section 2).
- WireGuard builds an encrypted tunnel (an interface, here `wg0`) between machines that know each other's public keys. Traffic sent to a mesh address goes through the tunnel; nothing else does.
- A program that listens on "all addresses" (`0.0.0.0`) accepts connections on every network interface. Closing the ordinary interface to those programs needs either a per-daemon setting or a host firewall.

## 3. Steps and status

| # | Step | Status | Result |
|---|---|---|---|
| 2.0 | Read-only pre-flight on both nodes | Done | Section 4 |
| 2.1 | Bring up the WireGuard mesh | Done | Section 5 |
| 2.2 | Point Hadoop at the mesh; add a host firewall | Done | Section 6 |
| 2.3 | A crawl over the mesh (run 5) | Done | Section 7 |
| 2.3b | okhttp inside the worker's task logs | Done for run 5 | 22 of the worker's task logs list okhttp, none list the old plugin |
| 2.4 | Refusal test from outside the mesh | Done, with a stand-in for the third machine | Section 7 |

## 4. Pre-flight (both nodes on kernel 6.17.0-1022-gcp)

| Item | Master | Worker |
|---|---|---|
| Ordinary address | `10.128.0.2` | `10.128.0.5` |
| Hadoop sockets | ResourceManager (8030 to 8033, 8088) and NameNode RPC (9000) on `10.128.0.2`; NameNode web page (9870) on all addresses | every Hadoop port on all addresses (NodeManager 8040, 8042 and a random port, shuffle 13562, DataNode 9864, 9866, 9867) |
| WireGuard | kernel module available, not loaded; tool not installed; package `wireguard-tools` 1.0.20210914 available | same |
| Host firewall | none (all policies `ACCEPT`) | none |

The master's RPC daemons were already bound to one address, presumably because the name `hadoop-master` resolves to it (not tested separately). The worker's were not.

## 5. The mesh

- Package: `wireguard-tools` from Ubuntu's signed archive, installed without recommended extras. This is the one package added to the VMs for the mesh.
- Keys: generated on each node (`/etc/wireguard/private.key`, owner root, mode 600). Only the public keys travelled to Cloud Shell; the private keys were never printed or copied.
- Interface `wg0`: master `10.10.0.1/24`, worker `10.10.0.2/24`, UDP port 51820, one peer each (`AllowedIPs` = the other node's `/32`), keepalive 25 seconds. The script also enabled `wg-quick@wg0` at boot; the facts file in the mesh evidence bundle records the service state. Google's `default-allow-internal` rule already carried UDP between the nodes.
- Result: ping 3 of 3 both ways, 0% loss, 0.32 to 0.44 ms; both nodes showed a recent handshake (8 and 16 seconds) and non-zero transfer counters.

## 6. Hadoop on the mesh

Changes, in order, by one script from Cloud Shell: check, stop the daemons (worker first), edit `/etc/hosts`, apply the firewall, confirm login, start the daemons (master first).

- **Names:** `hadoop-master` is now `10.10.0.1` and `hadoop-worker` is `10.10.0.2` in `/etc/hosts` on both nodes (backup `/etc/hosts.before-mesh`). Hadoop's configuration files are unchanged, so the measured configuration stays identical on both nodes.
- **Firewall** (iptables, inbound): accept loopback, established connections, everything arriving on `wg0`, UDP 51820, SSH (22), ping and Google's metadata server; a counted rule drops TCP to the Hadoop ports (8030 to 8033, 8088, 9000, 9870, 8040, 8042, 9864, 9866, 9867, 13562); the default policy drops everything else. The script scheduled the firewall to undo itself after 150 seconds unless a fresh login over the new rules succeeded; it did (`firewall kept`), and the timer was gone afterwards.
- **Result:** the master's ResourceManager and NameNode RPC now listen on `10.10.0.1`. The NameNode web page and all of the worker's daemons still listen on all addresses; the firewall is what closes them to the ordinary network. HDFS healthy: safe mode off, one live DataNode, no missing blocks.

**A problem found by reading the node list.** After the first restart the worker's node was listed as `tdx-lab-worker.us-central1-a.c.training-custody.internal:43125`, not `hadoop-worker`. It had named itself from reverse lookup of its own address, which the old `/etc/hosts` alias had hidden. That name resolves (Google DNS) to the **ordinary** address `10.128.0.5`, which the firewall drops, so the ResourceManager and the jobs could not have reached it (reasoning; the resolution was confirmed by `getent`). Fix: map the two nodes' internal names to the mesh addresses in `/etc/hosts` (backup `/etc/hosts.before-names`), restart, and run a real job. The node then registered as `hadoop-worker:39313`, and the Pi example finished (`Job Finished in 19.336 seconds`; 20.9 s on the ordinary network earlier; one small job, so no conclusion about speed).

## 7. Crawl and refusal test

**Run 5** (seeds `seeds-run5`, crawl `crawl-run5`; segments `20261006081716`, `20261006082025`, `20261006082413`):

| Item | Result |
|---|---|
| Duration | about 11 minutes; `Finished loop with 3 iterations` at 08:27:30 |
| Errors | none found by the log scan |
| Plugin lines in the master's log | okhttp 19, old plugin 0 |
| Worker task logs (not deleted this time) | 22 list the okhttp plugin, 0 list the old plugin |
| Pages | the same eight URLs as run 3 (`SAME-PAGES`; URLs, not content) |
| Addresses | the seven `toscrape` pages `35.211.122.109`; `www.zyte.com` `216.150.16.1` (run 3: `216.150.1.193`). The site is served from a pool of Vercel addresses (its canonical name is a `vercel-dns` name), and a later lookup gave a third address |
| Tunnel traffic during the crawl | master received 18.2 MB, sent 3,915.2 MB |
| YARN applications | 28 = 1 Pi test + 27 crawl applications |
| Hadoop-port drop rule after the crawl | 0 packets on both nodes |
| Measured stack afterwards | all ten digests unchanged (`check-unchanged.sh`) |

The master's 3.9 GB: 27 uploads of the 134,774,656-byte job file account for 3,639 MB of it, leaving about 276 MB for other traffic (the count matched a prediction; not proof of every byte). Each application uploads the job file into HDFS, and HDFS stores it on the worker, so the code reaches the worker across the mesh every time.

**Refusal test** (a script from Cloud Shell; no third VM, so the stand-in is the ordinary network path between the two nodes, which is where a stranger in the VPC would arrive):

| Direction | Ports | Ordinary address | Mesh address |
|---|---|---|---|
| worker to master | 8032, 9000, 9870 | no answer | open |
| master to worker | 9866, 9864, 8042, 13562 | no answer | open |
| a Pi job submitted to the master's ordinary address | | refused: `ConnectTimeoutException` after 3000 ms, exit code 255 | (the run 5 job used the mesh) |

The Hadoop-port drop counters rose from 0 to 24 on each node in the first run and from 24 to 48 in a second run kept as evidence. The error message says the call came from `tdx-lab-worker/10.10.0.2`; that is Hadoop's label for the local machine (the hosts file maps its name to the mesh address), not the packet's source.

## 8. What was not done

- **No real third machine.** Only the ordinary path between the two nodes was tested.
- **No packet capture.** The evidence is counters and the refusal results.
- **The worker's daemons still listen on all addresses.** The firewall closes them; per-daemon bind settings would add a second layer and were not done.
- **The firewall is not saved across a reboot.** The mesh interface is. After a reboot the rules are gone until the script runs again (it is safe to re-run).
- **IPv6 is not covered.** The daemons listen on IPv4 only.
- **Peers are authenticated by static keys only.** Nothing ties a node's key to its attestation quote, and the private keys sit on the boot disk (root only). Admission by quote belongs to Milestone 5.
- **The mesh configuration and firewall are not in the measured set.** The measured stack is unchanged by them (confirmed), but a change to them would not be detected by RTMR3.
- **Hadoop's own wire encryption and authentication were not enabled** (a different mechanism from the tunnel).

## 9. Differences from the handoff (to apply to the handoff later)

1. The handoff says the daemons are bound to the mesh. In practice the master's RPC daemons bind through their hostnames, while the NameNode web page and the worker's daemons bind to all addresses and are closed by the host firewall.
2. A job from "a third machine" was tested with a stand-in (ordinary network path), because no third VM was created.
3. Node names matter: a node can register under a name that resolves to the closed network, after an unrelated hosts-file change.
4. The job file travels to the worker through HDFS staging for every application (about 134.8 MB, 27 times in run 5), which supports the handoff's design of checking the job file at load on the worker.

## 10. Evidence (kept outside the repository)

| Bundle | Entries | Fingerprint (12 hex) | Contents |
|---|---|---|---|
| `evidence-run5.tar.gz` | 32 | `448cdd704b92` | 18 WARC and index files, crawl log, tunnel and firewall counters before and after, unchanged-check, HDFS listing, YARN application list |
| `evidence-m2-mesh.tar.gz` | 16 | `071551dfa827` | network facts for both nodes (addresses, `wg show`, hosts, firewall rules and counters, service state, key file permissions), the worker's task-log check, the refusal-test output (second run), the ten mesh scripts |

Both were compared by PowerShell on the laptop against their `.sha256` files (`MATCH`) and unpacked into `tdx-evidence\extracted`.

## 11. Scripts (committed under `ops/mesh/`)

`mesh-preflight.sh` (read-only look), `wg-node-prep.sh`, `wg-node-up.sh`, `mesh-up.sh` (install, keys, `wg0`), `mesh-hadoop-node.sh`, `mesh-hadoop.sh` (hosts, firewall, restart), `mesh-names-node.sh`, `mesh-names.sh` (internal-name fix and a Pi test), `mesh-outside-node.sh`, `mesh-outside.sh` (refusal test). Each was tested against a simulated two-node setup before its first real run.

## 12. Decisions taken at this milestone

ADR-013 (mesh addressing and tooling), ADR-014 (host firewall and hosts-file names instead of per-daemon binding), ADR-015 (node names mapped to the mesh), ADR-016 (refusal test without a third VM). See [decisions.md](decisions.md).
