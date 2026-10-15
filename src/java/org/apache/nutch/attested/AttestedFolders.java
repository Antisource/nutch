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
import java.security.SecureRandom;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import org.apache.hadoop.fs.FSDataInputStream;
import org.apache.hadoop.fs.FSDataOutputStream;
import org.apache.hadoop.fs.FileSystem;
import org.apache.hadoop.fs.Path;

/**
 * The folder identity files of step 5.1.2. Every folder that the wrapper makes (or adopts, when it first writes into it) gets a small
 * signed file "_attested-folder" with the folder's random ID, its own name and its parent's ID (a top folder: its full path). A record
 * bound to a folder (ATTEST03) names that ID, so a signed file copied into another folder, or under another name, no longer verifies.
 *
 * <p>All reads and writes here use the real (inner) file system, never the wrapper. Identity files are small and are cached per process
 * for a short time; a rename of a folder signs a new identity file for that one folder.</p>
 */
final class AttestedFolders {

  /** Where the wrapper's audit lines go. */
  interface Audit {
    void log(String op, Path p1, Path p2, String extra) throws IOException;
  }

  private static final int MAX_DEPTH = 256;
  private static final int MAX_IDENTITY_BYTES = 16384;
  private static final int PARTIAL_RETRIES = 40;
  private static final int CACHE_MAX = 4096;

  private static final class Entry {
    final AttestedFolderCodec.Decoded decoded;
    final long at;
    byte[] chainId;
    long chainAt;

    Entry(AttestedFolderCodec.Decoded decoded, long at) {
      this.decoded = decoded;
      this.at = at;
    }
  }

  private final FileSystem fs;
  private final AttestedSignatures sigs;
  private final long ttlNanos;
  private final Audit audit;
  private final SecureRandom random = new SecureRandom();
  private final Map<String, Entry> cache = new LinkedHashMap<String, Entry>(256, 0.75f, true) {
    private static final long serialVersionUID = 1L;

    @Override
    protected boolean removeEldestEntry(Map.Entry<String, Entry> eldest) {
      return size() > CACHE_MAX;
    }
  };

  AttestedFolders(FileSystem fs, AttestedSignatures sigs, long ttlNanos, Audit audit) {
    this.fs = fs;
    this.sigs = sigs;
    this.ttlNanos = ttlNanos;
    this.audit = audit;
  }

  static boolean isRoot(Path p) {
    return p == null || p.getName().isEmpty();
  }

  private static String key(Path dir) {
    return dir.toUri().getPath();
  }

  Path identityPath(Path dir) {
    return new Path(dir, AttestedFolderCodec.FILE_NAME);
  }

  /** Forget everything cached for this folder and the folders below it (after a rename or a delete). */
  void forgetTree(Path dir) {
    String prefix = key(dir);
    synchronized (cache) {
      cache.keySet().removeIf(k -> k.equals(prefix) || k.startsWith(prefix + "/"));
    }
  }

  private void forget(Path dir) {
    synchronized (cache) {
      cache.remove(key(dir));
    }
  }

  private byte[] readBytes(Path idPath) throws IOException {
    for (int i = 0; ; i++) {
      long size;
      try {
        size = fs.getFileStatus(idPath).getLen();
      } catch (FileNotFoundException e) {
        return null;
      }
      if (size > MAX_IDENTITY_BYTES) {
        throw new IOException("folder identity is damaged (too long): " + idPath);
      }
      if (size > 0) {
        byte[] all = new byte[(int) size];
        try (FSDataInputStream in = fs.open(idPath)) {
          in.readFully(0, all);
        } catch (FileNotFoundException e) {
          return null;
        } catch (java.io.EOFException e) {
          all = null;
        }
        if (all != null) {
          return all;
        }
      }
      // a file that is empty or short may be one that another task is still writing: wait a little
      if (i >= PARTIAL_RETRIES) {
        throw new IOException("folder identity is damaged (empty or too short): " + idPath);
      }
      try {
        Thread.sleep(50);
      } catch (InterruptedException e) {
        Thread.currentThread().interrupt();
        throw new IOException("interrupted while waiting for the identity of " + idPath);
      }
    }
  }

  /**
   * The verified identity of a folder, or null when it has none. Throws an IOException when the identity file is damaged or its signature
   * does not verify (the folder is then not trusted, and nothing is written into or read from it as if it were).
   */
  AttestedFolderCodec.Decoded read(Path dir) throws IOException {
    if (isRoot(dir)) {
      return null;
    }
    long now = System.nanoTime();
    synchronized (cache) {
      Entry e = cache.get(key(dir));
      if (e != null && ttlNanos > 0 && now - e.at < ttlNanos) {
        return e.decoded;
      }
    }
    byte[] bytes = readBytes(identityPath(dir));
    if (bytes == null) {
      return null;
    }
    AttestedFolderCodec.Decoded d = AttestedFolderCodec.decode(bytes);
    sigs.checkFolder(d);
    synchronized (cache) {
      cache.put(key(dir), new Entry(d, now));
    }
    return d;
  }

  /**
   * The identity of a folder that exists, made when it has none (the wrapper adopts the folder). The rule that decides what the identity is:
   * if some ancestor of the folder has an identity, every folder between that ancestor and this one that has none is adopted as a child of
   * the one above it, so the chain is closed; only when no ancestor has an identity is the folder a top folder, bound to its full path.
   * The rule never depends on timing: two writers that adopt the same folders at once write the same shapes, and the first identity file
   * written wins. (A top folder inside an identified tree would break when an ancestor is renamed.) Returns null for the root.
   */
  AttestedFolderCodec.Decoded ensure(Path dir) throws IOException {
    if (isRoot(dir)) {
      return null;
    }
    AttestedFolderCodec.Decoded d = read(dir);
    if (d != null) {
      return d;
    }
    List<Path> unidentified = new ArrayList<>();
    unidentified.add(dir);
    AttestedFolderCodec.Decoded above = null;
    for (Path cur = dir.getParent(); !isRoot(cur); cur = cur.getParent()) {
      if (unidentified.size() > MAX_DEPTH) {
        throw new IOException("the folder chain of " + dir + " is too deep");
      }
      above = read(cur);
      if (above != null) {
        break;
      }
      unidentified.add(cur);
    }
    if (above == null) {
      return create(dir, null);          // no ancestor has an identity: this folder alone becomes a top folder
    }
    AttestedFolderCodec.Decoded parent = above;
    for (int i = unidentified.size() - 1; i >= 0; i--) {   // from the folder just below the identified ancestor, down to dir
      parent = create(unidentified.get(i), parent);
    }
    return parent;
  }

  /** Writes the identity of one folder (a child of the given parent identity, or a top folder when it is null); the first writer wins. */
  private AttestedFolderCodec.Decoded create(Path dir, AttestedFolderCodec.Decoded parent) throws IOException {
    AttestedFolderCodec.Decoded existing = read(dir);
    if (existing != null) {
      return existing;
    }
    byte[] id = new byte[AttestedRecordCodec.FOLDER_ID];
    random.nextBytes(id);
    byte[] bytes = parent != null ? sigs.encodeFolder(id, dir.getName(), parent.folderId, null)
        : sigs.encodeFolder(id, dir.getName(), null, dir.toUri().getPath());
    Path idPath = identityPath(dir);
    try {
      audit.log("CREATE", idPath, null, "folder-identity " + (parent != null ? "child" : "top"));
      try (FSDataOutputStream out = fs.create(idPath, false)) {
        out.write(bytes);
      }
    } catch (IOException e) {
      // Another writer was first. The real HDFS tells the loser either "file exists" or, while the winner is still writing, "already being
      // created by another client" (a different exception), so any failure to create is followed by a look at what is there now: the
      // winner's identity is read and used (read waits a little for a file that is still being written). If there is none, the failure is real.
      forget(dir);
      AttestedFolderCodec.Decoded winner = read(dir);
      if (winner == null) {
        throw e;
      }
      return winner;
    }
    AttestedFolderCodec.Decoded made = AttestedFolderCodec.decode(bytes);
    synchronized (cache) {
      cache.put(key(dir), new Entry(made, System.nanoTime()));
    }
    return made;
  }

  /** The folders of this path that do not exist yet, from the topmost down to the folder itself. */
  List<Path> missingAncestors(Path dir) throws IOException {
    List<Path> missing = new ArrayList<>();
    Path cur = dir;
    while (!isRoot(cur) && !fs.exists(cur)) {
      missing.add(0, cur);
      cur = cur.getParent();
    }
    return missing;
  }

  /** Gives each of these (just made) folders its identity, topmost first. */
  void adopt(List<Path> folders) throws IOException {
    for (Path p : folders) {
      ensure(p);
    }
  }

  /** A recently verified identity from the cache, or null: no call to the NameNode is made. */
  private AttestedFolderCodec.Decoded cached(Path dir) {
    long now = System.nanoTime();
    synchronized (cache) {
      Entry e = cache.get(key(dir));
      return e != null && ttlNanos > 0 && now - e.at < ttlNanos ? e.decoded : null;
    }
  }

  /** Makes the folder and any missing parents, each with an identity; an existing folder is adopted. */
  void ensureTree(Path dir) throws IOException {
    if (isRoot(dir) || cached(dir) != null) {
      return;
    }
    List<Path> missing = missingAncestors(dir);
    if (!missing.isEmpty()) {
      fs.mkdirs(dir);
    }
    if (missing.isEmpty()) {
      ensure(dir);
    } else {
      adopt(missing);
    }
  }

  /**
   * Checks the whole chain of a folder up to the top and returns the folder's ID. Each identity must verify, name the folder it sits in,
   * and point at the identity of its parent; the top identity must be for the folder's own full path. A folder without an identity, a
   * folder that was moved or copied behind the wrapper's back, or an identity of another folder all throw an IOException.
   */
  byte[] verifyChain(Path dir) throws IOException {
    long now = System.nanoTime();
    synchronized (cache) {
      Entry e = cache.get(key(dir));
      if (e != null && e.chainId != null && ttlNanos > 0 && now - e.chainAt < ttlNanos) {
        return e.chainId;
      }
    }
    AttestedFolderCodec.Decoded first = read(dir);
    if (first == null) {
      throw new IOException("the folder " + dir + " has no identity");
    }
    Path cur = dir;
    AttestedFolderCodec.Decoded d = first;
    for (int depth = 0; ; depth++) {
      if (depth > MAX_DEPTH) {
        throw new IOException("the folder chain of " + dir + " is too deep or loops");
      }
      if (!d.name.equals(cur.getName())) {
        throw new IOException("the identity in " + cur + " is for a folder named '" + d.name + "', not '" + cur.getName() + "'");
      }
      if (d.top()) {
        if (!d.topPath.equals(key(cur))) {
          throw new IOException("the top folder identity in " + cur + " is for the path " + d.topPath + ", not " + key(cur));
        }
        break;
      }
      Path parent = cur.getParent();
      if (isRoot(parent)) {
        throw new IOException("the folder " + cur + " claims a parent folder but is at the top");
      }
      AttestedFolderCodec.Decoded pd = read(parent);
      if (pd == null) {
        throw new IOException("the parent folder " + parent + " has no identity");
      }
      if (!Arrays.equals(d.parentId, pd.folderId)) {
        throw new IOException("the identity in " + cur + " points to another parent folder than " + parent);
      }
      cur = parent;
      d = pd;
    }
    synchronized (cache) {
      Entry e = cache.get(key(dir));
      if (e != null) {
        e.chainId = first.folderId;
        e.chainAt = now;
      }
    }
    return first.folderId;
  }

  /**
   * After a folder was renamed (its identity file moved with it): signs its identity again with the new name and the new parent (or
   * path). The folder keeps its ID, so the records of the files inside stay valid and nothing below is touched.
   */
  void resign(Path newDir, AttestedFolderCodec.Decoded old) throws IOException {
    Path idPath = identityPath(newDir);
    Path parent = newDir.getParent();
    AttestedFolderCodec.Decoded pd = isRoot(parent) ? null : ensure(parent);
    byte[] bytes = pd != null ? sigs.encodeFolder(old.folderId, newDir.getName(), pd.folderId, null)
        : sigs.encodeFolder(old.folderId, newDir.getName(), null, newDir.toUri().getPath());
    forgetTree(newDir);
    audit.log("DELETE", idPath, null, "recursive=false folder-identity");
    fs.delete(idPath, false);
    audit.log("CREATE", idPath, null, "folder-identity resigned");
    try (FSDataOutputStream out = fs.create(idPath, false)) {
      out.write(bytes);
    }
  }
}
