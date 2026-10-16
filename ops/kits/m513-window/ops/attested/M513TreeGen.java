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

import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.Arrays;

/** REHEARSAL AND TESTS ONLY: makes a signed folder tree as the wrapper makes it, with the keys of a real signing service (started here, with a stand-in quote command). */
public final class M513TreeGen {
  private M513TreeGen() {
  }

  static byte[] data(int n, int seed) {
    byte[] b = new byte[n];
    for (int i = 0; i < n; i++) {
      b[i] = (byte) (i * 7 + seed);
    }
    return b;
  }

  static void file(AttestedSignatures s, Path dir, String name, byte[] content, byte[] folderId) throws Exception {
    Files.write(dir.resolve(name), content);
    MerkleHasher mh = new MerkleHasher(16384, true);
    mh.update(content, 0, content.length);
    byte[] root = mh.finish();
    Files.write(dir.resolve("." + name + ".attested"), s.encodeBound(16384, content.length, root, mh.leaves(), folderId, name));
  }

  /** quoteCmd null: a service key without a quote (SVC-). Returns the key id that signed the tree. */
  static String generate(Path svcDir, Path listDir, Path out, String top, String quoteCmd, boolean bad) throws Exception {
    KeyService svc = KeyService.start(svcDir, 0, listDir, quoteCmd, "gen-host");
    try {
      String token = new String(Files.readAllBytes(svcDir.resolve("token")), java.nio.charset.StandardCharsets.US_ASCII).trim();
      AttestedSignatures s = new AttestedSignatures(new ServiceKeys("127.0.0.1", svc.port(), token, new KeyList(listDir, true, null, 0), 3000), true, true, false);
      byte[] idTop = new byte[16];
      byte[] idA = new byte[16];
      byte[] idB = new byte[16];
      Arrays.fill(idTop, (byte) 1);
      Arrays.fill(idA, (byte) 2);
      Arrays.fill(idB, (byte) 3);
      String name = top.substring(top.lastIndexOf('/') + 1);
      Files.createDirectories(out.resolve("a"));
      Files.createDirectories(out.resolve("b"));
      Files.write(out.resolve("_attested-folder"), s.encodeFolder(idTop, name, null, top));
      Files.write(out.resolve("a/_attested-folder"), s.encodeFolder(idA, "a", idTop, null));
      Files.write(out.resolve("b/_attested-folder"), s.encodeFolder(idB, "b", idTop, null));
      file(s, out.resolve("a"), "part-r-00000", data(30000, 1), idA);
      file(s, out.resolve("b"), "data", data(20000, 2), idB);
      file(s, out, "_SUCCESS", new byte[0], idTop);
      if (bad) {
        Files.write(out.resolve("a/part-r-00000"), data(30000, 99));
      }
      return svc.keyId();
    } finally {
      svc.close();
    }
  }

  static String token(Path file) throws Exception {
    return new String(Files.readAllBytes(file), java.nio.charset.StandardCharsets.US_ASCII).trim();
  }

  /** Two RUNNING services sign one tree, as master and worker do in a crawl: A signs the folders and most files, B signs the file b/data. */
  static void generateTwo(int portA, Path tokenA, int portB, Path tokenB, Path listDir, Path out, String top, boolean bad) throws Exception {
    KeyList list = new KeyList(listDir, false, null, 0);
    AttestedSignatures a = new AttestedSignatures(new ServiceKeys("127.0.0.1", portA, token(tokenA), list, 3000), true, true, false);
    AttestedSignatures b = new AttestedSignatures(new ServiceKeys("127.0.0.1", portB, token(tokenB), list, 3000), true, true, false);
    byte[] idTop = new byte[16];
    byte[] idA = new byte[16];
    byte[] idB = new byte[16];
    Arrays.fill(idTop, (byte) 1);
    Arrays.fill(idA, (byte) 2);
    Arrays.fill(idB, (byte) 3);
    String name = top.substring(top.lastIndexOf('/') + 1);
    Files.createDirectories(out.resolve("a"));
    Files.createDirectories(out.resolve("b"));
    Files.write(out.resolve("_attested-folder"), a.encodeFolder(idTop, name, null, top));
    Files.write(out.resolve("a/_attested-folder"), a.encodeFolder(idA, "a", idTop, null));
    Files.write(out.resolve("b/_attested-folder"), a.encodeFolder(idB, "b", idTop, null));
    file(a, out.resolve("a"), "part-r-00000", data(30000, 1), idA);
    file(b, out.resolve("b"), "data", data(20000, 2), idB);
    file(a, out, "_SUCCESS", new byte[0], idTop);
    if (bad) {
      Files.write(out.resolve("a/part-r-00000"), data(30000, 99));
    }
  }

  /** args: two PORT_A TOKEN_FILE_A PORT_B TOKEN_FILE_B LIST_DIR OUT_DIR TOP_PATH [bad]   |   SERVICE_DIR LIST_DIR OUT_DIR TOP_PATH QUOTE_CMD|none [bad] */
  public static void main(String[] a) throws Exception {
    if (a[0].equals("two")) {
      generateTwo(Integer.parseInt(a[1]), Paths.get(a[2]), Integer.parseInt(a[3]), Paths.get(a[4]), Paths.get(a[5]), Paths.get(a[6]), a[7], a.length > 8 && a[8].equals("bad"));
      System.out.println("tree made, signed by two running services");
      return;
    }
    String id = generate(Paths.get(a[0]), Paths.get(a[1]), Paths.get(a[2]), a[3], a[4].equals("none") ? null : a[4], a.length > 5 && a[5].equals("bad"));
    System.out.println("tree made, signed by " + id);
  }
}
