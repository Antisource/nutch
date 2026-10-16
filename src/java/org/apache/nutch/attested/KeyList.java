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
import java.nio.file.DirectoryStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.PublicKey;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.function.Consumer;

/**
 * The public keys that this machine trusts for records: a folder of key bundles (*.attestkey), each of which must pass
 * the binding check of KeyBundle and the extra BundleCheck, if any. A key without a quote (SVC-) is accepted only when
 * allowed. The folder is read again when it is older than the cache time. Step 5.2.1 replaces the manual filling of the
 * folder by an admission that verifies the quotes; the extra check is where that verification plugs in.
 */
final class KeyList {
  private final Path dir;
  private final boolean allowUnquoted;
  private final BundleCheck extra;
  private final long ttlMillis;
  private volatile Map<String, KeyBundle> keys = Collections.emptyMap();
  private volatile List<String> rejected = Collections.emptyList();
  private volatile long loadedAt = -1;
  private volatile Consumer<String> sink;
  private final Set<String> reported = new HashSet<>();

  KeyList(Path dir, boolean allowUnquoted, BundleCheck extra, long ttlSeconds) {
    this.dir = dir;
    this.allowUnquoted = allowUnquoted;
    this.extra = extra;
    this.ttlMillis = ttlSeconds * 1000L;
  }

  /** Where the list reports each admission and each rejection (once per state), for the audit; null for no report. */
  void setSink(Consumer<String> sink) {
    this.sink = sink;
  }

  private void report(String line) {
    Consumer<String> s = sink;
    if (s == null) {
      return;
    }
    synchronized (reported) {
      if (!reported.add(line)) {
        return;
      }
    }
    try {
      s.accept(line);
    } catch (RuntimeException e) {
      // the report is for people; the list does not depend on it
    }
  }

  /** The public key of a trusted key id, or null. */
  PublicKey publicKey(String keyId) {
    KeyBundle b = bundle(keyId);
    return b == null ? null : b.publicKey;
  }

  KeyBundle bundle(String keyId) {
    long now = System.currentTimeMillis();
    if (loadedAt < 0 || now - loadedAt >= ttlMillis) {
      refresh();
    }
    return keys.get(keyId);
  }

  /** Why the files that were not accepted were refused (file name and reason), after the last reading. */
  List<String> rejected() {
    return rejected;
  }

  int size() {
    return keys.size();
  }

  synchronized void refresh() {
    Map<String, KeyBundle> found = new HashMap<>();
    List<String> bad = new ArrayList<>();
    if (Files.isDirectory(dir)) {
      try (DirectoryStream<Path> files = Files.newDirectoryStream(dir, "*" + KeyBundle.FILE_SUFFIX)) {
        for (Path f : files) {
          try {
            KeyBundle b = KeyBundle.decode(Files.readAllBytes(f));
            b.checkBinding();
            if (!b.hasQuote() && !allowUnquoted) {
              throw new IOException("a key without a quote is not accepted here (" + b.keyId + ")");
            }
            if (extra != null) {
              extra.check(b);
            }
            if (!f.getFileName().toString().equals(b.keyId + KeyBundle.FILE_SUFFIX)) {
              throw new IOException("the file name does not say the key id " + b.keyId);
            }
            found.put(b.keyId, b);
            report("ADMIT key=" + b.keyId + " host=" + b.host + (extra == null ? "" : " " + extra.note(b)));
          } catch (IOException e) {
            bad.add(f.getFileName() + ": " + e.getMessage());
            report("REJECT file=" + f.getFileName() + " reason=" + String.valueOf(e.getMessage()).replace('\n', ' '));
          }
        }
      } catch (IOException e) {
        bad.add(dir + ": " + e.getMessage());
      }
    } else {
      bad.add(dir + ": the key list folder does not exist");
    }
    keys = found;
    rejected = bad;
    loadedAt = System.currentTimeMillis();
  }
}
