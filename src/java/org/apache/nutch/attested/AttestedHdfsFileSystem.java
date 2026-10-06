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
import java.net.URI;
import java.util.EnumSet;
import java.util.List;

import org.apache.hadoop.conf.Configuration;
import org.apache.hadoop.fs.CreateFlag;
import org.apache.hadoop.fs.FSDataInputStream;
import org.apache.hadoop.fs.FSDataOutputStream;
import org.apache.hadoop.fs.FSDataOutputStreamBuilder;
import org.apache.hadoop.fs.FileSystem;
import org.apache.hadoop.fs.FilterFileSystem;
import org.apache.hadoop.fs.FutureDataInputStreamBuilder;
import org.apache.hadoop.fs.Options.ChecksumOpt;
import org.apache.hadoop.fs.Options.Rename;
import org.apache.hadoop.fs.Path;
import org.apache.hadoop.fs.XAttrSetFlag;
import org.apache.hadoop.fs.permission.AclEntry;
import org.apache.hadoop.fs.permission.FsPermission;
import org.apache.hadoop.hdfs.DistributedFileSystem;
import org.apache.hadoop.util.Progressable;

/**
 * The wrapper that stands in for HDFS: Hadoop is told, through
 * <code>fs.hdfs.impl</code>, to use this class for every <code>hdfs://</code>
 * address, and paths stay exactly as they are.
 *
 * <p>For now it only forwards every request to the real HDFS client and writes
 * one line per request to a local audit log ({@link AttestedAudit}). Nothing
 * is hashed, signed or checked yet.</p>
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

  private void audit(String op, Path p1, Path p2, String extra)
      throws IOException {
    AttestedAudit.log(op, p1 == null ? null : q(p1), p2 == null ? null : q(p2),
        extra);
  }

  // ------------------------------------------------------------- reads

  @Override
  public FSDataInputStream open(Path f, int bufferSize) throws IOException {
    audit("OPEN", f, null, null);
    return super.open(f, bufferSize);
  }

  @Override
  public FutureDataInputStreamBuilder openFile(Path path)
      throws IOException, UnsupportedOperationException {
    audit("OPEN", path, null, "openFile");
    return super.openFile(path);
  }

  @Override
  public void copyToLocalFile(boolean delSrc, Path src, Path dst)
      throws IOException {
    audit("OPEN", src, null, "copyToLocalFile");
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
    return super.create(f, permission, overwrite, bufferSize, replication,
        blockSize, progress);
  }

  @Override
  public FSDataOutputStream create(Path f, FsPermission permission,
      EnumSet<CreateFlag> flags, int bufferSize, short replication,
      long blockSize, Progressable progress, ChecksumOpt checksumOpt)
      throws IOException {
    audit("CREATE", f, null, "flags=" + flags);
    return super.create(f, permission, flags, bufferSize, replication,
        blockSize, progress, checksumOpt);
  }

  @Override
  @SuppressWarnings("deprecation")
  public FSDataOutputStream createNonRecursive(Path f, FsPermission permission,
      EnumSet<CreateFlag> flags, int bufferSize, short replication,
      long blockSize, Progressable progress) throws IOException {
    audit("CREATE", f, null, "createNonRecursive flags=" + flags);
    return super.createNonRecursive(f, permission, flags, bufferSize,
        replication, blockSize, progress);
  }

  @Override
  protected FSDataOutputStream primitiveCreate(Path f,
      FsPermission absolutePermission, EnumSet<CreateFlag> flag,
      int bufferSize, short replication, long blockSize, Progressable progress,
      ChecksumOpt checksumOpt) throws IOException {
    audit("CREATE", f, null, "primitiveCreate flags=" + flag);
    return super.primitiveCreate(f, absolutePermission, flag, bufferSize,
        replication, blockSize, progress, checksumOpt);
  }

  @Override
  @SuppressWarnings("rawtypes")
  public FSDataOutputStreamBuilder createFile(Path path) {
    try {
      audit("CREATE", path, null, "createFile builder");
    } catch (IOException e) {
      throw new IllegalStateException("attested audit log failed", e);
    }
    return super.createFile(path);
  }

  @Override
  public FSDataOutputStream append(Path f, int bufferSize,
      Progressable progress) throws IOException {
    audit("APPEND", f, null, null);
    return super.append(f, bufferSize, progress);
  }

  @Override
  @SuppressWarnings("rawtypes")
  public FSDataOutputStreamBuilder appendFile(Path path) {
    try {
      audit("APPEND", path, null, "appendFile builder");
    } catch (IOException e) {
      throw new IllegalStateException("attested audit log failed", e);
    }
    return super.appendFile(path);
  }

  @Override
  public void concat(Path f, Path[] psrcs) throws IOException {
    StringBuilder srcs = new StringBuilder("srcs=");
    for (int i = 0; i < psrcs.length; i++) {
      srcs.append(i > 0 ? "," : "").append(q(psrcs[i]).toUri().getPath());
    }
    audit("CONCAT", f, null, srcs.toString());
    super.concat(f, psrcs);
  }

  @Override
  public boolean truncate(Path f, long newLength) throws IOException {
    audit("TRUNCATE", f, null, "newLength=" + newLength);
    return super.truncate(f, newLength);
  }

  @Override
  public void copyFromLocalFile(boolean delSrc, Path src, Path dst)
      throws IOException {
    audit("COPYFROMLOCAL", dst, null, "src=" + src);
    super.copyFromLocalFile(delSrc, src, dst);
  }

  @Override
  public void copyFromLocalFile(boolean delSrc, boolean overwrite, Path[] srcs,
      Path dst) throws IOException {
    audit("COPYFROMLOCAL", dst, null, "srcs=" + java.util.Arrays.toString(srcs));
    super.copyFromLocalFile(delSrc, overwrite, srcs, dst);
  }

  @Override
  public void copyFromLocalFile(boolean delSrc, boolean overwrite, Path src,
      Path dst) throws IOException {
    audit("COPYFROMLOCAL", dst, null, "src=" + src);
    super.copyFromLocalFile(delSrc, overwrite, src, dst);
  }

  // -------------------------------------------------- names and folders

  @Override
  public boolean rename(Path src, Path dst) throws IOException {
    audit("RENAME", src, dst, null);
    return super.rename(src, dst);
  }

  @Override
  protected void rename(Path src, Path dst, Rename... options)
      throws IOException {
    audit("RENAME", src, dst, "options");
    super.rename(src, dst, options);
  }

  @Override
  public boolean delete(Path f, boolean recursive) throws IOException {
    audit("DELETE", f, null, "recursive=" + recursive);
    return super.delete(f, recursive);
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
