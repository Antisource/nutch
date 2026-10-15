# m512t: baby step 5.1.2, part 1: the wrapper with records bound to their folders, built and tested in a scratch clone (nothing on the cluster is touched)

Run on the master:  bash ops/attested/m512-test.sh COMMIT HER_PATCH HER_SHA256 patch/m512-wrapper.patch OUR_SHA256
patch/m512-wrapper.patch (9 files against branch head 9f4409d44fb4d6e8c5a53c91daf5ec2695b555f0): the record format ATTEST03 (the folder's ID and the file's name are signed),
the folder identity file _attested-folder (AttestedFolderCodec, AttestedFolders), the changes in AttestedHdfsFileSystem, AttestedSidecar, AttestedRecordCodec and
AttestedSignatures, 47 new smoke checks (the mentor's tamper demonstrations that move or copy signed files, renames, the reserved name, races, adoption) and 25 new core checks.
Everything is off by default: folder binding is switched on only in the site configuration (attested.folder.binding.enabled, which needs signing).
The real-HDFS mode of the smoke test also runs the signature and binding tests against the real HDFS, in scratch folders of its own.
Second version (after the first scratch run on the real master found a difference): a writer that loses the race to make a folder's identity gets, on the real HDFS,
"already being created by another client" and not "file exists"; it now reads the winner's identity. And a folder becomes a top folder only when no ancestor has
an identity; otherwise the folders in between are adopted as children, so the shape never depends on timing.
Third version: a new mode mr-bound (build-and-test.sh runs it): the word-count job through Hadoop's real output committer with signing and folder binding on and required,
checking that every output file keeps a record bound to its folder after the committer's folders, renames and merges. It is the first thing the real MapReduce libraries on the master run with binding on.
Unpacking drops the executable flag: run  chmod +x ~/m512tkit/m512t/ops/attested/*.sh  after unpacking.
