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
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.regex.Pattern;

/**
 * Which hosts may join the mesh and at which address (step 5.2.2): a plain text file, one line per host, HOST MESH_IP [VPC_IP]. The mesh address is decided by this table, not by the node: a node cannot
 * claim another's address. The VPC address (optional) is where the peer's WireGuard endpoint is reached. Lines that start with # and empty lines are ignored; a host or an address twice is refused.
 */
final class MeshPolicy {
  private static final Pattern HOST = Pattern.compile("[A-Za-z0-9._-]{1,63}");
  private static final Pattern IP = Pattern.compile("(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])(\\.(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])){3}");

  private final Map<String, String[]> byHost = new LinkedHashMap<>();

  static MeshPolicy load(Path file) throws IOException {
    String[] lines;
    try {
      lines = new String(Files.readAllBytes(file), StandardCharsets.UTF_8).split("\\r?\\n", -1);
    } catch (IOException e) {
      throw new IOException("the mesh policy file cannot be read: " + file + " (" + e.getMessage() + ")");
    }
    MeshPolicy p = new MeshPolicy();
    int n = 0;
    for (String line : lines) {
      n++;
      String t = line.trim();
      if (t.isEmpty() || t.startsWith("#")) {
        continue;
      }
      String[] f = t.split("\\s+");
      if (f.length < 2 || f.length > 3) {
        throw new IOException("mesh policy line " + n + ": expected HOST MESH_IP [VPC_IP], got " + f.length + " field(s)");
      }
      if (!HOST.matcher(f[0]).matches()) {
        throw new IOException("mesh policy line " + n + ": bad host " + f[0]);
      }
      if (!IP.matcher(f[1]).matches() || (f.length == 3 && !IP.matcher(f[2]).matches())) {
        throw new IOException("mesh policy line " + n + ": bad address");
      }
      if (p.byHost.containsKey(f[0])) {
        throw new IOException("mesh policy line " + n + ": the host " + f[0] + " is listed twice");
      }
      for (String[] e : p.byHost.values()) {
        if (e[0].equals(f[1])) {
          throw new IOException("mesh policy line " + n + ": the mesh address " + f[1] + " is given to two hosts");
        }
      }
      p.byHost.put(f[0], new String[] {f[1], f.length == 3 ? f[2] : ""});
    }
    if (p.byHost.isEmpty()) {
      throw new IOException("the mesh policy file lists no host: " + file);
    }
    return p;
  }

  boolean hasHost(String host) {
    return byHost.containsKey(host);
  }

  String meshIp(String host) {
    String[] e = byHost.get(host);
    return e == null ? null : e[0];
  }

  /** The VPC address of the host, or the empty string. */
  String vpcIp(String host) {
    String[] e = byHost.get(host);
    return e == null ? "" : e[1];
  }

  int size() {
    return byHost.size();
  }
}
