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

import java.io.IOException;
import java.io.InputStream;
import java.io.PrintStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.stream.Collectors;
import java.util.stream.Stream;

/**
 * Two tools for the demonstration of step 5.1.1. They are compiled next to the wrapper's classes (same package, so that they can use the
 * record codec) and are NOT part of the wrapper or the job.
 *
 * <pre>
 * M511Tools forge MODE CONTENT HONEST_RECORD OUT
 *     Writes the record that an attacker would put next to CONTENT (new bytes behind the wrapper's back). MODE is one of
 *       unsigned          a record in the old format (a downgrade)
 *       oldsig            the new content with the signature copied from the honest record
 *       attacker-real-id  signed with the attacker's own key but under the honest key id
 *       attacker-own-id   signed with the attacker's own key under its own key id
 * M511Tools verify KEYFILE DIR
 *     Checks a LOCAL copy of a folder of files: every file has a record, the record's signature verifies with the key in KEYFILE
 *     (a test key file, which may hold only the public key), and the record's chunk hashes and length match the file's bytes.
 * </pre>
 */
public final class M511Tools {

  private M511Tools() {
  }

  public static void main(String[] args) {
    System.exit(run(args, System.out, System.err));
  }

  static byte[] bytes(Path p) throws IOException {
    return Files.readAllBytes(p);
  }

  static int run(String[] a, PrintStream out, PrintStream err) {
    try {
      if (a.length == 5 && a[0].equals("forge")) {
        return forge(a[1], Paths.get(a[2]), Paths.get(a[3]), Paths.get(a[4]), out, err);
      }
      if (a.length == 3 && a[0].equals("verify")) {
        return verify(Paths.get(a[1]), Paths.get(a[2]), out);
      }
      err.println("usage: M511Tools forge MODE CONTENT HONEST_RECORD OUT | verify KEYFILE DIR");
      return 2;
    } catch (IOException e) {
      err.println("M511-TOOLS-STOP: " + e.getMessage());
      return 1;
    }
  }

  static int forge(String mode, Path content, Path honestRecord, Path outFile, PrintStream out,
      PrintStream err) throws IOException {
    AttestedRecordCodec.Decoded honest = AttestedRecordCodec.decode(bytes(honestRecord));
    byte[] data = bytes(content);
    MerkleHasher mh = new MerkleHasher(honest.chunkSize, true);
    mh.update(data, 0, data.length);
    byte[] root = mh.finish();
    List<byte[]> leaves = mh.leaves();
    byte[] record;
    if (mode.equals("unsigned")) {
      record = AttestedRecordCodec.encode(honest.chunkSize, data.length, root, leaves);
    } else if (mode.equals("oldsig")) {
      if (!honest.signed()) {
        throw new IOException("the honest record is not signed, there is no signature to copy");
      }
      record = AttestedRecordCodec.encodeSigned(honest.chunkSize, data.length, root, leaves,
          honest.keyId, honest.signature);
    } else if (mode.equals("attacker-real-id") || mode.equals("attacker-own-id")) {
      Path tmp = Files.createTempDirectory("attacker");
      try {
        TestKeys attacker = TestKeys.generate(tmp.resolve("attacker.txt"));
        String id = mode.equals("attacker-real-id") ? honest.keyId : attacker.signingKeyId();
        if (id == null) {
          throw new IOException("the honest record is not signed, there is no key id to claim");
        }
        byte[] sig = attacker.sign(AttestedRecordCodec.statement(id, honest.chunkSize, data.length, root));
        record = AttestedRecordCodec.encodeSigned(honest.chunkSize, data.length, root, leaves, id, sig);
      } finally {
        try (Stream<Path> s = Files.walk(tmp)) {
          for (Path p : s.sorted(Collections.reverseOrder()).collect(Collectors.toList())) {
            Files.deleteIfExists(p);
          }
        }
      }
    } else {
      err.println("M511-TOOLS-STOP: unknown mode " + mode);
      return 2;
    }
    Files.write(outFile, record);
    out.println("forged " + mode + " record for " + data.length + " bytes -> " + outFile + " (" + record.length + " bytes)");
    return 0;
  }

  static int verify(Path keyFile, Path dir, PrintStream out) throws IOException {
    TestKeys keys = TestKeys.load(keyFile);
    AttestedSignatures sigs = new AttestedSignatures(keys, false, true, true);
    List<Path> files;
    try (Stream<Path> s = Files.walk(dir)) {
      files = s.filter(Files::isRegularFile).sorted().collect(Collectors.toList());
    }
    int ok = 0;
    int bad = 0;
    int signed = 0;
    int unsigned = 0;
    List<String> lines = new ArrayList<>();
    for (Path f : files) {
      String name = f.getFileName().toString();
      boolean isRecord = name.startsWith(".") && name.endsWith(".attested");
      if (isRecord) {
        continue;
      }
      Path rec = f.resolveSibling("." + name + ".attested");
      String rel = dir.relativize(f).toString();
      if (!Files.exists(rec)) {
        bad++;
        lines.add("BAD  " + rel + "  no record");
        continue;
      }
      try {
        AttestedRecordCodec.Decoded d = AttestedRecordCodec.decode(bytes(rec));
        if (d.signed()) {
          signed++;
        } else {
          unsigned++;
        }
        String status = sigs.check(d);
        byte[] data = bytes(f);
        MerkleHasher mh = new MerkleHasher(d.chunkSize, true);
        mh.update(data, 0, data.length);
        byte[] root = mh.finish();
        if (data.length != d.length || !java.util.Arrays.equals(root, d.root)) {
          bad++;
          lines.add("BAD  " + rel + "  the file's bytes do not match its record");
        } else {
          ok++;
          lines.add("OK   " + rel + "  sig=" + status + (d.signed() ? " key=" + d.keyId : "") + "  chunks=" + d.leaves.length);
        }
      } catch (IOException e) {
        bad++;
        lines.add("BAD  " + rel + "  " + e.getMessage());
      }
    }
    for (String l : lines) {
      out.println(l);
    }
    out.println("VERIFY-DIR files=" + (ok + bad) + " ok=" + ok + " bad=" + bad + " signed=" + signed + " unsigned=" + unsigned);
    out.println(bad == 0 && ok > 0 ? "VERIFY-DIR-CLEAN" : "VERIFY-DIR-FINDINGS (" + bad + (ok + bad == 0 ? ", nothing verified" : "") + ")");
    return bad == 0 && ok > 0 ? 0 : 1;
  }
}
