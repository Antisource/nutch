# Milestone 1: measure the code that runs

Dates: 5 and 6 October 2026. Times are UTC unless a tool is named as printing laptop time (India Standard Time, UTC+5:30).
Status: **done for both nodes**, with the limitations in section 8. Written when the milestone closed.

## 1. Goal

The mentor's first feedback point: a quote covered only the OS and everything below it, not the code that runs. Measure the CCBot code base, JVM, Hadoop, seeds,
driver scripts and anything else involved in execution, so a verifier can tell whether the code executed is the code intended.

Pass condition (handoff, Gate A, step 3): boot a kernel that supports RTMR extension; extend RTMR3 with the hash of the job jar; the value appears in a quote
verified off-cloud; replaying the event log reproduces it. We extended this to the whole stack, on both nodes.

## 2. Background (first principles)

- A TDX quote carries fixed fields (MRTD) and four extendable registers (RTMR0 to RTMR3). An extension replaces a register with `SHA-384(old value + new digest)`, so entries can
  be added but not removed or reordered.
- On Google Cloud, MRTD covers the firmware, RTMR0 the firmware configuration, RTMR1 the boot loaders, RTMR2 the kernel and its command line; RTMR3 is left for software
  ([limitations-and-trust.md](limitations-and-trust.md), note 1). Before this milestone RTMR3 was all zeros in every quote.
- A register value alone says nothing about what was extended. A verifier needs the **event log** and replays it. The firmware keeps one for RTMR0 to RTMR2 (the
  CCEL ACPI table). For RTMR3 we keep our own.

## 3. Steps and status

| # | Step | Status | Result |
|---|---|---|---|
| 1.1 | Learn what a quote records | Done | Section 2 |
| 1.2 | What does kernel 6.8 expose? | Done | `/dev/tdx_guest` exists; no `measurements` folder under `tdx_guest/`; kernel config has no `TSM_MEASUREMENTS`; `/sys/kernel/config/tsm/` holds only `report` |
| 1.3 | Read and replay the boot event log | Done | Section 4 |
| 1.4 | Explain why the nodes' boot values differ | Done, one event left open | Section 5 |
| 1.5 | Inventory the software to measure and fingerprint it on both nodes | Done | Section 6 |
| 1.6 | Is a newer kernel needed? | Done: yes | Section 7 |
| 1.7 | Get a kernel that can extend RTMR3 | Done | Section 7 |
| 1.8 | Our own event log and extension script | Done | Section 9 |
| 1.9 | Replay check for RTMR3 | Done | Section 9 |
| 1.10 | Extend with the job jar; quote verified off-cloud; replay reproduces it | Done on both nodes | Section 9 |
| 1.11 | Widen to all components | Done | Master: 10 events; worker: 5 events (it holds no job, driver or seeds) |
| 1.12 | Replay RTMR0 to RTMR2 on the 6.17 boots | Done | Section 4 |
| (also) | Run the crawl on the measured stack; check nothing changed | Done | Section 10 |

## 4. Boot event log replay

The firmware's boot log (`/sys/firmware/acpi/tables/data/CCEL`, 262,144 bytes, mostly fill) is a standard TCG crypto-agile log in SHA-384. A replay script reads it,
starts each register at zeros, applies every event and compares with the quote.

| Boot | Events | RTMR0 / RTMR1 / RTMR2 events | Replay vs quote (first 12 hex) |
|---|---|---|---|
| Master, kernel 6.8 (first boot, 22 Sep) | 105 | 16 / 7 / 80 | `036d0bf4b669` / `34eb6472351e` / `c0b49059d19f`: all match |
| Worker, kernel 6.8 (2 Oct) | 105 | 16 / 7 / 80 | `5e276dcf6867` / `34f8a1d9bdca` / `cb8543db432e`: all match |
| Master, kernel 6.17 (5 Oct 17:15:31) | 110 | 16 / 7 / 85 | `036d0bf4b669` / `05718f1d5381` / `37e9c325474a`: all match |
| Worker, kernel 6.17 (5 Oct 18:47:47) | 108 | 16 / 7 / 83 | `5e276dcf6867` / `b8837821022e` / `e1ecda0d3f2e`: all match |

RTMR3 matches no replayed index in these runs, as expected: the firmware's log has nothing for it. The script's first version stopped with `KeyError: 65535`: the log ends
with `0xFF` fill, not zeros, and the script had assumed zeros. It was fixed to recognise the end marker and to stop with a parse error on any other surprise.

## 5. Why the boot values differ

Between the master and the worker (6.8 boots), 13 of 105 events differ by position: 1 in RTMR0 (`Boot0002`, the firmware's boot entry), 1 in RTMR1 (the disk's partition-table
event) and 11 in RTMR2 (GRUB: the config file path, the filesystem and partition UUIDs, the kernel version and command line, the menu entries). The comparison is by position, so it overstates
changes when one event is inserted early.

Between two boots of the **same** master and kernel (22 Sep and 5 Oct), RTMR0 was equal, RTMR1 and RTMR2 changed:

- RTMR2 changed because we had changed GRUB (a regenerated `grub.cfg`, a saved default entry, a rewritten `grubenv`). The log also grew by about 6 KB.
- RTMR1 changed because of the partition-table event: on the first boot the firmware measured a 4 GiB layout (`alternate_lba` 8,388,607, `last_usable_lba` 8,388,574); on later boots
  it measured the full 50 GiB disk (104,857,599 and 104,857,566), with partition 1's last sector and both CRCs changed. The cloud-init log confirms the cause: on the first boot,
  seven seconds after start, `'/' resized: changed ... from 4178558464 to 53570682368`, and every later boot says `NOCHANGE`. The firmware measures before the OS runs, so the first-boot quote
  records the old layout.

Open: the `Boot0002` difference between nodes was not decoded. It probably names each disk's partition identifier (not checked).

Consequence for a verifier: raw register values are not a stable identity, even for one node on one kernel. A verifier should replay the log and apply rules to individual events.

## 6. What was fingerprinted

A folder fingerprint is SHA-384 over a sorted list of lines `type, mode, file hash, path` (symlinks are recorded by target, not followed).

| Component | Location | Entries | Digest (12 hex) | Master vs worker |
|---|---|---|---|---|
| `jdk` | `/usr/lib/jvm/java-11-openjdk-amd64` | 345 | master `1598cab16fe8`, worker `d3497f2b7aae` | **1 file differs:** `lib/server/classes.jsa` (the JVM's start-up cache) |
| `java-settings` | `/etc/java-11-openjdk` | 24 | `99d8ca6bf799` | same |
| `java-ca-fingerprints` | sorted list of the Java CA store's certificate fingerprints | 121 certificates | `c76041c0ac65` | same list; the raw `cacerts` bytes differ |
| `hadoop-code` | `~/hadoop` without `logs/` and `etc/hadoop/` | 20,250 | `cae7d3bf40e5` | same |
| `hadoop-conf` | `~/hadoop/etc/hadoop` | 32 | `d94631f104f7` | same |
| `nutch-job` | the job file (SHA-384 of the file) | 1 | `f993fd407ab5` | master only |
| `nutch-deploy` | `runtime/deploy` (job file and the `crawl` and `nutch` scripts) | 3 | `c766220388aa` | master only |
| `driver` | `ops/` | 1 | `2a489782002e` | master only |
| `seeds` | `seeds/` | 1 | `75568deaa051` | master only |
| `test-marker` | a text file made for the first test | 1 | `9c1f0ae7f5e3` | master only (kept in the chain; see section 9) |

Findings that shaped the design:

- 26 files inside the JDK folder are symlinks into `/etc` (25 into `/etc/java-11-openjdk`, 1 to the CA store). A folder fingerprint records the link, not the target, so
  `java-settings` and the CA store are measured as separate components.
- The CA store files differ in bytes between nodes (same size, same 121 certificates, same package versions) but the sorted fingerprint lists are identical. Pin the list, not the raw file.
- `classes.jsa` is generated per machine. A single measured image would share one copy; excluding it without disabling the cache would leave it unmeasured. Decision deferred (ADR-009).
- The worker holds no job file, so the jar's fingerprint cannot be in the worker's boot-time measurement; the handoff's per-task record mechanism covers that (a later milestone).
- Hadoop lives in the user's home folder, writable by the lab user; its changing data lives outside it (`~/hadoop-data`), and only `~/hadoop/logs` needs excluding.
- Measuring `hadoop-code` takes about 60 seconds on these VMs; the whole master pass 1 minute 9 seconds.
- Digests computed on the old 6.8 boot equalled those measured on the 6.17 boot for seven of the eight master components, so the measurement is repeatable across the kernel change.

## 7. The kernel

- The kernel documentation lists the `rtmr[0123]:sha384` files under `/sys/devices/virtual/misc/tdx_guest/measurements/` as new in v6.16 (page: kernel.org
  `Documentation/ABI/testing/sysfs-devices-virtual-misc-tdx_guest`; plain text, so search for `KernelVersion: v6.16`). A kernel log mirror shows the 6.16 pull request adding the kernel function that extends the registers (not independently checked).
  Our 6.8 kernels lack the option and the files, so an upgrade was needed.
- Ubuntu 22.04 (our VMs) offers Google-cloud kernels only up to 6.8. Ubuntu 24.04 offers 6.17 and 7.0. The 6.17.0-1022-gcp build has `CONFIG_TSM_MEASUREMENTS=y`, and ext4, NVMe,
  virtio and SCSI built in, which matters because these images boot **without an initramfs** (`GRUB_FORCE_PARTUUID`).
- Route chosen (no new VM): install the signed `linux-image-6.17.0-1022-gcp` (16,068,900 bytes) and `linux-modules-6.17.0-1022-gcp` (40,151,232 bytes) from Ubuntu's archive onto the existing 22.04
  VMs, checked against the archive's SHA-256 values. This combination is not supported by Ubuntu. Safeguards: a disk snapshot first (`tdx-lab-pre-kernel-1005`, 50 GB; `tdx-lab-worker-pre-kernel-1005`, 10 GB),
  a GRUB backup, a file `zz-saved-default.cfg` (`GRUB_DEFAULT=saved`), the running kernel pinned as the default, and `grub-reboot` for one boot into 6.17. A reset therefore returns to the old kernel.
- Secure Boot is off on both nodes (efivar value 0; `mokutil`: disabled on the master).
- Master timeline: pin set and a test reboot (came back on 6.8.0-1067, as pinned); packages installed 17:05; one-time boot into 6.17 at 17:15:31. Worker: prep script at 18:46, boot into 6.17 at 18:47:47.
- After the one-time boots both nodes are on 6.17.0-1022-gcp, but a further reboot returns them to their pinned 6.8 kernels. RTMR3 resets at every boot, so the measurement must be redone each time.

## 8. What was not done

- **No lock-down.** The stack is measured after boot and before the crawl, and re-hashed after it (section 10). Nothing prevents a change between measuring and running; the root disk and its tools are not covered by any boot measurement
  we saw. Read-only root, no login and measurement at launch belong to a later milestone.
- **No known-good reference.** Digests are compared between nodes and across time, not against an independently built reference. A reproducible build would supply one.
- **MRTD not checked against Google's launch endorsement; no reference values for RTMR0 to RTMR2.**
- **Measurement is manual.** It runs from scripts we start, not from a boot service.
- **The worker is measured on five components only,** and the JDK difference was recorded, not resolved.
- **`Boot0002` not decoded; `td_attributes` and the TCB SVN were not re-read from the 6.17 quotes; MRTD of the 6.17 quotes was not printed.**
- **TLS certificate checking is still off.** A teammate's source-receipt code, which validates certificates itself and refuses to issue receipts for failures, is relayed, not tested by us (ADR-002).

## 9. Our own event log, quotes and replay

- `rtmr3-extend.sh` hashes a file or folder, writes the 48-byte digest to `rtmr3:sha384`, reads the register back and checks it equals `SHA-384(before + digest)`, and appends `name, digest, before, after` to a tab-separated log. Both writes succeeded on both nodes (each extension was checked).
- The quote is requested with the log as its input, so REPORTDATA is the log's SHA-512.
- Order: the worker's script measures before it restarts the node's Hadoop daemons. The master was measured with its daemons already running (restarted after the reboot), before the crawl.
- `rtmr3_replay.py` replays the log from zeros, checks each recorded step, compares the result with the quote's RTMR3 (offset 520) and checks REPORTDATA.

| Node | Events | Final RTMR3 (12 hex) | Quote |
|---|---|---|---|
| Master | 10: `test-marker`, `nutch-job`, `jdk`, `java-settings`, `java-ca-fingerprints`, `hadoop-code`, `hadoop-conf`, `nutch-deploy`, `driver`, `seeds` | `38a7e9661385` | `MATCH`, REPORTDATA `YES`; signature verified on the laptop with `-get_collateral=true -check_crl=true` (three warnings about the embedded Intel root); replay also run on the laptop |
| Worker | 5: `jdk`, `java-settings`, `java-ca-fingerprints`, `hadoop-code`, `hadoop-conf` | `928c8193b9cd` | same results |

The master's chain still contains the first test marker (`test-marker`, then `nutch-job`), because an extension cannot be undone until the next reboot. A clean chain needs a reboot, which a boot service will give.
A second master quote taken after the crawl had the same RTMR3 and REPORTDATA.

## 10. The crawl on the measured stack (run 4)

Seeds `seeds-run4`, crawl `crawl-run4`; segments `20261005175641`, `20261005175947`, `20261005180333`; about 17:56 to 18:07; `Finished loop with 3 iterations`; no failure lines found by the scan; 18 WARC and index files verified.
Compared with run 3 by the shell: `SAME-PAGES` and the same eight URL and IP pairs. A check that recomputes every measured digest after the crawl (`check-unchanged.sh`) printed `ALL-UNCHANGED` for all ten components, twice.
This is a point-in-time check: it cannot show that nothing changed during the run.

## 11. Operational events worth knowing

- **The worker's NodeManager exited.** With the master's ResourceManager down for about 23 minutes (stopped 17:08, restarted about 17:31), the worker's log shows it retrying the ResourceManager until 17:29:08 and then shutting down. It had to be started by hand. After any long master outage, check `jps` on the worker.
- **The master booted twice after the first reboot.** The journal shows a manual `sudo reboot` at 16:48:16 from an SSH session opened at 16:47:55. No automatic restart occurred, and no evidence belongs to the extra boot.
- The worker's NodeManager was stopped with `kill -9` by Hadoop after 5 seconds during the worker's prep; the node was idle.

## 12. Differences from the handoff (to apply to the handoff later)

1. Run 3 is not byte-comparable with runs 1 and 2 (the configuration is inside the job file).
2. Line 187, "identify the JDK": the JDK folder alone does not do it; JDK settings and the CA store live in `/etc`.
3. Line 187, an image digest on an allowlist: raw register values depend on disk identifiers, partition growth on the first boot and GRUB state. A verifier needs event-level policy.
4. The kernel requirement (6.16 or later) is confirmed. A 6.17 Google kernel exists for Ubuntu 24.04 and works, installed on Ubuntu 22.04, on these VMs. It exists for 22.04 only up to 6.8.
5. Lines 189 and 190 (substrate, TLS) now have mentor answers (ADR-001, ADR-002).
6. Line 181: the worker holds no job file; the jar digest needs the task-record mechanism.
7. YARN kept no container logs on this cluster, and the worker's local task logs were removed.
8. The handoff's Hadoop source references are from release 3.4.1 (line 153); the cluster runs 3.4.3.
9. Line 239 (does the 6.17 kernel expose RTMR extension and the boot log): yes, for Ubuntu 6.17.0-1022-gcp on these VMs, both nodes. Line 244 (why RTMR0 to RTMR2 differ between nodes): kernel, GRUB configuration and state, disk identifiers and partition growth; one RTMR0 event is not decoded.

## 13. Evidence (kept outside the repository)

| Bundle | Entries | Fingerprint (12 hex) | Contents |
|---|---|---|---|
| `evidence-m1.tar.gz` | 9 (by count of its contents; not counted directly) | `138a151acd79` | boot logs (6.8, both nodes), replay and diff scripts and outputs |
| `evidence-m1b.tar.gz` | 24 | `1b2c7d914ab5` | component manifests (both nodes), master vs worker comparison, JDK diff |
| `evidence-m1c.tar.gz` | 9 | `0221a95c0710` | first RTMR3 test: two events, quote, replay |
| `evidence-m1d.tar.gz` | 19 | `c7d1d2b516af` | master's ten-event chain, quote, manifests |
| `evidence-run4.tar.gz` | 32 | `a994a69cd7b5` | run 4 WARC, logs, unchanged-check, second quote |
| `evidence-worker-m1.tar.gz` | 18 | `bb229e51adea` | worker's five-event chain, quote, 6.17 boot log |
| `evidence-m1-closure.tar.gz` | 8 | `ef7a6f2257ba` | 6.17 boot-log replay, GPT comparison, cloud-init growpart lines |

All were compared by PowerShell on the laptop against their `.sha256` files (`MATCH`) and unpacked into `tdx-evidence\extracted`. Four RTMR3 quotes had their signatures verified on the laptop with the strict flags: the master's two-event quote (`evidence-m1c`), its ten-event quote (`evidence-m1d`), its second quote after run 4 (`evidence-run4`) and the worker's quote.

## 14. Scripts (committed)

On branch `feat/tee-hadoop-cluster`, commits `fae1ba5`, `1eb09e3`, `24c31a5`, `799e964`; a fresh clone matched the tested fingerprints.

| Script | Folder | Purpose |
|---|---|---|
| `rtmr3-extend.sh`, `measure-all.sh`, `check-unchanged.sh`, `treehash.sh`, `rtmr3_replay.py`, `worker-post-boot.sh` | `attest/measure/` | extend and log, measure the stack, re-hash and compare, folder fingerprint, replay, the worker's post-boot pass |
| `ccel_replay.py`, `ccel_diff.py`, `gpt_diff.py` | `attest/measure/` | replay the firmware log, compare two logs, compare the partition-table event |
| `worker-kernel-prep.sh` | `ops/` | backup, pin, install the 6.17 packages, request one boot, stop the node's Hadoop daemons |

## 15. Decisions taken at this milestone

ADR-003 (kernel route), ADR-004 (one RTMR3 event per component, own log), ADR-005 (pin the CA fingerprint list), ADR-006 (JDK settings and CA store separate), ADR-008 (scripts in the repo, evidence outside), ADR-009 (JDK start-up cache, deferred), ADR-010 (measure at run time now, lock down later). See [decisions.md](decisions.md).
