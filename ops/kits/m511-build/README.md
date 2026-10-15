# m511b: baby step 5.1.1, part 2: the job with signed records and the wrapper jar, built from the scratch tree of part 1 (nothing on the cluster is touched)

Run on the master:  bash ops/attested/m511-build.sh ~/m511/tree BASEJOB BASEJOB_SHA256 patch/m511-wrapper.patch
It builds the job with ant, compares it entry by entry with the job of 4.8.1 (only the classes of the patch may differ), builds the wrapper jar from the job's
classes, compares it class by class with the installed jar (only our classes may differ), and proves that the jar's key tool runs.
The new job and jar stay in the work folder (~/m511b); installing them is a separate, reserved step.
Unpacking drops the executable flag: run  chmod +x ~/m511bkit/m511b/ops/attested/*.sh  after unpacking.
