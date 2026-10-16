# m521b: baby step 5.2.1, part 2: the job and the wrapper jar of step 5.2.1, built in the scratch tree of part 1 (nothing on the cluster is touched)

Run on the master, after part 1 passed:
  bash ops/attested/m521-build.sh ~/m521/tree ~/m513b/new-apache-nutch-1.22.job 3a55e21d17c07d78 PATH/TO/m521t/patch/m521-wrapper.patch
It checks that the tree is exactly the branch head with her patch and ours, builds the job with ant, compares it with the job of step 5.1.3 entry by entry (only the 5.2.1 classes may differ), builds the wrapper jar from the job's
classes and compares it class by class with the jar of step 5.1.3 (only our classes may differ, and the new classes must be there), starts the new jar's signing service once to see that it still makes a key bundle that verifies,
and admits a REAL bundle of run 15 with the built jar (bundle-admit).
