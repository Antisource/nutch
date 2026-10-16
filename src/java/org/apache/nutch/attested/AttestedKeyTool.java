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
 *                                                                             is the SHA-512 of the statement (not the quote's signature chain: step 5.2.1)
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
