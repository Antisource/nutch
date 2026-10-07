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

import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;

/**
 * Streaming Merkle root of a byte stream, with the tree of RFC 6962 (Certificate
 * Transparency): the stream is cut into chunks of a fixed size, a leaf is
 * SHA-256(0x00 || chunk), an inner node is SHA-256(0x01 || left || right), and a
 * tree of n leaves splits at the largest power of two below n. The empty stream
 * has the hash of the empty string.
 *
 * <p>The hasher keeps only O(log n) hashes: equal-sized subtrees are merged as
 * soon as they exist, and the remaining ones are folded from the right at the
 * end, which gives the same root as the recursive definition.</p>
 */
public final class MerkleHasher {

  private final long chunkSize;
  private final MessageDigest leaf = sha256();
  private final MessageDigest node = sha256();
  private final ArrayList<byte[]> hashes = new ArrayList<>();
  private final ArrayList<Long> sizes = new ArrayList<>();
  private long inChunk;
  private long total;
  private long chunks;
  private byte[] root;

  public MerkleHasher(long chunkSize) {
    if (chunkSize < 1) {
      throw new IllegalArgumentException("chunk size must be at least 1");
    }
    this.chunkSize = chunkSize;
  }

  public void update(byte[] b, int off, int len) {
    if (root != null) {
      throw new IllegalStateException("already finished");
    }
    while (len > 0) {
      if (inChunk == 0) {
        leaf.update((byte) 0x00);
      }
      int n = (int) Math.min(len, chunkSize - inChunk);
      leaf.update(b, off, n);
      inChunk += n;
      off += n;
      len -= n;
      total += n;
      if (inChunk == chunkSize) {
        endChunk();
      }
    }
  }

  public void update(int b) {
    update(new byte[] { (byte) b }, 0, 1);
  }

  private void endChunk() {
    push(leaf.digest(), 1);
    inChunk = 0;
    chunks++;
  }

  private void push(byte[] hash, long size) {
    hashes.add(hash);
    sizes.add(size);
    while (sizes.size() >= 2
        && sizes.get(sizes.size() - 1).longValue() == sizes.get(sizes.size() - 2).longValue()) {
      byte[] right = hashes.remove(hashes.size() - 1);
      long rs = sizes.remove(sizes.size() - 1);
      byte[] left = hashes.remove(hashes.size() - 1);
      sizes.remove(sizes.size() - 1);
      hashes.add(parent(left, right));
      sizes.add(rs * 2);
    }
  }

  private byte[] parent(byte[] left, byte[] right) {
    node.update((byte) 0x01);
    node.update(left);
    node.update(right);
    return node.digest();
  }

  /** Finishes the stream and returns the root; later calls return the same root. */
  public byte[] finish() {
    if (root != null) {
      return root;
    }
    if (inChunk > 0) {
      endChunk();
    }
    if (hashes.isEmpty()) {
      root = sha256().digest();
    } else {
      byte[] r = hashes.get(hashes.size() - 1);
      for (int i = hashes.size() - 2; i >= 0; i--) {
        r = parent(hashes.get(i), r);
      }
      root = r;
    }
    return root;
  }

  public long length() {
    return total;
  }

  public long chunkCount() {
    return chunks;
  }

  public static String hex(byte[] b) {
    StringBuilder sb = new StringBuilder();
    for (byte x : b) {
      sb.append(String.format("%02x", x));
    }
    return sb.toString();
  }

  private static MessageDigest sha256() {
    try {
      return MessageDigest.getInstance("SHA-256");
    } catch (NoSuchAlgorithmException e) {
      throw new IllegalStateException(e);
    }
  }
}
