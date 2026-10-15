package org.apache.nutch.attested;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.attribute.PosixFilePermission;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Set;

/** Tests of the signing core (step 5.1.1) with no Hadoop: the codec, the test key and the signature rules. */
public final class SigCoreTest {
  static int pass = 0, fail = 0;

  static void chk(String what, boolean ok) {
    if (ok) { pass++; System.out.println("  pass: " + what); } else { fail++; System.out.println("  FAIL: " + what); }
  }

  interface Thrower { void run() throws Exception; }

  static boolean refuses(Thrower t, String text) {
    try { t.run(); return false; } catch (Exception e) { return e.getMessage() != null && e.getMessage().contains(text); }
  }

  /** A real file's record: the Merkle root and the leaves of the given bytes, as the wrapper makes them. */
  static final class Made { int chunk; long length; byte[] root; List<byte[]> leaves; }

  static Made made(byte[] content, int chunk) {
    MerkleHasher h = new MerkleHasher(chunk, true);
    h.update(content, 0, content.length);
    Made m = new Made(); m.root = h.finish(); m.length = h.length(); m.chunk = chunk; m.leaves = h.leaves();
    return m;
  }

  static byte[] bytes(int n, int seed) { byte[] b = new byte[n]; for (int i = 0; i < n; i++) b[i] = (byte) (i * 31 + seed); return b; }

  static AttestedSignatures sigs(AttestedKeys k, boolean sign, boolean required, boolean allowTest) throws IOException {
    return new AttestedSignatures(k, sign, required, allowTest);
  }

  public static void main(String[] args) throws Exception {
    Path dir = Files.createTempDirectory("sigcore");
    Path kf = dir.resolve("test-key.txt");
    TestKeys key = TestKeys.generate(kf);
    Made a = made(bytes(50000, 1), 16384);

    System.out.println("== 1. the old format is unchanged, the new one round-trips");
    byte[] v1 = AttestedRecordCodec.encode(a.chunk, a.length, a.root, a.leaves);
    chk("a version 1 record is 8+4+8+32+4+32n bytes and starts with ATTEST01", v1.length == 8 + 4 + 8 + 32 + 4 + 32 * a.leaves.size() && new String(v1, 0, 8).equals("ATTEST01"));
    AttestedRecordCodec.Decoded d1 = AttestedRecordCodec.decode(v1);
    chk("it decodes as unsigned with the same length, chunk size and root", !d1.signed() && d1.length == a.length && d1.chunkSize == a.chunk && Arrays.equals(d1.root, a.root) && d1.leaves.length == 4);
    AttestedSignatures on = sigs(key, true, true, true);
    byte[] v2 = on.encode(a.chunk, a.length, a.root, a.leaves);
    AttestedRecordCodec.Decoded d2 = AttestedRecordCodec.decode(v2);
    chk("a signed record starts with ATTEST02 and carries the test key id", new String(v2, 0, 8).equals("ATTEST02") && d2.signed() && d2.keyId.equals(key.signingKeyId()) && d2.keyId.startsWith("TEST-"));
    chk("the signed record is the unsigned body plus the signature block", v2.length > v1.length && v2.length < v1.length + 1 + 64 + 2 + 200);
    chk("signing with the right key verifies, and the status says test key", on.check(d2).equals("ok-test"));
    chk("two signatures of the same record both verify (the signature is not deterministic, the statement is)", on.check(AttestedRecordCodec.decode(on.encode(a.chunk, a.length, a.root, a.leaves))).equals("ok-test"));

    System.out.println("== 2. damaged records are refused with a reason");
    chk("wrong header", refuses(() -> AttestedRecordCodec.decode(concat("ATTESTXX".getBytes(), Arrays.copyOfRange(v2, 8, v2.length))), "wrong header"));
    chk("too short (cut in the leaves)", refuses(() -> AttestedRecordCodec.decode(Arrays.copyOf(v2, 100)), "too short"));
    chk("too short (cut in the signature)", refuses(() -> AttestedRecordCodec.decode(Arrays.copyOf(v2, v2.length - 5)), "too short"));
    chk("extra bytes after the signature", refuses(() -> AttestedRecordCodec.decode(concat(v2, new byte[]{1})), "extra bytes"));
    chk("extra bytes after an unsigned record", refuses(() -> AttestedRecordCodec.decode(concat(v1, new byte[]{1})), "extra bytes"));
    byte[] badRoot = v2.clone(); badRoot[8 + 4 + 8] ^= 1;
    chk("a root that does not match its own chunk hashes", refuses(() -> AttestedRecordCodec.decode(badRoot), "root does not match"));
    byte[] badLen = v2.clone(); badLen[8 + 4 + 2] ^= 1;
    chk("a length that does not fit the number of chunks", refuses(() -> AttestedRecordCodec.decode(badLen), "impossible sizes"));
    int idLenPos = v1.length;
    byte[] zeroId = v2.clone(); zeroId[idLenPos] = 0;
    chk("a key id of length 0", refuses(() -> AttestedRecordCodec.decode(zeroId), "key id length"));
    byte[] badChar = v2.clone(); badChar[idLenPos + 1] = ' ';
    chk("a key id with a character that is not allowed", refuses(() -> AttestedRecordCodec.decode(badChar), "impossible key id"));

    System.out.println("== 3. the pass condition of the step: a file rewritten together with its record, by someone without the key");
    AttestedSignatures need = sigs(key.publicOnly(), false, true, true);   // a reader: verifies, never signs, signatures required
    chk("the honest record is accepted by a reader that has only the public key", need.check(d2).equals("ok-test"));
    Made b = made(bytes(50000, 2), 16384);                                // the attacker's new content
    byte[] oldSig = d2.signature;
    byte[] forged1 = AttestedRecordCodec.encodeSigned(b.chunk, b.length, b.root, b.leaves, d2.keyId, oldSig);
    chk("new content and a new record, with the OLD signature copied over: refused", refuses(() -> need.check(AttestedRecordCodec.decode(forged1)), "does not verify"));
    TestKeys other = TestKeys.generate(dir.resolve("attacker.txt"));
    byte[] own = other.sign(AttestedRecordCodec.statement(d2.keyId, b.chunk, b.length, b.root));
    byte[] forged2 = AttestedRecordCodec.encodeSigned(b.chunk, b.length, b.root, b.leaves, d2.keyId, own);
    chk("signed with the attacker's own key under the real key id: refused", refuses(() -> need.check(AttestedRecordCodec.decode(forged2)), "does not verify"));
    byte[] own2 = other.sign(AttestedRecordCodec.statement(other.signingKeyId(), b.chunk, b.length, b.root));
    byte[] forged3 = AttestedRecordCodec.encodeSigned(b.chunk, b.length, b.root, b.leaves, other.signingKeyId(), own2);
    chk("signed with the attacker's own key under its own id: refused as not trusted", refuses(() -> need.check(AttestedRecordCodec.decode(forged3)), "not trusted here"));
    byte[] downgraded = AttestedRecordCodec.encode(b.chunk, b.length, b.root, b.leaves);
    chk("downgraded to the unsigned format: refused when signatures are required", refuses(() -> need.check(AttestedRecordCodec.decode(downgraded)), "signatures are required"));
    chk("the same downgrade is accepted as legacy when signatures are not required (the documented limit of the default)", sigs(key.publicOnly(), false, false, true).check(AttestedRecordCodec.decode(downgraded)).equals("none"));

    System.out.println("== 4. every signed field is covered");
    for (int field = 0; field < 4; field++) {
      final int f = field;
      Made m = made(bytes(50000, 1), 16384);
      int chunk = f == 0 ? 8192 : m.chunk; long len = f == 1 ? m.length + 1 : m.length; byte[] root = m.root.clone(); if (f == 2) root[0] ^= 1;
      String id = f == 3 ? d2.keyId.substring(0, d2.keyId.length() - 1) + (d2.keyId.endsWith("0") ? "1" : "0") : d2.keyId;
      List<byte[]> leaves = m.leaves;
      if (f == 0 || f == 1) { /* keep the record self-consistent where the codec would catch it first: only the signature check is under test */ }
      AttestedRecordCodec.Decoded fake = new AttestedRecordCodec.Decoded(2, chunk, len, root, m.leaves.toArray(new byte[0][]), id, d2.signature);
      chk("changing the " + new String[]{"chunk size", "length", "root", "key id"}[f] + " breaks the signature", refuses(() -> need.check(fake), f == 3 ? "not trusted" : "does not verify"));
    }
    chk("the statement is unambiguous: different (key id, chunk size, length) never give the same bytes",
        !Arrays.equals(AttestedRecordCodec.statement("A", 1, 2, a.root), AttestedRecordCodec.statement("A", 2, 1, a.root))
        && !Arrays.equals(AttestedRecordCodec.statement("AB", 1, 2, a.root), AttestedRecordCodec.statement("A", 1, 2, a.root)));

    System.out.println("== 5. the settings");
    AttestedSignatures noTest = sigs(key.publicOnly(), false, true, false);
    chk("with test keys not allowed, a test-signed record is refused (the real-key mode)", refuses(() -> noTest.check(d2), "not accepted"));
    chk("signing with a test key is refused when test keys are not allowed", refuses(() -> sigs(key, true, true, false), "test key, which is not allowed"));
    chk("signing without a private key is refused at start", refuses(() -> sigs(key.publicOnly(), true, true, true), "no private key"));
    chk("a signed record is checked even when signatures are not required (a bad signature is never accepted)", refuses(() -> sigs(key.publicOnly(), false, false, true).check(AttestedRecordCodec.decode(forged1)), "does not verify"));
    chk("a reader with no keys at all refuses a signed record", refuses(() -> sigs(null, false, false, true).check(d2), "not trusted"));
    chk("signing off writes the old format byte for byte", Arrays.equals(sigs(key, false, false, true).encode(a.chunk, a.length, a.root, a.leaves), v1));

    System.out.println("== 6. the test key file");
    TestKeys again = TestKeys.load(kf);
    chk("a key file loads with the same id and can sign what the original verified", again.signingKeyId().equals(key.signingKeyId()) && need.check(AttestedRecordCodec.decode(sigs(again, true, true, true).encode(a.chunk, a.length, a.root, a.leaves))).equals("ok-test"));
    boolean ownerOnly;
    try { Set<PosixFilePermission> p = Files.getPosixFilePermissions(kf); ownerOnly = p.size() == 2 && p.contains(PosixFilePermission.OWNER_READ) && p.contains(PosixFilePermission.OWNER_WRITE); } catch (UnsupportedOperationException e) { ownerOnly = true; }
    chk("the key file is readable by its owner only (mode 600)", ownerOnly);
    chk("an existing key file is never overwritten", refuses(() -> TestKeys.generate(kf), "exists already"));
    Path pubFile = dir.resolve("public.txt"); Files.write(pubFile, key.publicFileText().getBytes());
    TestKeys pubOnly = TestKeys.load(pubFile);
    chk("a public-only file loads, verifies and cannot sign", pubOnly.signingKeyId() == null && refuses(() -> pubOnly.sign(new byte[]{1}), "cannot sign") && sigs(pubOnly, false, true, true).check(d2).equals("ok-test"));
    List<String> lines = Files.readAllLines(kf); lines.set(1, "id=TEST-0000000000000000"); Path badId = dir.resolve("badid.txt"); Files.write(badId, lines);
    chk("a key file whose id does not match its public key is refused", refuses(() -> TestKeys.load(badId), "does not match"));
    Path junk = dir.resolve("junk.txt"); Files.write(junk, "hello\n".getBytes());
    chk("a file that is not a key file is refused", refuses(() -> TestKeys.load(junk), "not a test key file"));
    chk("the key id of a test key always starts with TEST- and is 21 characters", key.signingKeyId().startsWith("TEST-") && key.signingKeyId().length() == 21 && TestKeys.isTestKeyId(key.signingKeyId()) && !TestKeys.isTestKeyId("VM-abc"));

    System.out.println("== 7. an empty file and a file of exactly one chunk");
    for (int size : new int[]{0, 1, 16384, 16385}) {
      Made e = made(bytes(size, 3), 16384);
      AttestedRecordCodec.Decoded r = AttestedRecordCodec.decode(on.encode(e.chunk, e.length, e.root, e.leaves));
      chk("size " + size + ": signs, decodes and verifies (" + r.leaves.length + " chunks)", need.check(r).equals("ok-test") && r.length == size);
    }
    System.out.println("== 9. records bound to a folder and a name (ATTEST03, step 5.1.2)");
    byte[] folderA = new byte[16]; Arrays.fill(folderA, (byte) 0x11); byte[] folderB = new byte[16]; Arrays.fill(folderB, (byte) 0x22);
    byte[] b3 = on.encodeBound(a.chunk, a.length, a.root, a.leaves, folderA, "part-r-00000");
    AttestedRecordCodec.Decoded d3 = AttestedRecordCodec.decode(b3);
    chk("a bound record starts with ATTEST03 and carries the folder ID and the name", new String(b3, 0, 8).equals("ATTEST03") && d3.bound() && d3.signed() && Arrays.equals(d3.folderId, folderA) && d3.fileName.equals("part-r-00000"));
    chk("its signature verifies (the folder and the name are the caller's to compare)", need.check(d3).equals("ok-test"));
    chk("a name with a non-ASCII letter round-trips", AttestedRecordCodec.decode(on.encodeBound(a.chunk, a.length, a.root, a.leaves, folderA, "r\u00e9sum\u00e9 \u30c6\u30b9\u30c8")).fileName.equals("r\u00e9sum\u00e9 \u30c6\u30b9\u30c8"));
    // swapping the folder or the name in the record without the key breaks the signature
    AttestedRecordCodec.Decoded moved = new AttestedRecordCodec.Decoded(3, d3.chunkSize, d3.length, d3.root, d3.leaves, d3.keyId, d3.signature, folderB, d3.fileName);
    chk("the same record claiming another folder ID: refused", refuses(() -> need.check(moved), "does not verify"));
    AttestedRecordCodec.Decoded renamedRec = new AttestedRecordCodec.Decoded(3, d3.chunkSize, d3.length, d3.root, d3.leaves, d3.keyId, d3.signature, folderA, "part-r-00001");
    chk("the same record claiming another name: refused", refuses(() -> need.check(renamedRec), "does not verify"));
    byte[] unbound = on.encode(a.chunk, a.length, a.root, a.leaves);
    chk("an ATTEST02 record has no folder or name (it is unbound)", !AttestedRecordCodec.decode(unbound).bound() && AttestedRecordCodec.decode(unbound).folderId == null);
    chk("a bound record's statement differs from the unbound one (a signature of one never fits the other)", !Arrays.equals(AttestedRecordCodec.statementBound(d3.keyId, folderA, "x", 1, 2, a.root), AttestedRecordCodec.statement(d3.keyId, 1, 2, a.root)));
    chk("the statement is unambiguous: folder ID and name never run into each other", !Arrays.equals(AttestedRecordCodec.statementBound("K", folderA, "ab", 1, 2, a.root), AttestedRecordCodec.statementBound("K", folderA, "a", 1, 2, a.root)));
    byte[] cutName = b3.clone(); cutName[v1.length + 16] = 0; cutName[v1.length + 17] = 0;
    chk("a name of length 0 is refused", refuses(() -> AttestedRecordCodec.decode(cutName), "impossible name length"));
    chk("a truncated bound record is refused", refuses(() -> AttestedRecordCodec.decode(Arrays.copyOf(b3, b3.length - 3)), "too short"));
    chk("a name with a slash cannot be signed", refuses(() -> on.encodeBound(a.chunk, a.length, a.root, a.leaves, folderA, "a/b"), "cannot build the statement to sign"));
    chk("a bound record cannot be made with signing off", refuses(() -> sigs(key, false, false, true).encodeBound(a.chunk, a.length, a.root, a.leaves, folderA, "x"), "needs signing to be on"));

    System.out.println("== 10. the folder identity file");
    byte[] idTop = new byte[16]; Arrays.fill(idTop, (byte) 0x33);
    byte[] top = on.encodeFolder(idTop, "crawl", null, "/user/x/crawl");
    AttestedFolderCodec.Decoded t = AttestedFolderCodec.decode(top);
    chk("a top folder's identity binds its full path, has no parent, and verifies", t.top() && t.parentId == null && t.topPath.equals("/user/x/crawl") && t.name.equals("crawl") && need.checkFolder(t).equals("ok-test"));
    byte[] child = on.encodeFolder(folderA, "segments", idTop, null);
    AttestedFolderCodec.Decoded c = AttestedFolderCodec.decode(child);
    chk("a child's identity binds its name and its parent's ID, and verifies", !c.top() && Arrays.equals(c.parentId, idTop) && c.topPath == null && need.checkFolder(c).equals("ok-test"));
    chk("the identity file starts with ATTESTFD and its name is hidden by an underscore", new String(top, 0, 8).equals("ATTESTFD") && AttestedFolderCodec.isIdentityName("_attested-folder") && "_attested-folder".startsWith("_"));
    AttestedFolderCodec.Decoded otherName = new AttestedFolderCodec.Decoded(c.folderId, "other", c.parentId, null, c.keyId, c.signature);
    chk("the same identity under another folder name: refused", refuses(() -> need.checkFolder(otherName), "does not verify"));
    AttestedFolderCodec.Decoded otherParent = new AttestedFolderCodec.Decoded(c.folderId, c.name, folderB, null, c.keyId, c.signature);
    chk("the same identity under another parent: refused", refuses(() -> need.checkFolder(otherParent), "does not verify"));
    AttestedFolderCodec.Decoded otherPath = new AttestedFolderCodec.Decoded(t.folderId, t.name, null, "/user/x/other", t.keyId, t.signature);
    chk("the same top identity at another path: refused", refuses(() -> need.checkFolder(otherPath), "does not verify"));
    AttestedFolderCodec.Decoded asChild = new AttestedFolderCodec.Decoded(t.folderId, t.name, folderB, null, t.keyId, t.signature);
    chk("a top identity turned into a child (to hide the path): refused", refuses(() -> need.checkFolder(asChild), "does not verify"));
    byte[] foreign = other.sign(AttestedFolderCodec.statement(c.keyId, c.folderId, c.name, c.parentId, null));
    AttestedFolderCodec.Decoded forgedF1 = AttestedFolderCodec.decode(AttestedFolderCodec.encode(c.folderId, c.name, c.parentId, null, c.keyId, foreign));
    chk("an identity signed with the attacker's key under the real key id: refused", refuses(() -> need.checkFolder(forgedF1), "does not verify"));
    AttestedFolderCodec.Decoded forgedF2 = AttestedFolderCodec.decode(AttestedFolderCodec.encode(c.folderId, c.name, c.parentId, null, other.signingKeyId(), other.sign(AttestedFolderCodec.statement(other.signingKeyId(), c.folderId, c.name, c.parentId, null))));
    chk("an identity signed with the attacker's own key: refused as not trusted", refuses(() -> need.checkFolder(forgedF2), "not trusted here"));
    chk("a test-signed identity is refused when test keys are not allowed", refuses(() -> noTest.checkFolder(c), "not accepted"));
    chk("damaged identity files are refused: header, length, kind, extra bytes", refuses(() -> AttestedFolderCodec.decode(concat("ATTESTXX".getBytes(), Arrays.copyOfRange(child, 8, child.length))), "wrong header")
        && refuses(() -> AttestedFolderCodec.decode(Arrays.copyOf(child, 20)), "too short")
        && refuses(() -> AttestedFolderCodec.decode(concat(child, new byte[]{1})), "extra bytes")
        && refuses(() -> { byte[] k = child.clone(); k[8 + 16 + 2 + 8] = 7; AttestedFolderCodec.decode(k); }, "impossible kind"));
    chk("a name or a path that cannot be signed is refused", refuses(() -> on.encodeFolder(idTop, "a/b", null, "/x"), "cannot build a folder identity") && refuses(() -> on.encodeFolder(idTop, "x", null, null), "cannot build a folder identity"));
    chk("an identity cannot be made with signing off", refuses(() -> sigs(key, false, false, true).encodeFolder(idTop, "x", null, "/x"), "needs signing to be on"));

    System.out.println("== 8. the key tool");
    java.io.ByteArrayOutputStream o1 = new java.io.ByteArrayOutputStream(), e1 = new java.io.ByteArrayOutputStream();
    Path tk = dir.resolve("tool-key.txt");
    int rc1 = AttestedKeyTool.run(new String[]{"generate", tk.toString()}, new java.io.PrintStream(o1), new java.io.PrintStream(e1));
    String text1 = o1.toString();
    chk("generate makes a key file and prints its TEST- id (never the private key)", rc1 == 0 && Files.exists(tk) && text1.contains("TEST-") && !text1.contains("private"));
    java.io.ByteArrayOutputStream o2 = new java.io.ByteArrayOutputStream();
    int rc2 = AttestedKeyTool.run(new String[]{"generate", tk.toString()}, new java.io.PrintStream(o2), new java.io.PrintStream(e1));
    chk("generate never overwrites an existing key file", rc2 == 1 && e1.toString().contains("exists already"));
    java.io.ByteArrayOutputStream o3 = new java.io.ByteArrayOutputStream();
    int rc3 = AttestedKeyTool.run(new String[]{"info", tk.toString()}, new java.io.PrintStream(o3), new java.io.PrintStream(e1));
    chk("info prints the key id and says it can sign", rc3 == 0 && o3.toString().contains("can sign: true"));
    Path pubCopy = dir.resolve("tool-public.txt");
    java.io.ByteArrayOutputStream o4 = new java.io.ByteArrayOutputStream();
    int rc4 = AttestedKeyTool.run(new String[]{"public", tk.toString(), pubCopy.toString()}, new java.io.PrintStream(o4), new java.io.PrintStream(e1));
    java.io.ByteArrayOutputStream o5 = new java.io.ByteArrayOutputStream();
    AttestedKeyTool.run(new String[]{"info", pubCopy.toString()}, new java.io.PrintStream(o5), new java.io.PrintStream(e1));
    chk("public writes a copy that can verify and cannot sign, with the same key id",
        rc4 == 0 && o5.toString().contains("can sign: false") && o5.toString().contains(TestKeys.load(tk).keyId()) && !new String(Files.readAllBytes(pubCopy)).contains("private="));
    chk("an unknown command gives the usage", AttestedKeyTool.run(new String[]{"nope"}, new java.io.PrintStream(o5), new java.io.PrintStream(e1)) == 2);
    System.out.println("\npass: " + pass + "   fail: " + fail);
    System.out.println(fail == 0 ? "SIGCORE-PASS" : "SIGCORE-FAIL");
    if (fail != 0) System.exit(1);
  }

  static byte[] concat(byte[] x, byte[] y) { byte[] r = Arrays.copyOf(x, x.length + y.length); System.arraycopy(y, 0, r, x.length, y.length); return r; }
}
