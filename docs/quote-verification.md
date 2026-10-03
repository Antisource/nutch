# Quote verification and measurements

This records two reference exercises done on the four quotes from run 1 and run 2 (master and
worker of each): checking each quote's signature, and extracting and comparing the measurement registers.
Evidence layout and run details are in [run-1-pilot.md](run-1-pilot.md) and [run-2-scripted.md](run-2-scripted.md).

## 1. Signature verification

Done on 3 October 2026 (about 17:07 UTC), on a Windows laptop with no Google credentials, using the
`check` tool from Google's `go-tdx-guest` project.

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
3. **Agreement across runs is weak evidence.** The registers cover boot, not the crawl. If neither VM rebooted between
   runs, equal values are expected. Boot times were not checked.
4. **RTMR3 is all zeros.** It appears to be left for software to extend after boot, and nothing did.

Consequence for a verifier: one expected measurement cannot be assumed for the whole cluster. A verifier would need
expected values per node, or a way to replay the boot event log, and a trustworthy source for the firmware's expected
MRTD. Google documents a separate provenance tool for TDX VMs on its cloud; it was not tried here and is a candidate for
closing the MRTD question.

## 5. Not done

- Comparison against any published reference value for MRTD or the RTMRs.
- Replay of the boot event log to explain the RTMR differences.
- Independent validation of the offsets against Intel's specification.
- Checking the boot times of the VMs (`uptime -s`) against the two runs.
