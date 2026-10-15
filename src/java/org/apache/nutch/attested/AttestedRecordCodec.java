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

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.EOFException;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/**
 * The bytes of a record, with no Hadoop in it (so that it can be tested alone).
 *
 * <p>Format ATTEST01 (the original, unsigned): 8 bytes "ATTEST01", int chunk size, long
 * length, 32 bytes root, int number of chunks, then 32 bytes per chunk.</p>
 *
 * <p>Format ATTEST02 (step 5.1.1) is the same, followed by the signature block: one byte
 * for the length of the key id (1 to 64), the key id (letters, digits, dot, dash,
 * underscore), an unsigned short for the length of the signature (1 to 200) and the
 * signature (ECDSA with P-256 and SHA-256, DER). The signature covers
 * {@link #statement}: a fixed tag, the key id, the chunk size, the length and the root.
 * The root commits to every chunk hash, so the chunk hashes need no second signature.</p>
 */
final class AttestedRecordCodec {

  static final byte[] MAGIC1 = "ATTEST01".getBytes(StandardCharsets.US_ASCII);
  static final byte[] MAGIC2 = "ATTEST02".getBytes(StandardCharsets.US_ASCII);
  static final int HASH = 32;
  static final int MAX_KEY_ID = 64;
  static final int MAX_SIGNATURE = 200;
  private static final byte[] STATEMENT_TAG =
      "ATTEST02-SIGNED\n".getBytes(StandardCharsets.US_ASCII);

  private AttestedRecordCodec() {
  }

  /** A decoded record. */
  static final class Decoded {
    final int version;
    final int chunkSize;
    final long length;
    final byte[] root;
    final byte[][] leaves;
    /** Null for an unsigned (version 1) record. */
    final String keyId;
    final byte[] signature;

    Decoded(int version, int chunkSize, long length, byte[] root, byte[][] leaves,
        String keyId, byte[] signature) {
      this.version = version;
      this.chunkSize = chunkSize;
      this.length = length;
      this.root = root;
      this.leaves = leaves;
      this.keyId = keyId;
      this.signature = signature;
    }

    boolean signed() {
      return version == 2;
    }
  }

  static long chunksFor(long length, long chunkSize) {
    return length == 0 ? 0 : (length - 1) / chunkSize + 1;
  }

  static boolean validKeyId(String id) {
    if (id == null || id.isEmpty() || id.length() > MAX_KEY_ID) {
      return false;
    }
    for (int i = 0; i < id.length(); i++) {
      char c = id.charAt(i);
      boolean ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
          || (c >= '0' && c <= '9') || c == '.' || c == '-' || c == '_';
      if (!ok) {
        return false;
      }
    }
    return true;
  }

  /** The bytes that are signed. Every field has a fixed length or a length in front of it. */
  static byte[] statement(String keyId, int chunkSize, long length, byte[] root)
      throws IOException {
    if (!validKeyId(keyId) || root == null || root.length != HASH) {
      throw new IOException("cannot build the statement to sign (bad key id or root)");
    }
    byte[] id = keyId.getBytes(StandardCharsets.US_ASCII);
    ByteArrayOutputStream bytes = new ByteArrayOutputStream();
    DataOutputStream out = new DataOutputStream(bytes);
    out.write(STATEMENT_TAG);
    out.writeByte(id.length);
    out.write(id);
    out.writeInt(chunkSize);
    out.writeLong(length);
    out.write(root);
    out.flush();
    return bytes.toByteArray();
  }

  private static void body(DataOutputStream out, byte[] magic, int chunkSize, long length,
      byte[] root, List<byte[]> leaves) throws IOException {
    out.write(magic);
    out.writeInt(chunkSize);
    out.writeLong(length);
    out.write(root);
    out.writeInt(leaves.size());
    for (byte[] leaf : leaves) {
      out.write(leaf);
    }
  }

  /** An unsigned record (ATTEST01), byte for byte what the wrapper has always written. */
  static byte[] encode(int chunkSize, long length, byte[] root, List<byte[]> leaves)
      throws IOException {
    ByteArrayOutputStream bytes = new ByteArrayOutputStream(
        8 + 4 + 8 + HASH + 4 + HASH * leaves.size());
    DataOutputStream out = new DataOutputStream(bytes);
    body(out, MAGIC1, chunkSize, length, root, leaves);
    out.flush();
    return bytes.toByteArray();
  }

  /** A signed record (ATTEST02). */
  static byte[] encodeSigned(int chunkSize, long length, byte[] root, List<byte[]> leaves,
      String keyId, byte[] signature) throws IOException {
    if (!validKeyId(keyId) || signature == null || signature.length < 1
        || signature.length > MAX_SIGNATURE) {
      throw new IOException("cannot write a signed record (bad key id or signature)");
    }
    byte[] id = keyId.getBytes(StandardCharsets.US_ASCII);
    ByteArrayOutputStream bytes = new ByteArrayOutputStream(
        8 + 4 + 8 + HASH + 4 + HASH * leaves.size() + 1 + id.length + 2 + signature.length);
    DataOutputStream out = new DataOutputStream(bytes);
    body(out, MAGIC2, chunkSize, length, root, leaves);
    out.writeByte(id.length);
    out.write(id);
    out.writeShort(signature.length);
    out.write(signature);
    out.flush();
    return bytes.toByteArray();
  }

  /**
   * Decodes a whole record. Accepts both versions. Throws an IOException saying why when the
   * record is damaged or does not agree with itself.
   */
  static Decoded decode(byte[] all) throws IOException {
    DataInputStream in = new DataInputStream(new ByteArrayInputStream(all));
    try {
      byte[] magic = new byte[MAGIC1.length];
      in.readFully(magic);
      int version;
      if (Arrays.equals(magic, MAGIC1)) {
        version = 1;
      } else if (Arrays.equals(magic, MAGIC2)) {
        version = 2;
      } else {
        throw new IOException("record is damaged (wrong header)");
      }
      int chunk = in.readInt();
      long length = in.readLong();
      byte[] root = new byte[HASH];
      in.readFully(root);
      int n = in.readInt();
      if (chunk < 1 || length < 0 || n < 0
          || n != chunksFor(length, chunk) || (long) n * HASH > (1L << 30)) {
        throw new IOException("record is damaged (impossible sizes)");
      }
      byte[][] leaves = new byte[n][HASH];
      for (int i = 0; i < n; i++) {
        in.readFully(leaves[i]);
      }
      String keyId = null;
      byte[] signature = null;
      if (version == 2) {
        int idLen = in.readUnsignedByte();
        if (idLen < 1 || idLen > MAX_KEY_ID) {
          throw new IOException("record is damaged (impossible key id length)");
        }
        byte[] id = new byte[idLen];
        in.readFully(id);
        keyId = new String(id, StandardCharsets.US_ASCII);
        if (!validKeyId(keyId)) {
          throw new IOException("record is damaged (impossible key id)");
        }
        int sigLen = in.readUnsignedShort();
        if (sigLen < 1 || sigLen > MAX_SIGNATURE) {
          throw new IOException("record is damaged (impossible signature length)");
        }
        signature = new byte[sigLen];
        in.readFully(signature);
      }
      if (in.read() != -1) {
        throw new IOException("record is damaged (extra bytes at the end)");
      }
      List<byte[]> asList = new ArrayList<>(n);
      for (byte[] l : leaves) {
        asList.add(l);
      }
      if (!Arrays.equals(MerkleHasher.rootOfLeaves(asList), root)) {
        throw new IOException(
            "record is damaged (its root does not match its own chunk hashes)");
      }
      return new Decoded(version, chunk, length, root, leaves, keyId, signature);
    } catch (EOFException e) {
      throw new IOException("record is damaged (too short)");
    }
  }
}
