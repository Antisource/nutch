# m522b: baby step 5.2.2, part 2b: the job and the wrapper jar of step 5.2.2, built in the scratch tree of part 2 (nothing on the cluster is touched)

Run on the master, after the test passed:
  bash ops/attested/m522-build.sh ~/m522/tree ~/m521b/new-apache-nutch-1.22.job 8f21a37f933ee2ca PATH/TO/m522t/patch/m522-wrapper.patch
It checks that the tree is exactly the branch head with her patch and ours, builds the job with ant, compares it with the job of step 5.2.1 entry by entry (only the 5.2.2 classes may differ), builds the wrapper jar from
the job's classes and compares it class by class with the jar of step 5.2.1, starts the jar's signing service once, and runs the new jar's doorman on the two REAL node bundles of 17 October.
