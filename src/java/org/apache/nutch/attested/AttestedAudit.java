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

import java.io.BufferedWriter;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.OutputStreamWriter;
import java.net.InetAddress;
import java.nio.charset.StandardCharsets;

import org.apache.hadoop.conf.Configuration;
import org.apache.hadoop.fs.Path;

/**
 * The wrapper's own log of what it did, one tab-separated line per request,
 * written to local disk by every JVM that uses the wrapper.
 *
 * <p>Because the wrapper keeps the <code>hdfs://</code> paths, a path no longer
 * shows whether the wrapper was in use. This log is one half of the proof:
 * the audit lists all of storage before and after a crawl and checks that every
 * change is explained by a line in these logs (see
 * <code>ops/attested/audit_compare.py</code>).</p>
 *
 * <p>Line format: <code>epoch-millis, host, pid, operation, path1, path2,
 * extra</code>. Paths are absolute and carry no scheme. Lines are written
 * before the request is forwarded, so the log can only list more than what
 * happened, never less. Each JVM writes its own file
 * (<code>host-pid-start.tsv</code>) in <code>attested.audit.dir</code>
 * (default <code>/tmp/attested-audit</code>).</p>
 *
 * <p>If the folder cannot be written the wrapper refuses to start: no log, no
 * wrapper.</p>
 */
public final class AttestedAudit {

  public static final String DIR_KEY = "attested.audit.dir";
  public static final String DEFAULT_DIR = "/tmp/attested-audit";

  private static final Object LOCK = new Object();
  private static BufferedWriter out;
  private static File file;
  private static String host = "unknown";
  private static long pid;

  private AttestedAudit() {
  }

  /** Opens this JVM's log file (once per JVM). */
  public static void open(Configuration conf) throws IOException {
    synchronized (LOCK) {
      if (out != null) {
        return;
      }
      File dir = new File(conf.get(DIR_KEY, DEFAULT_DIR));
      if (!dir.isDirectory() && !dir.mkdirs() && !dir.isDirectory()) {
        throw new IOException("Cannot create the attested audit folder " + dir
            + " (setting " + DIR_KEY + "); no log, no wrapper");
      }
      if (!dir.canWrite()) {
        throw new IOException("The attested audit folder " + dir
            + " is not writable; no log, no wrapper");
      }
      try {
        host = InetAddress.getLocalHost().getHostName();
      } catch (Exception e) {
        host = "unknown";
      }
      pid = ProcessHandle.current().pid();
      file = new File(dir,
          host + "-" + pid + "-" + System.currentTimeMillis() + ".tsv");
      out = new BufferedWriter(new OutputStreamWriter(
          new FileOutputStream(file, true), StandardCharsets.UTF_8));
    }
  }

  /** Appends one line and flushes it. Throws if the log is not open. */
  public static void log(String op, Path p1, Path p2, String extra)
      throws IOException {
    synchronized (LOCK) {
      if (out == null) {
        throw new IOException("The attested audit log is not open");
      }
      out.write(System.currentTimeMillis() + "\t" + host + "\t" + pid + "\t"
          + op + "\t" + text(p1) + "\t" + text(p2) + "\t" + clean(extra)
          + "\n");
      out.flush();
    }
  }

  /** The log file of this JVM, or null if none is open. */
  public static File currentFile() {
    synchronized (LOCK) {
      return file;
    }
  }

  private static String text(Path p) {
    return p == null ? "" : clean(p.toUri().getPath());
  }

  private static String clean(String s) {
    return s == null ? "" : s.replace('\t', ' ').replace('\n', ' ')
        .replace('\r', ' ');
  }
}
