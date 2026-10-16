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
import java.security.KeyFactory;
import java.security.MessageDigest;
import java.security.PublicKey;
import java.security.interfaces.ECPublicKey;
import java.security.spec.X509EncodedKeySpec;
import java.util.Arrays;
import java.util.Base64;
import java.util.regex.Pattern;

/**
 * A machine's public signing key together with the statement that names it and, on a TDX machine, the quote that
 * vouches for it (step 5.1.3). The quote's REPORTDATA field holds the SHA-512 of the statement, exactly as
 * attest/quote.sh writes it and attest/verify-binding.sh checks it, so the statement (the key id, the public key,
 * the host, the time and a random nonce) is what the hardware vouched for.
 *
 * <p>File format (text): ATTESTED-KEY-BUNDLE 1, then statement=BASE64 and quote=BASE64 (or none).
 * Key ids: TDX- plus 16 hex digits of the SHA-256 of the public key, for a key that has a quote; SVC- plus the same,
 * for a service key without a quote (tests, never accepted unless the key list allows unquoted keys).</p>
 */
final class KeyBundle {
  static final String FILE_SUFFIX = ".attestkey";
  static final String TDX = "TDX-";
  static final String SVC = "SVC-";
  /** Where REPORTDATA starts in a TDX quote: the 48-byte header and 520 bytes into the TD report body. */
  static final int REPORTDATA_OFFSET = 568;
  static final int REPORTDATA_LENGTH = 64;
  private static final String STATEMENT_HEAD = "ATTESTED-KEY-STATEMENT 1";
  private static final String BUNDLE_HEAD = "ATTESTED-KEY-BUNDLE 1";
  private static final Pattern HOST = Pattern.compile("[A-Za-z0-9._-]{1,63}");
  private static final Pattern TIME = Pattern.compile("\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}Z");
  private static final Pattern NONCE = Pattern.compile("[0-9a-f]{32}");

  final String keyId;
  final String host;
  final String created;
  final String nonce;
  final byte[] publicEncoded;
  final PublicKey publicKey;
  final byte[] statement;
  /** The quote, or null for a key without one. */
  final byte[] quote;

  private KeyBundle(String keyId, String host, String created, String nonce, byte[] publicEncoded,
      PublicKey publicKey, byte[] statement, byte[] quote) {
    this.keyId = keyId;
    this.host = host;
    this.created = created;
    this.nonce = nonce;
    this.publicEncoded = publicEncoded;
    this.publicKey = publicKey;
    this.statement = statement;
    this.quote = quote;
  }

  static String idOf(String prefix, byte[] publicEncoded) throws IOException {
    try {
      byte[] h = MessageDigest.getInstance("SHA-256").digest(publicEncoded);
      return prefix + MerkleHasher.hex(h).substring(0, 16);
    } catch (GeneralSecurityException e) {
      throw new IOException("no SHA-256: " + e);
    }
  }

  static byte[] sha512(byte[] data) throws IOException {
    try {
      return MessageDigest.getInstance("SHA-512").digest(data);
    } catch (GeneralSecurityException e) {
      throw new IOException("no SHA-512: " + e);
    }
  }

  /** The statement text that the quote vouches for. */
  static byte[] statementBytes(String keyId, byte[] publicEncoded, String host, String created, String nonce)
      throws IOException {
    if (!HOST.matcher(host).matches() || !TIME.matcher(created).matches() || !NONCE.matcher(nonce).matches()) {
      throw new IOException("bad host, time or nonce in a key statement");
    }
    String text = STATEMENT_HEAD + "\nkey-id=" + keyId + "\npublic=" + Base64.getEncoder().encodeToString(publicEncoded)
        + "\nhost=" + host + "\ncreated=" + created + "\nnonce=" + nonce + "\n";
    return text.getBytes(StandardCharsets.US_ASCII);
  }

  /** Builds a bundle from its parts (the service does this once, at start). */
  static KeyBundle of(String prefix, byte[] publicEncoded, String host, String created, String nonce, byte[] quote)
      throws IOException {
    String id = idOf(prefix, publicEncoded);
    return parse(statementBytes(id, publicEncoded, host, created, nonce), quote);
  }

  byte[] encode() {
    String text = BUNDLE_HEAD + "\nstatement=" + Base64.getEncoder().encodeToString(statement) + "\nquote="
        + (quote == null ? "none" : Base64.getEncoder().encodeToString(quote)) + "\n";
    return text.getBytes(StandardCharsets.US_ASCII);
  }

  /** Reads a bundle file and checks that it is well formed and that the key id is the hash of the public key. */
  static KeyBundle decode(byte[] file) throws IOException {
    String[] lines = new String(file, StandardCharsets.US_ASCII).split("\n", -1);
    if (lines.length != 4 || !lines[3].isEmpty() || !BUNDLE_HEAD.equals(lines[0])
        || !lines[1].startsWith("statement=") || !lines[2].startsWith("quote=")) {
      throw new IOException("not a key bundle (wrong header or lines)");
    }
    try {
      byte[] statement = Base64.getDecoder().decode(lines[1].substring("statement=".length()));
      String q = lines[2].substring("quote=".length());
      byte[] quote = q.equals("none") ? null : Base64.getDecoder().decode(q);
      return parse(statement, quote);
    } catch (IllegalArgumentException e) {
      throw new IOException("the key bundle holds bad base64: " + e.getMessage());
    }
  }

  private static KeyBundle parse(byte[] statement, byte[] quote) throws IOException {
    String[] lines = new String(statement, StandardCharsets.US_ASCII).split("\n", -1);
    if (lines.length != 7 || !lines[6].isEmpty() || !STATEMENT_HEAD.equals(lines[0])) {
      throw new IOException("the key statement is malformed");
    }
    String id = field(lines[1], "key-id=");
    String pub = field(lines[2], "public=");
    String host = field(lines[3], "host=");
    String created = field(lines[4], "created=");
    String nonce = field(lines[5], "nonce=");
    if (!HOST.matcher(host).matches() || !TIME.matcher(created).matches() || !NONCE.matcher(nonce).matches()) {
      throw new IOException("the key statement has a bad host, time or nonce");
    }
    byte[] pubBytes;
    PublicKey key;
    try {
      pubBytes = Base64.getDecoder().decode(pub);
      key = KeyFactory.getInstance("EC").generatePublic(new X509EncodedKeySpec(pubBytes));
      if (!(key instanceof ECPublicKey) || ((ECPublicKey) key).getParams().getOrder().bitLength() != 256) {
        throw new IOException("the public key is not an EC P-256 key");
      }
    } catch (GeneralSecurityException | IllegalArgumentException e) {
      throw new IOException("the public key in the statement cannot be read: " + e.getMessage());
    }
    String prefix = id.startsWith(TDX) ? TDX : id.startsWith(SVC) ? SVC : null;
    if (prefix == null || !id.equals(idOf(prefix, pubBytes))) {
      throw new IOException("the key id " + id + " is not the hash of the public key in the statement");
    }
    return new KeyBundle(id, host, created, nonce, pubBytes, key, statement, quote);
  }

  private static String field(String line, String name) throws IOException {
    if (!line.startsWith(name) || line.length() == name.length()) {
      throw new IOException("the key statement lacks " + name);
    }
    return line.substring(name.length());
  }

  boolean hasQuote() {
    return quote != null;
  }

  /**
   * Checks what can be checked without the quote's signature chain: a TDX- key needs a quote, and the quote's
   * REPORTDATA must be the SHA-512 of the statement (so the hardware vouched for exactly this key).
   */
  void checkBinding() throws IOException {
    if (keyId.startsWith(TDX) && quote == null) {
      throw new IOException("the key " + keyId + " claims a TDX machine but the bundle has no quote");
    }
    if (keyId.startsWith(SVC) && quote != null) {
      throw new IOException("the key " + keyId + " is a service key without a quote, but the bundle carries one");
    }
    if (quote == null) {
      return;
    }
    if (quote.length < REPORTDATA_OFFSET + REPORTDATA_LENGTH) {
      throw new IOException("the quote of " + keyId + " is too short (" + quote.length + " bytes)");
    }
    byte[] embedded = Arrays.copyOfRange(quote, REPORTDATA_OFFSET, REPORTDATA_OFFSET + REPORTDATA_LENGTH);
    if (!MessageDigest.isEqual(embedded, sha512(statement))) {
      throw new IOException("the REPORTDATA of the quote is not the SHA-512 of the key statement of " + keyId
          + ": the hardware did not vouch for this key");
    }
  }
}
