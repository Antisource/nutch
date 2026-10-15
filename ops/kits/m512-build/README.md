# m512b: baby step 5.1.2, part 2: the job and the wrapper jar with records bound to their folders, built from the scratch tree of the test kit (nothing on the cluster is touched)

Run on the master:  bash ops/attested/m512-build.sh ~/m512/tree ~/m511b/new-apache-nutch-1.22.job 9a6dcb5f0c6fbe27 patch/m512-wrapper.patch
It builds the job with ant, compares it entry by entry with the job of step 5.1.1 (only the classes of the patch may differ), builds the wrapper jar from the job's classes,
compares it class by class with the jar of step 5.1.1 in ~/m511b (only the 5.1.2 classes may differ), and proves that the jar's key tool runs.
The new job and jar stay in the work folder (~/m512b); installing them is a separate, reserved step (the window kit).
Unpacking drops the executable flag: run  chmod +x ~/m512bkit/m512b/ops/attested/*.sh  after unpacking.
