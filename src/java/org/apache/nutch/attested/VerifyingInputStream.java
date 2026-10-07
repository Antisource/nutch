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

import java.io.EOFException;
import java.io.IOException;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.Arrays;

import org.apache.hadoop.fs.CanUnbuffer;
import org.apache.hadoop.fs.ChecksumException;
import org.apache.hadoop.fs.FSDataInputStream;
import org.apache.hadoop.fs.FSInputStream;
import org.apache.hadoop.fs.Path;
import org.apache.hadoop.fs.StreamCapabilities;
import org.apache.hadoop.fs.statistics.IOStatistics;
import org.apache.hadoop.fs.statistics.IOStatisticsSource;

/**
 * Reads a file through its record: every chunk is hashed as it is read from storage
 * and compared with the hash in the record before a single byte of it is handed on.
 * A chunk that does not match makes the read fail with a {@link ChecksumException}
 * (and a VERIFY-FAIL line in the audit log), so a task that reads a changed file
 * fails instead of using it.
 *
 * <p>Reads, seeks and positioned reads all work; internally the stream works in whole
 * chunks and keeps the last verified chunk. The length comes from the record.</p>
 */
final class VerifyingInputStream extends FSInputStream
    implements StreamCapabilities, CanUnbuffer, IOStatisticsSource {

  private final FSDataInputStream in;
  private final AttestedSidecar rec;
  private final Path path;
  private final MessageDigest md;
  private long pos;
  private long innerPos;
  private long curIdx = -1;
  private byte[] cur;
  private boolean closed;

  VerifyingInputStream(FSDataInputStream in, AttestedSidecar rec, Path path) {
    this.in = in;
    this.rec = rec;
    this.path = path;
    try {
      this.md = MessageDigest.getInstance("SHA-256");
    } catch (NoSuchAlgorithmException e) {
      throw new IllegalStateException(e);
    }
  }

  private void checkOpen() throws IOException {
    if (closed) {
      throw new IOException("Stream is closed: " + path);
    }
  }

  private void fail(long idx, String why) throws IOException {
    AttestedAudit.log("VERIFY-FAIL", path, null, "chunk=" + idx + " " + why);
    throw new ChecksumException("Attested verification failed for " + path
        + ": chunk " + idx + " (" + why + ")", idx * (long) rec.chunkSize);
  }

  /** Reads and verifies one whole chunk; afterwards it is the current chunk. */
  private void load(long idx) throws IOException {
    long start = idx * rec.chunkSize;
    int n = (int) Math.min((long) rec.chunkSize, rec.length - start);
    byte[] buf = new byte[n];
    try {
      if (innerPos != start) {
        in.seek(start);
      }
      in.readFully(buf, 0, n);
    } catch (EOFException e) {
      curIdx = -1;
      innerPos = -1;
      fail(idx, "the file ends before the length in its record");
    }
    innerPos = start + n;
    md.reset();
    md.update((byte) 0x00);
    md.update(buf);
    if (!Arrays.equals(md.digest(), rec.leaves[(int) idx])) {
      curIdx = -1;
      fail(idx, "hash does not match the record");
    }
    cur = buf;
    curIdx = idx;
  }

  @Override
  public synchronized int read() throws IOException {
    checkOpen();
    if (pos >= rec.length) {
      return -1;
    }
    long idx = pos / rec.chunkSize;
    if (idx != curIdx) {
      load(idx);
    }
    int b = cur[(int) (pos - idx * rec.chunkSize)] & 0xff;
    pos++;
    return b;
  }

  @Override
  public synchronized int read(byte[] b, int off, int len) throws IOException {
    checkOpen();
    if (off < 0 || len < 0 || len > b.length - off) {
      throw new IndexOutOfBoundsException();
    }
    if (len == 0) {
      return 0;
    }
    if (pos >= rec.length) {
      return -1;
    }
    int total = 0;
    while (len > 0 && pos < rec.length) {
      long idx = pos / rec.chunkSize;
      if (idx != curIdx) {
        load(idx);
      }
      int inChunk = (int) (pos - idx * rec.chunkSize);
      int n = Math.min(len, cur.length - inChunk);
      System.arraycopy(cur, inChunk, b, off, n);
      pos += n;
      off += n;
      len -= n;
      total += n;
    }
    return total;
  }

  @Override
  public synchronized long skip(long n) throws IOException {
    checkOpen();
    if (n <= 0) {
      return 0;
    }
    long k = Math.min(n, rec.length - pos);
    pos += k;
    return k;
  }

  @Override
  public synchronized void seek(long target) throws IOException {
    checkOpen();
    if (target < 0) {
      throw new EOFException("Cannot seek to a negative offset");
    }
    if (target > rec.length) {
      throw new EOFException("Cannot seek after EOF");
    }
    pos = target;
  }

  @Override
  public synchronized long getPos() throws IOException {
    return pos;
  }

  @Override
  public boolean seekToNewSource(long targetPos) throws IOException {
    return false;
  }

  @Override
  public synchronized int available() throws IOException {
    checkOpen();
    return (int) Math.min((long) Integer.MAX_VALUE, rec.length - pos);
  }

  @Override
  public boolean markSupported() {
    return false;
  }

  /** Only the capability of releasing buffers is passed on; everything else is not offered. */
  @Override
  public boolean hasCapability(String capability) {
    return StreamCapabilities.UNBUFFER.equals(capability) && in.hasCapability(capability);
  }

  /** Releases the real stream's buffers and forgets the cached chunk (it is read and checked again when needed). */
  @Override
  public synchronized void unbuffer() {
    in.unbuffer();
    cur = null;
    curIdx = -1;
    innerPos = -1;
  }

  @Override
  public IOStatistics getIOStatistics() {
    return in.getIOStatistics();
  }

  @Override
  public synchronized void close() throws IOException {
    if (!closed) {
      closed = true;
      in.close();
    }
  }
}
