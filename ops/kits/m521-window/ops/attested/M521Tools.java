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
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import java.util.stream.Collectors;
import java.util.stream.Stream;

/**
 * Tools for the demonstration of step 5.1.2. They are compiled next to the wrapper's classes (same package, so that they can use the record and
 * folder codecs) and are NOT part of the wrapper or the job.
 *
 * <pre>
 * M521Tools forge-record CONTENT HONEST_RECORD OUT      a record for CONTENT that names the honest record's folder and file name, signed with the
 *                                                      attacker's own key under the honest key id
 * M521Tools forge-identity HONEST_IDENTITY OUT          the same identity fields, signed with the attacker's own key under the honest key id
 * M521Tools inspect FILE                                prints what a record (ATTEST0x) or a folder identity file says
 * M521Tools verify-tree-admit KEYLISTDIR REFERENCE LOCALTOP HDFSTOP [--enforce a,b] [--root SHA256] [--no-dates]   the check of step 5.2.1: as verify-tree-list, but a key is trusted only if its bundle's
 *                                                      quote is admitted (the certificate chain to the pinned Intel root, the signatures, and the reference measurements); every rejection is printed
 * M521Tools verify-tree-list KEYLISTDIR LOCALTOP HDFSTOP   the same check for the real keys of step 5.2.1: the signatures are checked against the key list (a folder of key bundles that pass
 *                                                      the binding check; a key without a quote is not accepted), not against one test key; every OK line names the key
 * M521Tools verify-tree KEYFILE LOCALTOP HDFSTOP        checks a LOCAL copy of a whole folder tree with the public key only: every folder has an identity that
 *                                                      verifies, names the folder and points to its parent (the top: its full path HDFSTOP); every file has a
 *                                                      signed record bound to the folder it is in and to its name, and matching its bytes
 * </pre>
 */
public final class M521Tools {

  private M521Tools() {
  }

  public static void main(String[] args) {
    System.exit(run(args, System.out, System.err));
  }

  static int run(String[] a, PrintStream out, PrintStream err) {
    try {
      if (a.length == 4 && a[0].equals("forge-record")) {
        return forgeRecord(Paths.get(a[1]), Paths.get(a[2]), Paths.get(a[3]), out, err);
      }
      if (a.length == 3 && a[0].equals("forge-identity")) {
        return forgeIdentity(Paths.get(a[1]), Paths.get(a[2]), out);
      }
      if (a.length == 2 && a[0].equals("inspect")) {
        return inspect(Paths.get(a[1]), out);
      }
      if (a.length == 4 && a[0].equals("verify-tree")) {
        return verifyTree(Paths.get(a[1]), Paths.get(a[2]), a[3], out);
      }
      if (a.length >= 5 && a[0].equals("verify-tree-admit")) {
        String enforce = QuoteAdmission.DEFAULT_ENFORCE;
        String root = QuoteAdmission.INTEL_SGX_ROOT_SHA256;
        boolean dates = true;
        for (int i = 5; i < a.length; i++) {
          if (a[i].equals("--no-dates")) {
            dates = false;
          } else if (a[i].equals("--enforce") && i + 1 < a.length) {
            enforce = a[++i];
          } else if (a[i].equals("--root") && i + 1 < a.length) {
            root = a[++i];
          } else {
            err.println("unknown option " + a[i]);
            return 2;
          }
        }
        QuoteAdmission adm = new QuoteAdmission(AdmissionReference.load(Paths.get(a[2]), ""), QuoteAdmission.registers(enforce), QuoteAdmission.rootList(root), dates, java.time.Instant::now);
        KeyList list = new KeyList(Paths.get(a[1]), false, adm, 0);
        list.refresh();
        for (String r : list.rejected()) {
          out.println("KEYLIST-REJECTED  " + r);
        }
        out.println("KEYLIST " + list.size() + " key(s) admitted by their quotes");
        AttestedSignatures sigs = new AttestedSignatures(new ServiceKeys(null, 0, null, list, 0), false, true, false);
        return verifyTree(sigs, Paths.get(a[3]), a[4], out);
      }
      if (a.length == 4 && a[0].equals("verify-tree-list")) {
        KeyList list = new KeyList(Paths.get(a[1]), false, null, 0);
        list.refresh();
        for (String r : list.rejected()) {
          out.println("KEYLIST-REJECTED  " + r);
        }
        out.println("KEYLIST " + list.size() + " key(s) trusted");
        AttestedSignatures sigs = new AttestedSignatures(new ServiceKeys(null, 0, null, list, 0), false, true, false);
        return verifyTree(sigs, Paths.get(a[2]), a[3], out);
      }
      err.println("usage: M521Tools forge-record CONTENT HONEST_RECORD OUT | forge-identity HONEST_IDENTITY OUT | inspect FILE | verify-tree KEYFILE LOCALTOP HDFSTOP | verify-tree-list KEYLISTDIR LOCALTOP HDFSTOP | verify-tree-admit KEYLISTDIR REFERENCE LOCALTOP HDFSTOP [options]");
      return 2;
    } catch (IOException e) {
      err.println("M512-TOOLS-STOP: " + e.getMessage());
      return 1;
    }
  }

  private static TestKeys attacker() throws IOException {
    Path tmp = Files.createTempDirectory("attacker");
    try {
      return TestKeys.generate(tmp.resolve("attacker.txt"));
    } finally {
      try (Stream<Path> s = Files.walk(tmp)) {
        for (Path p : s.sorted(Collections.reverseOrder()).collect(Collectors.toList())) {
          Files.deleteIfExists(p);
        }
      }
    }
  }

  static int forgeRecord(Path content, Path honestRecord, Path outFile, PrintStream out, PrintStream err) throws IOException {
    AttestedRecordCodec.Decoded honest = AttestedRecordCodec.decode(Files.readAllBytes(honestRecord));
    if (!honest.bound()) {
      err.println("M512-TOOLS-STOP: the honest record is not bound to a folder (ATTEST03)");
      return 1;
    }
    byte[] data = Files.readAllBytes(content);
    MerkleHasher mh = new MerkleHasher(honest.chunkSize, true);
    mh.update(data, 0, data.length);
    byte[] root = mh.finish();
    TestKeys attacker = attacker();
    byte[] sig = attacker.sign(AttestedRecordCodec.statementBound(honest.keyId, honest.folderId, honest.fileName, honest.chunkSize, data.length, root));
    Files.write(outFile, AttestedRecordCodec.encodeBound(honest.chunkSize, data.length, root, mh.leaves(), honest.folderId, honest.fileName, honest.keyId, sig));
    out.println("forged a record for " + data.length + " bytes, bound to the honest folder and name '" + honest.fileName + "', signed by the attacker -> " + outFile);
    return 0;
  }

  static int forgeIdentity(Path honestIdentity, Path outFile, PrintStream out) throws IOException {
    AttestedFolderCodec.Decoded h = AttestedFolderCodec.decode(Files.readAllBytes(honestIdentity));
    TestKeys attacker = attacker();
    byte[] sig = attacker.sign(AttestedFolderCodec.statement(h.keyId, h.folderId, h.name, h.parentId, h.topPath));
    Files.write(outFile, AttestedFolderCodec.encode(h.folderId, h.name, h.parentId, h.topPath, h.keyId, sig));
    out.println("forged the identity of folder '" + h.name + "', signed by the attacker -> " + outFile);
    return 0;
  }

  private static String hex8(byte[] b) {
    return MerkleHasher.hex(b).substring(0, 8);
  }

  static int inspect(Path file, PrintStream out) throws IOException {
    byte[] all = Files.readAllBytes(file);
    String magic = all.length >= 8 ? new String(all, 0, 8, StandardCharsets.US_ASCII) : "";
    if (magic.equals("ATTESTFD")) {
      AttestedFolderCodec.Decoded d = AttestedFolderCodec.decode(all);
      out.println("folder identity: name=" + d.name + " id=" + hex8(d.folderId) + (d.top() ? " top path=" + d.topPath : " parent=" + hex8(d.parentId)) + " key=" + d.keyId);
    } else {
      AttestedRecordCodec.Decoded r = AttestedRecordCodec.decode(all);
      out.println("record: " + magic + " length=" + r.length + (r.bound() ? " folder=" + hex8(r.folderId) + " name=" + r.fileName : " (not bound to a folder)") + (r.signed() ? " key=" + r.keyId : " (unsigned)"));
    }
    return 0;
  }

  private static final class Tally {
    int folders;
    int files;
    int ok;
    int bad;
    final List<String> lines = new ArrayList<>();
  }

  static int verifyTree(Path keyFile, Path localTop, String hdfsTop, PrintStream out) throws IOException {
    TestKeys keys = TestKeys.load(keyFile);
    return verifyTree(new AttestedSignatures(keys, false, true, true), localTop, hdfsTop, out);
  }

  static int verifyTree(AttestedSignatures sigs, Path localTop, String hdfsTop, PrintStream out) throws IOException {
    Tally t = new Tally();
    String topName = hdfsTop.substring(hdfsTop.lastIndexOf('/') + 1);
    walk(localTop, hdfsTop, topName, null, sigs, t, true, hdfsTop);
    for (String l : t.lines) {
      out.println(l);
    }
    out.println("VERIFY-TREE folders=" + t.folders + " files=" + t.files + " ok=" + t.ok + " bad=" + t.bad);
    boolean clean = t.bad == 0 && t.files > 0;
    out.println(clean ? "VERIFY-TREE-CLEAN" : "VERIFY-TREE-FINDINGS (" + t.bad + (t.files == 0 ? ", nothing verified" : "") + ")");
    return clean ? 0 : 1;
  }

  private static void walk(Path dir, String hdfsPath, String name, AttestedFolderCodec.Decoded parent, AttestedSignatures sigs, Tally t,
      boolean top, String hdfsTop) throws IOException {
    t.folders++;
    Path idFile = dir.resolve(AttestedFolderCodec.FILE_NAME);
    List<Path> entries;
    try (Stream<Path> s = Files.list(dir)) {
      entries = s.sorted().collect(Collectors.toList());
    }
    AttestedFolderCodec.Decoded d = null;
    String why = null;
    if (!Files.exists(idFile)) {
      why = "the folder has no identity";
    } else {
      try {
        d = AttestedFolderCodec.decode(Files.readAllBytes(idFile));
        sigs.checkFolder(d);
        if (!d.name.equals(name)) {
          why = "the identity is for a folder named '" + d.name + "', not '" + name + "'";
        } else if (top && !(d.top() && d.topPath.equals(hdfsTop))) {
          why = "the top identity is not for the path " + hdfsTop;
        } else if (!top && (d.top() || !Arrays.equals(d.parentId, parent.folderId))) {
          why = "the identity points to another parent folder";
        }
      } catch (IOException e) {
        why = e.getMessage();
      }
    }
    if (why != null) {
      t.bad++;
      t.lines.add("BAD  " + hdfsPath + "/  " + why);
      d = null;
    }
    for (Path p : entries) {
      String n = p.getFileName().toString();
      if (Files.isDirectory(p)) {
        if (d != null) {
          walk(p, hdfsPath + "/" + n, n, d, sigs, t, false, hdfsTop);
        } else {
          t.bad++;
          t.lines.add("BAD  " + hdfsPath + "/" + n + "/  not checked: its parent folder is not trusted");
        }
        continue;
      }
      if (AttestedFolderCodec.isIdentityName(n) || (n.startsWith(".") && n.endsWith(".attested"))) {
        continue;
      }
      t.files++;
      Path rec = dir.resolve("." + n + ".attested");
      String rel = hdfsPath + "/" + n;
      if (d == null) {
        t.bad++;
        t.lines.add("BAD  " + rel + "  not checked: its folder is not trusted");
        continue;
      }
      if (!Files.exists(rec)) {
        t.bad++;
        t.lines.add("BAD  " + rel + "  the file has no record");
        continue;
      }
      try {
        AttestedRecordCodec.Decoded r = AttestedRecordCodec.decode(Files.readAllBytes(rec));
        sigs.check(r);
        if (!r.bound()) {
          throw new IOException("the record is not bound to a folder");
        }
        if (!Arrays.equals(r.folderId, d.folderId)) {
          throw new IOException("the record belongs to another folder than the one this file is in");
        }
        if (!r.fileName.equals(n)) {
          throw new IOException("the record is for a file named '" + r.fileName + "', not '" + n + "'");
        }
        byte[] data = Files.readAllBytes(p);
        MerkleHasher mh = new MerkleHasher(r.chunkSize, true);
        mh.update(data, 0, data.length);
        if (data.length != r.length || !Arrays.equals(mh.finish(), r.root)) {
          throw new IOException("the file's bytes do not match its record");
        }
        t.ok++;
        t.lines.add("OK   " + rel + "  folder=" + hex8(d.folderId) + " key=" + r.keyId);
      } catch (IOException e) {
        t.bad++;
        t.lines.add("BAD  " + rel + "  " + e.getMessage());
      }
    }
  }
}
