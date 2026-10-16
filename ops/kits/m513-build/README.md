# m513b: baby step 5.1.3, part 2: the job and the wrapper jar of step 5.1.3, built in the scratch tree of part 1 (nothing on the cluster is touched)

Run on the master, after part 1 passed:
  bash ops/attested/m513-build.sh ~/m513/tree ~/m512b/new-apache-nutch-1.22.job 6f98295641a4f559 PATH/TO/m513t/patch/m513-wrapper.patch
It checks that the tree is exactly the branch head with her patch and ours, builds the job with ant, compares it with the job of step 5.1.2 entry by entry (only the 5.1.3 classes may differ),
builds the wrapper jar from the job's classes and compares it class by class with the jar of step 5.1.2 (only our classes may differ, and the 6 new classes must be there), and starts the new jar's
signing service once, with no quote command, to see that it makes a key bundle that verifies (a throw-away service key, stopped and deleted).
