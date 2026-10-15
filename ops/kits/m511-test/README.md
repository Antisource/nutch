# m511t: baby step 5.1.1, part 1: the wrapper with signed records, built and tested in a scratch clone (nothing on the cluster is touched)

Run on the master:  bash ops/attested/m511-test.sh COMMIT HER_PATCH HER_SHA256 patch/m511-wrapper.patch OUR_SHA256
patch/m511-wrapper.patch (9 files against branch tip 0b2a7f28ebe2e9f470509763edaec7479e511cd8): the signed record format ATTEST02
(AttestedRecordCodec), the key interface (AttestedKeys), the test key (TestKeys, id TEST-...), the signature rules (AttestedSignatures),
a key tool (AttestedKeyTool), the changes in AttestedSidecar and AttestedHdfsFileSystem, the 26 new smoke checks and SigCoreTest (48 checks).
Everything is off by default: signing is switched on only in the site configuration (attested.signature.enabled).
Unpacking drops the executable flag: run  chmod +x ~/m511kit/m511t/ops/attested/*.sh  after unpacking.
