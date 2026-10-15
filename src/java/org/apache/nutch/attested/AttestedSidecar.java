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
import java.io.EOFException;
import java.io.IOException;
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
 * <p>Format ATTEST01: 8 bytes "ATTEST01", int chunk size, long length, 32 bytes root,
 * int number of chunks, then 32 bytes per chunk. In this format a record protects
 * against a change of the file alone, not against someone who rewrites file and record
 * together. Format ATTEST02 (step 5.1.1) adds a signature after the chunk hashes; the bytes
 * of both formats, and how they are read, are in {@link AttestedRecordCodec}.</p>
 */
final class AttestedSidecar {

  static final byte[] MAGIC = AttestedRecordCodec.MAGIC1;
  /** The longest record that is read (the old rule: at most 2^30 bytes of chunk hashes, plus the header and the signature). */
  private static final long MAX_RECORD = (1L << 30) + 1024;

  final int chunkSize;
  final long length;
  final byte[] root;
  final byte[][] leaves;
  /** The record as decoded, with its version and signature (step 5.1.1). */
  final AttestedRecordCodec.Decoded decoded;

  private AttestedSidecar(AttestedRecordCodec.Decoded d) {
    this.chunkSize = d.chunkSize;
    this.length = d.length;
    this.root = d.root;
    this.leaves = d.leaves;
    this.decoded = d;
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
    return AttestedRecordCodec.chunksFor(length, chunkSize);
  }

  /** An unsigned record (ATTEST01), byte for byte what the wrapper has always written. */
  static byte[] encode(int chunkSize, long length, byte[] root, List<byte[]> leaves)
      throws IOException {
    return AttestedRecordCodec.encode(chunkSize, length, root, leaves);
  }

  /**
   * Reads only the first 20 bytes of a record (the header) and returns the length
   * of the file it describes. Used by the metadata checks, which need no chunk
   * hashes; a read that verifies a file reads and checks the whole record. Throws
   * FileNotFoundException when there is no record, and an IOException saying why
   * when the header is damaged.
   */
  static long readLength(FileSystem fs, Path sidecar) throws IOException {
    try (FSDataInputStream raw = fs.open(sidecar);
        DataInputStream in = new DataInputStream(raw)) {
      byte[] magic = new byte[MAGIC.length];
      in.readFully(magic);
      if (!Arrays.equals(magic, AttestedRecordCodec.MAGIC1)
          && !Arrays.equals(magic, AttestedRecordCodec.MAGIC2)) {
        throw new IOException("record is damaged (wrong header)");
      }
      int chunk = in.readInt();
      long length = in.readLong();
      if (chunk < 1 || length < 0) {
        throw new IOException("record is damaged (impossible sizes)");
      }
      return length;
    } catch (EOFException e) {
      throw new IOException("record is damaged (too short)");
    }
  }

  /**
   * Reads a record with the given (real, not wrapped) file system. Throws
   * FileNotFoundException when there is none, and an IOException saying why when
   * the record is damaged or does not agree with itself. Both formats are read; the
   * signature (if any) is checked by the caller, see {@link AttestedSignatures}.
   */
  static AttestedSidecar read(FileSystem fs, Path sidecar) throws IOException {
    long size = fs.getFileStatus(sidecar).getLen();
    if (size > MAX_RECORD) {
      throw new IOException("record is damaged (impossible sizes)");
    }
    byte[] all = new byte[(int) size];
    try (FSDataInputStream raw = fs.open(sidecar)) {
      raw.readFully(0, all);
    } catch (EOFException e) {
      throw new IOException("record is damaged (too short)");
    }
    return new AttestedSidecar(AttestedRecordCodec.decode(all));
  }
}
