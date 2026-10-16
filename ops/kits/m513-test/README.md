# m513t: baby step 5.1.3, part 1: the wrapper with the real key (signing service, key bundles, key list), built and tested in a scratch clone (nothing on the cluster is touched)

Run on the master:  bash ops/attested/m513-test.sh COMMIT HER_PATCH HER_SHA256 patch/m513-wrapper.patch OUR_SHA256
patch/m513-wrapper.patch (10 files against branch head ee6571e6fcd400e9868067d30ad77202cec67e84): the signing service (KeyService: the key is made at start, kept in memory only, signs only the wrapper's
statements and only for its own key id, loopback socket with a token, audit log), the key bundle (KeyBundle: the statement and the quote, with the quote's REPORTDATA = SHA-512 of the statement,
as attest/quote.sh writes it), the key list (KeyList and the BundleCheck hook for step 5.2.1), the wrapper's side (ServiceKeys, AttestedKeyFactory, and one new setting attested.keys.provider in
AttestedHdfsFileSystem; the default stays the test key), two key tool commands (bundle-info, bundle-verify), 68 core checks (KeyCoreTest) and 21 wrapper checks in the smoke test
(real service, real list, attacks with a test key, an unlisted real key and a changed signature; service stopped; restart; a key without a quote).
Everything is off by default. The real-HDFS mode of the smoke test also runs the 21 new checks against the real HDFS, with a stand-in for the quote command (the quotes of real hardware come in the window).
Unpacking drops the executable flag: run  chmod +x ~/m513tbkit/m513tb/m513t/ops/attested/*.sh ~/m513tbkit/m513tb/m513b/ops/attested/*.sh  after unpacking.
