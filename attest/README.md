# Attestation scripts

Reusable scripts for binding the output of a Hadoop/Nutch crawl to an Intel TDX quote.

## Scripts
1. `make-manifest.sh <master|worker> <file>` writes a text inventory of one node.
2. `quote.sh <file> <quote>` requests a TDX quote whose REPORTDATA is the SHA-512 of that file.
3. `verify-binding.sh <file> <quote>` checks the binding (MATCH/MISMATCH).
4. Verify the quote's signature separately with go-tdx-guest's `check` tool.

## Relationship to the recorded 10-URL crawl
The evidence from the first crawl (2026-10-02) was produced with equivalent inline
shell commands, not with these scripts. The manifests differ in field order and
wording from what `make-manifest.sh` writes. The crawl ran at the code commit
recorded in its manifest; these scripts were added afterwards.

## What a MATCH shows
The 64 bytes inside the quote equal the SHA-512 of the file. Changing the manifest
breaks that match. Changing a listed output file makes its hash differ from the one
recorded in the manifest.

## What it does not show
- That the quote is genuine until its signature is verified (step 4).
- That manifest lines are true: they are text written by a script on the VM.
- That crawled pages came from the real websites: TEEs do not authenticate the network.
- That timestamps are correct: the clock is provided by the host.
- That the boot measurements are the expected ones for the cloud's virtual firmware.