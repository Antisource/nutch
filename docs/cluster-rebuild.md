# Rebuilding the cluster after a wipe

When a teammate or the mentor uses the lab machines, **our progress and the files we stored on the two TDX VMs are wiped; the VMs themselves stay.** Cloud Shell's `/tmp` is lost whenever Cloud Shell is reset. This page says what survives, what to do **before** that happens, and how to get back to a working cluster **after** it. It describes the rebuild kit in `ops/rebuild/`.

**Status of the kit (read this first).** The specification was checked against the working cluster (`check-existing.sh` on each node; the output is kept in the evidence bundle `evidence-rebuild-kit-check`), and each script was tested in a sandbox with stand-ins (fake Hadoop, fake `gcloud`). **The install actions have not yet run on fresh VMs.** The first real rebuild is the real test; expect to fix small things then, and add them here.

## 1. The idea

Think of a shared rented kitchen that is cleaned after every guest. You cannot leave anything in it. You keep your recipes in your own cupboard, your notes at home, and you carry a checklist so that you can set the kitchen up again quickly.

| Place | Survives a wipe? | What is kept there |
|---|---|---|
| GitHub (`Antisource/nutch`, branch `feat/tee-hadoop-cluster`) | yes | code, scripts, tools, documents, the rebuild kit |
| The user's laptop (`tdx-evidence`) | yes | evidence bundles, the VM-state bundle, the job files |
| Our files and progress on the VMs, Cloud Shell's `/tmp`, an assistant's sandbox | **no** | nothing that exists only there |

## 2. Before a wipe (end of every session)

1. In Cloud Shell, from a clone of the repository: `bash ops/rebuild/end-of-session.sh`. It collects the state of both VMs (configuration, firewall rules, WireGuard setup **without private keys**, package lists, the HDFS contents), bundles it, scans the bundle for secrets (every count must be 0) and prints its SHA-256.
2. Download `evidence-vm-state-<date>.tar.gz` to the laptop and compare its SHA-256 with the printed value.
3. Download any evidence bundle made during the session, and the job file if a new one was built (see section 6).
4. Keep a second copy of the whole evidence folder on another drive or in cloud storage.
5. Commit what was tested, in the usual gated way (code and documents in separate commits).

## 3. After a wipe (back to a working cluster)

You need a Cloud Shell with access to the project `training-custody` (`gcloud config set project training-custody`) and `sudo` on the VMs.

**The usual case: the VMs are still there.** The stages look before they act, so they only do what is missing:

```bash
git clone https://github.com/Antisource/nutch.git -b feat/tee-hadoop-cluster nutch && cd nutch
bash ops/rebuild/rebuild-cluster.sh ship base hadoop mesh build wrapper suite
```

If the VMs themselves are gone, run `bash ops/rebuild/rebuild-cluster.sh` with no stage names: it starts with `provision`.

What "looking first" means: `base` skips what is installed and **leaves Hadoop settings alone if they differ** from the specification (set `REBUILD_FORCE_CONF=1` to rewrite them); `hadoop` refuses to format a NameNode that still holds a file system, and `start` skips a daemon that already runs; `mesh` **skips itself when the mesh is already up** and stops with a message when it is only half there.

The stages, in order. Each one stops with a message at the first failure, and a stage that succeeded can be run again.

| Stage | What it does | Script |
|---|---|---|
| `provision` | creates `tdx-lab` and `tdx-lab-worker` if they do not exist: `c3-standard-4`, TDX, Ubuntu 22.04, a 50 GB boot disk, internal addresses `10.128.0.2` and `10.128.0.5` | `rebuild-cluster.sh` |
| `ship` | copies the repository's `ops/` folder to both VMs | `rebuild-cluster.sh` |
| `base` | packages, host names, Hadoop 3.4.3 (its SHA-512 checked against Apache's file), the four settings files, data folders | `node-base.sh` |
| `hadoop` | formats the NameNode (refuses if one exists), starts the daemons in the lab's order, waits for the cluster, creates `/user/<you>`, runs Hadoop's Pi example | `node-hadoop.sh` |
| `mesh` | the WireGuard mesh, Hadoop moved onto it, the host firewall (it undoes itself after 150 seconds unless confirmed), the names | the scripts in `ops/mesh` |
| `build` | builds `crawler-commons` and `language-detection-cld2` at the commits of the lab cluster, then the crawler job with `ant runtime` | `node-wrapper.sh` |
| `wrapper` | builds the wrapper's library jar from the job, installs it on both nodes, switches both to the wrapped configuration | `node-wrapper.sh` |
| `suite` | the smoke tests against the real HDFS and the contract tests, with a pass table at the end | `node-suite.sh` |

Expected time, not measured: about 40 minutes in all, most of it in `base` (a 491 MB download), `build` (a cold build is long) and `suite`. Cloud Shell can go to sleep when it sits idle, so stay with it, or run the stages one by one.

A result you can trust ends with `SUITE-OK` and a table. Run `bash ops/rebuild/rebuild-cluster.sh --dry-run <stages>` to see the commands without running them.

## 4. What the kit does not do yet

- **The measurement stage** (the 6.17 kernel, the one-time boot, measuring the stack into RTMR3, the quote). It was done by hand in Milestone 1 and is written down in `milestone-1-code-measurement.md` and in `attest/measure/` and `ops/worker-kernel-prep.sh`. A fresh VM boots a fresh measurement: the old quotes stay valid as evidence of the old image.
- **Which parts of the machines disappear** (only the home folder, or also installed packages, system settings and HDFS data) is not known. Because every stage looks first, the kit works in either case, and the first real rebuild will show which case this is.
- **Restoring the old HDFS contents.** The export is in the VM-state bundle (`hdfs/user-home`). Uploading it through the wrapper would give every file a new record; it is rarely needed.
- **The signing key and the attested admission** (steps B3 and B4 of `milestone-plan.md` section 8) are not built yet.
- Where the VMs get an internal address other than `10.128.0.2` and `10.128.0.5`, the existing mesh scripts need those addresses changed (they have them written in).

## 5. Checking the specification against a working cluster

On a node that works (read-only): `bash ops/rebuild/check-existing.sh master` (or `worker`). It compares the versions, the packages the kit installs, the host names and the four settings files with the kit's specification and prints `EXISTING-MATCHES-KIT` or each difference. A difference means the kit is wrong or incomplete.

## 6. Job files

The baseline job (the one whose SHA-384 starts `f993fd407ab5`, the value of the Milestone 1 quote) is kept as a full file; the other jobs are tiny `zstd` patches against it. The manifest in the job-patches evidence bundle (`MANIFEST.txt`) lists every fingerprint and the rebuild command:

```bash
zstd -d --long=28 --memory=2048MB --patch-from=job-bbd30ad9-baseline.job run9.patch.zst -o job-run9.job
```

then check that `sha256sum job-run9.job` equals the value in the manifest. A job built again from git has the same content but not the same bytes: only the baseline's exact bytes are tied to a quote.

## 7. When something goes wrong

| Message or symptom | Likely cause and what to do |
|---|---|
| `could not create tdx-lab (is 10.128.0.2 free, and is TDX available in the zone?)` | the old VM still holds the address, or the zone has no TDX capacity; delete the old VM or change `ZONE` |
| `passwordless sudo is needed` | the user on the VM has no passwordless `sudo`; the VMs made by `provision` have it |
| `less than 5 GB free` | the boot disk is too small; create the VM with `--boot-disk-size=50GB` |
| `the SHA-512 of the Hadoop download does not match` | a bad download; the file was removed, run the stage again |
| `CLUSTER-UP` never appears | check `~/hadoop/logs` on the node and that `hadoop-worker` resolves on both nodes (host names matter: the worker must register under that name) |
| `the mesh is half there` | `wg0` exists on one node only, or the nodes cannot reach each other; follow the message, then run the stage again |
| the mesh stage fails | the firewall undoes itself after 150 seconds; log in again and look at `sudo iptables -S` and `sudo wg show` |
| the build fails in `deps` | a snapshot library could not be fetched or built; read `~/.rebuild/mvn-<name>.log` on the master |
| `NameNode folder already holds a file system` | HDFS already exists on this VM; that is correct if you are re-running; remove `~/hadoop-data/namenode/current` only if you mean to erase HDFS |
