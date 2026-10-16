# m521t: baby step 5.2.1, part 1: readers accept only keys of attested machines: the admission of keys by their quote, built and tested in a scratch clone (nothing on the cluster is touched)

Run on the master:  bash ops/attested/m521-test.sh COMMIT HER_PATCH HER_SHA256 patch/m521-wrapper.patch OUR_SHA256
patch/m521-wrapper.patch (12 files against branch head 6051b375cfaf...): QuoteVerifier (an offline verification of a TDX quote version 4: the certificate chain in the quote to a pinned Intel root, the quoting enclave's report,
the quote's own signature; no network), AdmissionReference (the reference measurements: a plain text file, one line per allowed value, MRTD and RTMR0 to RTMR3, per host or for any host), QuoteAdmission (the check that the key
list runs on every bundle through the hook of step 5.1.3: a genuine quote, and every ENFORCED register allowed by the reference), the audit notes and reports of the key list, the settings in AttestedKeyFactory (all off or
at the decided defaults, every decision a setting or a line of the reference file), two key tool commands (quote-info, bundle-admit), 73 core checks with the two REAL quotes of run 15 as test vectors (reference file and vectors are
in ops/attested/testdata and ops/attested/reference-measurements-m521.txt), and 4 wrapper checks in the smoke test. Everything is off by default (attested.keys.admission.enabled).
ops/attested/m521-realdata.sh (run after part 2): checks the two real bundles and the whole plain copy of run 15's output in ~/run15 on the master with admission, and flips each decision with one edit.
Unpacking drops the executable flag: run  chmod +x ~/m521tbkit/m521tb/m521t/ops/attested/*.sh ~/m521tbkit/m521tb/m521b/ops/attested/*.sh  after unpacking.
