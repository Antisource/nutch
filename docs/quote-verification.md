# Quote verification and measurements

This records the reference exercises done on the four quotes from run 1 and run 2 (master and
worker of each): checking each quote's signature, extracting and comparing the measurement registers,
and two tamper tests (one on a manifest, one on a quote).
Evidence layout and run details are in [run-1-pilot.md](run-1-pilot.md) and [run-2-scripted.md](run-2-scripted.md).

## 1. Signature verification

Done on 3 October 2026 at about 11:37 UTC, on a Windows laptop with no Google credentials, using the
`check` tool from Google's `go-tdx-guest` project.

Time zones: the tool printed 17:07 on the laptop's clock, which is India Standard Time (UTC+5:30). Subtract
5 hours 30 minutes to get 11:37 UTC. An earlier draft of this record wrongly labelled the local time as UTC.
Times in the other sections come from the VMs, which run in UTC.

| Item | Value |
|---|---|
| Go | `go1.27.1 windows/amd64` |
| Tool | `go install github.com/google/go-tdx-guest/tools/check@latest` (module version not captured) |
| Input | The four `quote-*.bin` files unpacked from the evidence bundle (8000 bytes each) |

Basic check, one command per quote:

```powershell
& "$HOME\go\bin\check.exe" -in <quote-file> -inform bin
```

Result for all four quotes: `TDX Quote verified successfully`. Each run also printed a warning that
it used the **embedded Intel certificate** as the root of trust. The root certificate was bundled in the tool, not
supplied by the verifier.

Stricter check, with Intel's certificate data and revocation lists:

```powershell
& "$HOME\go\bin\check.exe" -in <quote-file> -inform bin -get_collateral=true -check_crl=true
```

Result for all four quotes: `TDX Quote verified successfully`.

Pitfall: the two flags need explicit values. Written as `-get_collateral -check_crl` (as in an example in the tool's
documentation), the tool reads the second flag as the value of the first and stops with
`flag -get_collateral=-check_crl invalid`.

What this shows: each quote carries a valid signature chain to Intel, so it was produced by a genuine TDX CPU and
not altered afterwards, and with the strict flags the tool also accepted the certificate data and revocation lists.
What it does not show: that the boot measurements are the expected ones, that the manifest text is true, or where the
crawled pages really came from.

## 2. Reading measurements out of a quote

Offsets are counted from the start of the raw quote, which has a 48-byte header followed by the TD report body.
They come from adding up the field sizes of the TDX quote v4 body, in the order a published field reference
lists them.

| Field | Offset | Length |
|---|---|---|
| TEE_TCB_SVN | 48 | 16 |
| MRSEAM | 64 | 48 |
| MRSIGNERSEAM | 112 | 48 |
| SEAMATTRIBUTES, TDATTRIBUTES, XFAM | 160, 168, 176 | 8 each |
| MRTD | 184 | 48 |
| MRCONFIGID, MROWNER, MROWNERCONFIG | 232, 280, 328 | 48 each |
| RTMR0, RTMR1, RTMR2, RTMR3 | 376, 424, 472, 520 | 48 each |
| REPORTDATA | 568 | 64 |

Checks that support the offsets (they are not an independent validation against Intel's specification):

- `MRSIGNERSEAM` and `MRCONFIGID` read as all zeros, as expected for those fields.
- REPORTDATA at 568 equalled the SHA-512 of run 1's master manifest.
- The layout arithmetic gives 568 for REPORTDATA, which matches the value already confirmed in all earlier quotes.

The measurements were extracted in Cloud Shell, which lacks `xxd`, using `od`:

```bash
od -An -v -tx1 -j <offset> -N 48 <quote> | tr -d ' \n'
```

## 3. Measurement results

First 12 hex characters of each 48-byte value (full values are in `~/measurements.txt` in Cloud Shell).

| Register | Master, run 1 | Master, run 2 | Worker, run 1 | Worker, run 2 | Distinct values |
|---|---|---|---|---|---|
| MRTD | `c1ee9c16e3af` | `c1ee9c16e3af` | `c1ee9c16e3af` | `c1ee9c16e3af` | 1 |
| RTMR0 | `036d0bf4b669` | `036d0bf4b669` | `5e276dcf6867` | `5e276dcf6867` | 2 |
| RTMR1 | `34eb6472351e` | `34eb6472351e` | `34f8a1d9bdca` | `34f8a1d9bdca` | 2 |
| RTMR2 | `c0b49059d19f` | `c0b49059d19f` | `cb8543db432e` | `cb8543db432e` | 2 |
| RTMR3 | all zeros | all zeros | all zeros | all zeros | 1 |

## 4. Interpretation

1. **MRTD is the same on both nodes and in both runs.** MRTD fingerprints the VM's initial contents, mainly the
   virtual firmware, so all four VMs appear to have started from the same firmware (inference). Whether that
   value is the expected one cannot be judged here: the firmware is the cloud provider's, and no reference value
   was available. This is the gap the mentor's reference note describes.
2. **RTMR0, RTMR1 and RTMR2 differ between the nodes and agree within each node across the runs.** The nodes
   run different kernels (`6.8.0-1067-gcp` and `6.8.0-1069-gcp`), which may account for part of the difference. Other boot
   differences are possible, and naming the differing events would need the boot event log, which was not examined.
3. **Agreement across runs carries no information about the crawl.** The registers cover boot, not the crawl.
   `uptime -s` (checked on 3 October, after both runs) gave a last boot of 2026-09-22 18:49:27 UTC for the master and
   2026-10-02 10:24:12 UTC for the worker. Both are before run 1's quotes (14:09 and 14:18 UTC on 2 October), so
   neither VM rebooted between the runs and equal values are expected.
4. **RTMR3 is all zeros.** It appears to be left for software to extend after boot, and nothing did.

Consequence for a verifier: one expected measurement cannot be assumed for the whole cluster. A verifier would need
expected values per node, or a way to replay the boot event log, and a trustworthy source for the firmware's expected
MRTD. Google documents a separate provenance tool for TDX VMs on its cloud; it was not tried here and is a candidate for
closing the MRTD question.

## 5. Tamper tests

### 5.1 Manifest: the binding breaks

Run on the master at 2026-10-03 12:05:55 UTC with the committed `attest/verify-binding.sh`. The log is kept as
`tamper-test-manifest.log` (copied to `~/evidence-run2/tamper-test/` in Cloud Shell) together with the tampered copy.

| Step | Result |
|---|---|
| Run 2 master manifest against its quote | `MATCH` |
| A copy was made and the first line changed from `crawl` to `Crawl` | `cmp -l` listed exactly one differing byte: position 20, octal 143 (`c`) became octal 103 (`C`) |
| SHA-256 of the original and the copy | Different (`5c9187dd8927…` and `b1248b6e362a…`) |
| Tampered copy against the **original** quote | `MISMATCH`, exit code 2 |

The original manifest was never modified; the edit was made on the copy only. The tampered copy is kept as
`manifest-master.TAMPERED.txt` (3,395 bytes).

### 5.2 Quote: the signature breaks

Done on the laptop. One bit of byte 600 of run 2's master quote (zero-based index, inside REPORTDATA) was flipped
(`$b[600] = $b[600] -bxor 1`) and the changed copy saved in a separate folder outside the repository.

| Check | Result |
|---|---|
| Both files are 8000 bytes; the only differing position is 600; SHA-256 values differ | Confirmed |
| `check` on the original quote | Exit code 0, `TDX Quote verified successfully` |
| `check` on the tampered copy | Exit code 2; the tool reported that it could not verify the message digest using the quote signature and the ECDSA attestation key |

Exit code 2 is the code the tool's documentation lists for quote verification errors. The tool's exact message
was written to `check-tampered.log` in the laptop's `tdx-evidence\tamper-test` folder, which is kept outside the repository.

### 5.3 What the two tests show together

| Layer | Edit | What detects it |
|---|---|---|
| Manifest or output files | One byte of the manifest | The quote's REPORTDATA no longer equals the SHA-512 of the file (`verify-binding.sh`) |
| The quote itself | One bit of the quote | Its Intel signature no longer verifies (`check`) |

So neither the manifest nor the quote can be edited unnoticed. This does not address whether the manifest was truthful when written.
These tests supersede the earlier hello-world tamper test, whose output was not captured.

## 6. Not done

- Comparison against any published reference value for MRTD or the RTMRs.
- Replay of the boot event log to explain the RTMR differences.
- Independent validation of the offsets against Intel's specification.
