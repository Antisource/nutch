package org.apache.nutch.attested;

import java.io.ByteArrayOutputStream;
import java.io.PrintStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Arrays;

/** Tests of the two demonstration tools (forge and verify). */
public final class M511ToolsTest {
  static int pass = 0, fail = 0;
  static void chk(String what, boolean ok) { if (ok) { pass++; System.out.println("  pass: " + what); } else { fail++; System.out.println("  FAIL: " + what); } }

  static String[] run(String... args) {
    ByteArrayOutputStream o = new ByteArrayOutputStream(), e = new ByteArrayOutputStream();
    int rc = M511Tools.run(args, new PrintStream(o), new PrintStream(e));
    return new String[] {String.valueOf(rc), o.toString(), e.toString()};
  }

  static byte[] data(int n, int seed) { byte[] b = new byte[n]; for (int i = 0; i < n; i++) b[i] = (byte) (i * 7 + seed); return b; }

  /** Writes a file and its signed record, as the wrapper does. */
  static void put(Path dir, String name, byte[] content, AttestedSignatures s) throws Exception {
    Files.write(dir.resolve(name), content);
    MerkleHasher mh = new MerkleHasher(16384, true);
    mh.update(content, 0, content.length);
    byte[] root = mh.finish();
    Files.write(dir.resolve("." + name + ".attested"), s.encode(16384, content.length, root, mh.leaves()));
  }

  public static void main(String[] args) throws Exception {
    Path tmp = Files.createTempDirectory("m511tools");
    Path keyFile = tmp.resolve("key.txt");
    TestKeys key = TestKeys.generate(keyFile);
    AttestedSignatures signer = new AttestedSignatures(key, true, true, true);
    Path pub = tmp.resolve("public.txt"); Files.write(pub, key.publicFileText().getBytes());

    System.out.println("== verify on a local copy");
    Path good = Files.createDirectory(tmp.resolve("good"));
    put(good, "a.txt", data(50000, 1), signer); put(good, "b.txt", data(100, 2), signer); put(good, "empty.txt", new byte[0], signer);
    String[] r = run("verify", pub.toString(), good.toString());
    chk("a folder of signed files verifies with a public-only key", r[0].equals("0") && r[1].contains("VERIFY-DIR files=3 ok=3 bad=0 signed=3 unsigned=0") && r[1].contains("VERIFY-DIR-CLEAN"));
    chk("each file's line names the key and the chunks", r[1].contains("sig=ok-test key=" + key.signingKeyId()) && r[1].contains("chunks=4"));
    Path bad1 = Files.createDirectory(tmp.resolve("bad1")); put(bad1, "a.txt", data(50000, 1), signer); Files.write(bad1.resolve("a.txt"), data(50000, 9));
    r = run("verify", pub.toString(), bad1.toString());
    chk("a changed file is found", r[0].equals("1") && r[1].contains("the file's bytes do not match its record") && r[1].contains("VERIFY-DIR-FINDINGS (1)"));
    Path bad2 = Files.createDirectory(tmp.resolve("bad2")); put(bad2, "a.txt", data(50000, 1), signer);
    Files.delete(bad2.resolve(".a.txt.attested"));
    r = run("verify", pub.toString(), bad2.toString());
    chk("a file without a record is found", r[1].contains("no record") && r[0].equals("1"));
    Path bad3 = Files.createDirectory(tmp.resolve("bad3")); put(bad3, "a.txt", data(50000, 1), new AttestedSignatures(null, false, false, true));
    r = run("verify", pub.toString(), bad3.toString());
    chk("an unsigned record is found (signatures are required)", r[1].contains("not signed") && r[0].equals("1") && r[1].contains("unsigned=1"));
    Path empty = Files.createDirectory(tmp.resolve("empty"));
    r = run("verify", pub.toString(), empty.toString());
    chk("an empty folder is not reported as clean", r[0].equals("1") && r[1].contains("nothing verified"));

    System.out.println("== forge: the attacker's records, and what the check says about each");
    byte[] orig = data(50000, 1), evil = data(50000, 99);
    Path honestDir = Files.createDirectory(tmp.resolve("honest")); put(honestDir, "a.txt", orig, signer);
    Path content = tmp.resolve("evil.bin"); Files.write(content, evil);
    Path honestRec = honestDir.resolve(".a.txt.attested");
    for (String mode : new String[] {"unsigned", "oldsig", "attacker-real-id", "attacker-own-id"}) {
      Path out = tmp.resolve("forged-" + mode + ".rec");
      r = run("forge", mode, content.toString(), honestRec.toString(), out.toString());
      chk("forge " + mode + " writes a record", r[0].equals("0") && Files.exists(out));
      Path d = Files.createDirectory(tmp.resolve("tampered-" + mode));
      Files.write(d.resolve("a.txt"), evil); Files.copy(out, d.resolve(".a.txt.attested"));
      r = run("verify", pub.toString(), d.toString());
      String why = mode.equals("unsigned") ? "not signed" : mode.equals("attacker-own-id") ? "not trusted" : "does not verify";
      chk("verify refuses the " + mode + " forgery (" + why + ")", r[0].equals("1") && r[1].contains(why));
    }
    r = run("forge", "oldsig", content.toString(), tmp.resolve("forged-unsigned.rec").toString(), tmp.resolve("x.rec").toString());
    chk("forge oldsig refuses an unsigned honest record", r[0].equals("1") && r[2].contains("not signed"));
    chk("an unknown mode gives a stop", run("forge", "nope", content.toString(), honestRec.toString(), tmp.resolve("y.rec").toString())[0].equals("2"));
    chk("the usage is shown for a wrong command", run("nope")[0].equals("2"));
    System.out.println("\npass: " + pass + "   fail: " + fail);
    System.out.println(fail == 0 ? "M511TOOLS-PASS" : "M511TOOLS-FAIL");
    if (fail != 0) System.exit(1);
  }
}
