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

import java.util.List;

import org.apache.hadoop.conf.Configuration;

/**
 * Where the wrapper's own settings may come from (step A3).
 *
 * <p>A job can carry settings of its own: in its job file, in a {@code -D} on the
 * command line, or set by code. If the wrapper obeyed those, a job could switch off
 * hashing or the checking of reads. So a setting counts only when the <b>site
 * configuration</b> (core-site.xml) is the last place that set it. A setting that
 * came from anywhere else is ignored, the secure default is used, and the setting
 * and its source are written to the audit log ({@code ignored=} in the INIT line).
 *
 * <p>The two log-folder settings (attested.audit.dir and attested.records.dir) are not
 * covered: our scripts pass them with -D, and a job that moves its logs is caught by
 * the audit, which expects the log of every host in the standard folder.
 *
 * <p>This is about unmeasured settings, not about code: code inside the JVM can
 * do anything, which is why the job file is measured and the driver is fixed
 * (steps 4.6 and 5.3). The check goes by the resource name Hadoop records for the
 * setting, so a job that put its own file named core-site.xml first on the class
 * path would also be replacing our own classes; that is closed by the measured
 * job, not here.
 */
final class AttestedSettings {

  /** Tests set this to feed the wrapper settings from code. Package-private on purpose. */
  private static volatile boolean trustAll = false;

  private AttestedSettings() {
  }

  static void trustAllSourcesForTesting(boolean on) {
    trustAll = on;
  }

  /** True when a setting whose last source is {@code source} may be obeyed. */
  static boolean trusted(String source) {
    if (trustAll) {
      return true;
    }
    return source != null
        && (source.endsWith("core-site.xml") || source.equals("core-default.xml"));
  }

  /**
   * True when the key is unset, or was last set by a trusted source. If not, the
   * rejected setting is noted in {@code ignored} (when given) and false is returned.
   */
  static boolean accepted(Configuration conf, String key, List<String> ignored) {
    String[] sources = conf.getPropertySources(key);
    if (sources == null || sources.length == 0) {
      return true;
    }
    String last = sources[sources.length - 1];
    if (trusted(last)) {
      return true;
    }
    if (ignored != null) {
      ignored.add(key + "<-" + last);
    }
    return false;
  }

  static boolean getBoolean(Configuration conf, String key, boolean def,
      List<String> ignored) {
    return accepted(conf, key, ignored) ? conf.getBoolean(key, def) : def;
  }

  static long getLong(Configuration conf, String key, long def,
      List<String> ignored) {
    return accepted(conf, key, ignored) ? conf.getLong(key, def) : def;
  }

  static String get(Configuration conf, String key, String def,
      List<String> ignored) {
    return accepted(conf, key, ignored) ? conf.get(key, def) : def;
  }
}
