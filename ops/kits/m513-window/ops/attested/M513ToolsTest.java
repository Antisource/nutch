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
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

/** Tests of M513Tools verify-tree-list and of m513_bundle_extract.py (run from the folder that holds the script). */
public final class M513ToolsTest {
  static int pass = 0;
  static int fail = 0;

  static void chk(String what, boolean ok) {
    if (ok) { pass++; System.out.println("  pass: " + what); } else { fail++; System.out.println("  FAIL: " + what); }
  }

  static String verify(Path list, Path tree, String top, int[] rc) throws Exception {
    ByteArrayOutputStream o = new ByteArrayOutputStream();
    ByteArrayOutputStream e = new ByteArrayOutputStream();
    rc[0] = M513Tools.run(new String[]{"verify-tree-list", list.toString(), tree.toString(), top}, new PrintStream(o), new PrintStream(e));
    return o.toString() + e.toString();
  }

  static String run(String... cmd) throws Exception {
    Process p = new ProcessBuilder(cmd).redirectErrorStream(true).start();
    String out = new String(p.getInputStream().readAllBytes(), StandardCharsets.UTF_8);
    p.waitFor();
    return out + "exit=" + p.exitValue();
  }

  public static void main(String[] args) throws Exception {
    Path tmp = Files.createTempDirectory("m513tools");
    Path quote = tmp.resolve("fake-quote.sh");
    Files.write(quote, ("#!/usr/bin/env bash\npython3 - \"$1\" \"$2\" <<'PY'\nimport hashlib, sys\nst = open(sys.argv[1], 'rb').read()\nq = bytearray(b'\\x04\\x00' + b'\\x00' * 630)\nq[568:632] = hashlib.sha512(st).digest()\nopen(sys.argv[2], 'wb').write(bytes(q))\nPY\n").getBytes(StandardCharsets.US_ASCII));
    Files.setPosixFilePermissions(quote, java.nio.file.attribute.PosixFilePermissions.fromString("rwxr-xr-x"));
    Path list = tmp.resolve("list");
    Path tree = tmp.resolve("tree");
    int[] rc = new int[1];
    System.out.println("== 1. a tree signed with a real key (TDX-) verifies against the key list");
    String id = M513TreeGen.generate(tmp.resolve("svc1"), list, tree, "/user/x/crawl-1", quote.toString(), false);
    String out = verify(list, tree, "/user/x/crawl-1", rc);
    chk("the key list trusts the key and the whole tree is clean (3 folders, 3 files)", rc[0] == 0 && out.contains("KEYLIST 1 key(s) trusted") && out.contains("VERIFY-TREE folders=3 files=3 ok=3 bad=0") && out.contains("VERIFY-TREE-CLEAN"));
    chk("every OK line names the TDX- key that signed it", out.contains("key=" + id) && out.lines().filter(l -> l.startsWith("OK ")).allMatch(l -> l.contains("key=" + id)));
    System.out.println("== 2. what must fail");
    Path bad = tmp.resolve("tree-bad");
    M513TreeGen.generate(tmp.resolve("svc2"), tmp.resolve("list2"), bad, "/user/x/crawl-2", quote.toString(), true);
    out = verify(tmp.resolve("list2"), bad, "/user/x/crawl-2", rc);
    chk("a file changed after it was signed is found (its bytes do not match its record)", rc[0] == 1 && out.contains("the file's bytes do not match its record"));
    Path empty = tmp.resolve("empty-list");
    Files.createDirectories(empty);
    out = verify(empty, tree, "/user/x/crawl-1", rc);
    chk("a key list that does not hold the key refuses everything: not trusted here", rc[0] == 1 && out.contains("not trusted here") && out.contains("VERIFY-TREE-FINDINGS"));
    Path softTree = tmp.resolve("tree-soft");
    M513TreeGen.generate(tmp.resolve("svc3"), tmp.resolve("list3"), softTree, "/user/x/crawl-3", null, false);
    out = verify(tmp.resolve("list3"), softTree, "/user/x/crawl-3", rc);
    chk("a tree signed by a key without a quote is refused, and the list says why", rc[0] == 1 && out.contains("KEYLIST-REJECTED") && out.contains("without a quote") && out.contains("not trusted here"));
    out = verify(list, tree, "/user/x/elsewhere", rc);
    chk("a tree copied to another path is refused (its top identity names the original folder)", rc[0] == 1 && out.contains("the identity is for a folder named") && out.contains("VERIFY-TREE-FINDINGS"));
    System.out.println("== 3. the bundle extraction");
    String script = Path.of(System.getProperty("m513.script", "m513_bundle_extract.py")).toString();
    Path bundle = java.nio.file.Files.list(list).findFirst().get();
    String ex = run("python3", script, bundle.toString(), tmp.resolve("x1").toString());
    chk("a bundle is taken apart: statement and quote written, REPORTDATA equals the SHA-512 of the statement (EXTRACT-MATCH)", ex.contains("EXTRACT-MATCH") && ex.endsWith("exit=0") && Files.size(tmp.resolve("x1/quote.bin")) == 632 && ex.contains("key id    " + id));
    chk("the statement file is what verify-binding.sh needs: its SHA-512 equals the REPORTDATA", ex.contains("REPORTDATA " + ex.substring(ex.indexOf("SHA-512 of the statement ") + 25, ex.indexOf("SHA-512 of the statement ") + 25 + 128)));
    Path soft = java.nio.file.Files.list(tmp.resolve("list3")).findFirst().get();
    ex = run("python3", script, soft.toString(), tmp.resolve("x2").toString());
    chk("a bundle without a quote is reported (EXTRACT-NO-QUOTE, exit 1)", ex.contains("EXTRACT-NO-QUOTE") && ex.endsWith("exit=1"));
    String text = new String(Files.readAllBytes(bundle), StandardCharsets.US_ASCII);
    Path tampered = tmp.resolve("t.attestkey");
    byte[] q = java.util.Base64.getDecoder().decode(text.split("\n")[2].substring(6));
    q[600] ^= 1;
    Files.write(tampered, (text.split("\n")[0] + "\n" + text.split("\n")[1] + "\nquote=" + java.util.Base64.getEncoder().encodeToString(q) + "\n").getBytes());
    ex = run("python3", script, tampered.toString(), tmp.resolve("x3").toString());
    chk("a quote whose REPORTDATA was changed is reported (EXTRACT-MISMATCH, exit 1)", ex.contains("EXTRACT-MISMATCH") && ex.endsWith("exit=1"));
    ex = run("python3", script, tmp.resolve("fake-quote.sh").toString(), tmp.resolve("x4").toString());
    chk("a file that is not a bundle is refused", ex.contains("not a key bundle") && ex.endsWith("exit=1"));
    System.out.println("\npass: " + pass + "   fail: " + fail);
    System.out.println(fail == 0 ? "M513TOOLS-PASS" : "M513TOOLS-FAIL");
    if (fail != 0) System.exit(1);
  }
}
