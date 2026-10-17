# m522t: baby step 5.2.2, part 2: the doorman of the mesh, built and tested in a scratch clone (nothing on the cluster is touched)

Run on the master:  bash ops/attested/m522-test.sh COMMIT HER_PATCH HER_SHA256 patch/m522-wrapper.patch OUR_SHA256
patch/m522-wrapper.patch (9 files against branch head 7ff9a2d84...): NodeBundle (a node's statement and the quote that binds it: strict parser, binding check), MeshPolicy (the table of hosts that may join and the address
that each is given), MeshAdmission (the doorman's decision: binding, policy table, freshness, then the genuine-quote and reference check of step 5.2.1; and the roster that admits a host or a mesh key once only),
two key tool commands (node-admit, node-admit-all), QuoteAdmission (its quote part can now be used for a node's quote), 62 core checks with the two REAL node bundles of 17 October as test vectors (ops/attested/testdata),
and the policy table ops/attested/mesh-peers-m522.txt. Nothing of the wrapper's file system changes: the fake, committer, hash and HDFS counts are those of step 5.2.1.
Unpacking drops the executable flag: run  chmod +x ~/m522tbkit/m522tb/m522t/ops/attested/*.sh ~/m522tbkit/m522tb/m522b/ops/attested/*.sh  after unpacking.
