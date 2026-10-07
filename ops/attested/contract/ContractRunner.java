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
package org.apache.nutch.attested.contracttest;

import java.io.FileOutputStream;
import java.io.OutputStreamWriter;
import java.io.PrintWriter;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.Map;

import org.junit.runner.Description;
import org.junit.runner.JUnitCore;
import org.junit.runner.Result;
import org.junit.runner.notification.Failure;
import org.junit.runner.notification.RunListener;

/**
 * Runs JUnit test classes one after the other and writes one line per test method:
 * mode, class, method, outcome (PASS, FAIL, SKIP for an assumption that did not hold, IGNORED)
 * and the first line of the message. The comparison of the plain and the wrapped run is made
 * by contract_compare.py.
 *
 * <p>Usage: ContractRunner RESULTS.tsv TestClass...</p>
 */
public final class ContractRunner {

  private ContractRunner() {
  }

  private static String clip(Failure f) {
    String m = String.valueOf(f.getMessage()).replace('\n', ' ').replace('\r', ' ').replace('\t', ' ');
    if (m.length() > 300) {
      m = m.substring(0, 300);
    }
    return f.getException().getClass().getSimpleName() + ": " + m;
  }

  public static void main(String[] args) throws Exception {
    if (args.length < 2) {
      System.err.println("usage: ContractRunner RESULTS.tsv TestClass...");
      System.exit(2);
    }
    String mode = Boolean.parseBoolean(System.getProperty(AttestedHdfsContract.WRAPPER_PROP, "true"))
        ? "wrapped" : "plain";
    try (PrintWriter out = new PrintWriter(
        new OutputStreamWriter(new FileOutputStream(args[0]), StandardCharsets.UTF_8))) {
      int total = 0;
      int failed = 0;
      int skipped = 0;
      for (int i = 1; i < args.length; i++) {
        Class<?> c = Class.forName(args[i]);
        final Map<String, String> res = new LinkedHashMap<>();
        final Map<String, Integer> seen = new HashMap<>();
        final String[] current = { null };
        JUnitCore core = new JUnitCore();
        core.addListener(new RunListener() {
          /** Parameterized tests can repeat a method name; the second one is kept as name#2, and so on. */
          private String keyFor(String method) {
            int n = seen.merge(method, 1, Integer::sum);
            return n == 1 ? method : method + "#" + n;
          }

          /** The test the event belongs to: the one that is running, or "(class)" for a failure outside any test. */
          private String keyOf(Description d) {
            String m = d.getMethodName();
            if (m == null || current[0] == null || !current[0].startsWith(m)) {
              return m == null ? "(class)" : m;
            }
            return current[0];
          }

          @Override
          public void testStarted(Description d) {
            current[0] = keyFor(String.valueOf(d.getMethodName()));
            res.put(current[0], "PASS\t");
          }

          @Override
          public void testFailure(Failure f) {
            String key = keyOf(f.getDescription());
            String cur = res.get(key);
            if (cur == null || cur.startsWith("PASS")) {
              res.put(key, "FAIL\t" + clip(f));
            }
          }

          @Override
          public void testAssumptionFailure(Failure f) {
            res.put(keyOf(f.getDescription()), "SKIP\t" + clip(f));
          }

          @Override
          public void testIgnored(Description d) {
            res.put(keyFor(String.valueOf(d.getMethodName())), "IGNORED\t");
          }
        });
        Result r = core.run(c);
        int cf = 0;
        int cs = 0;
        for (Map.Entry<String, String> e : res.entrySet()) {
          out.println(mode + "\t" + c.getSimpleName() + "\t" + e.getKey() + "\t" + e.getValue());
          if (e.getValue().startsWith("FAIL")) {
            cf++;
          } else if (e.getValue().startsWith("SKIP") || e.getValue().startsWith("IGNORED")) {
            cs++;
          }
        }
        out.flush();
        total += res.size();
        failed += cf;
        skipped += cs;
        System.out.println("CLASS " + c.getSimpleName() + ": tests " + res.size() + ", failed " + cf
            + ", skipped " + cs + " (JUnit says run " + r.getRunCount() + ", failures " + r.getFailureCount() + ")");
      }
      System.out.println("RUN-DONE mode=" + mode + " tests=" + total + " failed=" + failed + " skipped=" + skipped);
    }
  }
}
