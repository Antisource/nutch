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

import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.ByteArrayOutputStream;
import java.io.EOFException;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

import org.apache.hadoop.fs.FSDataInputStream;
import org.apache.hadoop.fs.FileSystem;
import org.apache.hadoop.fs.Path;

/**
 * The record of one file, stored next to it as a small hidden file named
 * <code>.NAME.attested</code> (the same idea as Hadoop's own <code>.NAME.crc</code>
 * checksum files). It holds the length, the chunk size, the hash of every chunk
 * and the Merkle root of those hashes.
 *
 * <p>Because the record sits in the same folder, it follows the file when the
 * folder is renamed; the wrapper moves it when the file itself is renamed and
 * deletes it when the file is deleted, and hides it from listings.</p>
 *
 * <p>Format: 8 bytes "ATTEST01", int chunk size, long length, 32 bytes root,
 * int number of chunks, then 32 bytes per chunk. Until records are signed
 * (a later stage) a record only protects against a change of the file alone,
 * not against someone who rewrites file and record together.</p>
 */
final class AttestedSidecar {

  static final byte[] MAGIC = "ATTEST01".getBytes(StandardCharsets.US_ASCII);
  private static final int HASH = 32;

  final int chunkSize;
  final long length;
  final byte[] root;
  final byte[][] leaves;

  private AttestedSidecar(int chunkSize, long length, byte[] root, byte[][] leaves) {
    this.chunkSize = chunkSize;
    this.length = length;
    this.root = root;
    this.leaves = leaves;
  }

  static boolean isSidecar(Path p) {
    String n = p.getName();
    return n.length() > ".attested".length() + 1 && n.startsWith(".")
        && n.endsWith(".attested");
  }

  static Path pathFor(Path file) {
    String n = "." + file.getName() + ".attested";
    Path parent = file.getParent();
    return parent == null ? new Path("/" + n) : new Path(parent, n);
  }

  static long chunksFor(long length, long chunkSize) {
    return length == 0 ? 0 : (length - 1) / chunkSize + 1;
  }

  static byte[] encode(int chunkSize, long length, byte[] root, List<byte[]> leaves)
      throws IOException {
    ByteArrayOutputStream bytes = new ByteArrayOutputStream(
        8 + 4 + 8 + HASH + 4 + HASH * leaves.size());
    DataOutputStream out = new DataOutputStream(bytes);
    out.write(MAGIC);
    out.writeInt(chunkSize);
    out.writeLong(length);
    out.write(root);
    out.writeInt(leaves.size());
    for (byte[] leaf : leaves) {
      out.write(leaf);
    }
    out.flush();
    return bytes.toByteArray();
  }

  /**
   * Reads a record with the given (real, not wrapped) file system. Throws
   * FileNotFoundException when there is none, and an IOException saying why when
   * the record is damaged or does not agree with itself.
   */
  static AttestedSidecar read(FileSystem fs, Path sidecar) throws IOException {
    try (FSDataInputStream raw = fs.open(sidecar);
        DataInputStream in = new DataInputStream(raw)) {
      byte[] magic = new byte[MAGIC.length];
      in.readFully(magic);
      if (!Arrays.equals(magic, MAGIC)) {
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
      return new AttestedSidecar(chunk, length, root, leaves);
    } catch (EOFException e) {
      throw new IOException("record is damaged (too short)");
    }
  }
}
