package org.apache.nutch.attested;

import java.io.ByteArrayOutputStream;
import java.io.PrintStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/** Tests of the 5.1.2 demonstration tools: a tree built the way the wrapper builds it, then every attack on it. */
public final class M512ToolsTest {
  static int pass = 0, fail = 0;
  static void chk(String what, boolean ok) { if (ok) { pass++; System.out.println("  pass: " + what); } else { fail++; System.out.println("  FAIL: " + what); } }

  static String[] run(String... args) {
    ByteArrayOutputStream o = new ByteArrayOutputStream(), e = new ByteArrayOutputStream();
    int rc = M512Tools.run(args, new PrintStream(o), new PrintStream(e));
    return new String[] {String.valueOf(rc), o.toString(), e.toString()};
  }

  static byte[] data(int n, int seed) { byte[] b = new byte[n]; for (int i = 0; i < n; i++) b[i] = (byte) (i * 7 + seed); return b; }
  static byte[] id(int v) { byte[] b = new byte[16]; Arrays.fill(b, (byte) v); return b; }

  static void identity(AttestedSignatures s, Path dir, byte[] id, String name, byte[] parent, String top) throws Exception {
    Files.createDirectories(dir);
    Files.write(dir.resolve("_attested-folder"), s.encodeFolder(id, name, parent, top));
  }

  static void file(AttestedSignatures s, Path dir, String name, byte[] content, byte[] folderId) throws Exception {
    Files.write(dir.resolve(name), content);
    MerkleHasher mh = new MerkleHasher(16384, true);
    mh.update(content, 0, content.length);
    byte[] root = mh.finish();
    Files.write(dir.resolve("." + name + ".attested"), s.encodeBound(16384, content.length, root, mh.leaves(), folderId, name));
  }

  /** A tree top/{seg1/a, seg2/b} as the wrapper makes it. */
  static Path tree(AttestedSignatures s, Path base, String label) throws Exception {
    Path top = base.resolve(label).resolve("crawl");
    identity(s, top, id(1), "crawl", null, "/user/x/crawl");
    identity(s, top.resolve("seg1"), id(2), "seg1", id(1), null);
    identity(s, top.resolve("seg2"), id(3), "seg2", id(1), null);
    file(s, top.resolve("seg1"), "part", data(30000, 1), id(2));
    file(s, top.resolve("seg2"), "part", data(20000, 2), id(3));
    return top;
  }

  public static void main(String[] args) throws Exception {
    Path tmp = Files.createTempDirectory("m512tools");
    TestKeys key = TestKeys.generate(tmp.resolve("key.txt"));
    Path pub = tmp.resolve("public.txt"); Files.write(pub, key.publicFileText().getBytes());
    AttestedSignatures signer = new AttestedSignatures(key, true, true, true);
    String top = "/user/x/crawl";

    System.out.println("== verify-tree on an honest tree");
    Path ok = tree(signer, tmp, "ok");
    String[] r = run("verify-tree", pub.toString(), ok.toString(), top);
    chk("an honest tree verifies: 3 folders, 2 files", r[0].equals("0") && r[1].contains("VERIFY-TREE folders=3 files=2 ok=2 bad=0") && r[1].contains("VERIFY-TREE-CLEAN"));
    chk("each file's line names the folder and the key", r[1].contains("folder=" + MerkleHasher.hex(id(2)).substring(0, 8)) && r[1].contains("key=" + key.signingKeyId()));

    System.out.println("== the attacks, one tree each");
    Path swap = tree(signer, tmp, "swap");
    byte[] a = Files.readAllBytes(swap.resolve("seg1/part")), ra = Files.readAllBytes(swap.resolve("seg1/.part.attested"));
    Files.write(swap.resolve("seg1/part"), Files.readAllBytes(swap.resolve("seg2/part"))); Files.write(swap.resolve("seg1/.part.attested"), Files.readAllBytes(swap.resolve("seg2/.part.attested")));
    Files.write(swap.resolve("seg2/part"), a); Files.write(swap.resolve("seg2/.part.attested"), ra);
    r = run("verify-tree", pub.toString(), swap.toString(), top);
    chk("two same-named files swapped between folders: both found", r[0].equals("1") && r[1].contains("bad=2") && r[1].contains("belongs to another folder"));
    Path copyName = tree(signer, tmp, "copyname");
    Files.copy(copyName.resolve("seg1/part"), copyName.resolve("seg1/copy")); Files.copy(copyName.resolve("seg1/.part.attested"), copyName.resolve("seg1/.copy.attested"));
    r = run("verify-tree", pub.toString(), copyName.toString(), top);
    chk("a file and its record copied under another name: found (the record names another file)", r[1].contains("is for a file named 'part', not 'copy'") && r[1].contains("bad=1"));
    Path stolen = tree(signer, tmp, "stolen");
    Files.copy(stolen.resolve("seg1/part"), stolen.resolve("seg2/stolen")); Files.copy(stolen.resolve("seg1/.part.attested"), stolen.resolve("seg2/.stolen.attested"));
    r = run("verify-tree", pub.toString(), stolen.toString(), top);
    chk("a file and its record moved into another folder: found", r[1].contains("belongs to another folder") && r[1].contains("bad=1"));
    Path planted = tree(signer, tmp, "planted");
    Files.copy(planted.resolve("seg2/_attested-folder"), planted.resolve("seg1/_attested-folder"), java.nio.file.StandardCopyOption.REPLACE_EXISTING);
    r = run("verify-tree", pub.toString(), planted.toString(), top);
    chk("another folder's identity planted: found (and the folder's files are not trusted)", r[1].contains("is for a folder named 'seg2', not 'seg1'") && r[1].contains("not checked: its folder is not trusted"));
    Path gone = tree(signer, tmp, "gone");
    Files.delete(gone.resolve("seg1/_attested-folder"));
    r = run("verify-tree", pub.toString(), gone.toString(), top);
    chk("an identity deleted: found (the folder has no identity)", r[1].contains("the folder has no identity") && r[0].equals("1"));
    Path evilId = tree(signer, tmp, "evilid");
    run("forge-identity", evilId.resolve("seg1/_attested-folder").toString(), tmp.resolve("forged-id.bin").toString());
    Files.copy(tmp.resolve("forged-id.bin"), evilId.resolve("seg1/_attested-folder"), java.nio.file.StandardCopyOption.REPLACE_EXISTING);
    r = run("verify-tree", pub.toString(), evilId.toString(), top);
    chk("an identity signed with the attacker's key under the real key id: found", r[1].contains("does not verify") && r[0].equals("1"));
    Path moved = tree(signer, tmp, "moved");
    r = run("verify-tree", pub.toString(), moved.toString(), "/user/x/elsewhere/crawl");
    chk("the whole tree claimed at another path: found (the top identity is for another path)", r[1].contains("the top identity is not for the path") && r[0].equals("1"));
    r = run("verify-tree", pub.toString(), moved.toString(), "/user/x/other");
    chk("the tree under another top name: found (the identity names another folder)", r[1].contains("is for a folder named 'crawl', not 'other'"));
    Path orphan = tree(signer, tmp, "orphan");
    identity(signer, orphan.resolve("seg1/under"), id(9), "under", id(7), null);   // its parent id is not seg1's
    file(signer, orphan.resolve("seg1/under"), "z", data(100, 3), id(9));
    r = run("verify-tree", pub.toString(), orphan.toString(), top);
    chk("a folder whose identity points to another parent: found", r[1].contains("points to another parent folder"));
    Path unsigned = tree(signer, tmp, "unsigned");
    Files.write(unsigned.resolve("seg1/extra"), data(50, 4));
    r = run("verify-tree", pub.toString(), unsigned.toString(), top);
    chk("a file with no record: found", r[1].contains("the file has no record") && r[0].equals("1"));
    Path changed = tree(signer, tmp, "changed");
    Files.write(changed.resolve("seg2/part"), data(20000, 99));
    r = run("verify-tree", pub.toString(), changed.toString(), top);
    chk("a file whose bytes were changed: found", r[1].contains("the file's bytes do not match its record"));
    Path unbound = tree(signer, tmp, "unbound");
    Files.write(unbound.resolve("seg1/.part.attested"), new AttestedSignatures(key, true, true, true).encode(16384, 30000, AttestedRecordCodec.decode(Files.readAllBytes(unbound.resolve("seg1/.part.attested"))).root, new ArrayList<byte[]>(Arrays.asList(AttestedRecordCodec.decode(Files.readAllBytes(unbound.resolve("seg1/.part.attested"))).leaves))));
    r = run("verify-tree", pub.toString(), unbound.toString(), top);
    chk("a signed record that is not bound to a folder (ATTEST02): found", r[1].contains("the record is not bound to a folder"));
    r = run("verify-tree", pub.toString(), tmp.resolve("nothing").toString(), top);
    chk("a folder that does not exist is a stop, not a clean result", r[0].equals("1") || r[2].contains("STOP") || r[0].equals("1"));

    System.out.println("== forge-record: a record signed by the attacker for the right folder and name");
    Path fr = tree(signer, tmp, "forgedrec");
    Files.write(tmp.resolve("evil.bin"), data(30000, 77));
    r = run("forge-record", tmp.resolve("evil.bin").toString(), fr.resolve("seg1/.part.attested").toString(), tmp.resolve("forged-rec.bin").toString());
    chk("forge-record writes a record", r[0].equals("0") && Files.exists(tmp.resolve("forged-rec.bin")));
    Files.copy(tmp.resolve("evil.bin"), fr.resolve("seg1/part"), java.nio.file.StandardCopyOption.REPLACE_EXISTING); Files.copy(tmp.resolve("forged-rec.bin"), fr.resolve("seg1/.part.attested"), java.nio.file.StandardCopyOption.REPLACE_EXISTING);
    r = run("verify-tree", pub.toString(), fr.toString(), top);
    chk("the forged record (right folder, right name, attacker's signature) is found", r[1].contains("does not verify") && r[0].equals("1"));
    r = run("forge-record", tmp.resolve("evil.bin").toString(), tmp.resolve("evil.bin").toString(), tmp.resolve("x.bin").toString());
    chk("forge-record refuses something that is not a record", r[0].equals("1"));

    System.out.println("== inspect");
    r = run("inspect", ok.resolve("seg1/.part.attested").toString());
    chk("inspect shows a record: ATTEST03, length, folder, name, key", r[0].equals("0") && r[1].contains("ATTEST03") && r[1].contains("length=30000") && r[1].contains("name=part") && r[1].contains("key=" + key.signingKeyId()));
    r = run("inspect", ok.resolve("_attested-folder").toString());
    chk("inspect shows a top identity with its path", r[1].contains("name=crawl") && r[1].contains("top path=/user/x/crawl"));
    r = run("inspect", ok.resolve("seg2/_attested-folder").toString());
    chk("inspect shows a child identity with its parent", r[1].contains("name=seg2") && r[1].contains("parent=" + MerkleHasher.hex(id(1)).substring(0, 8)));
    chk("the usage is shown for a wrong command", run("nope")[0].equals("2"));
    System.out.println("\npass: " + pass + "   fail: " + fail);
    System.out.println(fail == 0 ? "M512TOOLS-PASS" : "M512TOOLS-FAIL");
    if (fail != 0) System.exit(1);
  }
}
