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

import java.io.FileNotFoundException;
import java.io.IOException;
import java.io.UncheckedIOException;
import java.net.URI;
import java.util.ArrayList;
import java.util.EnumSet;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.NoSuchElementException;
import java.util.Set;
import java.util.concurrent.CompletableFuture;

import org.apache.hadoop.conf.Configuration;
import org.apache.hadoop.fs.ChecksumException;
import org.apache.hadoop.fs.CreateFlag;
import org.apache.hadoop.fs.FSDataInputStream;
import org.apache.hadoop.fs.FSDataOutputStream;
import org.apache.hadoop.fs.FSDataOutputStreamBuilder;
import org.apache.hadoop.fs.FileStatus;
import org.apache.hadoop.fs.FileSystem;
import org.apache.hadoop.fs.FileUtil;
import org.apache.hadoop.fs.FilterFileSystem;
import org.apache.hadoop.fs.FutureDataInputStreamBuilder;
import org.apache.hadoop.fs.LocatedFileStatus;
import org.apache.hadoop.fs.Options.ChecksumOpt;
import org.apache.hadoop.fs.Options.Rename;
import org.apache.hadoop.fs.Path;
import org.apache.hadoop.fs.PathFilter;
import org.apache.hadoop.fs.RemoteIterator;
import org.apache.hadoop.fs.XAttrSetFlag;
import org.apache.hadoop.fs.impl.FutureDataInputStreamBuilderImpl;
import org.apache.hadoop.fs.impl.OpenFileParameters;
import org.apache.hadoop.fs.permission.AclEntry;
import org.apache.hadoop.fs.permission.FsPermission;
import org.apache.hadoop.hdfs.DistributedFileSystem;
import org.apache.hadoop.util.Progressable;

/**
 * The wrapper that stands in for HDFS: Hadoop is told, through
 * <code>fs.hdfs.impl</code>, to use this class for every <code>hdfs://</code>
 * address, and paths stay exactly as they are.
 *
 * <p>It forwards every request to the real HDFS client and writes one line per
 * request that changes storage to a local audit log ({@link AttestedAudit}).
 * Since stage B1 it also hashes every file it creates (SHA-256 per chunk, Merkle
 * root) and writes one record per file at close ({@link AttestedRecords}).
 * Since stage B2 it also keeps each record next to its file ({@link AttestedSidecar})
 * and checks every read against it ({@link VerifyingInputStream}): a file that
 * changed after it was written fails the read. Records follow renames, go with
 * deletes and are hidden from listings.</p>
 *
 * <p>The real HDFS client is constructed directly in {@link #createInner()}.
 * It must never be looked up by scheme (<code>FileSystem.get(...)</code>):
 * the lookup would find this wrapper again and loop. The class refuses to
 * start if the inner file system is another wrapper.</p>
 *
 * <p>Every request that changes storage is logged before it is forwarded.
 * Requests that are not listed here still work (they are forwarded) but leave
 * no log line, so the audit reports them: that is the point of the audit.</p>
 *
 * <p>Hadoop's other lookup, used by <code>FileContext</code>, needs its own
 * small adapter: see {@link AttestedHdfs}.</p>
 */
public class AttestedHdfsFileSystem extends FilterFileSystem {

  public static final String SCHEME = "hdfs";
  static final int DEFAULT_PORT = 8020;

  /** Stage B1: hash every file written through the wrapper (observe only). */
  public static final String HASH_ENABLED_KEY = "attested.hash.enabled";
  public static final String CHUNK_SIZE_KEY = "attested.hash.chunk.size";
  public static final long DEFAULT_CHUNK_SIZE = 16384;

  /** Stage B2: keep each file's record next to it, and verify reads against it. */
  public static final String SIDECAR_KEY = "attested.sidecar.enabled";
  public static final String VERIFY_KEY = "attested.verify.reads";
  /** What to do when a file has no record: allow, warn (log it) or fail. */
  public static final String MISSING_KEY = "attested.verify.missing";

  /**
   * Step 4.5: answers about files (length, existence, listings) are checked against
   * the records, so that a file that was cut, extended, removed or slipped in behind
   * the wrapper's back is noticed without anyone reading it.
   */
  public static final String META_KEY = "attested.metadata.check";
  /** What to do when storage and a record disagree: allow, warn (log it) or fail. */
  public static final String META_MISMATCH_KEY = "attested.metadata.mismatch";
  /** How many seconds a record's length is remembered when no listing can vouch for it. */
  public static final String META_CACHE_KEY = "attested.metadata.cache.seconds";
  private static final int META_CACHE_MAX = 4096;
  private static final int META_REPORTED_MAX = 20000;

  private boolean metadataCheck = true;
  private String mismatchPolicy = "fail";
  private long cacheNanos = 10L * 1000 * 1000 * 1000;

  /** A record's length as read, with the state of the record file it came from. */
  private static final class CachedLength {
    final long length;
    final long recLen;
    final long recMtime;
    final long loadedNanos;

    CachedLength(long length, long recLen, long recMtime, long loadedNanos) {
      this.length = length;
      this.recLen = recLen;
      this.recMtime = recMtime;
      this.loadedNanos = loadedNanos;
    }
  }

  private final Map<String, CachedLength> lengths =
      new LinkedHashMap<String, CachedLength>(256, 0.75f, true) {
        private static final long serialVersionUID = 1L;

        @Override
        protected boolean removeEldestEntry(Map.Entry<String, CachedLength> e) {
          return size() > META_CACHE_MAX;
        }
      };
  private final Set<String> reported = new HashSet<>();

  private boolean hashing = true;
  private boolean sidecars = true;
  private boolean verifyReads = true;
  private String missingPolicy = "warn";
  private long chunkSize = DEFAULT_CHUNK_SIZE;
  private String jobId = "";
  private String attemptId = "";

  public AttestedHdfsFileSystem() {
    super();
  }

  /**
   * The real HDFS client, constructed directly. Tests replace it with a fake
   * in a subclass; production code does not.
   */
  protected FileSystem createInner() {
    return new DistributedFileSystem();
  }

  @Override
  public void initialize(URI name, Configuration conf) throws IOException {
    if (name.getScheme() == null || !SCHEME.equalsIgnoreCase(name.getScheme())) {
      throw new IOException(
          "This wrapper only serves hdfs:// addresses, got: " + name);
    }
    AttestedAudit.open(conf);
    this.hashing = conf.getBoolean(HASH_ENABLED_KEY, true);
    this.chunkSize = conf.getLong(CHUNK_SIZE_KEY, DEFAULT_CHUNK_SIZE);
    if (chunkSize < 1) {
      throw new IOException(CHUNK_SIZE_KEY + " must be at least 1, got " + chunkSize);
    }
    this.sidecars = hashing && conf.getBoolean(SIDECAR_KEY, true);
    this.verifyReads = conf.getBoolean(VERIFY_KEY, true);
    this.missingPolicy = conf.get(MISSING_KEY, "warn").trim().toLowerCase();
    if (!missingPolicy.equals("allow") && !missingPolicy.equals("warn")
        && !missingPolicy.equals("fail")) {
      throw new IOException(MISSING_KEY + " must be allow, warn or fail, got "
          + missingPolicy);
    }
    this.metadataCheck = sidecars && conf.getBoolean(META_KEY, true);
    this.mismatchPolicy = conf.get(META_MISMATCH_KEY, "fail").trim().toLowerCase();
    if (!mismatchPolicy.equals("allow") && !mismatchPolicy.equals("warn")
        && !mismatchPolicy.equals("fail")) {
      throw new IOException(META_MISMATCH_KEY + " must be allow, warn or fail, got "
          + mismatchPolicy);
    }
    long cacheSeconds = conf.getLong(META_CACHE_KEY, 10);
    if (cacheSeconds < 0) {
      throw new IOException(META_CACHE_KEY + " must not be negative, got " + cacheSeconds);
    }
    this.cacheNanos = cacheSeconds * 1000L * 1000L * 1000L;
    if (sidecars && chunkSize > Integer.MAX_VALUE) {
      throw new IOException(CHUNK_SIZE_KEY + " must not exceed "
          + Integer.MAX_VALUE + " when records are kept, got " + chunkSize);
    }
    this.jobId = conf.get("mapreduce.job.id", "");
    this.attemptId = conf.get("mapreduce.task.attempt.id", "");
    if (hashing) {
      AttestedRecords.open(conf);
    }
    FileSystem inner = createInner();
    if (inner == null || inner instanceof AttestedHdfsFileSystem) {
      throw new IOException("The wrapped file system must be the real HDFS "
          + "client, constructed directly. Looking it up by scheme would find "
          + "this wrapper again and loop.");
    }
    this.fs = inner;
    super.initialize(name, conf);
    AttestedAudit.log("INIT", null, null, "uri=" + name + " inner="
        + inner.getClass().getName() + " wrapper=" + getClass().getName()
        + " hash=" + hashing + " chunk=" + chunkSize + " sidecar=" + sidecars
        + " verify=" + verifyReads + " missing=" + missingPolicy
        + " from=" + where());
  }

  private String where() {
    try {
      return getClass().getProtectionDomain().getCodeSource().getLocation()
          .toString();
    } catch (Exception e) {
      return "unknown";
    }
  }

  @Override
  public String getScheme() {
    return SCHEME;
  }

  @Override
  protected int getDefaultPort() {
    return DEFAULT_PORT;
  }

  private Path q(Path p) {
    try {
      return makeQualified(p);
    } catch (RuntimeException e) {
      return p;
    }
  }

  /** Wraps a new output stream so that its bytes are hashed and a record is written at close. */
  private FSDataOutputStream hashed(Path f, FSDataOutputStream stream) {
    if (!hashing) {
      return stream;
    }
    return new FSDataOutputStream(new HashingOutputStream(stream,
        q(f).toUri().getPath(), chunkSize, jobId, attemptId,
        sidecars ? this::writeSidecar : null), null);
  }

  // ------------------------------------------------ records next to files

  private boolean track() {
    return sidecars || verifyReads;
  }

  private boolean isPlainFile(Path f) throws IOException {
    try {
      return fs.getFileStatus(f).isFile();
    } catch (FileNotFoundException e) {
      return false;
    }
  }

  private boolean isDir(Path f) throws IOException {
    try {
      return fs.getFileStatus(f).isDirectory();
    } catch (FileNotFoundException e) {
      return false;
    }
  }

  /** Stores a finished record next to its file, with the real HDFS client. */
  private void writeSidecar(String filePath, long length, long chunk,
      byte[] root, List<byte[]> leaves) throws IOException {
    Path sc = AttestedSidecar.pathFor(new Path(filePath));
    forget(sc);
    byte[] bytes = AttestedSidecar.encode((int) chunk, length, root, leaves);
    audit("CREATE", sc, null, "sidecar");
    try (FSDataOutputStream out = fs.create(sc, true)) {
      out.write(bytes);
    }
  }

  /** The file changed, so its record no longer describes it: remove the record. */
  private void dropSidecar(Path f) throws IOException {
    Path sc = AttestedSidecar.pathFor(f);
    forget(sc);
    if (fs.exists(sc)) {
      audit("DELETE", sc, null, "recursive=false sidecar");
      fs.delete(sc, false);
    }
  }

  /** After a file was renamed: move its record along, and clear any old record at the new name. */
  private void moveSidecar(Path src, Path dst) throws IOException {
    Path from = AttestedSidecar.pathFor(src);
    Path to = AttestedSidecar.pathFor(dst);
    forget(from);
    forget(to);
    boolean had = fs.exists(from);
    if (fs.exists(to)) {
      audit("DELETE", to, null, "recursive=false sidecar");
      fs.delete(to, false);
    }
    if (had) {
      audit("RENAME", from, to, "sidecar");
      if (!fs.rename(from, to)) {
        throw new IOException("Could not move the attested record of " + src
            + " to " + dst);
      }
    }
  }

  /**
   * Wraps a freshly opened stream so that every chunk read is checked against the
   * file's record. Files without a record follow the missing policy; a record that
   * is damaged or disagrees with the file's length fails the open.
   */
  private FSDataInputStream verified(Path f, FSDataInputStream raw, String how)
      throws IOException {
    String tag = how == null ? "" : how + " ";
    if (!verifyReads || AttestedSidecar.isSidecar(f)) {
      audit("OPEN", f, null, tag + "verify=off");
      return raw;
    }
    AttestedSidecar rec = null;
    try {
      rec = AttestedSidecar.read(fs, AttestedSidecar.pathFor(f));
    } catch (FileNotFoundException e) {
      rec = null;
    } catch (IOException e) {
      raw.close();
      audit("VERIFY-FAIL", f, null, tag + e.getMessage());
      throw new ChecksumException("Attested verification failed for " + f
          + ": " + e.getMessage(), 0);
    }
    if (rec == null) {
      if (missingPolicy.equals("fail")) {
        raw.close();
        audit("VERIFY-FAIL", f, null, tag + "no record");
        throw new IOException("Attested verification failed for " + f
            + ": the file has no record");
      }
      audit("OPEN", f, null, tag + (missingPolicy.equals("warn")
          ? "verify=missing" : "verify=skipped"));
      return raw;
    }
    long len = fs.getFileStatus(f).getLen();
    if (rec.length != len) {
      raw.close();
      String why = "length is " + len + " in storage but " + rec.length
          + " in its record";
      audit("VERIFY-FAIL", f, null, tag + why);
      throw new ChecksumException("Attested verification failed for " + f
          + ": " + why, 0);
    }
    audit("OPEN", f, null, tag + "verify=ok");
    return new FSDataInputStream(new VerifyingInputStream(raw, rec, q(f)));
  }

  // ------------------------------------------------------------- metadata (step 4.5)

  private void forget(Path sidecar) {
    synchronized (lengths) {
      lengths.remove(q(sidecar).toString());
    }
  }

  /** Logs a finding once per path and kind in this JVM, so that a repeated question does not flood the log. */
  private void report(String op, Path p, String why) throws IOException {
    String key = op + "\t" + q(p) + "\t" + why;
    synchronized (reported) {
      if (reported.size() > META_REPORTED_MAX) {
        reported.clear();
      }
      if (!reported.add(key)) {
        return;
      }
    }
    audit(op, p, null, why);
  }

  /** Storage and a record disagree: allow, warn or fail, as the setting says. */
  private void mismatch(Path f, String op, String why) throws IOException {
    if (mismatchPolicy.equals("allow")) {
      return;
    }
    if (mismatchPolicy.equals("warn")) {
      report(op, f, why);
      return;
    }
    audit(op, f, null, why);
    throw new ChecksumException("Attested metadata check failed for " + f + ": " + why, 0);
  }

  /** A file without a record follows the same setting as a read does. */
  private void missingRecord(Path f) throws IOException {
    if (missingPolicy.equals("allow")) {
      return;
    }
    if (missingPolicy.equals("warn")) {
      report("META-MISSING", f, "no record");
      return;
    }
    audit("META-MISSING", f, null, "no record");
    throw new IOException("Attested metadata check failed for " + f
        + ": the file has no record");
  }

  /**
   * A record whose file is gone: someone removed the file behind the wrapper's back,
   * unless a delete through the wrapper is just finishing (it removes the file and
   * then the record), so look again after a moment before deciding.
   */
  private void orphan(Path data) throws IOException {
    Path rec = AttestedSidecar.pathFor(data);
    try {
      Thread.sleep(25);
    } catch (InterruptedException e) {
      Thread.currentThread().interrupt();
    }
    if (fs.exists(data) || !fs.exists(rec)) {
      return;
    }
    mismatch(data, "META-ORPHAN", "the file is missing in storage but its record exists");
  }

  /**
   * The length written in f's record, or -1 when f has no record. When the status of
   * the record file is known (from a listing) a remembered length is used only if
   * the record file is unchanged; otherwise only for a few seconds.
   */
  private long recordLength(Path f, FileStatus recStatus, boolean fresh) throws IOException {
    Path rec = AttestedSidecar.pathFor(f);
    String key = q(rec).toString();
    long now = System.nanoTime();
    if (!fresh) {
      CachedLength c;
      synchronized (lengths) {
        c = lengths.get(key);
      }
      if (c != null) {
        boolean valid = recStatus != null
            ? c.recLen == recStatus.getLen() && c.recMtime == recStatus.getModificationTime()
            : now - c.loadedNanos < cacheNanos;
        if (valid) {
          return c.length;
        }
      }
    }
    long len;
    try {
      len = AttestedSidecar.readLength(fs, rec);
    } catch (FileNotFoundException e) {
      synchronized (lengths) {
        lengths.remove(key);
      }
      return -1;
    }
    synchronized (lengths) {
      lengths.put(key, new CachedLength(len, recStatus == null ? -1 : recStatus.getLen(),
          recStatus == null ? -1 : recStatus.getModificationTime(), now));
    }
    return len;
  }

  /** Compares one file's length in storage with its record. */
  private void checkFile(Path f, long storageLen, FileStatus recStatus) throws IOException {
    long rec;
    try {
      rec = recordLength(f, recStatus, false);
    } catch (IOException damaged) {
      mismatch(f, "META-FAIL", "its record is unreadable: " + damaged.getMessage());
      return;
    }
    if (rec < 0) {
      missingRecord(f);
      return;
    }
    if (rec != storageLen) {
      // another task may just have rewritten the file and its record: look at the record afresh
      try {
        rec = recordLength(f, recStatus, true);
      } catch (IOException damaged) {
        mismatch(f, "META-FAIL", "its record is unreadable: " + damaged.getMessage());
        return;
      }
      if (rec < 0) {
        missingRecord(f);
      } else if (rec != storageLen) {
        mismatch(f, "META-FAIL", "length is " + storageLen + " in storage but " + rec
            + " in its record");
      }
    }
  }

  /**
   * Checks what one listing shows against the records in it: a file whose length is
   * not the one in its record, a file without a record, and a record without a file.
   */
  private void checkListing(Path f, FileStatus[] all) throws IOException {
    if (!metadataCheck || all.length == 0) {
      return;
    }
    if (all.length == 1 && !all[0].isDirectory()
        && all[0].getPath().toUri().getPath().equals(f.toUri().getPath())) {
      // the listing of a single file shows the file only, not its record
      if (!AttestedSidecar.isSidecar(all[0].getPath())) {
        checkFile(all[0].getPath(), all[0].getLen(), null);
      }
      return;
    }
    Map<String, FileStatus> byName = new HashMap<>();
    for (FileStatus s : all) {
      byName.put(s.getPath().getName(), s);
    }
    for (FileStatus s : all) {
      Path p = s.getPath();
      String name = p.getName();
      if (AttestedSidecar.isSidecar(p)) {
        String dataName = name.substring(1, name.length() - ".attested".length());
        if (!byName.containsKey(dataName)) {
          orphan(new Path(p.getParent(), dataName));
        }
      } else if (!s.isDirectory()) {
        FileStatus rec = byName.get("." + name + ".attested");
        if (rec == null) {
          missingRecord(p);
        } else {
          checkFile(p, s.getLen(), rec);
        }
      }
    }
  }

  /** The whole listing is read and checked first; the records are then left out, and the caller's filter applied. */
  private <T extends FileStatus> RemoteIterator<T> checkedIterator(Path dir,
      RemoteIterator<T> it, final PathFilter filter) throws IOException {
    List<T> all = new ArrayList<>();
    while (it.hasNext()) {
      all.add(it.next());
    }
    checkListing(dir, all.toArray(new FileStatus[0]));
    final List<T> kept = new ArrayList<>();
    for (T s : all) {
      if (!AttestedSidecar.isSidecar(s.getPath())
          && (filter == null || filter.accept(s.getPath()))) {
        kept.add(s);
      }
    }
    final Iterator<T> kit = kept.iterator();
    return new RemoteIterator<T>() {
      @Override
      public boolean hasNext() {
        return kit.hasNext();
      }

      @Override
      public T next() {
        if (!kit.hasNext()) {
          throw new NoSuchElementException();
        }
        return kit.next();
      }
    };
  }

  @Override
  public FileStatus getFileStatus(Path f) throws IOException {
    FileStatus st;
    try {
      st = super.getFileStatus(f);
    } catch (FileNotFoundException e) {
      if (metadataCheck && !AttestedSidecar.isSidecar(f) && f.getParent() != null
          && fs.exists(AttestedSidecar.pathFor(f))) {
        orphan(f);
      }
      throw e;
    }
    if (metadataCheck && st.isFile() && !AttestedSidecar.isSidecar(f)) {
      checkFile(f, st.getLen(), null);
    }
    return st;
  }

  private static FileStatus[] withoutSidecars(FileStatus[] all) {
    int keep = 0;
    for (FileStatus s : all) {
      if (!AttestedSidecar.isSidecar(s.getPath())) {
        keep++;
      }
    }
    if (keep == all.length) {
      return all;
    }
    FileStatus[] out = new FileStatus[keep];
    int i = 0;
    for (FileStatus s : all) {
      if (!AttestedSidecar.isSidecar(s.getPath())) {
        out[i++] = s;
      }
    }
    return out;
  }

  @Override
  public FileStatus[] listStatus(Path f) throws IOException {
    FileStatus[] all = super.listStatus(f);
    checkListing(f, all);
    return withoutSidecars(all);
  }

  @Override
  public RemoteIterator<FileStatus> listStatusIterator(Path f)
      throws IOException {
    return checkedIterator(f, super.listStatusIterator(f), null);
  }

  @Override
  public RemoteIterator<LocatedFileStatus> listLocatedStatus(Path f)
      throws IOException {
    return checkedIterator(f, super.listLocatedStatus(f), null);
  }

  @Override
  protected RemoteIterator<LocatedFileStatus> listLocatedStatus(Path f,
      PathFilter filter) throws IOException {
    // read the whole listing without the filter, so that the records are seen, then apply it
    return checkedIterator(f, super.listLocatedStatus(f), filter);
  }

  private void audit(String op, Path p1, Path p2, String extra)
      throws IOException {
    AttestedAudit.log(op, p1 == null ? null : q(p1), p2 == null ? null : q(p2),
        extra);
  }

  // ------------------------------------------------------------- reads

  @Override
  public FSDataInputStream open(Path f, int bufferSize) throws IOException {
    return verified(f, super.open(f, bufferSize), null);
  }

  /**
   * The builder form of open (used by sequence files and others) must come to this
   * class too, not go straight to the real client, or its reads would not be checked.
   */
  @Override
  public FutureDataInputStreamBuilder openFile(Path path)
      throws IOException, UnsupportedOperationException {
    return new FutureDataInputStreamBuilderImpl(this, path) {
      @Override
      public CompletableFuture<FSDataInputStream> build()
          throws IllegalArgumentException, UnsupportedOperationException,
          IOException {
        OpenFileParameters params = new OpenFileParameters()
            .withMandatoryKeys(getMandatoryKeys())
            .withOptionalKeys(getOptionalKeys())
            .withOptions(getOptions())
            .withBufferSize(getBufferSize())
            .withStatus(getStatus());
        return AttestedHdfsFileSystem.this.openFileWithOptions(getPath(), params);
      }
    };
  }

  @Override
  protected CompletableFuture<FSDataInputStream> openFileWithOptions(Path path,
      OpenFileParameters parameters) throws IOException {
    return super.openFileWithOptions(path, parameters).thenApply(raw -> {
      try {
        return verified(path, raw, "openFile");
      } catch (IOException e) {
        throw new UncheckedIOException(e);
      }
    });
  }

  @Override
  public void copyToLocalFile(boolean delSrc, Path src, Path dst)
      throws IOException {
    audit("OPEN", src, null, "copyToLocalFile verify=bypassed");
    if (delSrc) {
      audit("DELETE", src, null, "recursive=true copyToLocalFile");
    }
    super.copyToLocalFile(delSrc, src, dst);
  }

  // ------------------------------------------------------ data changes

  @Override
  public FSDataOutputStream create(Path f, FsPermission permission,
      boolean overwrite, int bufferSize, short replication, long blockSize,
      Progressable progress) throws IOException {
    audit("CREATE", f, null, "overwrite=" + overwrite);
    return hashed(f, super.create(f, permission, overwrite, bufferSize,
        replication, blockSize, progress));
  }

  @Override
  public FSDataOutputStream create(Path f, FsPermission permission,
      EnumSet<CreateFlag> flags, int bufferSize, short replication,
      long blockSize, Progressable progress, ChecksumOpt checksumOpt)
      throws IOException {
    audit("CREATE", f, null, "flags=" + flags);
    return hashed(f, super.create(f, permission, flags, bufferSize,
        replication, blockSize, progress, checksumOpt));
  }

  @Override
  @SuppressWarnings("deprecation")
  public FSDataOutputStream createNonRecursive(Path f, FsPermission permission,
      EnumSet<CreateFlag> flags, int bufferSize, short replication,
      long blockSize, Progressable progress) throws IOException {
    audit("CREATE", f, null, "createNonRecursive flags=" + flags);
    return hashed(f, super.createNonRecursive(f, permission, flags, bufferSize,
        replication, blockSize, progress));
  }

  @Override
  protected FSDataOutputStream primitiveCreate(Path f,
      FsPermission absolutePermission, EnumSet<CreateFlag> flag,
      int bufferSize, short replication, long blockSize, Progressable progress,
      ChecksumOpt checksumOpt) throws IOException {
    audit("CREATE", f, null, "primitiveCreate flags=" + flag);
    return hashed(f, super.primitiveCreate(f, absolutePermission, flag,
        bufferSize, replication, blockSize, progress, checksumOpt));
  }

  /**
   * The builder forms of create and append must come to this class too: a builder bound to the real
   * client would write files without hashing them, and would change a file without dropping its
   * record, so a later read would fail on a stale record. These builders call this class's create
   * and append (the same factory Hadoop's own {@code FileSystem} uses).
   */
  @Override
  @SuppressWarnings("rawtypes")
  public FSDataOutputStreamBuilder createFile(Path path) {
    return createDataOutputStreamBuilder(this, path).create().overwrite(true);
  }

  @Override
  public FSDataOutputStream append(Path f, int bufferSize,
      Progressable progress) throws IOException {
    audit("APPEND", f, null, null);
    if (track()) {
      dropSidecar(f);
    }
    if (hashing) {
      AttestedRecords.log(jobId, attemptId, q(f).toUri().getPath(), -1,
          chunkSize, 0, "", "append-unhashed");
    }
    return super.append(f, bufferSize, progress);
  }

  @Override
  @SuppressWarnings("rawtypes")
  public FSDataOutputStreamBuilder appendFile(Path path) {
    return createDataOutputStreamBuilder(this, path).append();
  }

  @Override
  public void concat(Path f, Path[] psrcs) throws IOException {
    StringBuilder srcs = new StringBuilder("srcs=");
    for (int i = 0; i < psrcs.length; i++) {
      srcs.append(i > 0 ? "," : "").append(q(psrcs[i]).toUri().getPath());
    }
    audit("CONCAT", f, null, srcs.toString());
    super.concat(f, psrcs);
    if (track()) {
      dropSidecar(f);
      for (Path src : psrcs) {
        dropSidecar(src);
      }
    }
  }

  @Override
  public boolean truncate(Path f, long newLength) throws IOException {
    audit("TRUNCATE", f, null, "newLength=" + newLength);
    boolean done = super.truncate(f, newLength);
    if (track()) {
      dropSidecar(f);
    }
    return done;
  }

  @Override
  public void copyFromLocalFile(boolean delSrc, Path src, Path dst)
      throws IOException {
    audit("COPYFROMLOCAL", dst, null, "src=" + src);
    if (hashing) {
      FileUtil.copy(FileSystem.getLocal(getConf()), src, this, dst, delSrc, true,
          getConf());
    } else {
      super.copyFromLocalFile(delSrc, src, dst);
    }
  }

  @Override
  public void copyFromLocalFile(boolean delSrc, boolean overwrite, Path[] srcs,
      Path dst) throws IOException {
    audit("COPYFROMLOCAL", dst, null, "srcs=" + java.util.Arrays.toString(srcs));
    if (hashing) {
      FileUtil.copy(FileSystem.getLocal(getConf()), srcs, this, dst, delSrc,
          overwrite, getConf());
    } else {
      super.copyFromLocalFile(delSrc, overwrite, srcs, dst);
    }
  }

  @Override
  public void copyFromLocalFile(boolean delSrc, boolean overwrite, Path src,
      Path dst) throws IOException {
    audit("COPYFROMLOCAL", dst, null, "src=" + src);
    if (hashing) {
      FileUtil.copy(FileSystem.getLocal(getConf()), src, this, dst, delSrc,
          overwrite, getConf());
    } else {
      super.copyFromLocalFile(delSrc, overwrite, src, dst);
    }
  }

  // -------------------------------------------------- names and folders

  @Override
  public boolean rename(Path src, Path dst) throws IOException {
    audit("RENAME", src, dst, null);
    boolean file = track() && isPlainFile(src);
    Path target = dst;
    if (file && isDir(dst)) {
      target = new Path(dst, src.getName());
    }
    boolean ok = super.rename(src, dst);
    if (ok && file) {
      moveSidecar(src, target);
    }
    return ok;
  }

  @Override
  protected void rename(Path src, Path dst, Rename... options)
      throws IOException {
    audit("RENAME", src, dst, "options");
    boolean file = track() && isPlainFile(src);
    super.rename(src, dst, options);
    if (file) {
      moveSidecar(src, dst);
    }
  }

  @Override
  public boolean delete(Path f, boolean recursive) throws IOException {
    audit("DELETE", f, null, "recursive=" + recursive);
    boolean file = track() && isPlainFile(f);
    boolean ok = super.delete(f, recursive);
    if (ok && file) {
      dropSidecar(f);
    }
    return ok;
  }

  @Override
  public boolean mkdirs(Path f, FsPermission permission) throws IOException {
    audit("MKDIRS", f, null, null);
    return super.mkdirs(f, permission);
  }

  @Override
  public boolean mkdirs(Path f) throws IOException {
    audit("MKDIRS", f, null, null);
    return super.mkdirs(f);
  }

  @Override
  protected boolean primitiveMkdir(Path f, FsPermission abdolutePermission)
      throws IOException {
    audit("MKDIRS", f, null, "primitiveMkdir");
    return super.primitiveMkdir(f, abdolutePermission);
  }

  @Override
  public void createSymlink(Path target, Path link, boolean createParent)
      throws IOException {
    audit("SETATTR", link, target, "createSymlink");
    super.createSymlink(target, link, createParent);
  }

  // ------------------------------------------------------- attributes

  @Override
  public void setPermission(Path p, FsPermission permission)
      throws IOException {
    audit("SETATTR", p, null, "setPermission");
    super.setPermission(p, permission);
  }

  @Override
  public void setOwner(Path p, String username, String groupname)
      throws IOException {
    audit("SETATTR", p, null, "setOwner");
    super.setOwner(p, username, groupname);
  }

  @Override
  public void setTimes(Path p, long mtime, long atime) throws IOException {
    audit("SETATTR", p, null, "setTimes");
    super.setTimes(p, mtime, atime);
  }

  @Override
  public boolean setReplication(Path src, short replication)
      throws IOException {
    audit("SETATTR", src, null, "setReplication");
    return super.setReplication(src, replication);
  }

  @Override
  public void setXAttr(Path path, String name, byte[] value)
      throws IOException {
    audit("SETATTR", path, null, "setXAttr");
    super.setXAttr(path, name, value);
  }

  @Override
  public void setXAttr(Path path, String name, byte[] value,
      EnumSet<XAttrSetFlag> flag) throws IOException {
    audit("SETATTR", path, null, "setXAttr");
    super.setXAttr(path, name, value, flag);
  }

  @Override
  public void removeXAttr(Path path, String name) throws IOException {
    audit("SETATTR", path, null, "removeXAttr");
    super.removeXAttr(path, name);
  }

  @Override
  public void modifyAclEntries(Path path, List<AclEntry> aclSpec)
      throws IOException {
    audit("SETATTR", path, null, "modifyAclEntries");
    super.modifyAclEntries(path, aclSpec);
  }

  @Override
  public void removeAclEntries(Path path, List<AclEntry> aclSpec)
      throws IOException {
    audit("SETATTR", path, null, "removeAclEntries");
    super.removeAclEntries(path, aclSpec);
  }

  @Override
  public void removeDefaultAcl(Path path) throws IOException {
    audit("SETATTR", path, null, "removeDefaultAcl");
    super.removeDefaultAcl(path);
  }

  @Override
  public void removeAcl(Path path) throws IOException {
    audit("SETATTR", path, null, "removeAcl");
    super.removeAcl(path);
  }

  @Override
  public void setAcl(Path path, List<AclEntry> aclSpec) throws IOException {
    audit("SETATTR", path, null, "setAcl");
    super.setAcl(path, aclSpec);
  }

  @Override
  public Path createSnapshot(Path path, String snapshotName)
      throws IOException {
    audit("SETATTR", path, null, "createSnapshot");
    return super.createSnapshot(path, snapshotName);
  }

  @Override
  public void renameSnapshot(Path path, String snapshotOldName,
      String snapshotNewName) throws IOException {
    audit("SETATTR", path, null, "renameSnapshot");
    super.renameSnapshot(path, snapshotOldName, snapshotNewName);
  }

  @Override
  public void deleteSnapshot(Path path, String snapshotName)
      throws IOException {
    audit("SETATTR", path, null, "deleteSnapshot");
    super.deleteSnapshot(path, snapshotName);
  }

  @Override
  public void satisfyStoragePolicy(Path src) throws IOException {
    audit("SETATTR", src, null, "satisfyStoragePolicy");
    super.satisfyStoragePolicy(src);
  }

  @Override
  public void setStoragePolicy(Path src, String policyName)
      throws IOException {
    audit("SETATTR", src, null, "setStoragePolicy");
    super.setStoragePolicy(src, policyName);
  }

  @Override
  public void unsetStoragePolicy(Path src) throws IOException {
    audit("SETATTR", src, null, "unsetStoragePolicy");
    super.unsetStoragePolicy(src);
  }
}
