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

/**
 * A small command line tool for the TEST key of step 5.1.1.
 *
 * <pre>
 * java -cp attested-hdfs.jar org.apache.nutch.attested.AttestedKeyTool generate FILE   make a new test key file (mode 600; never overwrites)
 * java -cp attested-hdfs.jar org.apache.nutch.attested.AttestedKeyTool info FILE       print the key id and whether the file can sign
 * java -cp attested-hdfs.jar org.apache.nutch.attested.AttestedKeyTool public FILE OUT write a public-only copy (it can verify, not sign)
 * java -cp attested-hdfs.jar org.apache.nutch.attested.AttestedKeyTool bundle-info FILE   print what a key bundle says (key id, host, time, quote)
 * java -cp attested-hdfs.jar org.apache.nutch.attested.AttestedKeyTool bundle-verify FILE [--allow-unquoted]
 *                                                                             check a key bundle: the key id is the hash of the public key and the quote's REPORTDATA
 *                                                                             is the SHA-512 of the statement (not the quote's signature chain: bundle-admit does that)
 * java -cp attested-hdfs.jar org.apache.nutch.attested.AttestedKeyTool bundle-admit FILE REFERENCE [--no-dates] [--enforce mrtd,rtmr0,...] [--root SHA256]
 *                                                                             admit a key bundle by its quote (step 5.2.1): the certificate chain, the signatures and the reference measurements; prints ADMIT or REJECT
 * java -cp attested-hdfs.jar org.apache.nutch.attested.AttestedKeyTool node-admit BUNDLE REFERENCE POLICY [--max-age S] [--skew S] [--enforce a,b] [--root SHA256] [--no-dates] [--now ISO]
 *                                                                             the doorman's decision for one node bundle (step 5.2.2): binding, policy table, freshness, genuine quote and reference
 * java -cp attested-hdfs.jar org.apache.nutch.attested.AttestedKeyTool node-admit-all REFERENCE POLICY OUT.tsv [options as above] BUNDLE...
 *                                                                             the same for several bundles; writes the admitted nodes (host, mesh key, mesh address, VPC address) to OUT.tsv; refuses a host or a mesh key twice
 * java -cp attested-hdfs.jar org.apache.nutch.attested.AttestedKeyTool quote-info FILE   print the measurement registers and the certificate chain of a bundle's quote (no verification)
 * </pre>
 *
 * <p>It prints the key id, never the private key. The test key is never to be used in evidence.</p>
 */
public final class AttestedKeyTool {

  private AttestedKeyTool() {
  }

  public static void main(String[] args) {
    System.exit(run(args, System.out, System.err));
  }

  static int run(String[] args, PrintStream out, PrintStream err) {
    try {
      if (args.length == 2 && args[0].equals("generate")) {
        TestKeys k = TestKeys.generate(Paths.get(args[1]));
        out.println("generated " + args[1] + "   key id " + k.signingKeyId() + "   (a TEST key: never for evidence)");
        return 0;
      }
      if (args.length == 2 && args[0].equals("info")) {
        TestKeys k = TestKeys.load(Paths.get(args[1]));
        out.println("file " + args[1] + "   key id " + k.keyId() + "   can sign: " + (k.signingKeyId() != null));
        return 0;
      }
      if (args.length >= 2 && args[0].equals("quote-info")) {
        KeyBundle b = KeyBundle.decode(Files.readAllBytes(Paths.get(args[1])));
        QuoteVerifier.Quote q = QuoteVerifier.parse(b.quote);
        out.println("key id " + b.keyId + "   host " + b.host + "   quote version " + q.version + "   tee type 0x" + Long.toHexString(q.teeType));
        for (String reg : QuoteVerifier.REGISTERS) {
          out.println(String.format("%-6s %s", reg.toUpperCase(), q.register(reg)));
        }
        return 0;
      }
      if (args.length >= 4 && (args[0].equals("node-admit") || args[0].equals("node-admit-all"))) {
        boolean all = args[0].equals("node-admit-all");
        String reference = all ? args[1] : args[2];
        String policyFile = all ? args[2] : args[3];
        String tsv = all ? args[3] : null;
        java.util.List<String> bundles = new java.util.ArrayList<>();
        if (!all) {
          bundles.add(args[1]);
        }
        long maxAge = 900;
        long skew = 60;
        boolean dates = true;
        String enforce = QuoteAdmission.DEFAULT_ENFORCE;
        String root = QuoteAdmission.INTEL_SGX_ROOT_SHA256;
        java.time.Instant now = null;
        for (int i = all ? 4 : 4; i < args.length; i++) {
          if (args[i].equals("--no-dates")) {
            dates = false;
          } else if (args[i].equals("--max-age") && i + 1 < args.length) {
            maxAge = Long.parseLong(args[++i]);
          } else if (args[i].equals("--skew") && i + 1 < args.length) {
            skew = Long.parseLong(args[++i]);
          } else if (args[i].equals("--enforce") && i + 1 < args.length) {
            enforce = args[++i];
          } else if (args[i].equals("--root") && i + 1 < args.length) {
            root = args[++i];
          } else if (args[i].equals("--now") && i + 1 < args.length) {
            now = java.time.Instant.parse(args[++i]);
          } else if (all && !args[i].startsWith("--")) {
            bundles.add(args[i]);
          } else {
            throw new IOException("unknown option " + args[i]);
          }
        }
        if (bundles.isEmpty()) {
          throw new IOException("no node bundle given");
        }
        final java.time.Instant fixedNow = now;
        java.util.function.Supplier<java.time.Instant> clock = () -> fixedNow != null ? fixedNow : java.time.Instant.now();
        QuoteAdmission qa = new QuoteAdmission(AdmissionReference.load(Paths.get(reference), ""), QuoteAdmission.registers(enforce), QuoteAdmission.rootList(root), dates, clock);
        MeshAdmission door = new MeshAdmission(MeshAdmission.of(qa), MeshPolicy.load(Paths.get(policyFile)), maxAge, skew, clock);
        MeshAdmission.Roster admitted = new MeshAdmission.Roster();
        int refused = 0;
        for (String f : bundles) {
          String name = Paths.get(f).getFileName().toString();
          try {
            MeshAdmission.Admitted a = door.admit(NodeBundle.decode(Files.readAllBytes(Paths.get(f))));
            admitted.add(a);
            out.println("ADMIT-NODE host=" + a.host + " mesh-public=" + a.meshPublic + " mesh-ip=" + a.meshIp + " vpc-ip=" + (a.vpcIp.isEmpty() ? "-" : a.vpcIp) + " " + a.note);
          } catch (IOException e) {
            if (!all) {
              throw new IOException("REJECT-NODE " + name + ": " + e.getMessage());
            }
            refused++;
            out.println("REJECT-NODE " + name + ": " + e.getMessage());
          }
        }
        if (all) {
          StringBuilder sb = new StringBuilder();
          for (MeshAdmission.Admitted a : admitted.all()) {
            sb.append(a.host).append('\t').append(a.meshPublic).append('\t').append(a.meshIp).append('\t').append(a.vpcIp.isEmpty() ? "-" : a.vpcIp).append('\n');
          }
          Files.write(Paths.get(tsv), sb.toString().getBytes(java.nio.charset.StandardCharsets.UTF_8));
          out.println("NODES " + admitted.size() + " admitted, " + refused + " refused");
          return refused == 0 ? 0 : 1;
        }
        return 0;
      }
      if (args.length >= 3 && args[0].equals("bundle-admit")) {
        KeyBundle b = KeyBundle.decode(Files.readAllBytes(Paths.get(args[1])));
        b.checkBinding();
        boolean dates = true;
        String enforce = QuoteAdmission.DEFAULT_ENFORCE;
        String root = QuoteAdmission.INTEL_SGX_ROOT_SHA256;
        for (int i = 3; i < args.length; i++) {
          if (args[i].equals("--no-dates")) {
            dates = false;
          } else if (args[i].equals("--enforce") && i + 1 < args.length) {
            enforce = args[++i];
          } else if (args[i].equals("--root") && i + 1 < args.length) {
            root = args[++i];
          } else {
            throw new IOException("unknown option " + args[i]);
          }
        }
        QuoteAdmission adm = new QuoteAdmission(AdmissionReference.load(Paths.get(args[2]), ""), QuoteAdmission.registers(enforce), QuoteAdmission.rootList(root), dates, java.time.Instant::now);
        adm.check(b);
        out.println("ADMIT   key id " + b.keyId + "   host " + b.host + "   " + adm.note(b));
        return 0;
      }
      if (args.length >= 2 && args[0].startsWith("bundle-")) {
        KeyBundle b = KeyBundle.decode(Files.readAllBytes(Paths.get(args[1])));
        if (args[0].equals("bundle-info") && args.length == 2) {
          out.println("key id " + b.keyId + "   host " + b.host + "   created " + b.created + "   quote "
              + (b.hasQuote() ? b.quote.length + " bytes" : "none"));
          return 0;
        }
        if (args[0].equals("bundle-verify") && (args.length == 2 || (args.length == 3 && args[2].equals("--allow-unquoted")))) {
          b.checkBinding();
          if (!b.hasQuote() && args.length == 2) {
            throw new IOException("the bundle has no quote (" + b.keyId + "): it is accepted only with --allow-unquoted");
          }
          out.println("BUNDLE-OK   key id " + b.keyId + "   host " + b.host + "   "
              + (b.hasQuote() ? "the quote's REPORTDATA is the SHA-512 of the statement (the quote's own signature is not checked here)"
                  : "no quote (a service key)"));
          return 0;
        }
      }
      if (args.length == 3 && args[0].equals("public")) {
        TestKeys k = TestKeys.load(Paths.get(args[1]));
        Path outFile = Paths.get(args[2]);
        if (Files.exists(outFile)) {
          err.println("ATTESTED-KEY-TOOL-STOP: " + args[2] + " exists already");
          return 1;
        }
        Files.write(outFile, k.publicFileText().getBytes(StandardCharsets.US_ASCII));
        TestKeys check = TestKeys.load(outFile);
        out.println("wrote " + args[2] + "   key id " + check.keyId() + "   (public only: it can verify, it cannot sign)");
        return 0;
      }
      err.println("usage: AttestedKeyTool generate FILE | info FILE | public FILE OUT");
      return 2;
    } catch (IOException e) {
      err.println("ATTESTED-KEY-TOOL-STOP: " + e.getMessage());
      return 1;
    }
  }
}
