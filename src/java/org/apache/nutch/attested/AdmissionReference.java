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
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.GeneralSecurityException;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.regex.Pattern;

/**
 * The reference measurements that an attested machine must have (step 5.2.1): a plain text file that anybody can read and edit. One line per allowed
 * value: REGISTER VALUE [HOST], where REGISTER is MRTD or RTMR0 to RTMR3, VALUE is the 96 hex digits of the register, and HOST (optional, default *) is the
 * host name that the key's statement must carry. Lines that start with # and empty lines are ignored. Several lines for one register mean "any of these".
 * To allow a new value, add a line; to forbid one, delete its line. The file may be pinned by its SHA-256 in the settings.
 */
final class AdmissionReference {
  private static final Pattern HEX96 = Pattern.compile("[0-9a-fA-F]{96}");
  private static final Pattern HOST = Pattern.compile("[A-Za-z0-9._-]{1,63}|\\*");

  private final Map<String, List<String[]>> entries = new HashMap<>();
  final String sha256;
  final int lines;

  private AdmissionReference(String sha256, int lines) {
    this.sha256 = sha256;
    this.lines = lines;
  }

  /** pin: the expected SHA-256 of the file (lower-case hex), or empty for no pin. */
  static AdmissionReference load(Path file, String pin) throws IOException {
    byte[] raw;
    try {
      raw = Files.readAllBytes(file);
    } catch (IOException e) {
      throw new IOException("the reference measurements file cannot be read: " + file + " (" + e.getMessage() + ")");
    }
    String sha;
    try {
      sha = MerkleHasher.hex(MessageDigest.getInstance("SHA-256").digest(raw));
    } catch (GeneralSecurityException e) {
      throw new IOException("no SHA-256: " + e);
    }
    if (pin != null && !pin.isEmpty() && !pin.equalsIgnoreCase(sha)) {
      throw new IOException("the reference measurements file " + file + " has SHA-256 " + sha.substring(0, 16) + "... but the settings pin " + pin.substring(0, Math.min(16, pin.length())) + "...");
    }
    String[] all = new String(raw, StandardCharsets.UTF_8).split("\\r?\\n", -1);
    AdmissionReference r = new AdmissionReference(sha, all.length);
    int n = 0;
    for (String line : all) {
      n++;
      String t = line.trim();
      if (t.isEmpty() || t.startsWith("#")) {
        continue;
      }
      String[] p = t.split("\\s+");
      if (p.length < 2 || p.length > 3) {
        throw new IOException("reference line " + n + ": expected REGISTER VALUE [HOST], got " + p.length + " field(s)");
      }
      String reg = p[0].toLowerCase(Locale.ROOT);
      boolean known = false;
      for (String k : QuoteVerifier.REGISTERS) {
        known |= k.equals(reg);
      }
      if (!known) {
        throw new IOException("reference line " + n + ": unknown register " + p[0] + " (use MRTD, RTMR0, RTMR1, RTMR2 or RTMR3)");
      }
      if (!HEX96.matcher(p[1]).matches()) {
        throw new IOException("reference line " + n + ": the value of " + p[0] + " must be 96 hex digits");
      }
      String host = p.length == 3 ? p[2] : "*";
      if (!HOST.matcher(host).matches()) {
        throw new IOException("reference line " + n + ": bad host " + host);
      }
      r.entries.computeIfAbsent(reg, k -> new ArrayList<>()).add(new String[] {p[1].toLowerCase(Locale.ROOT), host});
    }
    return r;
  }

  boolean hasRegister(String reg) {
    return entries.containsKey(reg);
  }

  boolean allows(String reg, String value, String host) {
    for (String[] e : entries.getOrDefault(reg, new ArrayList<>())) {
      if (e[0].equals(value) && (e[1].equals("*") || e[1].equals(host))) {
        return true;
      }
    }
    return false;
  }

  /** The first 12 digits of each value that is allowed for this host, for messages. */
  String allowedFor(String reg, String host) {
    StringBuilder sb = new StringBuilder();
    for (String[] e : entries.getOrDefault(reg, new ArrayList<>())) {
      if (e[1].equals("*") || e[1].equals(host)) {
        sb.append(sb.length() == 0 ? "" : ", ").append(e[0], 0, 12).append("...");
      }
    }
    return sb.length() == 0 ? "none for this host" : sb.toString();
  }
}
