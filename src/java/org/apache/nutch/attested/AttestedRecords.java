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

/**
 * One line per file the wrapper has hashed, written to local disk by every JVM
 * that uses the wrapper (stage B1: records are only observed, nothing is enforced).
 *
 * <p>Line format: epoch-millis, host, pid, job id, task attempt id, path,
 * length, chunk size, number of chunks, Merkle root (hex), flag. The flag is
 * <code>closed</code> for a complete record and <code>append-unhashed</code>
 * for a file that was opened for append (its content is not covered). Each
 * JVM writes its own file <code>host-pid-start.tsv</code> in
 * <code>attested.records.dir</code> (default <code>/tmp/attested-records</code>);
 * the wrapper refuses to start if the folder cannot be written.</p>
 */
public final class AttestedRecords {

  public static final String DIR_KEY = "attested.records.dir";
  public static final String DEFAULT_DIR = "/tmp/attested-records";

  private static final Object LOCK = new Object();
  private static BufferedWriter out;
  private static File file;
  private static String host = "unknown";
  private static long pid;

  private AttestedRecords() {
  }

  public static void open(Configuration conf) throws IOException {
    synchronized (LOCK) {
      if (out != null) {
        return;
      }
      File dir = new File(conf.get(DIR_KEY, DEFAULT_DIR));
      if (!dir.isDirectory() && !dir.mkdirs() && !dir.isDirectory()) {
        throw new IOException("Cannot create the attested records folder " + dir
            + " (setting " + DIR_KEY + "); no records, no wrapper");
      }
      if (!dir.canWrite()) {
        throw new IOException("The attested records folder " + dir
            + " is not writable; no records, no wrapper");
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

  public static void log(String job, String attempt, String path, long length,
      long chunkSize, long chunks, String rootHex, String flag)
      throws IOException {
    synchronized (LOCK) {
      if (out == null) {
        throw new IOException("The attested records log is not open");
      }
      out.write(System.currentTimeMillis() + "\t" + host + "\t" + pid + "\t"
          + clean(job) + "\t" + clean(attempt) + "\t" + clean(path) + "\t"
          + length + "\t" + chunkSize + "\t" + chunks + "\t" + rootHex + "\t"
          + flag + "\n");
      out.flush();
    }
  }

  public static File currentFile() {
    synchronized (LOCK) {
      return file;
    }
  }

  private static String clean(String s) {
    return s == null ? "" : s.replace('\t', ' ').replace('\n', ' ')
        .replace('\r', ' ');
  }
}
