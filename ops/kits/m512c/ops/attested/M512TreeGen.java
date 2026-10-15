package org.apache.nutch.attested;

import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.Arrays;

/** REHEARSAL ONLY: makes a signed folder tree (as the wrapper makes it) at OUTDIR for the top path TOPPATH; with "bad" one file is changed afterwards. */
public final class M512TreeGen {
  static byte[] data(int n, int seed) { byte[] b = new byte[n]; for (int i = 0; i < n; i++) b[i] = (byte) (i * 7 + seed); return b; }

  static void file(AttestedSignatures s, Path dir, String name, byte[] content, byte[] folderId) throws Exception {
    Files.write(dir.resolve(name), content);
    MerkleHasher mh = new MerkleHasher(16384, true);
    mh.update(content, 0, content.length);
    Files.write(dir.resolve("." + name + ".attested"), s.encodeBound(16384, content.length, mh.finish(), mh.leaves(), folderId, name));
  }

  public static void main(String[] a) throws Exception {
    TestKeys key = TestKeys.load(Paths.get(a[0]));
    AttestedSignatures s = new AttestedSignatures(key, true, true, true);
    Path out = Paths.get(a[1]);
    String top = a[2];
    boolean bad = a.length > 3 && a[3].equals("bad");
    byte[] idTop = new byte[16], idA = new byte[16], idB = new byte[16];
    Arrays.fill(idTop, (byte) 1); Arrays.fill(idA, (byte) 2); Arrays.fill(idB, (byte) 3);
    String name = top.substring(top.lastIndexOf('/') + 1);
    Files.createDirectories(out.resolve("a")); Files.createDirectories(out.resolve("b"));
    Files.write(out.resolve("_attested-folder"), s.encodeFolder(idTop, name, null, top));
    Files.write(out.resolve("a/_attested-folder"), s.encodeFolder(idA, "a", idTop, null));
    Files.write(out.resolve("b/_attested-folder"), s.encodeFolder(idB, "b", idTop, null));
    file(s, out.resolve("a"), "part-r-00000", data(30000, 1), idA);
    file(s, out.resolve("b"), "data", data(20000, 2), idB);
    file(s, out, "_SUCCESS", new byte[0], idTop);
    if (bad) {
      Files.write(out.resolve("a/part-r-00000"), data(30000, 99));
    }
  }
}
