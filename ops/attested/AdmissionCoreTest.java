/*
 * Licensed to the Apache Software Foundation (ASF) under one or more
 * contributor license agreements.  See the NOTICE file distributed with
 * this work for additional information regarding copyright ownership.
 * The ASF licenses this file to You under the Apache License, Version 2.0
 * (the "License"); you may not use this file except in compliance with
 * the License.  You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package org.apache.nutch.attested;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Base64;
import java.util.Collections;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import org.apache.hadoop.conf.Configuration;

/**
 * Tests of step 5.2.1: the offline verification of real TDX quotes (two quotes of run 15 are the test vectors), the reference file, the admission check,
 * the key list with admission, the settings and the tool. Every decision of the step is shown to flip with ONE edit: a line of the reference file, the enforce
 * setting or the pinned root.
 */
public final class AdmissionCoreTest {
  static int pass = 0;
  static int fail = 0;
  static final Instant NOW = Instant.parse("2026-10-16T12:00:00Z");
  static final Set<String> ROOT = Collections.singleton(QuoteAdmission.INTEL_SGX_ROOT_SHA256);

  static void chk(String what, boolean ok) {
    if (ok) { pass++; System.out.println("  pass: " + what); } else { fail++; System.out.println("  FAIL: " + what); }
  }

  interface Thrower { void run() throws Exception; }

  static boolean refuses(Thrower t, String text) {
    try { t.run(); return false; } catch (Exception e) { return e.getMessage() != null && e.getMessage().contains(text); }
  }

  static boolean accepts(Thrower t) {
    try { t.run(); return true; } catch (Exception e) { System.out.println("      unexpected: " + e.getMessage()); return false; }
  }

  static byte[] flip(byte[] q, int at) { byte[] c = q.clone(); c[at] ^= 0x01; return c; }

  static String hex(byte[] b) { return MerkleHasher.hex(b); }

  static void verify(byte[] quote) throws Exception { QuoteVerifier.verify(QuoteVerifier.parse(quote), ROOT, true, NOW); }

  static String refText(String mrtd, String rtmr0M, String rtmr0W, String rtmr1M, String rtmr1W, String rtmr2M, String rtmr2W) {
    return "MRTD " + mrtd + " *\nRTMR0 " + rtmr0M + " tdx-lab\nRTMR0 " + rtmr0W + " tdx-lab-worker\nRTMR1 " + rtmr1M + " tdx-lab\nRTMR1 " + rtmr1W + " tdx-lab-worker\nRTMR2 " + rtmr2M + " tdx-lab\nRTMR2 " + rtmr2W + " tdx-lab-worker\n";
  }

  static AdmissionReference refOf(Path tmp, String name, String text) throws IOException {
    Path f = tmp.resolve(name); Files.write(f, text.getBytes(StandardCharsets.UTF_8)); return AdmissionReference.load(f, "");
  }

  static QuoteAdmission adm(AdmissionReference r, String enforce, Set<String> roots, boolean dates) throws IOException {
    return new QuoteAdmission(r, QuoteAdmission.registers(enforce), roots, dates, () -> NOW);
  }

  public static void main(String[] args) throws Exception {
    Path vec = Paths.get(System.getProperty("m521.vectors", "ops/attested/testdata"));
    Path realRef = Paths.get(System.getProperty("m521.reference", "ops/attested/reference-measurements-m521.txt"));
    Path tmp = Files.createTempDirectory("admission");
    KeyBundle m = KeyBundle.decode(Files.readAllBytes(vec.resolve("TDX-428f3734fdb03238.attestkey")));
    KeyBundle w = KeyBundle.decode(Files.readAllBytes(vec.resolve("TDX-5fdb825500807c66.attestkey")));
    m.checkBinding(); w.checkBinding();

    System.out.println("== 1. two REAL quotes (run 15) verify offline: the certificate chain to Intel's root, the quoting enclave's report, the quote's signature");
    QuoteVerifier.Quote qm = QuoteVerifier.parse(m.quote); QuoteVerifier.Quote qw = QuoteVerifier.parse(w.quote);
    chk("the master's quote is version 4, ECDSA P-256, a TDX quote", qm.version == 4 && qm.attKeyType == 2 && qm.teeType == 0x81);
    chk("the master's quote verifies", accepts(() -> verify(m.quote)));
    chk("the worker's quote verifies", accepts(() -> verify(w.quote)));
    chk("the registers are the ones documented for these machines (MRTD c1ee9c16e3af, RTMR0 036d0bf4b669 and 5e276dcf6867)", qm.register("mrtd").startsWith("c1ee9c16e3af") && qm.register("rtmr0").startsWith("036d0bf4b669") && qw.register("rtmr0").startsWith("5e276dcf6867") && qw.register("mrtd").equals(qm.register("mrtd")));
    chk("the two machines have different RTMR3 (the registers differ, so the quotes are not copies)", !qm.register("rtmr3").equals(qw.register("rtmr3")));

    System.out.println("== 2. the dates and the pinned root");
    chk("before the PCK certificate's notBefore (1 August 2026) the quote is refused", refuses(() -> QuoteVerifier.verify(qm, ROOT, true, Instant.parse("2026-08-01T00:00:00Z")), "certificate chain"));
    chk("after the PCK certificate expired (2034) the quote is refused", refuses(() -> QuoteVerifier.verify(qm, ROOT, true, Instant.parse("2034-01-01T00:00:00Z")), "certificate chain"));
    chk("... and with the date check switched off (one setting) it passes again", accepts(() -> QuoteVerifier.verify(qm, ROOT, false, Instant.parse("2034-01-01T00:00:00Z"))));
    chk("another root fingerprint is not trusted", refuses(() -> QuoteVerifier.verify(qm, Collections.singleton("00".repeat(32)), true, NOW), "not one of the trusted roots"));
    chk("an empty list of roots verifies nothing", refuses(() -> QuoteVerifier.verify(qm, new HashSet<>(), true, NOW), "no trusted root"));

    System.out.println("== 3. one flipped bit in each part of the quote is found");
    int sig = 636;
    chk("in the quote's own signature", refuses(() -> verify(flip(m.quote, sig + 5)), "signature of the quote does not verify"));
    chk("in the header (the quoting enclave's version)", refuses(() -> verify(flip(m.quote, 8)), "signature of the quote does not verify"));
    chk("in MRTD (the measurement that a machine cannot change without the signature failing)", refuses(() -> verify(flip(m.quote, 184)), "signature of the quote does not verify"));
    chk("in RTMR3", refuses(() -> verify(flip(m.quote, 520)), "signature of the quote does not verify"));
    chk("in the attestation key", refuses(() -> verify(flip(m.quote, sig + 64 + 3)), "does not name the attestation key"));
    chk("in the quoting enclave's report", refuses(() -> verify(flip(m.quote, sig + 128 + 6 + 10)), "quoting enclave's report does not verify"));
    chk("in the quoting enclave's signature", refuses(() -> verify(flip(m.quote, sig + 128 + 6 + 384 + 7)), "quoting enclave's report does not verify"));
    chk("in the quoting enclave's authentication data", refuses(() -> verify(flip(m.quote, sig + 128 + 6 + 448 + 2 + 3)), "does not name the attestation key"));
    int pemAt = new String(m.quote, StandardCharsets.ISO_8859_1).indexOf("-----BEGIN CERTIFICATE-----");
    chk("in the PCK certificate (one character of its text)", refuses(() -> verify(flip(m.quote, pemAt + 120)), "certificate chain"));
    chk("in the platform CA certificate", refuses(() -> verify(flip(m.quote, new String(m.quote, StandardCharsets.ISO_8859_1).indexOf("-----BEGIN CERTIFICATE-----", pemAt + 30) + 130)), "certificate chain"));
    String pem = new String(qm.pemChain, StandardCharsets.US_ASCII);
    int second = pem.indexOf("-----END CERTIFICATE-----") + "-----END CERTIFICATE-----".length();
    byte[] leafOnly = Arrays.copyOf(pem.getBytes(StandardCharsets.US_ASCII), second);
    chk("a chain that stops at the leaf (no root) is refused", refuses(() -> QuoteVerifier.verify(withChain(qm, leafOnly), ROOT, true, NOW), "does not reach a root"));
    int third = pem.indexOf("-----END CERTIFICATE-----", second) + "-----END CERTIFICATE-----".length();
    byte[] noRoot = Arrays.copyOf(pem.getBytes(StandardCharsets.US_ASCII), third);
    chk("a chain without the root certificate is refused", refuses(() -> QuoteVerifier.verify(withChain(qm, noRoot), ROOT, true, NOW), "certificate chain"));
    chk("the other machine's chain does not fit this machine's quote", refuses(() -> QuoteVerifier.verify(withChain(qm, qw.pemChain), ROOT, true, NOW), "does not verify"));

    System.out.println("== 4. a quote that is not what it should be");
    chk("a short quote", refuses(() -> QuoteVerifier.parse(Arrays.copyOf(m.quote, 500)), "too short"));
    byte[] v3 = m.quote.clone(); v3[0] = 3;
    chk("version 3", refuses(() -> QuoteVerifier.parse(v3), "version 3 is not supported"));
    byte[] sgx = m.quote.clone(); sgx[4] = 0;
    chk("an SGX quote (tee type 0)", refuses(() -> QuoteVerifier.parse(sgx), "not a TDX quote"));
    byte[] ak = m.quote.clone(); ak[2] = 3;
    chk("another attestation key type", refuses(() -> QuoteVerifier.parse(ak), "attestation key type 3"));
    byte[] tail = m.quote.clone(); tail[tail.length - 1] = 1;
    chk("a non-zero byte after the signature data", refuses(() -> QuoteVerifier.parse(tail), "non-zero bytes after"));
    byte[] big = m.quote.clone(); big[632 + 3] = (byte) 0x7f;
    chk("a signature data length that does not fit", refuses(() -> QuoteVerifier.parse(big), "does not fit the quote"));
    byte[] outer = m.quote.clone(); outer[636 + 128] = 7;
    chk("an unsupported outer certification data type", refuses(() -> QuoteVerifier.parse(outer), "not of type 6"));
    byte[] inner = m.quote.clone(); inner[636 + 128 + 6 + 448 + 2 + 32] = 4;
    chk("an unsupported certification data type (not a PCK chain)", refuses(() -> QuoteVerifier.parse(inner), "not 5"));
    chk("a raw signature of the wrong length", refuses(() -> QuoteVerifier.derOf(new byte[63]), "64 bytes"));

    System.out.println("== 5. the reference file");
    String good = refText(qm.register("mrtd"), qm.register("rtmr0"), qw.register("rtmr0"), qm.register("rtmr1"), qw.register("rtmr1"), qm.register("rtmr2"), qw.register("rtmr2"));
    AdmissionReference ref = refOf(tmp, "good.txt", "# a comment\n\n" + good);
    chk("comments and empty lines are ignored; the allowed values are found per host", ref.allows("mrtd", qm.register("mrtd"), "any-host") && ref.allows("rtmr0", qm.register("rtmr0"), "tdx-lab") && !ref.allows("rtmr0", qm.register("rtmr0"), "tdx-lab-worker"));
    chk("the shipped reference file (made from these two quotes) loads", accepts(() -> AdmissionReference.load(realRef, "")));
    chk("a bad register name is refused with its line number", refuses(() -> refOf(tmp, "b1.txt", "MRTD " + "0".repeat(96) + "\nFOO " + "0".repeat(96) + "\n"), "reference line 2: unknown register FOO"));
    chk("a value of the wrong length is refused", refuses(() -> refOf(tmp, "b2.txt", "MRTD abc\n"), "must be 96 hex digits"));
    chk("a line with four fields is refused", refuses(() -> refOf(tmp, "b3.txt", "MRTD " + "0".repeat(96) + " * x\n"), "expected REGISTER VALUE [HOST]"));
    chk("a bad host is refused", refuses(() -> refOf(tmp, "b4.txt", "MRTD " + "0".repeat(96) + " bad host!\n"), "reference line 1"));
    chk("a missing file is refused", refuses(() -> AdmissionReference.load(tmp.resolve("nowhere.txt"), ""), "cannot be read"));
    String realSha = AdmissionReference.load(realRef, "").sha256;
    chk("a pin that equals the file's SHA-256 is accepted, another pin is refused", accepts(() -> AdmissionReference.load(realRef, realSha)) && refuses(() -> AdmissionReference.load(realRef, "0".repeat(64)), "pin"));

    System.out.println("== 6. admission: each decision flips with ONE edit");
    QuoteAdmission base = adm(ref, QuoteAdmission.DEFAULT_ENFORCE, ROOT, true);
    chk("both real machines are admitted with the reference and the default enforce list", accepts(() -> base.check(m)) && accepts(() -> base.check(w)));
    chk("the audit note says which registers were enforced and that RTMR3 is only shown", base.note(m).contains("mrtd=c1ee9c16e3af(enforced)") && base.note(m).contains("rtmr3=0e137cc3e973(shown only)"));
    AdmissionReference wrongMrtd = refOf(tmp, "e1.txt", good.replace(qm.register("mrtd"), "ab".repeat(48)));
    chk("EDIT 1: change MRTD in the reference: both are refused, and the message names MRTD and the allowed value", refuses(() -> adm(wrongMrtd, QuoteAdmission.DEFAULT_ENFORCE, ROOT, true).check(m), "MRTD of tdx-lab is c1ee9c16e3af..., which the reference does not allow (allowed: abababababab...)"));
    AdmissionReference swapped = refOf(tmp, "e2.txt", good.replace("RTMR0 " + qm.register("rtmr0") + " tdx-lab\n", "RTMR0 " + qm.register("rtmr0") + " tdx-lab-worker\n").replace("RTMR0 " + qw.register("rtmr0") + " tdx-lab-worker\n", "RTMR0 " + qw.register("rtmr0") + " tdx-lab\n"));
    chk("EDIT 2: put the RTMR0 values on the other hosts: the machines are refused (values are per host)", refuses(() -> adm(swapped, QuoteAdmission.DEFAULT_ENFORCE, ROOT, true).check(m), "RTMR0 of tdx-lab"));
    chk("EDIT 3: take rtmr0 out of the enforce setting: the same wrong reference now admits the machine", accepts(() -> adm(swapped, "mrtd,rtmr1,rtmr2", ROOT, true).check(m)));
    chk("EDIT 4: enforce RTMR3 although the reference has no RTMR3 line: refused, and it says why", refuses(() -> adm(ref, "mrtd,rtmr3", ROOT, true).check(m), "the reference has no value for RTMR3, which is enforced"));
    AdmissionReference withR3 = refOf(tmp, "e3.txt", good + "RTMR3 " + qm.register("rtmr3") + " tdx-lab\nRTMR3 " + qw.register("rtmr3") + " tdx-lab-worker\n");
    chk("EDIT 5: add the two RTMR3 lines and enforce rtmr3: admitted (RTMR3 can be enforced without changing any code)", accepts(() -> adm(withR3, "mrtd,rtmr0,rtmr1,rtmr2,rtmr3", ROOT, true).check(m)) && adm(withR3, "mrtd,rtmr3", ROOT, true).note(m).contains("rtmr3=0e137cc3e973(enforced)"));
    chk("EDIT 6: another pinned root: refused", refuses(() -> adm(ref, QuoteAdmission.DEFAULT_ENFORCE, Collections.singleton("11".repeat(32)), true).check(m), "not one of the trusted roots"));
    chk("EDIT 7: a wildcard host line (a value allowed for any host) admits the worker with the master's RTMR0, which the per-host file refuses", refuses(() -> adm(refOf(tmp, "e4a.txt", good.replace("RTMR0 " + qw.register("rtmr0") + " tdx-lab-worker\n", "")), QuoteAdmission.DEFAULT_ENFORCE, ROOT, true).check(w), "RTMR0 of tdx-lab-worker") && accepts(() -> adm(refOf(tmp, "e4b.txt", good.replace("RTMR0 " + qw.register("rtmr0") + " tdx-lab-worker\n", "RTMR0 " + qw.register("rtmr0") + " *\n")), QuoteAdmission.DEFAULT_ENFORCE, ROOT, true).check(w)));
    chk("an empty enforce list admits by the quote alone (the chain and the binding)", accepts(() -> adm(ref, "", ROOT, true).check(m)));
    chk("an unknown register in the enforce setting is refused", refuses(() -> QuoteAdmission.registers("mrtd,rtmr9"), "unknown register in the enforce list"));
    chk("a root that is not 64 hex digits is refused (colons are accepted)", refuses(() -> QuoteAdmission.rootList("zz"), "64 hex digits") && QuoteAdmission.rootList("44:a0:19:6b:2b:99:f8:89:b8:e1:49:e9:5b:80:7a:35:0e:74:24:96:43:99:e8:85:a7:cb:b8:cc:fa:b6:74:d3").contains(QuoteAdmission.INTEL_SGX_ROOT_SHA256));
    KeyBundle noQuote = KeyBundle.decode(("ATTESTED-KEY-BUNDLE 1\nstatement=" + Base64.getEncoder().encodeToString(m.statement) + "\nquote=none\n").getBytes());
    chk("a bundle without a quote cannot be admitted", refuses(() -> base.check(noQuote), "has no quote"));

    System.out.println("== 7. the key list with admission, and its audit lines");
    Path list = tmp.resolve("list"); Files.createDirectories(list);
    Files.copy(vec.resolve("TDX-428f3734fdb03238.attestkey"), list.resolve("TDX-428f3734fdb03238.attestkey")); Files.copy(vec.resolve("TDX-5fdb825500807c66.attestkey"), list.resolve("TDX-5fdb825500807c66.attestkey"));
    List<String> lines = new ArrayList<>();
    KeyList kl = new KeyList(list, false, base, 0); kl.setSink(lines::add);
    chk("both real keys are trusted by a list that admits by quote", kl.publicKey(m.keyId) != null && kl.publicKey(w.keyId) != null && kl.size() == 2);
    kl.refresh();
    chk("each admission is reported once (a second reading adds no line), with the registers that were checked", lines.size() == 2 && lines.get(0).startsWith("ADMIT key=TDX-") && lines.get(0).contains("(enforced)"));
    Path badDir = tmp.resolve("svc-fake"); java.nio.file.Path fq = tmp.resolve("fake-quote.sh");
    Files.write(fq, ("#!/usr/bin/env bash\npython3 - \"$1\" \"$2\" <<'PY'\nimport hashlib, sys\nst = open(sys.argv[1], 'rb').read()\nq = bytearray(b'\\x04\\x00' + b'\\x00' * 630)\nq[568:632] = hashlib.sha512(st).digest()\nopen(sys.argv[2], 'wb').write(bytes(q))\nPY\n").getBytes());
    Files.setPosixFilePermissions(fq, java.nio.file.attribute.PosixFilePermissions.fromString("rwxr-xr-x"));
    KeyService fake = KeyService.start(badDir, 0, list, fq.toString(), "rogue-node");
    chk("a key whose quote is a fake (it passes the binding check, but has no Intel chain) is NOT trusted by the admitting list", kl.publicKey(fake.keyId()) == null && kl.rejected().stream().anyMatch(r -> r.contains(fake.keyId()) && r.contains("too short")));
    chk("... and the rejection is reported with its reason", lines.stream().anyMatch(l -> l.startsWith("REJECT file=" + fake.keyId()) && l.contains("reason=")));
    chk("the same list WITHOUT admission trusts that fake key (this is the hole that step 5.2.1 closes)", new KeyList(list, false, null, 0).publicKey(fake.keyId()) != null);
    fake.close();
    AdmissionReference noHost = refOf(tmp, "e5.txt", good.replace("tdx-lab-worker", "somewhere-else"));
    KeyList kl2 = new KeyList(list, false, adm(noHost, QuoteAdmission.DEFAULT_ENFORCE, ROOT, true), 0);
    chk("a reference that does not know the worker's host refuses the worker's key and keeps the master's", kl2.publicKey(m.keyId) != null && kl2.publicKey(w.keyId) == null);

    System.out.println("== 8. the settings (the wrapper's own wiring)");
    AttestedSettings.trustAllSourcesForTesting(true);
    Configuration c = new Configuration(false);
    c.set(AttestedKeyFactory.LIST_DIR_KEY, list.toString()); c.setLong(AttestedKeyFactory.LIST_CACHE_KEY, 0);
    c.set(AttestedKeyFactory.LIST_AUDIT_FILE_KEY, tmp.resolve("keylist-audit.log").toString());
    c.setBoolean(AttestedKeyFactory.ADMISSION_ENABLED_KEY, true); c.set(AttestedKeyFactory.ADMISSION_REFERENCE_KEY, realRef.toString());
    List<String> ign = new ArrayList<>();
    Path vec2 = tmp.resolve("list-real"); Files.createDirectories(vec2);
    Files.copy(vec.resolve("TDX-428f3734fdb03238.attestkey"), vec2.resolve("TDX-428f3734fdb03238.attestkey")); Files.copy(vec.resolve("TDX-5fdb825500807c66.attestkey"), vec2.resolve("TDX-5fdb825500807c66.attestkey"));
    c.set(AttestedKeyFactory.LIST_DIR_KEY, vec2.toString());
    ServiceKeys sk = AttestedKeyFactory.service(c, false, ign);
    chk("with the settings alone (enabled + the reference file) the list admits both real keys", sk.publicKey(m.keyId) != null && sk.publicKey(w.keyId) != null);
    chk("the list's audit lines are written to the file that the setting names", Files.readAllLines(tmp.resolve("keylist-audit.log")).stream().filter(l -> l.contains(" ADMIT key=TDX-")).count() == 2);
    chk("the default of the admission is OFF: the same configuration without the enabled setting does not call the quote check at all", doesNotAdmit(vec2, tmp, ign));
    Configuration c2 = new Configuration(c); c2.unset(AttestedKeyFactory.ADMISSION_REFERENCE_KEY);
    chk("enabled without a reference file is refused at start, and says which setting is missing", refuses(() -> AttestedKeyFactory.service(c2, false, ign), AttestedKeyFactory.ADMISSION_REFERENCE_KEY));
    Configuration c3 = new Configuration(c); c3.set(AttestedKeyFactory.ADMISSION_REFERENCE_SHA_KEY, "0".repeat(64));
    chk("a reference file that does not match its pinned SHA-256 is refused at start", refuses(() -> AttestedKeyFactory.service(c3, false, ign), "pin"));
    Configuration c4 = new Configuration(c); c4.set(AttestedKeyFactory.ADMISSION_ENFORCE_KEY, "mrtd,bogus");
    chk("a bad enforce setting is refused at start", refuses(() -> AttestedKeyFactory.service(c4, false, ign), "unknown register"));
    Configuration c5 = new Configuration(c); c5.set(AttestedKeyFactory.ADMISSION_ENFORCE_KEY, "mrtd,rtmr0,rtmr1,rtmr2,rtmr3");
    chk("SETTING EDIT: enforcing rtmr3 with the shipped reference (which has no RTMR3 lines) makes the list trust nobody (fail closed), with no code change", AttestedKeyFactory.service(c5, false, ign).publicKey(m.keyId) == null);
    Configuration c6 = new Configuration(c); c6.set(AttestedKeyFactory.ADMISSION_ROOT_KEY, "22".repeat(32));
    chk("SETTING EDIT: pinning another root makes the list trust nobody", AttestedKeyFactory.service(c6, false, ign).publicKey(m.keyId) == null);
    AttestedKeyFactory.clock = () -> Instant.parse("2034-01-01T00:00:00Z");
    chk("SETTING EDIT: the clock is after the certificates expired and the dates are checked (the default): nobody is trusted", AttestedKeyFactory.service(c, false, ign).publicKey(m.keyId) == null);
    Configuration c7 = new Configuration(c); c7.setBoolean(AttestedKeyFactory.ADMISSION_DATES_KEY, false);
    chk("SETTING EDIT: attested.keys.admission.check.dates false: the same keys are trusted again", AttestedKeyFactory.service(c7, false, ign).publicKey(m.keyId) != null);
    AttestedKeyFactory.clock = Instant::now;
    AttestedSettings.trustAllSourcesForTesting(false);

    System.out.println("== 9. the tool");
    ByteArrayOutputStream o = new ByteArrayOutputStream(), e = new ByteArrayOutputStream();
    String bf = vec.resolve("TDX-428f3734fdb03238.attestkey").toString();
    int rc = AttestedKeyTool.run(new String[]{"bundle-admit", bf, realRef.toString()}, new PrintStream(o), new PrintStream(e));
    chk("bundle-admit admits the real bundle (exit 0, ADMIT line with the registers)", rc == 0 && o.toString().contains("ADMIT   key id TDX-428f3734fdb03238") && o.toString().contains("rtmr3=0e137cc3e973(shown only)"));
    o.reset(); e.reset();
    rc = AttestedKeyTool.run(new String[]{"bundle-admit", bf, realRef.toString(), "--root", "33".repeat(32)}, new PrintStream(o), new PrintStream(e));
    chk("bundle-admit with another root refuses (exit 1) and says why", rc == 1 && e.toString().contains("not one of the trusted roots"));
    o.reset(); e.reset();
    rc = AttestedKeyTool.run(new String[]{"bundle-admit", bf, realRef.toString(), "--enforce", "rtmr3"}, new PrintStream(o), new PrintStream(e));
    chk("bundle-admit with an enforced register that the reference lacks refuses", rc == 1 && e.toString().contains("RTMR3"));
    o.reset(); e.reset();
    rc = AttestedKeyTool.run(new String[]{"quote-info", bf}, new PrintStream(o), new PrintStream(e));
    chk("quote-info prints the five registers", rc == 0 && o.toString().contains("MRTD   c1ee9c16e3af") && o.toString().contains("RTMR3"));
    System.out.println("\npass: " + pass + "   fail: " + fail);
    System.out.println(fail == 0 ? "ADMISSION-PASS" : "ADMISSION-FAIL");
    if (fail != 0) System.exit(1);
  }

  /** With the admission switched off the list trusts the real keys without reading any reference and writes no admission note. */
  static boolean doesNotAdmit(Path listDir, Path tmp, List<String> ign) throws Exception {
    AttestedSettings.trustAllSourcesForTesting(true);
    Configuration c = new Configuration(false);
    c.set(AttestedKeyFactory.LIST_DIR_KEY, listDir.toString()); c.setLong(AttestedKeyFactory.LIST_CACHE_KEY, 0);
    c.set(AttestedKeyFactory.LIST_AUDIT_FILE_KEY, tmp.resolve("off-audit.log").toString());
    c.set(AttestedKeyFactory.ADMISSION_REFERENCE_KEY, "/nonexistent/reference.txt");
    ServiceKeys k = AttestedKeyFactory.service(c, false, ign);
    boolean trusts = k.publicKey("TDX-428f3734fdb03238") != null;
    boolean noNote = !Files.exists(tmp.resolve("off-audit.log")) || Files.readAllLines(tmp.resolve("off-audit.log")).stream().noneMatch(l -> l.contains("(enforced)"));
    return trusts && noNote;
  }

  /** The same quote with another certificate chain in place of its own (for the tests that cut or swap the chain). */
  static QuoteVerifier.Quote withChain(QuoteVerifier.Quote q, byte[] chain) throws IOException {
    int oldLen = q.pemChain.length; int pemAt = indexOf(q.raw, q.pemChain);
    byte[] nq = Arrays.copyOf(q.raw, pemAt + chain.length + 4);
    System.arraycopy(chain, 0, nq, pemAt, chain.length);
    long newSig = (pemAt - 636) + chain.length;
    nq[632] = (byte) newSig; nq[633] = (byte) (newSig >> 8); nq[634] = (byte) (newSig >> 16); nq[635] = (byte) (newSig >> 24);
    long outer = newSig - 128 - 6; int oAt = 636 + 128 + 2;
    nq[oAt] = (byte) outer; nq[oAt + 1] = (byte) (outer >> 8); nq[oAt + 2] = (byte) (outer >> 16); nq[oAt + 3] = (byte) (outer >> 24);
    int innerAt = pemAt - 4;
    nq[innerAt] = (byte) chain.length; nq[innerAt + 1] = (byte) (chain.length >> 8); nq[innerAt + 2] = (byte) (chain.length >> 16); nq[innerAt + 3] = (byte) (chain.length >> 24);
    return QuoteVerifier.parse(Arrays.copyOf(nq, pemAt + chain.length));
  }

  static int indexOf(byte[] hay, byte[] needle) {
    outer:
    for (int i = 0; i + needle.length <= hay.length; i++) {
      for (int j = 0; j < needle.length; j++) { if (hay[i + j] != needle[j]) continue outer; }
      return i;
    }
    return -1;
  }
}
