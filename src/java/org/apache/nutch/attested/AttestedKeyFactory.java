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
import java.nio.file.Paths;
import java.time.Instant;
import java.util.List;
import org.apache.hadoop.conf.Configuration;

/**
 * Chooses where the wrapper's keys come from (step 5.1.3). The default is the test key of step 5.1.1, read by the file system
 * as before. With attested.keys.provider=service, signing is done by the signing service on this machine (KeyService) and the
 * public keys that are trusted come from the key list. All these settings are read from core-site.xml only (ADR-039).
 */
final class AttestedKeyFactory {
  static final String PROVIDER_KEY = "attested.keys.provider";
  static final String SERVICE_ADDRESS_KEY = "attested.keys.service.address";
  static final String SERVICE_TOKEN_FILE_KEY = "attested.keys.service.token.file";
  static final String SERVICE_TIMEOUT_KEY = "attested.keys.service.timeout.millis";
  static final String LIST_DIR_KEY = "attested.keys.list.dir";
  static final String LIST_CACHE_KEY = "attested.keys.list.cache.seconds";
  static final String LIST_ALLOW_UNQUOTED_KEY = "attested.keys.list.allow.unquoted";
  static final String LIST_CHECK_CLASS_KEY = "attested.keys.list.check.class";
  static final String LIST_AUDIT_FILE_KEY = "attested.keys.list.audit.file";
  static final String ADMISSION_ENABLED_KEY = "attested.keys.admission.enabled";
  static final String ADMISSION_REFERENCE_KEY = "attested.keys.admission.reference.file";
  static final String ADMISSION_REFERENCE_SHA_KEY = "attested.keys.admission.reference.sha256";
  static final String ADMISSION_ENFORCE_KEY = "attested.keys.admission.enforce";
  static final String ADMISSION_ROOT_KEY = "attested.keys.admission.root.sha256";
  static final String ADMISSION_DATES_KEY = "attested.keys.admission.check.dates";

  /** The clock of the quote admission (the validity dates of the certificates); tests set it. */
  static java.util.function.Supplier<Instant> clock = Instant::now;

  private AttestedKeyFactory() {
  }

  /** Both checks, in order; either may be null. */
  static BundleCheck both(BundleCheck first, BundleCheck second) {
    if (second == null) {
      return first;
    }
    if (first == null) {
      return second;
    }
    return new BundleCheck() {
      @Override
      public void check(KeyBundle b) throws IOException {
        first.check(b);
        second.check(b);
      }

      @Override
      public String note(KeyBundle b) {
        return (first.note(b) + " " + second.note(b)).trim();
      }
    };
  }

  /** "test" (the default) or "service". */
  static String provider(Configuration conf, List<String> ignored) throws IOException {
    String p = AttestedSettings.get(conf, PROVIDER_KEY, "test", ignored).trim().toLowerCase();
    if (!p.equals("test") && !p.equals("service")) {
      throw new IOException(PROVIDER_KEY + " must be test or service, got " + p);
    }
    return p;
  }

  /** The keys of the service provider; signing is possible only when an address is set. */
  static ServiceKeys service(Configuration conf, boolean signOn, List<String> ignored) throws IOException {
    String home = System.getProperty("user.home");
    Path listDir = Paths.get(AttestedSettings.get(conf, LIST_DIR_KEY, home + "/tc-keys/list", ignored).trim());
    long ttl = AttestedSettings.getLong(conf, LIST_CACHE_KEY, 10, ignored);
    if (ttl < 0) {
      throw new IOException(LIST_CACHE_KEY + " must not be negative, got " + ttl);
    }
    boolean unquoted = AttestedSettings.getBoolean(conf, LIST_ALLOW_UNQUOTED_KEY, false, ignored);
    BundleCheck extra = null;
    String cls = AttestedSettings.get(conf, LIST_CHECK_CLASS_KEY, "", ignored).trim();
    if (!cls.isEmpty()) {
      try {
        java.lang.reflect.Constructor<?> c = Class.forName(cls).getDeclaredConstructor();
        c.setAccessible(true);
        extra = (BundleCheck) c.newInstance();
      } catch (ReflectiveOperationException | ClassCastException e) {
        throw new IOException(LIST_CHECK_CLASS_KEY + " names a class that cannot be used as a bundle check: " + cls + " (" + e + ")");
      }
    }
    if (AttestedSettings.getBoolean(conf, ADMISSION_ENABLED_KEY, false, ignored)) {
      String ref = AttestedSettings.get(conf, ADMISSION_REFERENCE_KEY, "", ignored).trim();
      if (ref.isEmpty()) {
        throw new IOException(ADMISSION_REFERENCE_KEY + " is needed when " + ADMISSION_ENABLED_KEY + " is true");
      }
      AdmissionReference reference = AdmissionReference.load(Paths.get(ref), AttestedSettings.get(conf, ADMISSION_REFERENCE_SHA_KEY, "", ignored).trim());
      BundleCheck admission = new QuoteAdmission(reference, QuoteAdmission.registers(AttestedSettings.get(conf, ADMISSION_ENFORCE_KEY, QuoteAdmission.DEFAULT_ENFORCE, ignored)),
          QuoteAdmission.rootList(AttestedSettings.get(conf, ADMISSION_ROOT_KEY, QuoteAdmission.INTEL_SGX_ROOT_SHA256, ignored)),
          AttestedSettings.getBoolean(conf, ADMISSION_DATES_KEY, true, ignored), () -> clock.get());
      extra = both(admission, extra);
    }
    KeyList list = new KeyList(listDir, unquoted, extra, ttl);
    Path auditFile = Paths.get(AttestedSettings.get(conf, LIST_AUDIT_FILE_KEY, listDir.toAbsolutePath().getParent() == null ? "keylist-audit.log"
        : listDir.toAbsolutePath().getParent().resolve("keylist-audit.log").toString(), ignored).trim());
    list.setSink(line -> {
      try {
        Files.write(auditFile, (Instant.now() + " " + line + "\n").getBytes(StandardCharsets.UTF_8), java.nio.file.StandardOpenOption.CREATE, java.nio.file.StandardOpenOption.APPEND);
      } catch (IOException e) {
        // the audit file is for people; the list does not depend on it
      }
    });
    String address = AttestedSettings.get(conf, SERVICE_ADDRESS_KEY, "", ignored).trim();
    if (address.isEmpty()) {
      if (signOn) {
        throw new IOException(SERVICE_ADDRESS_KEY + " is needed for signing with the service provider");
      }
      return new ServiceKeys(null, 0, null, list, 0);
    }
    int colon = address.lastIndexOf(':');
    if (colon <= 0 || colon == address.length() - 1) {
      throw new IOException(SERVICE_ADDRESS_KEY + " must be HOST:PORT, got " + address);
    }
    int port;
    try {
      port = Integer.parseInt(address.substring(colon + 1));
    } catch (NumberFormatException e) {
      throw new IOException(SERVICE_ADDRESS_KEY + " has a bad port: " + address);
    }
    Path tokenFile = Paths.get(AttestedSettings.get(conf, SERVICE_TOKEN_FILE_KEY, home + "/tc-keyservice/token", ignored).trim());
    if (!Files.isReadable(tokenFile)) {
      throw new IOException("the token file of the signing service is missing or unreadable: " + tokenFile);
    }
    String token = new String(Files.readAllBytes(tokenFile), StandardCharsets.US_ASCII).trim();
    int timeout = (int) AttestedSettings.getLong(conf, SERVICE_TIMEOUT_KEY, 5000, ignored);
    ServiceKeys keys = new ServiceKeys(address.substring(0, colon), port, token, list, timeout);
    if (signOn && keys.signingKeyId() == null) {
      throw new IOException("signing is on but the signing service does not answer: " + keys.lastError());
    }
    return keys;
  }
}
