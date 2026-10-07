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
import java.io.OutputStream;

import org.apache.hadoop.fs.FSDataOutputStream;
import org.apache.hadoop.fs.StreamCapabilities;
import org.apache.hadoop.fs.Syncable;

/**
 * Passes every byte to the real output stream and to a {@link MerkleHasher}; when
 * the stream has been closed successfully it writes one record
 * ({@link AttestedRecords}). Flush and sync requests are forwarded, so the
 * stream behaves as before for its caller.
 */
final class HashingOutputStream extends OutputStream
    implements Syncable, StreamCapabilities {

  private final FSDataOutputStream inner;
  private final MerkleHasher hasher;
  private final String path;
  private final String job;
  private final String attempt;
  private final long chunkSize;
  private final SidecarSink sink;
  private boolean closed;

  /** Receives the finished record of a file so that it can be stored next to the file. */
  interface SidecarSink {
    void write(String path, long length, long chunkSize, byte[] root,
        java.util.List<byte[]> leaves) throws IOException;
  }

  HashingOutputStream(FSDataOutputStream inner, String path, long chunkSize,
      String job, String attempt, SidecarSink sink) {
    this.inner = inner;
    this.path = path;
    this.chunkSize = chunkSize;
    this.job = job;
    this.attempt = attempt;
    this.sink = sink;
    this.hasher = new MerkleHasher(chunkSize, sink != null);
  }

  @Override
  public void write(int b) throws IOException {
    inner.write(b);
    hasher.update(b);
  }

  @Override
  public void write(byte[] b, int off, int len) throws IOException {
    inner.write(b, off, len);
    hasher.update(b, off, len);
  }

  @Override
  public void flush() throws IOException {
    inner.flush();
  }

  /** Older name of hflush (no longer part of Syncable in recent Hadoop versions). */
  public void sync() throws IOException {
    inner.hflush();
  }

  @Override
  public void hflush() throws IOException {
    inner.hflush();
  }

  @Override
  public void hsync() throws IOException {
    inner.hsync();
  }

  @Override
  public boolean hasCapability(String capability) {
    return inner.hasCapability(capability);
  }

  @Override
  public void close() throws IOException {
    if (closed) {
      return;
    }
    closed = true;
    inner.close();
    byte[] root = hasher.finish();
    AttestedRecords.log(job, attempt, path, hasher.length(), chunkSize,
        hasher.chunkCount(), MerkleHasher.hex(root), "closed");
    if (sink != null) {
      sink.write(path, hasher.length(), chunkSize, root, hasher.leaves());
    }
  }
}
