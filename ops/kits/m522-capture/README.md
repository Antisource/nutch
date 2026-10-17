# m522c: step 5.2.2, part 1: the node's quote that binds its WireGuard public key (a capture; nothing on the cluster changes)

node-attest.sh (run on a node): reads /etc/wireguard/public.key, asks the TDX guest for a quote whose REPORTDATA is the SHA-512 of a statement (host, WireGuard public key, the mesh address asked for, time, nonce),
checks the binding, and writes an ATTESTED-NODE-BUNDLE (statement + quote). It reads one public file, writes one file, and uses sudo for the quote exactly as attest/quote.sh always did.
node_bundle_extract.py takes a bundle apart (statement.txt, quote.bin) and checks the binding; the quote files are for go-tdx-guest's check on the laptop.
node-attest-rehearse.sh (18 checks): the real script with stand-ins for the TDX guest. The real bundles that this capture makes become the test vectors of the admission code of the next part.
Unpacking drops the executable flag: run  chmod +x ops/attested/*.sh  after unpacking.
