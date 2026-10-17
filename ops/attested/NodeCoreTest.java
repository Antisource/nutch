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
import java.security.MessageDigest;
import java.time.Instant;
import java.util.Arrays;
import java.util.Base64;
import java.util.Collections;
import java.util.List;

/**
 * Tests of the doorman of step 5.2.2: two REAL node bundles (made on the two real nodes on 17 October 2026, quotes verified with go-tdx-guest on the laptop) are the test vectors. Every part of the
 * decision is shown to refuse what it should: the binding, the policy table, the freshness, the quote's chain and the reference, and a rogue node with a fake quote is refused by the quote check alone.
 */
public final class NodeCoreTest {
  static int pass = 0;
  static int fail = 0;

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

  static byte[] bundleFile(String tag, byte[] statement, byte[] quote) {
    return (tag + "\nstatement=" + Base64.getEncoder().encodeToString(statement) + "\nquote=" + Base64.getEncoder().encodeToString(quote) + "\n").getBytes(StandardCharsets.UTF_8);
  }

  static NodeBundle withStatement(NodeBundle real, String statement) throws IOException {
    return NodeBundle.decode(bundleFile(NodeBundle.TAG, statement.getBytes(StandardCharsets.UTF_8), real.quote));
  }

  static byte[] fakeQuote(byte[] statement) throws Exception {
    byte[] q = new byte[632]; q[0] = 4;
    System.arraycopy(MessageDigest.getInstance("SHA-512").digest(statement), 0, q, 568, 64);
    return q;
  }

  static String stmt(NodeBundle b) { return new String(b.statement, StandardCharsets.UTF_8); }

  static MeshPolicy policyOf(Path tmp, String name, String text) throws IOException {
    Path f = tmp.resolve(name); Files.write(f, text.getBytes(StandardCharsets.UTF_8)); return MeshPolicy.load(f);
  }

  static MeshAdmission door(QuoteAdmission qa, MeshPolicy pol, long maxAge, long skew, Instant now) {
    return new MeshAdmission(MeshAdmission.of(qa), pol, maxAge, skew, () -> now);
  }

  public static void main(String[] args) throws Exception {
    Path vec = Paths.get(System.getProperty("m522.vectors", "ops/attested/testdata"));
    Path realRef = Paths.get(System.getProperty("m522.reference", "ops/attested/reference-measurements-m521.txt"));
    Path tmp = Files.createTempDirectory("node");
    byte[] mFile = Files.readAllBytes(vec.resolve("node-bundle-tdx-lab.attestnode")); byte[] wFile = Files.readAllBytes(vec.resolve("node-bundle-tdx-lab-worker.attestnode"));
    NodeBundle m = NodeBundle.decode(mFile); NodeBundle w = NodeBundle.decode(wFile);
    MeshPolicy pol = policyOf(tmp, "policy.txt", "# test\ntdx-lab 10.20.0.1 10.128.0.2\ntdx-lab-worker 10.20.0.2 10.128.0.5\n");
    AdmissionReference ref = AdmissionReference.load(realRef, "");
    QuoteAdmission qa = new QuoteAdmission(ref, QuoteAdmission.registers(QuoteAdmission.DEFAULT_ENFORCE), Collections.singleton(QuoteAdmission.INTEL_SGX_ROOT_SHA256), true, () -> m.created.plusSeconds(300));
    Instant now = m.created.plusSeconds(300);
    MeshAdmission ok = door(qa, pol, 900, 60, now);

    System.out.println("== 1. two REAL node bundles");
    chk("the master's bundle: host, mesh key, mesh address and time as captured", m.host.equals("tdx-lab") && m.meshPublic.equals("dQWkCJ+KKLMy5rCT0r6jnD7E5R0Du8UppXFkLORZoRA=") && m.meshIp.equals("10.20.0.1") && m.created.equals(Instant.parse("2026-10-17T08:14:27Z")));
    chk("the worker's bundle: host, mesh key, mesh address and time as captured", w.host.equals("tdx-lab-worker") && w.meshPublic.equals("mgzs+5CcDcTKx0dnechOgH/Sxxv6sADipwM0e9bXr2Y=") && w.meshIp.equals("10.20.0.2") && w.created.equals(Instant.parse("2026-10-17T08:14:50Z")));
    chk("each quote's REPORTDATA is the SHA-512 of its statement", accepts(m::checkBinding) && accepts(w::checkBinding));
    chk("the two machines have different mesh keys and different nonces", !m.meshPublic.equals(w.meshPublic) && !m.nonce.equals(w.nonce));

    System.out.println("== 2. the doorman admits both real nodes (5 minutes after the capture)");
    MeshAdmission.Admitted am = ok.admit(m); MeshAdmission.Admitted aw = ok.admit(w);
    chk("the master is admitted with its table address and VPC address", am.host.equals("tdx-lab") && am.meshIp.equals("10.20.0.1") && am.vpcIp.equals("10.128.0.2"));
    chk("the worker is admitted with its table address and VPC address", aw.host.equals("tdx-lab-worker") && aw.meshIp.equals("10.20.0.2") && aw.vpcIp.equals("10.128.0.5"));
    chk("the audit note names the registers that were enforced", am.note.contains("mrtd=c1ee9c16e3af(enforced)") && aw.note.contains("rtmr0=5e276dcf6867(enforced)"));

    System.out.println("== 3. a statement changed after the quote was made: the binding refuses it");
    String ms = stmt(m);
    chk("the worker's mesh key put into the master's statement (the key swap that the step exists to stop)", refuses(() -> ok.admit(withStatement(m, ms.replace(m.meshPublic, w.meshPublic))), "REPORTDATA is not the SHA-512 of the statement"));
    chk("another mesh address (10.20.0.1 became 10.20.0.9)", refuses(() -> ok.admit(withStatement(m, ms.replace("10.20.0.1", "10.20.0.9"))), "REPORTDATA is not the SHA-512 of the statement"));
    chk("another host name", refuses(() -> ok.admit(withStatement(m, ms.replace("host=tdx-lab\n", "host=tdx-lab-worker\n"))), "REPORTDATA is not the SHA-512 of the statement"));
    chk("a newer time (to make an old statement look fresh)", refuses(() -> ok.admit(withStatement(m, ms.replace("2026-10-17T08:14:27Z", "2026-10-17T08:19:27Z"))), "REPORTDATA is not the SHA-512 of the statement"));
    byte[] badRd = m.quote.clone(); badRd[570] ^= 1;
    chk("one flipped bit in the quote's REPORTDATA", refuses(() -> ok.admit(NodeBundle.decode(bundleFile(NodeBundle.TAG, m.statement, badRd))), "REPORTDATA is not the SHA-512 of the statement"));
    chk("a quote too short to hold a REPORTDATA", refuses(() -> ok.admit(NodeBundle.decode(bundleFile(NodeBundle.TAG, m.statement, Arrays.copyOf(m.quote, 100)))), "too short"));

    System.out.println("== 4. a quote changed after it was signed (the binding still holds, the signature does not)");
    byte[] badMrtd = m.quote.clone(); badMrtd[184] ^= 1;
    chk("one flipped bit in MRTD", refuses(() -> ok.admit(NodeBundle.decode(bundleFile(NodeBundle.TAG, m.statement, badMrtd))), "signature of the quote does not verify"));
    byte[] badSig = m.quote.clone(); badSig[641] ^= 1;
    chk("one flipped bit in the quote's signature", refuses(() -> ok.admit(NodeBundle.decode(bundleFile(NodeBundle.TAG, m.statement, badSig))), "signature of the quote does not verify"));

    System.out.println("== 5. freshness (made 2026-10-17T08:14:27Z, limit 900 s, skew 60 s)");
    chk("exactly at the limit (900 s) is admitted", accepts(() -> door(qa, pol, 900, 60, m.created.plusSeconds(900)).admit(m)));
    chk("one second past the limit is stale, and the message gives both numbers", refuses(() -> door(qa, pol, 900, 60, m.created.plusSeconds(901)).admit(m), "it was made 901 s ago and the limit is 900 s"));
    chk("a clock 59 s behind the node is within the skew", accepts(() -> door(qa, pol, 900, 60, m.created.minusSeconds(59)).admit(m)));
    chk("a statement dated more than the skew in the future is refused", refuses(() -> door(qa, pol, 900, 60, m.created.minusSeconds(61)).admit(m), "dated in the future"));
    chk("EDIT: a longer limit (3600 s) admits a statement that is an hour old", accepts(() -> door(qa, pol, 3600, 60, m.created.plusSeconds(3600)).admit(m)));

    System.out.println("== 6. the policy table decides the host and the address");
    MeshPolicy only = policyOf(tmp, "only-worker.txt", "tdx-lab-worker 10.20.0.2\n");
    chk("a host that is not in the table is refused", refuses(() -> door(qa, only, 900, 60, now).admit(m), "tdx-lab is not in the mesh policy table"));
    MeshPolicy other = policyOf(tmp, "other-ip.txt", "tdx-lab 10.20.0.5\ntdx-lab-worker 10.20.0.2\n");
    chk("an address that the table does not give to the host is refused, naming both", refuses(() -> door(qa, other, 900, 60, now).admit(m), "asks for the mesh address 10.20.0.1 but the policy table gives it 10.20.0.5"));
    chk("a policy line without a VPC address is allowed (the address is then empty)", policyOf(tmp, "novpc.txt", "tdx-lab 10.20.0.1\n").vpcIp("tdx-lab").isEmpty());
    chk("a policy file with a bad line is refused with its line number", refuses(() -> policyOf(tmp, "p1.txt", "tdx-lab 10.20.0.1\nbad\n"), "mesh policy line 2: expected HOST MESH_IP"));
    chk("a host listed twice is refused", refuses(() -> policyOf(tmp, "p2.txt", "a 10.20.0.1\na 10.20.0.2\n"), "listed twice"));
    chk("one address given to two hosts is refused", refuses(() -> policyOf(tmp, "p3.txt", "a 10.20.0.1\nb 10.20.0.1\n"), "given to two hosts"));
    chk("a bad address is refused", refuses(() -> policyOf(tmp, "p4.txt", "a 10.20.0.256\n"), "bad address"));
    chk("an empty policy is refused", refuses(() -> policyOf(tmp, "p5.txt", "# nothing\n"), "lists no host"));
    chk("a missing policy file is refused", refuses(() -> MeshPolicy.load(tmp.resolve("nowhere.txt")), "cannot be read"));

    System.out.println("== 7. the reference and the root, as in step 5.2.1");
    String good = new String(Files.readAllBytes(realRef), StandardCharsets.UTF_8);
    Path wrongRef = tmp.resolve("wrong-ref.txt"); Files.write(wrongRef, good.replaceFirst("MRTD [0-9a-f]{96}", "MRTD " + "ab".repeat(48)).getBytes(StandardCharsets.UTF_8));
    QuoteAdmission qaWrong = new QuoteAdmission(AdmissionReference.load(wrongRef, ""), QuoteAdmission.registers(QuoteAdmission.DEFAULT_ENFORCE), Collections.singleton(QuoteAdmission.INTEL_SGX_ROOT_SHA256), true, () -> now);
    chk("EDIT 1: one changed MRTD in the reference refuses the node, and names MRTD", refuses(() -> door(qaWrong, pol, 900, 60, now).admit(m), "MRTD of tdx-lab is c1ee9c16e3af..."));
    QuoteAdmission qaNoMrtd = new QuoteAdmission(AdmissionReference.load(wrongRef, ""), QuoteAdmission.registers("rtmr0,rtmr1,rtmr2"), Collections.singleton(QuoteAdmission.INTEL_SGX_ROOT_SHA256), true, () -> now);
    chk("EDIT 2: mrtd out of the enforce list admits it again", accepts(() -> door(qaNoMrtd, pol, 900, 60, now).admit(m)));
    QuoteAdmission qaRoot = new QuoteAdmission(ref, QuoteAdmission.registers(QuoteAdmission.DEFAULT_ENFORCE), Collections.singleton("11".repeat(32)), true, () -> now);
    chk("EDIT 3: another trusted root refuses it", refuses(() -> door(qaRoot, pol, 900, 60, now).admit(m), "not one of the trusted roots"));
    QuoteAdmission qaLate = new QuoteAdmission(ref, QuoteAdmission.registers(QuoteAdmission.DEFAULT_ENFORCE), Collections.singleton(QuoteAdmission.INTEL_SGX_ROOT_SHA256), true, () -> Instant.parse("2034-01-01T00:00:00Z"));
    chk("EDIT 4: after the certificates expired the quote is refused, and with dates off it is admitted", refuses(() -> door(qaLate, pol, 900, 60, now).admit(m), "certificate chain") && accepts(() -> door(new QuoteAdmission(ref, QuoteAdmission.registers(QuoteAdmission.DEFAULT_ENFORCE), Collections.singleton(QuoteAdmission.INTEL_SGX_ROOT_SHA256), false, () -> Instant.parse("2034-01-01T00:00:00Z")), pol, 900, 60, now).admit(m)));
    String swapped = good.replaceFirst("RTMR0 (" + "[0-9a-f]{96}" + ") tdx-lab\\n", "RTMR0 $1 tdx-lab-worker\\n");
    Path swapRef = tmp.resolve("swap-ref.txt"); StringBuilder sw = new StringBuilder();
    for (String line : good.split("\\n")) { if (line.startsWith("RTMR0 ") && line.endsWith(" tdx-lab")) { sw.append(line.replace(" tdx-lab", " tdx-lab-worker")).append("\n"); } else if (line.startsWith("RTMR0 ") && line.endsWith(" tdx-lab-worker")) { sw.append(line.replace(" tdx-lab-worker", " tdx-lab")).append("\n"); } else { sw.append(line).append("\n"); } }
    Files.write(swapRef, sw.toString().getBytes(StandardCharsets.UTF_8));
    QuoteAdmission qaSwap = new QuoteAdmission(AdmissionReference.load(swapRef, ""), QuoteAdmission.registers(QuoteAdmission.DEFAULT_ENFORCE), Collections.singleton(QuoteAdmission.INTEL_SGX_ROOT_SHA256), true, () -> now);
    chk("EDIT 5: the RTMR0 values put on the other host's lines (the reference is per host): the master is refused, naming RTMR0 of tdx-lab", refuses(() -> door(qaSwap, pol, 900, 60, now).admit(m), "RTMR0 of tdx-lab is 036d0bf4b669"));

    System.out.println("== 8. a rogue node with a fake quote is refused by the quote check alone");
    String rogueText = "ATTESTED-NODE-STATEMENT 1\nhost=tdx-lab\nmesh-public=" + "A".repeat(43) + "=\nmesh-ip=10.20.0.1\ncreated=" + m.created.plusSeconds(280) + "\nnonce=" + "0".repeat(32) + "\n";
    NodeBundle rogue = NodeBundle.decode(bundleFile(NodeBundle.TAG, rogueText.getBytes(StandardCharsets.UTF_8), fakeQuote(rogueText.getBytes(StandardCharsets.UTF_8))));
    chk("the rogue's fake quote passes the binding check (its REPORTDATA is right)", accepts(rogue::checkBinding));
    chk("the doorman refuses it: the quote is too short to be a TDX quote", refuses(() -> ok.admit(rogue), "the quote is too short (632 bytes)"));
    chk("with the quote check removed the same bundle WOULD be admitted (it is the quote check that stops it, not the other checks)", accepts(() -> new MeshAdmission((q, h) -> "no quote check", pol, 900, 60, () -> now).admit(rogue)));
    NodeBundle rogue2 = NodeBundle.decode(bundleFile(NodeBundle.TAG, rogueText.replace("host=tdx-lab\n", "host=intruder\n").getBytes(StandardCharsets.UTF_8), fakeQuote(rogueText.replace("host=tdx-lab\n", "host=intruder\n").getBytes(StandardCharsets.UTF_8))));
    chk("a host that is not in the table is refused before the quote is even looked at", refuses(() -> ok.admit(rogue2), "intruder is not in the mesh policy table"));

    System.out.println("== 9. the parser is strict");
    String sb = "ATTESTED-NODE-STATEMENT 1\nhost=tdx-lab\nmesh-public=" + m.meshPublic + "\nmesh-ip=10.20.0.1\ncreated=2026-10-17T08:14:27Z\nnonce=" + m.nonce + "\n";
    chk("the reference statement itself parses", accepts(() -> withStatement(m, sb)));
    chk("a file with another tag is refused", refuses(() -> NodeBundle.decode(bundleFile("ATTESTED-KEY-BUNDLE 1", m.statement, m.quote)), "not a node bundle"));
    chk("a file with an extra line is refused", refuses(() -> NodeBundle.decode((new String(mFile, StandardCharsets.UTF_8) + "extra=1\n").getBytes(StandardCharsets.UTF_8)), "not a node bundle"));
    chk("a file with a line missing is refused", refuses(() -> NodeBundle.decode(("ATTESTED-NODE-BUNDLE 1\nstatement=AAAA\n").getBytes(StandardCharsets.UTF_8)), "not a node bundle"));
    chk("a statement that is not valid base64 is refused", refuses(() -> NodeBundle.decode("ATTESTED-NODE-BUNDLE 1\nstatement=!!!\nquote=AAAA\n".getBytes(StandardCharsets.UTF_8)), "not valid base64"));
    chk("another statement tag is refused", refuses(() -> withStatement(m, sb.replace("NODE-STATEMENT 1", "NODE-STATEMENT 2")), "must be 'ATTESTED-NODE-STATEMENT 1'"));
    chk("fields in another order are refused", refuses(() -> withStatement(m, sb.replace("host=tdx-lab\nmesh-public=" + m.meshPublic, "mesh-public=" + m.meshPublic + "\nhost=tdx-lab")), "must have the line"));
    chk("an extra field is refused", refuses(() -> withStatement(m, sb + "extra=1\n"), "exactly the lines"));
    chk("a missing field is refused", refuses(() -> withStatement(m, sb.replace("nonce=" + m.nonce + "\n", "")), "exactly the lines"));
    chk("a mesh key of the wrong length is refused", refuses(() -> withStatement(m, sb.replace(m.meshPublic, "AAAA=")), "mesh-public is not in the required form"));
    chk("an address with an octet above 255 is refused", refuses(() -> withStatement(m, sb.replace("10.20.0.1", "10.20.0.256")), "mesh-ip is not in the required form"));
    chk("a time in another form is refused", refuses(() -> withStatement(m, sb.replace("2026-10-17T08:14:27Z", "2026-10-17 08:14:27")), "created is not in the required form"));
    chk("a nonce of the wrong length is refused", refuses(() -> withStatement(m, sb.replace(m.nonce, "abcd")), "nonce is not in the required form"));
    chk("a host name with a space is refused", refuses(() -> withStatement(m, sb.replace("host=tdx-lab\n", "host=tdx lab\n")), "host is not in the required form"));

    System.out.println("== 10. one host or one mesh key admitted once only (the roster)");
    MeshAdmission.Roster r = new MeshAdmission.Roster();
    r.add(am);
    chk("the same host twice is refused", refuses(() -> r.add(am), "already admitted from another bundle"));
    chk("another host with the same mesh key is refused, naming the first", refuses(() -> r.add(new MeshAdmission.Admitted("tdx-lab-worker", m.meshPublic, "10.20.0.2", "", "")), "mesh key is already used by the admitted host tdx-lab"));
    chk("a different host with a different key is admitted", accepts(() -> r.add(aw)) && r.size() == 2);

    System.out.println("== 11. the tool");
    Path tsv = tmp.resolve("admitted.tsv"); Path mf = vec.resolve("node-bundle-tdx-lab.attestnode"); Path wf = vec.resolve("node-bundle-tdx-lab-worker.attestnode");
    String nowArg = "2026-10-17T08:20:00Z"; ByteArrayOutputStream o = new ByteArrayOutputStream(), e = new ByteArrayOutputStream();
    int rc = AttestedKeyTool.run(new String[]{"node-admit-all", realRef.toString(), tmp.resolve("policy.txt").toString(), tsv.toString(), "--now", nowArg, mf.toString(), wf.toString()}, new PrintStream(o), new PrintStream(e));
    chk("node-admit-all admits both real nodes (exit 0, two ADMIT-NODE lines, NODES 2 admitted, 0 refused)", rc == 0 && o.toString().split("ADMIT-NODE").length == 3 && o.toString().contains("NODES 2 admitted, 0 refused"));
    List<String> rows = Files.readAllLines(tsv);
    chk("the table of admitted nodes has host, mesh key, mesh address and VPC address, tab separated", rows.size() == 2 && rows.get(0).equals("tdx-lab\t" + m.meshPublic + "\t10.20.0.1\t10.128.0.2") && rows.get(1).equals("tdx-lab-worker\t" + w.meshPublic + "\t10.20.0.2\t10.128.0.5"));
    o.reset(); e.reset();
    rc = AttestedKeyTool.run(new String[]{"node-admit-all", realRef.toString(), tmp.resolve("policy.txt").toString(), tsv.toString(), "--now", nowArg, mf.toString(), mf.toString()}, new PrintStream(o), new PrintStream(e));
    chk("the same bundle twice: exit 1, the second is REJECT-NODE (already admitted), the table has one node", rc == 1 && o.toString().contains("REJECT-NODE node-bundle-tdx-lab.attestnode: the host tdx-lab was already admitted") && Files.readAllLines(tsv).size() == 1);
    o.reset(); e.reset();
    rc = AttestedKeyTool.run(new String[]{"node-admit", mf.toString(), realRef.toString(), tmp.resolve("policy.txt").toString(), "--now", "2026-10-17T09:30:00Z"}, new PrintStream(o), new PrintStream(e));
    chk("node-admit on a stale bundle: exit 1 and the reason is printed", rc == 1 && e.toString().contains("REJECT-NODE node-bundle-tdx-lab.attestnode: the statement is stale"));
    o.reset(); e.reset();
    rc = AttestedKeyTool.run(new String[]{"node-admit", mf.toString(), realRef.toString(), tmp.resolve("policy.txt").toString(), "--now", "2026-10-17T09:30:00Z", "--max-age", "7200"}, new PrintStream(o), new PrintStream(e));
    chk("EDIT: --max-age 7200 admits the same bundle", rc == 0 && o.toString().contains("ADMIT-NODE host=tdx-lab "));
    o.reset(); e.reset();
    rc = AttestedKeyTool.run(new String[]{"node-admit", mf.toString(), realRef.toString(), tmp.resolve("policy.txt").toString(), "--bogus"}, new PrintStream(o), new PrintStream(e));
    chk("an unknown option is refused", rc != 0 && e.toString().contains("unknown option --bogus"));
    o.reset(); e.reset();
    rc = AttestedKeyTool.run(new String[]{"node-admit-all", realRef.toString(), tmp.resolve("policy.txt").toString(), tsv.toString(), "--now", nowArg}, new PrintStream(o), new PrintStream(e));
    chk("node-admit-all with no bundle is refused", rc != 0 && e.toString().contains("no node bundle given"));
    System.out.println("\npass: " + pass + "   fail: " + fail);
    System.out.println(fail == 0 ? "NODECORE-PASS" : "NODECORE-FAIL");
    if (fail != 0) System.exit(1);
  }
}
