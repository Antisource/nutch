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
import java.security.GeneralSecurityException;
import java.security.MessageDigest;
import java.time.Instant;
import java.util.Arrays;
import java.util.Base64;
import java.util.regex.Pattern;

/**
 * A node's statement and the quote that binds it (step 5.2.2), made on the node by node-attest.sh: the statement names the host, the node's WireGuard PUBLIC key, the mesh address that the node
 * asks for, the time and a random nonce; the quote's REPORTDATA is the SHA-512 of the statement bytes (the rule of the signing keys' bundles). The file has three lines: the tag, the statement
 * in base64 and the quote in base64. Parsing is strict: a file or statement that is not exactly of this form is refused.
 */
final class NodeBundle {
  static final String TAG = "ATTESTED-NODE-BUNDLE 1";
  static final String STATEMENT_TAG = "ATTESTED-NODE-STATEMENT 1";
  private static final Pattern HOST = Pattern.compile("[A-Za-z0-9._-]{1,63}");
  private static final Pattern KEY = Pattern.compile("[A-Za-z0-9+/]{43}=");
  private static final Pattern IP = Pattern.compile("(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])(\\.(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])){3}");
  private static final Pattern TIME = Pattern.compile("[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z");
  private static final Pattern NONCE = Pattern.compile("[0-9a-f]{32}");
  private static final String[] FIELDS = {"host", "mesh-public", "mesh-ip", "created", "nonce"};

  final byte[] statement;
  final byte[] quote;
  final String host;
  final String meshPublic;
  final String meshIp;
  final Instant created;
  final String nonce;

  private NodeBundle(byte[] statement, byte[] quote, String host, String meshPublic, String meshIp, Instant created, String nonce) {
    this.statement = statement;
    this.quote = quote;
    this.host = host;
    this.meshPublic = meshPublic;
    this.meshIp = meshIp;
    this.created = created;
    this.nonce = nonce;
  }

  static NodeBundle decode(byte[] file) throws IOException {
    String[] lines = new String(file, StandardCharsets.UTF_8).split("\n", -1);
    int n = lines.length;
    if (n > 0 && lines[n - 1].isEmpty()) {
      n--;
    }
    if (n != 3 || !TAG.equals(lines[0]) || !lines[1].startsWith("statement=") || !lines[2].startsWith("quote=")) {
      throw new IOException("not a node bundle: it must have exactly the lines '" + TAG + "', 'statement=...' and 'quote=...'");
    }
    byte[] statement;
    byte[] quote;
    try {
      statement = Base64.getDecoder().decode(lines[1].substring("statement=".length()));
      quote = Base64.getDecoder().decode(lines[2].substring("quote=".length()));
    } catch (IllegalArgumentException e) {
      throw new IOException("the statement or the quote of the node bundle is not valid base64");
    }
    String[] st = new String(statement, StandardCharsets.UTF_8).split("\n", -1);
    int m = st.length;
    if (m > 0 && st[m - 1].isEmpty()) {
      m--;
    }
    if (m != 1 + FIELDS.length || !STATEMENT_TAG.equals(st[0])) {
      throw new IOException("the node statement must be '" + STATEMENT_TAG + "' and exactly the lines " + Arrays.toString(FIELDS) + " in this order");
    }
    String[] v = new String[FIELDS.length];
    for (int i = 0; i < FIELDS.length; i++) {
      String prefix = FIELDS[i] + "=";
      if (!st[i + 1].startsWith(prefix)) {
        throw new IOException("the node statement must have the line '" + prefix + "...' at position " + (i + 1) + " (fields, in this order: " + Arrays.toString(FIELDS) + ")");
      }
      v[i] = st[i + 1].substring(prefix.length());
    }
    need(HOST, v[0], "host");
    need(KEY, v[1], "mesh-public");
    need(IP, v[2], "mesh-ip");
    need(TIME, v[3], "created");
    need(NONCE, v[4], "nonce");
    if (Base64.getDecoder().decode(v[1]).length != 32) {
      throw new IOException("mesh-public is not a 32-byte WireGuard key");
    }
    return new NodeBundle(statement, quote, v[0], v[1], v[2], Instant.parse(v[3]), v[4]);
  }

  private static void need(Pattern p, String value, String name) throws IOException {
    if (!p.matcher(value).matches()) {
      throw new IOException("the node statement's " + name + " is not in the required form: " + (value.length() > 60 ? value.substring(0, 60) + "..." : value));
    }
  }

  /** The quote's REPORTDATA (64 bytes at offset 568) must be the SHA-512 of the statement. */
  void checkBinding() throws IOException {
    if (quote.length < 632) {
      throw new IOException("the quote is too short to carry a REPORTDATA (" + quote.length + " bytes)");
    }
    byte[] digest;
    try {
      digest = MessageDigest.getInstance("SHA-512").digest(statement);
    } catch (GeneralSecurityException e) {
      throw new IOException("no SHA-512: " + e);
    }
    if (!MessageDigest.isEqual(Arrays.copyOfRange(quote, 568, 632), digest)) {
      throw new IOException("the quote's REPORTDATA is not the SHA-512 of the statement: the quote does not belong to this statement");
    }
  }
}
