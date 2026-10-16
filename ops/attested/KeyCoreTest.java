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

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.OutputStreamWriter;
import java.io.Writer;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.nio.file.DirectoryStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.attribute.PosixFilePermissions;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Base64;
import java.util.List;
import java.util.concurrent.atomic.AtomicInteger;

/** Tests of step 5.1.3: the key bundle, the key list, the signing service, the provider and the signed formats with the real key. */
public final class KeyCoreTest {
  static int pass = 0;
  static int fail = 0;

  static void chk(String what, boolean ok) {
    if (ok) { pass++; System.out.println("  pass: " + what); } else { fail++; System.out.println("  FAIL: " + what); }
  }

  interface Thrower { void run() throws Exception; }

  static boolean refuses(Thrower t, String text) {
    try { t.run(); return false; } catch (Exception e) { return e.getMessage() != null && e.getMessage().contains(text); }
  }

  static byte[] bytes(int n, int seed) { byte[] b = new byte[n]; for (int i = 0; i < n; i++) b[i] = (byte) (i * 31 + seed); return b; }

  static Path fakeQuote(Path dir, boolean works) throws IOException {
    Path f = dir.resolve(works ? "fake-quote.sh" : "broken-quote.sh");
    String body = works
        ? "#!/usr/bin/env bash\n"
        + "python3 - \"$1\" \"$2\" <<'PY'\n"
        + "import hashlib, sys\n"
        + "st = open(sys.argv[1], 'rb').read()\n"
        + "q = bytearray(b'\\x04\\x00' + b'\\x00' * 630)\n"
        + "q[568:632] = hashlib.sha512(st).digest()\n"
        + "open(sys.argv[2], 'wb').write(bytes(q))\n"
        + "PY\n"
        : "#!/usr/bin/env bash\necho 'no TDX here' >&2\nexit 3\n";
    Files.write(f, body.getBytes(StandardCharsets.US_ASCII));
    Files.setPosixFilePermissions(f, PosixFilePermissions.fromString("rwxr-xr-x"));
    return f;
  }

  static List<String> raw(int port, String... lines) throws IOException {
    List<String> out = new ArrayList<>();
    try (Socket s = new Socket("127.0.0.1", port)) {
      s.setSoTimeout(5000);
      Writer w = new OutputStreamWriter(s.getOutputStream(), StandardCharsets.US_ASCII);
      for (String l : lines) { w.write(l + "\n"); }
      w.flush();
      BufferedReader r = new BufferedReader(new InputStreamReader(s.getInputStream(), StandardCharsets.US_ASCII));
      String x;
      while ((x = r.readLine()) != null) { out.add(x); }
    }
    return out;
  }

  static String token(Path dir) throws IOException { return new String(Files.readAllBytes(dir.resolve("token")), StandardCharsets.US_ASCII).trim(); }

  static boolean anyFileHolds(Path root, byte[] needle) throws IOException {
    String b64 = Base64.getEncoder().encodeToString(needle);
    final boolean[] found = {false};
    Files.walk(root).filter(Files::isRegularFile).forEach(p -> {
      try {
        byte[] c = Files.readAllBytes(p);
        if (indexOf(c, needle) >= 0 || new String(c, StandardCharsets.ISO_8859_1).contains(b64)) { found[0] = true; }
      } catch (IOException e) { found[0] = true; }
    });
    return found[0];
  }

  static int indexOf(byte[] hay, byte[] n) {
    outer:
    for (int i = 0; i + n.length <= hay.length; i++) {
      for (int j = 0; j < n.length; j++) { if (hay[i + j] != n[j]) continue outer; }
      return i;
    }
    return -1;
  }

  public static void main(String[] args) throws Exception {
    Path tmp = Files.createTempDirectory("keycore");
    Path quoteCmd = fakeQuote(tmp, true);
    Path badCmd = fakeQuote(tmp, false);

    System.out.println("== 1. the key bundle: well formed, bound to its statement, and refused when it is not");
    Path d1 = tmp.resolve("svc1"); Path l1 = tmp.resolve("list1");
    KeyService s1 = KeyService.start(d1, 0, l1, quoteCmd.toString(), "node-a");
    KeyBundle b = KeyBundle.decode(Files.readAllBytes(s1.bundleFile()));
    chk("the service of a TDX machine (with a quote command) makes a TDX- key", b.keyId.startsWith("TDX-") && b.keyId.equals(s1.keyId()));
    chk("the key id is TDX- and 16 hex digits of the SHA-256 of the public key", b.keyId.equals(KeyBundle.idOf("TDX-", b.publicEncoded)) && b.keyId.length() == 4 + 16);
    chk("the bundle has the quote and its REPORTDATA is the SHA-512 of the statement", b.hasQuote() && refuses(() -> { throw new IOException("x"); }, "x"));
    b.checkBinding();
    chk("the binding check passes for the genuine bundle", true);
    chk("the same bundle is written into the key list folder", Files.exists(l1.resolve(b.keyId + ".attestkey")));
    byte[] file = Files.readAllBytes(s1.bundleFile());
    chk("a bundle decodes and encodes to the same bytes", Arrays.equals(file, KeyBundle.decode(file).encode()));
    String text = new String(file, StandardCharsets.US_ASCII);
    chk("a wrong header is refused", refuses(() -> KeyBundle.decode(text.replace("ATTESTED-KEY-BUNDLE 1", "ATTESTED-KEY-BUNDLE 2").getBytes()), "not a key bundle"));
    chk("an extra line is refused", refuses(() -> KeyBundle.decode((text + "x=1\n").getBytes()), "not a key bundle"));
    chk("bad base64 is refused", refuses(() -> KeyBundle.decode(text.replace("statement=", "statement=!!").getBytes()), "bad base64"));
    byte[] statement = b.statement;
    byte[] hostChanged = new String(statement, StandardCharsets.US_ASCII).replace("host=node-a", "host=node-b").getBytes(StandardCharsets.US_ASCII);
    KeyBundle changed = KeyBundle.decode(("ATTESTED-KEY-BUNDLE 1\nstatement=" + Base64.getEncoder().encodeToString(hostChanged) + "\nquote=" + Base64.getEncoder().encodeToString(b.quote) + "\n").getBytes());
    chk("a statement changed after the quote was made (the host) no longer matches the quote's REPORTDATA", refuses(changed::checkBinding, "did not vouch for this key"));
    java.security.KeyPairGenerator gen = java.security.KeyPairGenerator.getInstance("EC"); gen.initialize(new java.security.spec.ECGenParameterSpec("secp256r1"));
    byte[] otherPub = gen.generateKeyPair().getPublic().getEncoded();
    byte[] otherKeyStatement = new String(statement, StandardCharsets.US_ASCII).replaceFirst("public=[A-Za-z0-9+/=]+", "public=" + Base64.getEncoder().encodeToString(otherPub)).getBytes(StandardCharsets.US_ASCII);
    chk("a statement with another, valid public key under the old key id is refused (the key id is not the hash of that key)", refuses(() -> KeyBundle.decode(("ATTESTED-KEY-BUNDLE 1\nstatement=" + Base64.getEncoder().encodeToString(otherKeyStatement) + "\nquote=none\n").getBytes()), "is not the hash of the public key"));
    byte[] badQuote = b.quote.clone(); badQuote[600] ^= 1;
    KeyBundle tq = KeyBundle.decode(("ATTESTED-KEY-BUNDLE 1\nstatement=" + Base64.getEncoder().encodeToString(statement) + "\nquote=" + Base64.getEncoder().encodeToString(badQuote) + "\n").getBytes());
    chk("a quote whose REPORTDATA was changed by one bit is refused", refuses(tq::checkBinding, "did not vouch for this key"));
    KeyBundle sq = KeyBundle.decode(("ATTESTED-KEY-BUNDLE 1\nstatement=" + Base64.getEncoder().encodeToString(statement) + "\nquote=" + Base64.getEncoder().encodeToString(Arrays.copyOf(b.quote, 100)) + "\n").getBytes());
    chk("a quote that is too short is refused", refuses(sq::checkBinding, "too short"));
    KeyBundle nq = KeyBundle.decode(("ATTESTED-KEY-BUNDLE 1\nstatement=" + Base64.getEncoder().encodeToString(statement) + "\nquote=none\n").getBytes());
    chk("a TDX- key with no quote is refused", refuses(nq::checkBinding, "no quote"));
    chk("the bundle tool accepts the genuine bundle", AttestedKeyTool.run(new String[]{"bundle-verify", s1.bundleFile().toString()}, new java.io.PrintStream(new java.io.ByteArrayOutputStream()), new java.io.PrintStream(new java.io.ByteArrayOutputStream())) == 0);
    java.io.ByteArrayOutputStream tOut = new java.io.ByteArrayOutputStream();
    Path tamperedFile = tmp.resolve("tampered.attestkey"); Files.write(tamperedFile, ("ATTESTED-KEY-BUNDLE 1\nstatement=" + Base64.getEncoder().encodeToString(hostChanged) + "\nquote=" + Base64.getEncoder().encodeToString(b.quote) + "\n").getBytes());
    chk("the bundle tool refuses the tampered bundle with the reason", AttestedKeyTool.run(new String[]{"bundle-verify", tamperedFile.toString()}, new java.io.PrintStream(new java.io.ByteArrayOutputStream()), new java.io.PrintStream(tOut)) == 1 && tOut.toString().contains("did not vouch"));

    System.out.println("== 2. the service: the key never leaves, only wrapper statements are signed, and only for its own key");
    int p1 = s1.port(); String t1 = token(d1);
    chk("the token file is private (mode 600)", Files.getPosixFilePermissions(d1.resolve("token")).equals(PosixFilePermissions.fromString("rw-------")));
    chk("the private key is not in any file of the service or of the list (raw bytes or base64)", !anyFileHolds(tmp, s1.privateEncodedForTest()));
    chk("ID answers the key id", raw(p1, "AUTH " + t1, "ID").equals(Arrays.asList("OK", "OK " + s1.keyId())));
    chk("PUBLIC answers the public key", raw(p1, "AUTH " + t1, "PUBLIC").get(1).equals("OK " + Base64.getEncoder().encodeToString(b.publicEncoded)));
    chk("no token: refused", raw(p1, "ID").get(0).startsWith("ERR"));
    chk("a wrong token: refused", raw(p1, "AUTH wrong", "ID").get(0).startsWith("ERR"));
    byte[] root = bytes(32, 5);
    byte[] st02 = AttestedRecordCodec.statement(s1.keyId(), 16384, 50000, root);
    List<String> ok = raw(p1, "AUTH " + t1, "SIGN " + Base64.getEncoder().encodeToString(st02));
    java.security.Signature v = java.security.Signature.getInstance("SHA256withECDSA"); v.initVerify(b.publicKey); v.update(st02);
    chk("a record statement is signed, and the signature verifies with the public key of the bundle", ok.get(1).startsWith("OK ") && v.verify(Base64.getDecoder().decode(ok.get(1).substring(3))));
    byte[] folder = new byte[16];
    byte[] st03 = AttestedRecordCodec.statementBound(s1.keyId(), folder, "part-r-00000", 16384, 50000, root);
    byte[] stfd = AttestedFolderCodec.statement(s1.keyId(), folder, "seg1", new byte[16], null);
    chk("a bound record statement and a folder identity statement are signed too",
        raw(p1, "AUTH " + t1, "SIGN " + Base64.getEncoder().encodeToString(st03)).get(1).startsWith("OK ")
        && raw(p1, "AUTH " + t1, "SIGN " + Base64.getEncoder().encodeToString(stfd)).get(1).startsWith("OK "));
    chk("an arbitrary text is not signed (no wrapper tag)", raw(p1, "AUTH " + t1, "SIGN " + Base64.getEncoder().encodeToString("hello".getBytes())).get(1).contains("unknown tag"));
    chk("a statement of the wrapper for ANOTHER key id is not signed", raw(p1, "AUTH " + t1, "SIGN " + Base64.getEncoder().encodeToString(AttestedRecordCodec.statement("TDX-0123456789abcdef", 16384, 50000, root))).get(1).contains("another key id"));
    chk("a statement of the wrapper for a key id of another length is not signed", raw(p1, "AUTH " + t1, "SIGN " + Base64.getEncoder().encodeToString(AttestedRecordCodec.statement("TDX-01", 16384, 50000, root))).get(1).contains("another key id")
        && raw(p1, "AUTH " + t1, "SIGN " + Base64.getEncoder().encodeToString(AttestedRecordCodec.statement(s1.keyId() + "0", 16384, 50000, root))).get(1).contains("another key id"));
    chk("a statement of a test key (TEST-) is not signed either", raw(p1, "AUTH " + t1, "SIGN " + Base64.getEncoder().encodeToString(AttestedRecordCodec.statement("TEST-0123456789abcdef", 16384, 50000, root))).get(1).contains("another key id"));
    chk("a statement that is too long is refused", raw(p1, "AUTH " + t1, "SIGN " + Base64.getEncoder().encodeToString(new byte[KeyService.MAX_STATEMENT + 1])).get(1).contains("too long"));
    chk("bad base64 is refused", raw(p1, "AUTH " + t1, "SIGN !!!").get(1).contains("bad base64"));
    chk("an unknown command is refused", raw(p1, "AUTH " + t1, "DELETE").get(1).contains("unknown command"));
    String log = new String(Files.readAllBytes(d1.resolve("audit.log")), StandardCharsets.UTF_8);
    chk("the audit log has a line for the start, for every signature and for every refusal", log.contains(" START key=" + s1.keyId()) && log.contains(" SIGNED ") && log.contains(" REFUSED "));
    chk("the audit log never holds a statement or a signature, only a short digest", !log.contains(Base64.getEncoder().encodeToString(st02)));
    chk("the counts agree with the log", s1.signedCount() == 3 && s1.refusedCount() >= 8);

    System.out.println("== 3. a service without a quote command makes an SVC- key; a failing quote command makes no key at all");
    Path d2 = tmp.resolve("svc2"); Path l2 = tmp.resolve("list2");
    KeyService s2 = KeyService.start(d2, 0, l2, null, "node-b");
    chk("an SVC- key, with a bundle that has no quote", s2.keyId().startsWith("SVC-") && !s2.bundle().hasQuote());
    chk("the bundle tool refuses it unless --allow-unquoted is given", AttestedKeyTool.run(new String[]{"bundle-verify", s2.bundleFile().toString()}, new java.io.PrintStream(new java.io.ByteArrayOutputStream()), new java.io.PrintStream(new java.io.ByteArrayOutputStream())) == 1
        && AttestedKeyTool.run(new String[]{"bundle-verify", s2.bundleFile().toString(), "--allow-unquoted"}, new java.io.PrintStream(new java.io.ByteArrayOutputStream()), new java.io.PrintStream(new java.io.ByteArrayOutputStream())) == 0);
    chk("a quote command that fails: the service does not start (fail closed)", refuses(() -> KeyService.start(tmp.resolve("svc3"), 0, null, badCmd.toString(), "node-c"), "quote command failed"));
    chk("every start makes a new key (the key of a restarted service is another key)", !KeyService.start(tmp.resolve("svc4"), 0, null, null, "node-b").keyId().equals(s2.keyId()));

    System.out.println("== 4. the key list trusts only the bundles that pass");
    Path list = tmp.resolve("list-main"); Files.createDirectories(list);
    Files.copy(s1.bundleFile(), list.resolve(s1.keyId() + ".attestkey"));
    Files.copy(s2.bundleFile(), list.resolve(s2.keyId() + ".attestkey"));
    Files.copy(tamperedFile, list.resolve(b.keyId.replace("TDX-", "TDX-0") + ".attestkey"));
    Files.write(list.resolve("garbage.attestkey"), "hello".getBytes());
    Files.write(list.resolve("note.txt"), "not a bundle file".getBytes());
    KeyList strict = new KeyList(list, false, null, 0);
    chk("a TDX bundle with a valid binding is trusted", strict.publicKey(s1.keyId()) != null);
    chk("a service key without a quote is not trusted by default", strict.publicKey(s2.keyId()) == null);
    chk("... and the list says why", strict.rejected().stream().anyMatch(r -> r.contains(s2.keyId()) && r.contains("without a quote")));
    Path tlist = tmp.resolve("list-tampered"); Files.createDirectories(tlist);
    Files.copy(tamperedFile, tlist.resolve(b.keyId + ".attestkey"));
    KeyList tl = new KeyList(tlist, true, null, 0);
    chk("a tampered bundle (right file name, but the statement was changed after the quote) is not trusted, and the list says why", tl.publicKey(b.keyId) == null && tl.rejected().stream().anyMatch(r -> r.contains("did not vouch")));
    chk("garbage in the folder is rejected, other files are ignored", strict.rejected().stream().anyMatch(r -> r.startsWith("garbage.attestkey")) && strict.rejected().stream().noneMatch(r -> r.startsWith("note.txt")));
    chk("an unknown key id is not trusted", strict.publicKey("TDX-ffffffffffffffff") == null);
    KeyList lenient = new KeyList(list, true, null, 0);
    chk("with allow.unquoted the service key is trusted too", lenient.publicKey(s2.keyId()) != null);
    Files.copy(s1.bundleFile(), list.resolve("TDX-aaaaaaaaaaaaaaaa.attestkey"));
    KeyList renamed = new KeyList(list, false, null, 0);
    chk("a genuine bundle under the name of another key id is refused (the file name must say the id)", renamed.publicKey("TDX-aaaaaaaaaaaaaaaa") == null
        && renamed.rejected().stream().anyMatch(r -> r.startsWith("TDX-aaaaaaaaaaaaaaaa.attestkey") && r.contains("file name")));
    Files.delete(list.resolve("TDX-aaaaaaaaaaaaaaaa.attestkey"));
    BundleCheck deny = bundle -> { throw new IOException("the admission says no to " + bundle.keyId); };
    KeyList denied = new KeyList(list, true, deny, 0);
    chk("the extra check (the hook of step 5.2.1) can refuse a bundle that passes the binding", denied.publicKey(s1.keyId()) == null && denied.rejected().stream().anyMatch(r -> r.contains("admission says no")));
    Files.delete(list.resolve(s1.keyId() + ".attestkey"));
    chk("a bundle that is removed from the folder is no longer trusted at the next reading", strict.publicKey(s1.keyId()) == null);
    Files.copy(s1.bundleFile(), list.resolve(s1.keyId() + ".attestkey"));
    KeyList cached = new KeyList(list, false, null, 3600);
    chk("with a cache time the list is read once", cached.publicKey(s1.keyId()) != null);
    Files.delete(list.resolve(s1.keyId() + ".attestkey"));
    chk("... and a change inside the cache time is not seen yet (limitations: the list is read again after the cache time)", cached.publicKey(s1.keyId()) != null);
    Files.copy(s1.bundleFile(), list.resolve(s1.keyId() + ".attestkey"));
    chk("a missing folder trusts nothing and says so", new KeyList(tmp.resolve("nowhere"), true, null, 0).rejected().isEmpty() && new KeyList(tmp.resolve("nowhere"), true, null, 0).publicKey("x") == null);

    System.out.println("== 5. the wrapper's signed formats with the real key");
    ServiceKeys keys = new ServiceKeys("127.0.0.1", s1.port(), t1, new KeyList(list, false, null, 0), 3000);
    AttestedSignatures sig = new AttestedSignatures(keys, true, true, false);
    MerkleHasher h = new MerkleHasher(16384, true); byte[] content = bytes(50000, 9); h.update(content, 0, content.length);
    byte[] r1 = h.finish();
    byte[] rec = sig.encode(16384, content.length, r1, h.leaves());
    AttestedRecordCodec.Decoded dec = AttestedRecordCodec.decode(rec);
    chk("a record signed through the service names the TDX- key", dec.keyId.equals(s1.keyId()));
    chk("it verifies, and the status is ok (not ok-test)", sig.check(dec).equals("ok"));
    byte[] fid = bytes(16, 3);
    byte[] bound = sig.encodeBound(16384, content.length, r1, h.leaves(), fid, "part-r-00000");
    chk("a bound record verifies with status ok", sig.check(AttestedRecordCodec.decode(bound)).equals("ok"));
    byte[] fd = sig.encodeFolder(fid, "seg1", null, "/user/x/seg1");
    chk("a folder identity verifies with status ok", sig.checkFolder(AttestedFolderCodec.decode(fd)).equals("ok"));
    byte[] flipped = rec.clone(); flipped[flipped.length - 3] ^= 1;
    chk("a flipped bit in the signature is refused", refuses(() -> sig.check(AttestedRecordCodec.decode(flipped)), "does not verify"));
    ServiceKeys reader = new ServiceKeys(null, 0, null, new KeyList(list, false, null, 0), 3000);
    AttestedSignatures readerSig = new AttestedSignatures(reader, false, true, false);
    chk("a reader that has only the key list (no service) verifies the same record", readerSig.check(AttestedRecordCodec.decode(rec)).equals("ok"));
    ServiceKeys stranger = new ServiceKeys(null, 0, null, new KeyList(tmp.resolve("empty-list"), false, null, 0), 3000);
    chk("a reader whose list does not hold the key refuses the record: not trusted here", refuses(() -> new AttestedSignatures(stranger, false, true, false).check(AttestedRecordCodec.decode(rec)), "not trusted here"));
    chk("a JVM that has no signing service cannot be set to sign", refuses(() -> new AttestedSignatures(reader, true, true, false), "sign"));
    TestKeys attacker = TestKeys.generate(tmp.resolve("attacker.txt"));
    byte[] forged = new AttestedSignatures(attacker, true, true, true).encode(16384, content.length, r1, h.leaves());
    chk("a record signed with a test key is refused when test keys are not allowed", refuses(() -> sig.check(AttestedRecordCodec.decode(forged)), "test key"));
    ServiceKeys other = new ServiceKeys(null, 0, null, new KeyList(list, false, null, 0), 3000);
    byte[] forgedId = AttestedRecordCodec.encodeSigned(16384, content.length, r1, h.leaves(), s1.keyId(), AttestedRecordCodec.decode(rec).signature);
    byte[] forgedLen = AttestedRecordCodec.encodeSigned(16384, content.length + 1, r1, h.leaves(), s1.keyId(), AttestedRecordCodec.decode(rec).signature);
    chk("the signature of a record cannot be moved to a record with another length (it does not verify)", refuses(() -> new AttestedSignatures(other, false, true, false).check(AttestedRecordCodec.decode(forgedLen)), "does not verify") || refuses(() -> new AttestedSignatures(other, false, true, false).check(AttestedRecordCodec.decode(forgedLen)), "impossible"));
    chk("... and the record with the right values still verifies", new AttestedSignatures(other, false, true, false).check(AttestedRecordCodec.decode(forgedId)).equals("ok"));

    System.out.println("== 6. when the service stops, reading goes on and writing says why; a new service means a new key");
    int oldPort = s1.port(); s1.close(); Thread.sleep(100);
    chk("the service is gone: signing fails with a message that names the service", refuses(() -> keys.sign(st02), "signing service"));
    chk("... but a reader still verifies the record that the old key signed", sig.check(AttestedRecordCodec.decode(rec)).equals("ok"));
    KeyService s5 = KeyService.start(tmp.resolve("svc5"), 0, list, quoteCmd.toString(), "node-a");
    chk("a restarted service has another key, written to the key list as well", !s5.keyId().equals(s1.keyId()) && Files.exists(list.resolve(s5.keyId() + ".attestkey")));
    chk("the old key stays in the list, so the records that it signed still verify", new KeyList(list, false, null, 0).publicKey(s1.keyId()) != null && new KeyList(list, false, null, 0).publicKey(s5.keyId()) != null);

    System.out.println("== 7. many callers at once");
    ServiceKeys many = new ServiceKeys("127.0.0.1", s5.port(), token(tmp.resolve("svc5")), new KeyList(list, false, null, 0), 5000);
    AtomicInteger good = new AtomicInteger(); AtomicInteger bad = new AtomicInteger();
    Thread[] ts = new Thread[8];
    for (int i = 0; i < ts.length; i++) {
      final int n = i;
      ts[i] = new Thread(() -> {
        for (int k = 0; k < 25; k++) {
          try {
            byte[] st = AttestedRecordCodec.statement(s5.keyId(), 16384, n * 1000L + k, bytes(32, n + k));
            byte[] sg = many.sign(st);
            java.security.Signature vv = java.security.Signature.getInstance("SHA256withECDSA"); vv.initVerify(s5.bundle().publicKey); vv.update(st);
            if (vv.verify(sg)) good.incrementAndGet(); else bad.incrementAndGet();
          } catch (Exception e) { bad.incrementAndGet(); }
        }
      });
      ts[i].start();
    }
    for (Thread t : ts) t.join();
    chk("8 threads signed 25 statements each and all 200 signatures verify", good.get() == 200 && bad.get() == 0);
    chk("the audit log counted them", s5.signedCount() == 200);
    s5.close(); s2.close();

    System.out.println("\npass: " + pass + "   fail: " + fail);
    System.out.println(fail == 0 ? "KEYCORE-PASS" : "KEYCORE-FAIL");
    if (fail != 0) System.exit(1);
  }
}
